import Combine
import AVFoundation
import CoreFoundation
import Foundation

/// 可注入假的 Pod；自測不啟動瀏覽器、不讀登入資料、不連外。
@MainActor
protocol ChatGPTPodTransport: AnyObject {
    var onEvent: ((String) -> Void)? { get set }
    var isRunning: Bool { get }
    var isHosted: Bool { get }
    var isClosing: Bool { get }
    func waitUntilClosed(timeout: Duration) async throws
    func start() throws
    func stop()
    func run(_ script: String)
    func setSpaceVisible(_ visible: Bool)
    func setBackgroundWorkActive(_ active: Bool)
    var onDisplayFrame: ((String?, UInt64, Bool, Int) -> Void)? { get set }
    func displayPage(_ javascript: String) throws
    func restoreDisplayedPage(_ url: URL)
    var displayGeneration: UInt64 { get }
}

extension ChatGPTPodTransport {
    var isClosing: Bool { false }
    func waitUntilClosed(timeout: Duration) async throws {}
    func setSpaceVisible(_ visible: Bool) {}
    func setBackgroundWorkActive(_ active: Bool) {}
    var onDisplayFrame: ((String?, UInt64, Bool, Int) -> Void)? { get { nil } set {} }
    func displayPage(_ javascript: String) throws { throw TapPodError.profileUnavailable }
    func restoreDisplayedPage(_ url: URL) {}
    var displayGeneration: UInt64 { 0 }
}

extension TapWebPod: ChatGPTPodTransport {}

/// TAP 的第一座 Tap：ChatGPT（W177，使用者 2026-09-24「接入真正的chatgpt 以chatgpt的訂閱方式來聊天 而不是耗codex額度」）。
/// Pod＝OS 瀏覽器核心裡看不見的 chatgpt.com（自己的登入空間）。讀清單、讀對話、讀模型直接用網頁自己的登入標頭；
/// 送出一律在網頁自己的輸入框送（網頁自己做 sentinel 安全檢查），回答的串流由腳本複製一份轉回 App。
/// 2026-09-24 驗證（staging v2.0.19.001）：不被 Cloudflare 擋、清單 28/29、模型 23 個、首段 0.8 秒。
/// 權杖只存在 Pod 網頁的記憶體裡：腳本不回報、App 不寫檔、不進記錄。
@MainActor
final class ChatGPTTap: ObservableObject, ConversationTap {
    static let shared = ChatGPTTap()
    /// Pod 自己的 CEF 設定檔（不跟 OS 瀏覽器共用：一個設定檔同時只能給一個宿主，也符合 TAP 登入各自隔離）。
    static let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000177")!
    static let enabledKey = "tatwo.tap.chatgpt.enabled"
    static let homeURL = URL(string: "https://chatgpt.com/")!

    let tapID = "chatgpt"
    let displayName = "ChatGPT"
    let podKindTitle = "網頁艙"
    @Published private(set) var isLoggedIn = false
    @Published private(set) var connection: TapConnection = .off {
        didSet {
            if connection == .ready { isLoggedIn = true }
            if connection == .needsLogin {
                isLoggedIn = false
                if storesReadiness { UserDefaults.standard.removeObject(forKey: Self.readyOnceKey) }
            }
            guard connection != oldValue else { return }
            // W184 G3 第三輪（修正核對 #2）：連線狀態變了（要登入、重新連上、Pod 重開）而沒人拿著語音＝語音旗標歸零，
            // 不讓一個沒人拿著的旗標擋住兩邊的語音、［連線］、「新增」。
            if voiceClaim == nil {
                voiceOpen = false
                voiceSeenLive = false
            }
            // 重新連上：排著的送出（例如語音那一頁關掉重開時留下來的）接著送。
            if connection == .ready { drainQueue() }
        }
    }
    @Published private(set) var recoveryNotice: String?
    static let stopRecoveryNotice = "ChatGPT 停止時沒有即時回應，已重新整理；下次送出會自動啟動"

    /// 最近一次送出的串流格式（只有事件名稱與欄位名稱，沒有內容）；設定 › Plugin › TAP 顯示，給診斷用。
    @Published private(set) var lastStreamShape: String?
    /// 最近一次送出時，串流本身解析得到文字（false＝靠網頁畫面備援）。
    @Published private(set) var lastStreamParsed = false
    /// 網頁自己實際會用的模型與強度選項（看到網頁送出請求時回報）；選單沒特別選時照這個顯示。
    @Published private(set) var pageSelection: (model: String, effort: String?)?
    var pod: TapWebPod {
        guard let pod = transport as? TapWebPod else { preconditionFailure("Fake Pod has no web view") }
        return pod
    }
    private let transport: any ChatGPTPodTransport
    var webPod: TapWebPod? { transport as? TapWebPod }
    @Published private(set) var dotsState: ChatGPTDotsState = .closed
    private enum PodHolder: Equatable {
        case connector(UUID), menu(UUID), voice(VoiceClaim), dots(UUID)
        var lease: UUID? {
            switch self { case .connector(let id), .menu(let id), .dots(let id): id; case .voice: nil }
        }
        var voiceClaim: VoiceClaim? { if case .voice(let claim) = self { claim } else { nil } }
        var queuesSend: Bool { if case .connector = self { false } else { true } }
    }
    @Published private var podHolder: PodHolder?
    private var dotsLease: UUID? { if case .dots(let id) = podHolder { id } else { nil } }
    var voiceClaims: AnyPublisher<VoiceClaim?, Never> { $podHolder.map { $0?.voiceClaim }.eraseToAnyPublisher() }
    private func releasePodHolder() {
        let lease = podHolder?.lease
        podHolder = nil
        if let lease { releaseLease(lease) }
    }
    private var dotsReturning = false
    private var dotsReturnWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var dotsReturnURL = ChatGPTTap.homeURL
    private var dotsDeadline: Task<Void, Never>?
    private var dotsGeneration: UInt64 = 0
    private var dotsOpenEpoch = 0
    private let storesReadiness: Bool
    var voiceMicrophonePermission: @MainActor () async -> Bool
    /// 麥克風允許後、送出網頁啟動前；持有者核對 claim 與 session。
    var voiceReadyToStart: @MainActor (VoiceClaim) -> Void = { _ in }
    private var results: [String: CheckedContinuation<Any, Error>] = [:]
    private var streams: [String: AsyncStream<TapStreamEvent>.Continuation] = [:]
    /// 網頁回過「收到了」的送出（沒回的 60 秒後判定失敗）。
    private var acceptedStreams: Set<String> = []
    /// 與「交給 Pod／有回應」分開：網站已出現送出證據後，絕不能把失敗還原成可重送草稿。
    private var websiteSubmittedStreams: Set<String> = []
    private struct QueuedSend {
        let id: String
        let script: String
        let silence: Duration
        /// W184 G3 第三輪：送出內容本身（Pod 重開會換鑰匙，出隊時用現在的鑰匙重新組指令）。
        let payload: [String: Any]
    }
    private var sendQueue: [QueuedSend] = []
    private var activeRequestID: String?
    private var stoppingRequestID: String?
    private var stopAcknowledgementID: String?
    private var streamWatchdog: Task<Void, Never>?
    private var stopWatchdog: Task<Void, Never>?
    private var leases: Set<UUID> = []
    private var backgroundWorkLeases: Set<UUID> = []
    /// Coder 尚未建立串流，但已經有送出在等網頁就緒。
    private var readinessWaiters = 0
    @Published private(set) var usageCount = 0
    var hasActiveUsers: Bool { usageCount > 0 }
    private var startGeneration = 0
    private var idleSleep: Task<Void, Never>?
    private var idleSleepDelay: Duration = .seconds(15 * 60)
    /// 測試可縮短；正式值仍保留附件 150 秒／普通 60 秒的未回應期限。
    private let silenceOverride: Duration?
    private var streamActivity: [String: ContinuousClock.Instant] = [:]
    private static let noProgressMessage = "ChatGPT 3 分鐘沒有任何進度，這句可能沒有完成"
    private let progressSilence: Duration
    private let stopDeadline: Duration
    /// W184 G3 第三輪：排在語音後面（或語音那一頁重開還沒好）的送出最多等多久；過了就不送，交回畫面放回輸入框。
    private let voiceQueueLimit: Duration
    private let startupTimeout: Duration

    private convenience init() {
        self.init(transport: TapWebPod(podID: "chatgpt", profileID: Self.profileID, homeURL: Self.homeURL, script: Self.podScript),
                  connection: Self.isEnabled ? .sleeping : .off, storesReadiness: true)
    }

    init(transport: any ChatGPTPodTransport, connection: TapConnection = .ready, storesReadiness: Bool = false,
         silenceOverride: Duration? = nil,
         progressSilence: Duration = .seconds(180),
         stopDeadline: Duration = .seconds(15), voiceQueueLimit: Duration = .seconds(20),
         startupTimeout: Duration = .seconds(60)) {
        self.transport = transport
        self.connection = connection
        self.storesReadiness = storesReadiness
        self.isLoggedIn = connection == .ready || (storesReadiness && Self.hasBeenReady && connection != .needsLogin)
        self.voiceMicrophonePermission = storesReadiness ? { await Self.requestMicrophone() } : { true }
        self.silenceOverride = silenceOverride
        self.progressSilence = progressSilence
        self.stopDeadline = stopDeadline
        self.voiceQueueLimit = voiceQueueLimit
        self.startupTimeout = startupTimeout
        transport.onEvent = { [weak self] json in self?.receive(json) }
        transport.setSpaceVisible(false)
        transport.setBackgroundWorkActive(false)
        transport.onDisplayFrame = { [weak self] url, generation, loading, status in
            guard let self, self.dotsLease != nil, !self.dotsReturning, !loading,
                  generation > self.dotsGeneration, self.dotsState != .unavailable,
                  let url, url != "about:blank" else { return }
            self.dotsState = ChatGPTDotsState.loaded(url: url, status: status)
        }
    }

    /// W197：同一個 Pod 暫借給人看 Dots；所有 TAP 讀取與換頁暫停，送出照舊排隊。
    func openDots(returnURL: URL) async {
        guard dotsLease == nil || dotsReturning else { return }
        dotsOpenEpoch += 1
        let epoch = dotsOpenEpoch
        dotsState = .loading
        var ownsLease = false
        do {
            // 快速返回再打開也先等原頁恢復；不搶上一份還在交還的租約。
            try await waitForDotsReturn()
            guard epoch == dotsOpenEpoch else { return }
            try await readyForSend()
            try Task.checkCancellation()
            guard epoch == dotsOpenEpoch else { return }
            guard podHolder == nil, !voiceOpen,
                  streams.isEmpty, results.isEmpty, pageRequests == 0, backgroundWorkLeases.isEmpty,
                  readinessWaiters == 0, activeRequestID == nil, stoppingRequestID == nil else {
                dotsState = .blocked("ChatGPT 正在忙，等它結束再開 Dots")
                return
            }
            guard returnURL.scheme == "https", returnURL.host == "chatgpt.com" else { throw TapPodError.profileUnavailable }
            dotsReturnURL = returnURL
            dotsReturning = false
            podHolder = .dots(acquireLease())
            ownsLease = true
            dotsGeneration = transport.displayGeneration
            try transport.displayPage("if(location.host==='chatgpt.com'){window.name='__tatwoDotsDisplay';location.replace('https://chatgpt.com/dots');}")
            dotsDeadline?.cancel()
            dotsDeadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, self.dotsLease != nil, !self.dotsReturning, self.dotsState == .loading else { return }
                self.dotsState = .blocked("Dots 還沒打開，請稍後再試")
            }
        } catch {
            guard epoch == dotsOpenEpoch else { return }
            if ownsLease { releaseDotsLease() }
            dotsState = Task.isCancelled ? .closed : .blocked("ChatGPT 還沒連上，請稍後再試")
        }
    }

    func closeDots() {
        dotsOpenEpoch += 1
        dotsState = .closed
        guard !dotsReturning else { return }
        dotsDeadline?.cancel()
        guard dotsLease != nil else { return }
        dotsReturning = true
        if let dotsLease { backgroundWorkLeases.insert(dotsLease); updateUsage() }
        var target = URLComponents(url: dotsReturnURL, resolvingAgainstBaseURL: false)!
        target.fragment = "tatwo-dots-return"
        transport.restoreDisplayedPage(target.url!)
        // 重新載入原頁、收到新文件 hello 才放行；舊頁沒有擷取器，也不能收送出。
        dotsDeadline = Task { @MainActor [weak self, startupTimeout] in
            do { try await Task.sleep(for: startupTimeout) } catch { return }
            guard let self, self.dotsReturning else { return }
            self.sleep()
        }
    }

    private func waitForDotsReturn() async throws {
        guard dotsReturning else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { waiter.resume(throwing: CancellationError()) }
                else if dotsReturning { dotsReturnWaiters[id] = waiter }
                else { waiter.resume() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.dotsReturnWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
        try Task.checkCancellation()
    }

    private func releaseDotsLease() {
        dotsDeadline?.cancel()
        dotsDeadline = nil
        dotsReturning = false
        let waiters = dotsReturnWaiters; dotsReturnWaiters.removeAll()
        for waiter in waiters.values { waiter.resume() }
        if dotsLease != nil { releasePodHolder() }
    }

    /// 登入過（連上過）一次：之後 App 一開就在背景先準備好（新裝的、從沒用過的不預熱）。
    static let readyOnceKey = "tatwo.tap.chatgpt.readyOnce"
    static var hasBeenReady: Bool { UserDefaults.standard.bool(forKey: readyOnceKey) }

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    func setEnabled(_ enabled: Bool) {
        Self.isEnabled = enabled
        if enabled { start() } else { sleep(); connection = .off }
    }

    /// 用到時才開；已經在跑就不動。
    func start() {
        guard !storesReadiness || Self.isEnabled else { connection = .off; return }
        guard !transport.isRunning, connection != .starting else { return }
        startGeneration += 1
        let generation = startGeneration
        connection = .starting
        updateUsage()
        Task { @MainActor [weak self, startupTimeout] in
            do { try await Task.sleep(for: startupTimeout) } catch { return }
            guard let self, self.startGeneration == generation, self.connection == .starting else { return }
            // 關掉未報到的舊網頁；回稿後下一次送出可以重新喚醒。
            self.transport.stop()
            self.connection = .sleeping
            self.failPending("ChatGPT 啟動逾時，這句尚未送出；草稿已保留")
        }
        if transport.isClosing {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.transport.waitUntilClosed(timeout: .seconds(20))
                    guard self.startGeneration == generation, self.connection == .starting else { return }
                    self.startPreparedTransport()
                } catch {
                    guard self.startGeneration == generation, self.connection == .starting else { return }
                    self.connection = .failed("ChatGPT 網頁艙尚未關閉")
                    self.failPending("ChatGPT 重新啟動未完成，這句尚未送出；草稿已保留")
                }
            }
        } else {
            startPreparedTransport()
        }
    }

    private func startPreparedTransport() {
        // 對話內容不落地：每次開 App 第一次啟動前清掉上次留下的瀏覽器快取（登入不動）。
        if storesReadiness {
            TapPodStorage.purgeHTTPCacheOnce(profileID: Self.profileID)
            do {
                // W183 R9 審查（GPT-6 #3）：每次建立 Pod（新的瀏覽器）換一把鑰匙；換不掉腳本裡的佔位字＝Pod 不開（scriptRejected）。
                let key = Self.makePodKey()
                podKey = key
                try pod.start(script: Self.keyedPodScript(key))
            } catch {
                connection = .failed(error.localizedDescription)
                failPending("ChatGPT 啟動失敗，這句尚未送出；草稿已保留")
                return
            }
        } else {
            do { try transport.start() }
            catch {
                connection = .failed(error.localizedDescription)
                failPending("ChatGPT 啟動失敗，這句尚未送出；草稿已保留")
                return
            }
        }
        updateUsage()
    }

    func logout() {
        start()
        Task { @MainActor in
            for _ in 0..<400 {
                if connection != .starting { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard transport.isRunning else { return }
            transport.restoreDisplayedPage(URL(string: "https://chatgpt.com/auth/logout")!)
        }
    }

    /// 收起 Pod 省記憶體；登入資料留著，下次開不用重登。
    func sleep() {
        dotsOpenEpoch += 1
        dotsState = .closed
        releaseDotsLease()
        startGeneration += 1
        idleSleep?.cancel()
        idleSleep = nil
        voiceOpen = false   // W183 R6b 審查：網頁關了，語音也沒了
        voiceSeenLive = false
        if voiceClaim != nil { releasePodHolder() }   // 網頁關了＝麥克風一定停了
        voiceHolderNotice = nil
        voiceEndRequest = nil
        transport.stop()
        connection = !storesReadiness || Self.isEnabled ? .sleeping : .off
        failPending("已休眠")
    }

    /// 畫面租約只防休眠；Coder 的背景工作租約另外保護建立串流之前的準備階段。
    @discardableResult
    func acquireLease(backgroundWork: Bool = false) -> UUID {
        let id = UUID()
        leases.insert(id)
        if backgroundWork { backgroundWorkLeases.insert(id) }
        updateUsage()
        return id
    }

    func releaseLease(_ id: UUID) {
        guard leases.remove(id) != nil else { return }
        backgroundWorkLeases.remove(id)
        updateUsage()
    }

    func setSpaceVisible(_ visible: Bool) {
        transport.setSpaceVisible(visible)
    }

    // MARK: W183 R6b：ChatGPT 手腳的連接器（使用者在私訊框按「連線」才用）

    /// 連接器流程獨占 Pod：聊天中不硬換頁（有一則正在送、語音開著、有會換頁的指令在跑就拿不到，等空檔）；拿著的時候新的送出先排隊、
    /// 會換頁的指令（語音、分支、分享、探查、換頁）一律拒絕（W183 R6b 審查：租約要蓋住所有會換頁或改表單的指令）。
    var connectorHold: UUID? { if case .connector(let id) = podHolder { id } else { nil } }
    /// 即時語音開著（開始到結束；W183 R6b 審查：語音中拿不到獨占，不會被連接器換頁切斷）。
    private(set) var voiceOpen = false
    private var voiceSeenLive = false

    // MARK: W184 G3：即時語音的擁有者（Pod 只有一個網頁、一個麥克風：ChatGPT Space 與私訊框先佔先用）

    /// 拿著即時語音的那一邊：哪一個 ChatGPTVoiceMode（owner）、第幾次（generation；晚到的回覆對不上就作廢）。
    struct VoiceClaim: Equatable, Sendable {
        let owner: UUID
        let generation: Int
    }
    /// 送出「開始語音」之前就佔住；確認麥克風停了（或 Pod 關掉）才放掉。兩邊的聲波鈕、開始、停止、晚到的回覆都看它。
    var voiceClaim: VoiceClaim? { podHolder?.voiceClaim }
    /// W184 G3b 第二輪（審查 #4、#5）：哪一則對話剛在 TAP 上送完一輪（ChatGPT Space、私訊框任一欄都算）：同一則開著的另一邊重讀正本，
    /// 清單裡還沒有它就重讀清單。只有對話代號與請求代號，沒有內容。
    @Published private(set) var conversationUpdate: TapConversationUpdate?
    /// 每個串流送的是哪一則（新對話等 ChatGPT 回報代號才知道）。臨時對話（不在紀錄裡）的不記、不通知。
    private var streamConversations: [String: String] = [:]
    private var temporaryStreams: Set<String> = []
    /// W184 G3c（GPT-6 審查 #1）：臨時的串流收到網頁艙「實際送出的內容確認帶了不存紀錄旗標」（kind temporary）的那幾個。
    private var temporaryConfirmed: Set<String> = []
    /// 臨時聊天沒收到網頁艙的確認，卻收到了送出之後才會有的事件（接受、對話代號、回答、完成）＝可能以一般對話送出了：當失敗、停下。
    static let temporaryUnconfirmedReason = "臨時聊天沒能確認帶上「不存紀錄」的旗標，已停下；這一則可能存進了 ChatGPT 的紀錄"
    private var conversationUpdateSerial = 0
    private var voiceGeneration = 0
    /// W184 G3 第三輪（修正核對 #1）：拿著語音的是哪一邊（給另一邊的一句說明，例如「ChatGPT Space 的語音模式還開著」）、
    /// 以及那一邊的「結束」（另一邊按「結束那邊的語音」時叫它；走那一邊自己的確認結束，畫面跟著收）。
    private(set) var voiceHolderNotice: String?
    private var voiceEndRequest: (@MainActor () -> Void)?
    /// 語音等不到結束、排著沒送出的那一則的原因（畫面看到這句就把它放回輸入框）。
    static let queueTimeoutReason = "語音模式一直開著，這則沒有送出"

    /// 現在不能開始即時語音的原因（nil＝可以）：沒連上、有人拿著語音、有回答在跑或排隊、有會換頁的指令、連接器或「新增」拿著 Pod。
    var voiceStartBlocker: String? {
        if connection != .ready { return "ChatGPT 還沒連上" }
        if voiceClaim != nil || voiceOpen { return "另一邊的語音模式還開著" }
        if !streams.isEmpty || activeRequestID != nil || stoppingRequestID != nil || !sendQueue.isEmpty || pageRequests > 0 {
            return "ChatGPT 正在回答；等它結束再開語音"
        }
        if podHolder != nil { return "ChatGPT 正在處理別的事；等一下再開語音" }
        return nil
    }

    /// 佔住即時語音（拿不到＝nil）。在第一個 await 之前呼叫，兩邊不會同時開始。
    /// holderNotice：給另一邊看的一句話；onEndRequest：另一邊請這一邊結束時叫的（這一邊自己的確認結束）。
    func claimVoice(owner: UUID, holderNotice: String? = nil, onEndRequest: (@MainActor () -> Void)? = nil) -> VoiceClaim? {
        guard voiceStartBlocker == nil else { return nil }
        voiceGeneration += 1
        let claim = VoiceClaim(owner: owner, generation: voiceGeneration)
        voiceHolderNotice = holderNotice
        voiceEndRequest = onEndRequest
        podHolder = .voice(claim)
        updateUsage()
        return claim
    }

    /// 放掉（只放自己的；別人的不動）。放掉＝確認停了、或網頁已經換過一份：語音旗標一定清（連線不是 ready 也一樣；
    /// 修正核對 #2）。放掉後排隊的送出接著送。
    func releaseVoice(_ claim: VoiceClaim) {
        guard voiceClaim == claim else { return }
        releasePodHolder()
        voiceHolderNotice = nil
        voiceEndRequest = nil
        voiceOpen = false
        voiceSeenLive = false
        updateUsage()
        drainQueue()
    }

    /// 另一邊按「結束那邊的語音」：請拿著語音的那一邊走它自己的確認結束。沒人拿著、或拿著的那一邊沒給結束方法＝false。
    @discardableResult
    func requestVoiceEnd() -> Bool {
        guard voiceClaim != nil, let voiceEndRequest else { return false }
        voiceEndRequest()
        return true
    }

    /// 結束語音的結果：確認麥克風停了；或兩次都沒確認，關掉了語音那一頁（Pod）。
    enum VoiceEnd: Equatable { case confirmed, forced }

    /// 結束語音並確認：送結束、稍等、查狀態，不是 live 才算；兩輪都沒確認（網頁沒回、查到還在聽）就關掉語音那一頁——
    /// 網頁關了麥克風一定停（登入留著；有人看著就重開）。只結束自己拿著的語音；Pod 已經關了＝早就停了。
    /// seen：確認時網頁所在的那一則（語音一直拿著 Pod，別人換不了頁；新對話講完馬上結束、還沒看過編號時用）。
    func endVoice(claim: VoiceClaim, stopTimeout: Duration = .seconds(6), stateTimeout: Duration = .seconds(4),
                  pause: Duration = .milliseconds(400), seen: @MainActor (String) -> Void = { _ in }) async -> VoiceEnd {
        for _ in 0..<2 {
            guard voiceClaim == claim, connection == .ready, transport.isRunning else { return .confirmed }
            try? await voiceStop(claim: claim, timeout: stopTimeout)
            try? await Task.sleep(for: pause)
            guard voiceClaim == claim, connection == .ready, transport.isRunning else { return .confirmed }
            if let state = try? await voiceState(timeout: stateTimeout), !state.live {
                if voiceClaim == claim, let id = state.conversationID { seen(id) }
                return .confirmed
            }
        }
        guard voiceClaim == claim else { return .confirmed }
        forceEndVoice(claim)
        return .forced
    }

    /// 後備：關掉語音那一頁（Pod 休眠＝網頁關掉，麥克風一定停）。有人看著（租約）或有人在排隊就過一下重開。
    /// W184 G3 第三輪（修正核對 #6）：排在語音後面、還沒交給網頁的送出不丟——關頁前先拿出來，重開好（ready）照順序送；
    /// 重開一直沒好就照「排太久」交回畫面放回輸入框。
    func forceEndVoice(_ claim: VoiceClaim) {
        guard voiceClaim == claim else { return }
        let waiting = sendQueue.compactMap { item in streams[item.id].map { (item, $0) } }
        for (item, _) in waiting { streams[item.id] = nil }
        sendQueue.removeAll()
        let users = !leases.isEmpty || !waiting.isEmpty
        sleep()
        for (item, continuation) in waiting {
            streams[item.id] = continuation
            sendQueue.append(item)
            continuation.yield(.queued)
            scheduleQueueDeadline(item.id)
        }
        updateUsage()
        guard users else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.connection == .sleeping, !self.leases.isEmpty || !self.sendQueue.isEmpty else { return }
            self.start()
        }
    }

    /// 排在語音後面（或語音那一頁重開還沒好）太久：不送，交回畫面放回輸入框（queueTimeoutReason）。
    /// 排在別的回答後面照常等（那是一般的排隊，不在這裡算）。
    private func scheduleQueueDeadline(_ id: String) {
        Task { @MainActor [weak self, voiceQueueLimit] in
            try? await Task.sleep(for: voiceQueueLimit)
            guard let self, self.sendQueue.contains(where: { $0.id == id }),
                  self.voiceClaim != nil || self.dotsLease != nil || self.connection != .ready else { return }
            self.sendQueue.removeAll { $0.id == id }
            if self.dotsLease != nil {
                self.streams[id]?.yield(.notSubmitted("Dots 開著，這則沒有送出；返回後請手動送出"))
            } else { self.streams[id]?.yield(.failed(Self.queueTimeoutReason)) }
            self.finishStream(id)
        }
    }
    /// 還在跑、會換頁的指令數。
    private var pageRequests = 0
    /// 網頁腳本報到（hello）的次數：Pod 帶回首頁之後，等新的一份網頁報到才放行排隊的聊天。
    private(set) var helloCount = 0

    /// 會換頁（或切走網頁畫面）的指令：連接器獨占時一律不做。voice 的「結束」不算（讓語音能停）。
    static let pageCommands: Set<String> = ["voice", "branch", "share", "probe", "navigate", "pluginNewMenu"]   // W183 R9：pluginNewMenu 也會換頁

    /// 拿獨占（正在送一則、語音開著、有會換頁的指令在跑＝nil，呼叫端等一下再試）。
    /// W183 R9 審查（GPT-6 #9）：原生「新增 ▾」拿著 Pod 的操作租約（menuHold）時也拿不到（雙向）。
    func beginConnectorHold() -> UUID? {
        guard podHolder == nil, activeRequestID == nil, stoppingRequestID == nil, !voiceOpen,
              pageRequests == 0 else { return nil }
        let id = acquireLease()
        podHolder = .connector(id)
        return id
    }

    func endConnectorHold(_ id: UUID) {
        guard connectorHold == id else { return }
        releasePodHolder()
        drainQueue()   // 排隊的送出接著送
    }

    /// 只收連接器的那幾個指令（其他指令走各自的方法）。
    static let connectorCommands: Set<String> = ["connectorScan", "connectorDevMode", "connectorCreate", "connectorReconnect",
                                                 "connectorPress", "connectorConsent", "connectorHighlight", "connectorHome", "connectorSettings",
                                                 "connectorAbort", "connectorAccount", "connectorNavigated",
                                                 "connectorGesture",   // W183 R12（主導 2）：要真人點的那一顆指給他看（只標、不按）
                                                 "connectorOutline",   // W183 R12（.033 實機）：對不上時的結構快照（只讀；DOM 文字，不是截圖）
                                                 "connectorTick",   // W183 R12（.034 實機）：代勾的 DOM 驗證（量位置、點完看勾上了沒；不按）
                                                 "connectorInspect", "connectorDelete"]
    /// 只讀、不換頁、不改表單的：不用拿獨占。其他的一定要帶著目前的獨占（hold）才送。
    static let connectorReads: Set<String> = ["connectorDevMode", "connectorAccount"]

    func connectorRequest(_ command: String, _ arguments: [String: Any], hold: UUID?, timeout: Duration) async throws -> [String: Any] {
        guard Self.connectorCommands.contains(command) else { throw TapError.remote("unknown connector command") }
        if !Self.connectorReads.contains(command) {
            guard let hold, hold == connectorHold else { throw TapError.remote("ChatGPT 的連接器指令要先拿到獨占") }
        }
        return try await request(command, arguments, timeout: timeout) as? [String: Any] ?? [:]
    }

    /// W183 R9：原生外掛頁「新增 ▾」的三項（網頁腳本 pluginNewMenu 只收這三個字）。
    static let pluginNewMenuItems: Set<String> = ["plugin", "archive", "mcp"]

    // MARK: W183 R9 審查（GPT-6 #8、#9）：原生「新增 ▾」的 Pod 操作租約（跟連接器獨占同級）
    // 拿著的時候：聊天送出、重新產生先排隊（drainQueue 也看它）、會換頁的指令（語音、分支、分享、探查、換頁）一律拒絕、連線流程拿不到獨占；
    // 反過來：正在回答、語音中、連線流程拿著、有會換頁的指令在跑＝拿不到。對話框交給使用者之後照樣拿著，直到 ChatGPTPluginNewMenu 放掉
    // （分頁關掉、私訊框收起來、網頁的對話框關了、逾時、Pod 關了）。

    /// 拿著「新增 ▾」操作租約的那一次（nil＝沒有）。
    var menuHold: UUID? { if case .menu(let id) = podHolder { id } else { nil } }

    /// 現在拿不到租約的原因（一句話；nil＝拿得到）。
    var menuHoldBlocker: String? {
        if dotsLease != nil { return "Dots 還開著，先返回 ChatGPT" }
        if connection != .ready { return "ChatGPT 的網頁還沒準備好；等一下再按" }
        if connectorHold != nil { return "ChatGPT 正在連接 TATWO（私訊框）；等它完成再按" }
        if menuHold != nil { return "上一個「新增」還開著（私訊框 Browser 的 ChatGPT Dev 分頁）；先關掉那個對話框再按" }
        if activeRequestID != nil || stoppingRequestID != nil || voiceOpen || voiceClaim != nil || pageRequests > 0 {
            return "ChatGPT 正在回答（或在語音模式）；等它結束再按"
        }
        return nil
    }

    func beginMenuHold() -> UUID? {
        guard menuHoldBlocker == nil else { return nil }
        let id = acquireLease()
        podHolder = .menu(id)
        return id
    }

    func endMenuHold(_ id: UUID) {
        guard menuHold == id else { return }
        releasePodHolder()
        drainQueue()   // 排隊的送出接著送
    }

    /// 一次性操作序號（ChatGPTPluginNewMenu 每按一次發一個；網頁腳本用過就不再收）。
    static func validMenuOp(_ op: String) -> Bool {
        (8...64).contains(op.utf8.count) && op.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 }
    }

    /// W183 R9：Pod 到 /plugins、按「新增」、選那一項，只把網頁的對話框打開（不填、不勾、不按 Create）；「上傳外掛程式封存檔」只打開選單、
    /// 標出那一項（選檔要使用者自己按）。W183 R9 審查：要帶著目前的操作租約與這一次的操作序號。
    func pluginNewMenu(_ item: String, op: String, hold: UUID) async throws -> [String: Any] {
        guard Self.pluginNewMenuItems.contains(item) else { throw TapError.remote("unknown plugin menu item") }
        guard Self.validMenuOp(op) else { throw TapError.remote("bad plugin menu operation") }
        guard menuHold == hold else { throw TapError.remote("「新增」要先拿到 ChatGPT 的操作租約") }
        return try await request("pluginNewMenu", ["item": item, "op": op], timeout: .seconds(25), owner: hold) as? [String: Any] ?? [:]
    }

    /// 這一次打開的對話框（或選單）還開著嗎：true／false；nil＝問不到（網頁換了一份、Pod 關了、沒回）。
    func pluginNewMenuOpen(op: String, hold: UUID) async -> Bool? {
        guard menuHold == hold, Self.validMenuOp(op),
              let data = try? await request("pluginNewMenuWatch", ["op": op], timeout: .seconds(6), owner: hold) as? [String: Any],
              data["known"] as? Bool == true else { return nil }
        return data["open"] as? Bool
    }

    /// 撤銷這一次（還在找選單、按項目的會在下一個動作之前停手；標出的框拿掉）。不等回覆：馬上排進 Pod，放掉租約之前送。
    func abortPluginNewMenu(op: String) {
        guard connection == .ready, Self.validMenuOp(op),
              let script = try? keyedCommandScript(["cmd": "pluginNewMenuAbort", "id": UUID().uuidString, "op": op]) else { return }
        transport.run(script)
    }

    // MARK: W183 R9 審查（GPT-6 #3）：Pod 指令的鑰匙
    // App 每次建立 Pod（新的瀏覽器）產生一把隨機鑰匙：只在記憶體（不落地、不寫 log、不進狀態檔），換進腳本的閉包裡（網頁自己的程式讀不到）；
    // App 送的每一個 __tatwoPod.command 都帶它，腳本用 === 比對，不符＝安靜丟掉（不回任何結果）。
    // 殘餘（不宣稱已解）：同源的網頁程式本來就能自己點、自己填網頁；這一道擋的是它繞過原生的獨占、回答中、語音檢查叫 TATWO 的指令。

    /// 腳本裡的佔位字（只出現一次）。
    static let podKeyPlaceholder = "__TATWO_POD_KEY__"
    /// 現在這個 Pod 的鑰匙（自測的假 Pod 也有一把；真的 Pod 每次 start 換一把）。
    private var podKey = ChatGPTTap.makePodKey()

    /// 32 位元組的隨機數（系統的密碼學亂數），64 個小寫十六進位字。
    nonisolated static func makePodKey() -> String {
        var generator = SystemRandomNumberGenerator()
        let hex = Array("0123456789abcdef")
        return String((0..<32).flatMap { _ -> [Character] in
            let byte = UInt8.random(in: .min ... .max, using: &generator)
            return [hex[Int(byte >> 4)], hex[Int(byte & 0x0f)]]
        })
    }

    /// 換掉腳本裡唯一的佔位字；鑰匙不是 64 個小寫十六進位字、佔位字不是剛好一個、換完還在＝scriptRejected（Pod 不開）。
    static func keyedPodScript(_ key: String) throws -> String { try keyedPodScript(key, script: podScript) }

    static func keyedPodScript(_ key: String, script: String) throws -> String {
        guard key.utf8.count == 64, key.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else {
            throw TapPodError.scriptRejected
        }
        let parts = script.components(separatedBy: podKeyPlaceholder)
        guard parts.count == 2 else { throw TapPodError.scriptRejected }
        let keyed = parts.joined(separator: key)
        guard !keyed.contains(podKeyPlaceholder) else { throw TapPodError.scriptRejected }
        return keyed
    }

    /// 帶著這個 Pod 的鑰匙的指令（每一個都走這裡）。
    private func keyedCommandScript(_ payload: [String: Any]) throws -> String {
        var keyed = payload
        keyed["key"] = podKey
        return try Self.commandScript(keyed)
    }

    #if DEBUG
    /// 自測看：假 Pod 收到的每一個指令都帶著這一把。
    var podKeyForSelfTest: String { podKey }
    #endif

    func scheduleIdleSleep(after delay: Duration = .seconds(15 * 60)) {
        idleSleepDelay = delay
        updateUsage()
    }

    @discardableResult
    func sleepIfIdle() -> Bool {
        guard !hasActiveUsers, !transport.isHosted else { return false }
        sleep()
        return true
    }

    private func updateUsage() {
        // 畫面租約只防休眠；Coder 準備送出時的工作租約要讓網頁醒著。
        // 排隊、串流、停止回執與語音仍要醒著，第一個原生送出前就解除 hidden。
        transport.setBackgroundWorkActive(!backgroundWorkLeases.isEmpty || readinessWaiters > 0 || !streams.isEmpty || stoppingRequestID != nil || voiceClaim != nil || pageRequests > 0)
        usageCount = leases.count + readinessWaiters + streams.count + (stoppingRequestID == nil ? 0 : 1)
        idleSleep?.cancel()
        idleSleep = nil
        guard !hasActiveUsers, transport.isRunning else { return }
        idleSleep = Task { @MainActor [weak self, idleSleepDelay] in
            do { try await Task.sleep(for: idleSleepDelay) } catch { return }
            guard let self else { return }
            // 網頁版仍被設定頁掛載時不睡；收起後下一輪可正常回收。
            if !self.sleepIfIdle() { self.updateUsage() }
        }
    }

    /// 重新開一次（設定檔租約要等上一個網頁真的關掉才還回來，所以等一下再開）。
    func restart() {
        sleep()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.start()
        }
    }

    // MARK: - TAP v0

    func conversations(offset: Int, limit: Int) async throws -> (items: [TapConversation], total: Int) {
        guard let data = try await request("list", ["offset": offset, "limit": limit]) as? [String: Any],
              let rows = data["items"] as? [[String: Any]] else { throw TapError.remote("讀不到對話清單") }
        let items = rows.compactMap { item -> TapConversation? in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let title = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "新對話"
            return TapConversation(id: id, title: title, updatedAt: Self.date(item["update_time"]) ?? .distantPast)
        }
        return (items, (data["total"] as? NSNumber)?.intValue ?? items.count)
    }

    func messages(conversationID: String) async throws -> [TapMessage] {
        try await thread(conversationID: conversationID, branch: nil).messages
    }

    /// 對話的一支；branch＝某個版本的節點（網頁的 ‹ 1/2 ›），nil＝ChatGPT 目前那一支。
    func thread(conversationID: String, branch: String?) async throws -> TapThread {
        var payload: [String: Any] = ["conversationID": conversationID]
        if let branch { payload["branch"] = branch }
        let data = try await request("get", payload) as? [String: Any] ?? [:]
        let parents = data["parents"] as? [String: Any] ?? [:]
        let messages = (data["messages"] as? [[String: Any]] ?? []).compactMap { item -> TapMessage? in
            guard let id = item["id"] as? String, let role = (item["role"] as? String).flatMap(TapRole.init(rawValue:)),
                  let text = item["text"] as? String else { return nil }
            let images = (item["images"] as? [[String: Any]] ?? []).compactMap { image -> TapImage? in
                guard let pointer = image["pointer"] as? String, !pointer.isEmpty else { return nil }
                return TapImage(id: pointer, width: (image["width"] as? NSNumber)?.intValue, height: (image["height"] as? NSNumber)?.intValue)
            }
            let sources = (item["sources"] as? [[String: Any]] ?? []).compactMap { source -> TapSource? in
                guard let string = source["url"] as? String, let url = URL(string: string),
                      let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
                let title = (source["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.host ?? string
                return TapSource(url: url, title: title)
            }
            var message = TapMessage(id: id, role: role, text: text, model: item["model"] as? String, images: images,
                                     files: item["files"] as? [String] ?? [], sources: sources)
            message.parentID = parents[id] as? String
            if let variant = item["variant"] as? [String: Any], let index = (variant["index"] as? NSNumber)?.intValue,
               let count = (variant["count"] as? NSNumber)?.intValue, let nodes = variant["nodes"] as? [String],
               count > 1, nodes.indices.contains(index) {
                message.variant = TapVariant(index: index, count: count, nodes: nodes)
            }
            return message
        }
        return TapThread(messages: messages, leaf: data["leaf"] as? String, isCurrent: (data["current"] as? Bool) ?? true,
                         isWork: (data["work"] as? Bool) ?? false, projectID: data["projectID"] as? String)
    }

    func models() async throws -> (items: [TapModel], defaultID: String?, currentEffortID: String?) {
        let data = try await request("models") as? [String: Any] ?? [:]
        // 新版選單的版本：代號前面加「version:」，選單上跟模型分開顯示；送出時只用檔位（代號|強度）。
        let versions = (data["versions"] as? [[String: Any]] ?? []).compactMap { item -> TapModel? in
            guard let id = item["id"] as? String, !id.isEmpty, let title = item["title"] as? String else { return nil }
            let presets = (item["presets"] as? [[String: Any]] ?? []).compactMap { preset -> TapEffort? in
                guard let pid = preset["id"] as? String, !pid.isEmpty else { return nil }
                return TapEffort(id: pid, title: (preset["title"] as? String) ?? pid, detail: (preset["detail"] as? String) ?? "",
                                 version: (preset["version"] as? String) ?? "", level: (preset["level"] as? String) ?? "",
                                 isMax: (preset["max"] as? Bool) ?? false, showsVersion: (preset["showVersion"] as? Bool) ?? false)
            }
            return presets.isEmpty ? nil : TapModel(id: "version:" + id, title: title, detail: "", efforts: presets)
        }
        let flat = (data["models"] as? [[String: Any]] ?? []).compactMap { item -> TapModel? in
            guard let slug = item["slug"] as? String, !slug.isEmpty else { return nil }
            let efforts = (item["efforts"] as? [[String: Any]] ?? []).compactMap { effort -> TapEffort? in
                guard let id = effort["id"] as? String, !id.isEmpty else { return nil }
                return TapEffort(id: id, title: (effort["title"] as? String) ?? id)
            }
            return TapModel(id: slug, title: (item["title"] as? String) ?? slug,
                            detail: (item["description"] as? String) ?? "", efforts: efforts)
        }
        // 目前的檔位＝ChatGPT 伺服器記的「上次使用」（網頁、桌面版、手機共用）；讀不到就用第一個版本。
        let current = data["current"] as? [String: Any]
        let currentVersion = (current?["version"] as? String).map { "version:" + $0 }
        let defaultID = currentVersion.flatMap { id in versions.contains { $0.id == id } ? id : nil }
            ?? versions.first?.id ?? (data["default"] as? String)
        return (versions + flat, defaultID, current?["preset"] as? String)
    }

    func tools() async throws -> [TapTool] {
        guard let data = try await request("tools") as? [String: Any],
              let items = data["items"] as? [[String: Any]] else {
            throw TapError.remote("讀不到 ChatGPT 的工具清單")
        }
        return items.compactMap { item -> TapTool? in
            guard let id = item["id"] as? String, !id.isEmpty, let title = item["title"] as? String, !title.isEmpty else { return nil }
            var tool = TapTool(id: id, title: title, detail: (item["description"] as? String) ?? "",
                               primary: (item["primary"] as? Bool) ?? true)
            tool.rank = (item["rank"] as? NSNumber)?.doubleValue
            tool.isApp = (item["app"] as? Bool) ?? false
            tool.headApp = (item["head"] as? Bool) ?? false
            tool.hidden = (item["hidden"] as? Bool) ?? false
            tool.firstPartyApp = (item["firstParty"] as? Bool) ?? false
            return tool
        }
    }

    func home() async throws -> (greeting: String?, suggestions: [TapSuggestion]) {
        let data = try await request("home") as? [String: Any] ?? [:]
        let items = (data["items"] as? [[String: Any]] ?? []).compactMap { item -> TapSuggestion? in
            guard let title = item["title"] as? String, !title.isEmpty else { return nil }
            return TapSuggestion(id: (item["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title,
                                 title: title, prompt: (item["prompt"] as? String) ?? title)
        }
        return (data["greeting"] as? String, items)
    }

    func gpts() async throws -> [TapFolder] {
        let data = try await request("gpts") as? [String: Any] ?? [:]
        return Self.folders(data["items"])
    }

    func pinned() async throws -> [TapFolder] {
        let data = try await request("pins") as? [String: Any] ?? [:]
        return Self.folders(data["items"])
    }

    func projects() async throws -> [TapFolder] {
        guard let data = try await request("projects") as? [String: Any], let items = data["items"] as? [[String: Any]] else {
            throw TapError.remote("讀不到專案清單")
        }
        return Self.folders(items)
    }

    func createProject(name: String, description: String) async throws -> TapFolder {
        let data = try await request("createProject", ["name": name, "description": description]) as? [String: Any] ?? [:]
        guard let project = Self.folders([data]).first, project.kind == .project,
              project.id.hasPrefix("g-p-") else {
            throw TapError.remote("ChatGPT 建立專案沒有回傳專案 ID；這句未送出")
        }
        return project
    }

    func projectDetails(projectID: String) async throws -> TapFolder {
        guard projectID.hasPrefix("g-p-"),
              let data = try await request("projectDetails", ["projectID": projectID]) as? [String: Any],
              let folder = Self.folders([data]).first, folder.id == projectID, folder.kind == .project else {
            throw TapError.remote("讀不到 ChatGPT 專案識別說明")
        }
        return folder
    }

    func conversations(inProject projectID: String) async throws -> [TapConversation] {
        guard let data = try await request("projectConversations", ["projectID": projectID]) as? [String: Any],
              let rows = data["items"] as? [[String: Any]] else { throw TapError.remote("讀不到這個專案的對話") }
        return rows.compactMap { item -> TapConversation? in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let title = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "新對話"
            return TapConversation(id: id, title: title, updatedAt: Self.date(item["update_time"]) ?? .distantPast)
        }
    }

    /// 圖片只放記憶體：同網域由 Pod 讀回；外部網址用不落地的連線下載（ephemeral，不寫快取）。
    /// 暫時對話沒有對話編號也照樣讀（09-24 實機：暫時對話裡自己上傳的圖讀不到）。
    func imageData(pointer: String, conversationID: String?) async throws -> Data {
        var payload: [String: Any] = ["pointer": pointer]
        if let conversationID { payload["conversationID"] = conversationID }
        let data = try await request("image", payload) as? [String: Any] ?? [:]
        return try await Self.bytes(from: data)
    }

    /// 資料庫（網頁的 Library）：一頁 40 個檔案；分頁跟網頁版一樣（建議／圖片／全部），可搜尋。
    func library(tab: TapLibraryTab, query: String, cursor: String?) async throws -> (items: [TapLibraryItem], cursor: String?) {
        var payload: [String: Any] = ["tab": tab.rawValue, "query": query]
        if let cursor { payload["cursor"] = cursor }
        let data = try await request("library", payload) as? [String: Any] ?? [:]
        let items = (data["items"] as? [[String: Any]] ?? []).compactMap { item -> TapLibraryItem? in
            guard let id = item["id"] as? String, !id.isEmpty, let name = item["name"] as? String, !name.isEmpty else { return nil }
            return TapLibraryItem(id: id, name: name, mime: (item["mime"] as? String) ?? "",
                                  category: (item["category"] as? String) ?? "file",
                                  date: Self.date(item["time"]), size: (item["size"] as? NSNumber)?.intValue)
        }
        let next = (data["cursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (items, next)
    }

    /// 資料庫檔案：縮圖或原檔（只放記憶體；存檔由使用者自己選位置）。
    func libraryData(itemID: String, full: Bool) async throws -> Data {
        let data = try await request("libraryData", ["itemID": itemID, "full": full], timeout: .seconds(full ? 90 : 20))
            as? [String: Any] ?? [:]
        return try await Self.bytes(from: data)
    }

    /// 資料庫：刪除（跟網頁一樣移到資料庫的垃圾桶，可在網頁還原）。
    func deleteLibraryItem(itemID: String) async throws {
        _ = try await request("libraryDelete", ["itemID": itemID])
    }

    /// 分享：用網頁自己的分享鈕建立公開連結；messageID＝只分享那一則提問（Share prompt）。
    func share(conversationID: String, messageID: String?) async throws -> URL {
        var payload: [String: Any] = ["conversationID": conversationID]
        if let messageID { payload["messageID"] = messageID }
        let data = try await request("share", payload, timeout: .seconds(45)) as? [String: Any] ?? [:]
        guard let string = data["url"] as? String, let url = URL(string: string), url.scheme == "https" else {
            throw TapError.remote("ChatGPT 沒有給分享連結")
        }
        return url
    }

    /// 停止分享：刪掉那個公開連結。對話分享是 /share/<編號>、新式貼文是 /s/<編號>。
    /// 回傳公開頁是不是已經打不開（nil＝沒辦法確認）。
    @discardableResult
    func deleteShare(url: URL) async throws -> Bool? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2, parts[0] == "s" || parts[0] == "share",
              parts[1].range(of: #"^[A-Za-z0-9_-]{4,128}$"#, options: .regularExpression) != nil else {
            throw TapError.remote("看不懂這個分享連結")
        }
        let data = try await request("shareDelete", ["shareID": parts[1], "kind": parts[0]]) as? [String: Any] ?? [:]
        return data["gone"] as? Bool
    }

    func automations() async throws -> [TapAutomation] {
        let data = try await request("automations") as? [String: Any] ?? [:]
        return (data["items"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            return TapAutomation(id: id, title: (item["title"] as? String) ?? "", prompt: (item["prompt"] as? String) ?? "",
                                 schedule: (item["schedule"] as? String) ?? "", enabled: (item["enabled"] as? Bool) ?? true,
                                 nextRun: Self.date(item["next"]), conversationID: item["conversationID"] as? String,
                                 display: (item["display"] as? String) ?? "", completed: (item["completed"] as? Bool) ?? false,
                                 watching: (item["watching"] as? Bool) ?? false)
        }
    }

    func setAutomation(id: String, enabled: Bool) async throws {
        _ = try await request("automationStatus", ["automationID": id, "enabled": enabled])
    }

    func removeAutomation(id: String) async throws {
        _ = try await request("automationRemove", ["automationID": id])
    }

    func plugins() async throws -> (installed: [TapPlugin], sections: [TapPluginSection]) {
        let data = try await request("plugins") as? [String: Any] ?? [:]
        func parse(_ value: Any?) -> [TapPlugin] {
            (value as? [[String: Any]] ?? []).compactMap { item in
                guard let id = item["id"] as? String, !id.isEmpty, let name = item["name"] as? String else { return nil }
                return TapPlugin(id: id, name: name, detail: (item["description"] as? String) ?? "",
                                 enabled: (item["enabled"] as? Bool) ?? true,
                                 iconURL: (item["icon"] as? String).flatMap(URL.init(string:)),
                                 installed: (item["installed"] as? Bool) ?? false)
            }
        }
        let sections = (data["sections"] as? [[String: Any]] ?? []).compactMap { item -> TapPluginSection? in
            guard let id = item["id"] as? String, !id.isEmpty, let title = item["title"] as? String, !title.isEmpty else { return nil }
            let plugins = parse(item["plugins"])
            return plugins.isEmpty ? nil : TapPluginSection(id: id, title: title, plugins: plugins)
        }
        return (parse(data["installed"]), sections)
    }

    /// 外掛詳細頁：說明、開發者、能力、範例提示、技能、工具（讀取／寫入）、截圖與連結。
    func pluginDetail(id: String) async throws -> TapPluginDetail {
        let data = try await request("pluginDetail", ["pluginID": id], timeout: .seconds(30)) as? [String: Any] ?? [:]
        func text(_ key: String) -> String { (data[key] as? String) ?? "" }
        func link(_ key: String) -> URL? { (data[key] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil } }
        let skills = (data["skills"] as? [[String: Any]] ?? []).compactMap { item -> TapPluginDetail.Skill? in
            guard let name = item["name"] as? String, !name.isEmpty else { return nil }
            return TapPluginDetail.Skill(name: name, detail: (item["description"] as? String) ?? "")
        }
        let tools = (data["tools"] as? [[String: Any]] ?? []).compactMap { item -> TapPluginDetail.Tool? in
            guard let name = item["name"] as? String, !name.isEmpty else { return nil }
            return TapPluginDetail.Tool(name: name, detail: (item["description"] as? String) ?? "", read: (item["read"] as? Bool) ?? false,
                                        destructive: (item["destructive"] as? Bool) ?? false)
        }
        let state = text("tools_state")
        return TapPluginDetail(id: id, name: text("name"), developer: text("developer"), category: text("category"),
                               summary: text("summary"), about: text("about"),
                               capabilities: data["capabilities"] as? [String] ?? [], prompts: data["prompts"] as? [String] ?? [],
                               website: link("website"), privacy: link("privacy"), terms: link("terms"), icon: link("icon"),
                               screenshots: (data["screenshots"] as? [String] ?? []).compactMap(URL.init(string:)).filter { $0.scheme == "https" },
                               skills: skills, tools: tools, toolsState: state == "ok" ? .loaded : state == "failed" ? .failed : .none)
    }

    /// 外掛動作；要登入那個 App 時回傳網頁版的授權網址。
    func pluginAction(id: String, action: String, enabled: Bool = true) async throws -> URL? {
        let data = try await request("pluginAction", ["pluginID": id, "action": action, "enabled": enabled]) as? [String: Any] ?? [:]
        guard let raw = data["authURL"] as? String else { return nil }
        // W178：只把 https 網址交給系統打開；file:、自訂協定可能直接啟動本機程式。
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            throw TapError.remote("授權網址不是 https，已擋下")
        }
        return url
    }

    func sites() async throws -> [TapSite] {
        let data = try await request("sites") as? [String: Any] ?? [:]
        return (data["items"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            return TapSite(id: id, name: (item["name"] as? String) ?? "", url: (item["url"] as? String).flatMap(URL.init(string:)),
                           updatedAt: Self.date(item["updated"]), status: (item["status"] as? String) ?? "")
        }
    }

    func siteURL(id: String) async throws -> URL? {
        let data = try await request("siteURL", ["siteID": id]) as? [String: Any] ?? [:]
        return (data["url"] as? String).flatMap(URL.init(string:))
    }

    func memories() async throws -> (items: [TapMemory], usage: Int?) {
        let data = try await request("memories") as? [String: Any] ?? [:]
        let items = (data["items"] as? [[String: Any]] ?? []).compactMap { item -> TapMemory? in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            return TapMemory(id: id, text: (item["text"] as? String) ?? "", updatedAt: Self.date(item["updated"]))
        }
        return (items, (data["usage"] as? NSNumber)?.intValue)
    }

    func deleteMemory(id: String) async throws {
        _ = try await request("memoryDelete", ["memoryID": id])
    }

    func clearMemories() async throws {
        _ = try await request("memoryClear")
    }

    func instructions() async throws -> TapInstructions {
        let data = try await request("instructions") as? [String: Any] ?? [:]
        return TapInstructions(enabled: (data["enabled"] as? Bool) ?? true, nickname: (data["nickname"] as? String) ?? "",
                               occupation: (data["occupation"] as? String) ?? "", traits: (data["traits"] as? String) ?? "",
                               aboutYou: (data["about"] as? String) ?? "")
    }

    func saveInstructions(_ value: TapInstructions) async throws {
        _ = try await request("saveInstructions", ["enabled": value.enabled, "nickname": value.nickname,
                                                   "occupation": value.occupation, "traits": value.traits, "about": value.aboutYou])
    }

    func account() async throws -> TapAccount {
        let data = try await request("account") as? [String: Any] ?? [:]
        return TapAccount(name: (data["name"] as? String) ?? "", email: (data["email"] as? String) ?? "",
                          plan: data["plan"] as? String, pictureURL: (data["picture"] as? String).flatMap(URL.init(string:)))
    }

    /// 網頁版小視窗：讓 Pod 的網頁切到某一頁（例如 /#settings、/plugins、外掛的授權網址）。
    func navigate(_ pathOrURL: String) async {
        _ = try? await request("navigate", ["url": pathOrURL])
    }

    /// 即時語音：開始（在 Pod 裡按網頁的語音模式）、結束、查狀態。
    /// W184 G3：開始要先拿到語音（claimVoice）；不是自己的就不開。
    private static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func voice(start conversationID: String?, claim: VoiceClaim) async throws -> (live: Bool, conversationID: String?) {
        guard voiceClaim == claim else { throw TapError.remote("語音模式在另一邊") }
        let allowed = await voiceMicrophonePermission()
        guard voiceClaim == claim else { throw TapError.remote("語音已取消") }
        guard allowed else { throw TapError.remote("沒有麥克風權限；請在系統設定允許 TATWO OS 使用麥克風") }
        voiceReadyToStart(claim)
        var payload: [String: Any] = [:]
        if let conversationID { payload["conversationID"] = conversationID }
        let data: [String: Any]
        do {
            data = try await request("voice", payload, timeout: .seconds(40)) as? [String: Any] ?? [:]
        } catch {
            if voiceClaim == claim { voiceOpen = false }   // W183 R6b 審查：沒開成
            throw error
        }
        let live = (data["live"] as? Bool) ?? false
        // W183 R6b 審查：開始了（或還在等麥克風權限）：直到結束前連接器拿不到獨占。W184 G3 第三輪：語音還是自己的才記。
        if voiceClaim == claim {
            voiceOpen = true
            if live { voiceSeenLive = true }
        }
        return (live, data["conversationID"] as? String)
    }

    /// W184 G3：只結束自己拿著的語音，或已經沒人拿著時（晚回來的「開始」）補送的結束；別人的語音不動。
    /// 送成功才算網頁收到結束（失敗照樣算還開著，交給 endVoice 再試或關掉那一頁）。
    func voiceStop(claim: VoiceClaim, timeout: Duration = .seconds(20)) async throws {
        guard voiceClaim == nil || voiceClaim == claim else { throw TapError.remote("語音模式在另一邊") }
        _ = try await request("voice", ["stop": true], timeout: timeout)
        voiceOpen = false   // W183 R6b 審查
        voiceSeenLive = false
    }

    /// 直接開始（W183 的自測在用）：一樣先拿語音（拿不到就不送），voiceStop() 結束並放掉。畫面一律走 ChatGPTVoiceMode。
    func voice(start conversationID: String?) async throws -> (live: Bool, conversationID: String?) {
        guard let claim = claimVoice(owner: UUID()) else { throw TapError.remote(voiceStartBlocker ?? "語音模式在另一邊") }
        legacyVoiceClaim = claim
        do {
            return try await voice(start: conversationID, claim: claim)
        } catch {
            releaseVoice(claim)
            legacyVoiceClaim = nil
            throw error
        }
    }

    /// 結束直接開始的那一次（W183 的自測在用）：送結束、放掉語音。
    func voiceStop() async throws {
        let claim = legacyVoiceClaim   // 只放自己那一次拿的（別人拿著的語音不動）
        defer {
            voiceOpen = false   // W183 R6b 審查
            voiceSeenLive = false
            if let claim { releaseVoice(claim) }
            legacyVoiceClaim = nil
        }
        _ = try await request("voice", ["stop": true])
    }
    private var legacyVoiceClaim: VoiceClaim?

    func voiceState(timeout: Duration = .seconds(20)) async throws -> (live: Bool, conversationID: String?) {
        let data = try await request("voiceState", timeout: timeout) as? [String: Any] ?? [:]
        let live = (data["live"] as? Bool) ?? false
        // W183 R6b 審查：網頁自己結束了語音（開始過、現在沒了）＝語音關了。
        if live { voiceSeenLive = true } else if voiceSeenLive { voiceOpen = false; voiceSeenLive = false }
        return (live, data["conversationID"] as? String)
    }

    /// 外部小圖（外掛圖示、頭像）：不落地的連線、只放記憶體；只連公開網際網路（W178）。
    func remoteImage(_ url: URL) async -> Data? {
        try? await TapRemoteFetch.fetch(url, maxBytes: 4 * 1024 * 1024, session: Self.imageSession)
    }

    /// Pod 回的檔案：同網域的已經是 base64；外部網址（有簽章、會過期）用不落地的連線下載，只連公開網際網路（W178）。
    private static func bytes(from data: [String: Any]) async throws -> Data {
        if let base64 = data["base64"] as? String, let bytes = Data(base64Encoded: base64) { return bytes }
        guard let string = data["url"] as? String, let url = URL(string: string), url.scheme == "https" else {
            throw TapError.remote("拿不到檔案")
        }
        do {
            return try await TapRemoteFetch.fetch(url, maxBytes: 512 * 1024 * 1024, session: imageSession)
        } catch let failure as TapRemoteFetch.Failure {
            throw TapError.remote(failure.localizedDescription)
        }
    }

    private static let imageSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    func feedback(conversationID: String, messageID: String, good: Bool) async throws {
        _ = try await request("feedback", ["conversationID": conversationID, "messageID": messageID,
                                           "rating": good ? "thumbsUp" : "thumbsDown"])
    }

    func rename(conversationID: String, title: String) async throws {
        _ = try await request("rename", ["conversationID": conversationID, "title": title])
    }

    func archive(conversationID: String) async throws {
        _ = try await request("archive", ["conversationID": conversationID])
    }

    func delete(conversationID: String) async throws {
        _ = try await request("remove", ["conversationID": conversationID])
    }

    func search(query: String) async throws -> [TapConversation] {
        guard let data = try await request("search", ["query": query]) as? [String: Any],
              let rows = data["items"] as? [[String: Any]] else { throw TapError.remote("讀不到搜尋結果") }
        return rows.compactMap { item -> TapConversation? in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let title = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "新對話"
            return TapConversation(id: id, title: title, updatedAt: Self.date(item["update_time"]) ?? .distantPast)
        }
    }

    /// 探查網頁自己的選單（只記選項名稱）；結果放進診斷。library＝順便看相簿頁用哪些接口。
    func probe(conversationID: String?, library: Bool = false) async {
        var payload: [String: Any] = ["library": library]
        if let conversationID { payload["conversationID"] = conversationID }
        _ = try? await request("probe", payload)
    }

    func setPinned(conversationID: String, pinned: Bool) async throws {
        _ = try await request("pin", ["conversationID": conversationID, "pinned": pinned])
    }

    /// 在新對話分支；回傳新對話編號。
    func branch(conversationID: String) async throws -> String? {
        let data = try await request("branch", ["conversationID": conversationID]) as? [String: Any] ?? [:]
        return data["conversationID"] as? String
    }

    /// Pod 腳本的診斷（只有欄位名稱與短代號，沒有內容）；設定 › Plugin › TAP 顯示。
    func diagnostics() async -> [(String, String)] {
        guard let data = try? await request("diagnostics") as? [String: Any] else { return [] }
        return data.compactMap { key, value in (value as? String).map { (key, $0) } }.sorted { $0.0 < $1.0 }
    }

    static func folders(_ value: Any?) -> [TapFolder] {
        (value as? [[String: Any]] ?? []).compactMap { item -> TapFolder? in
            guard let id = item["id"] as? String, !id.isEmpty, let title = item["title"] as? String, !title.isEmpty else { return nil }
            return TapFolder(id: id, title: title, kind: TapFolder.Kind(rawValue: (item["kind"] as? String) ?? "") ?? .other,
                             description: (item["description"] as? String) ?? "")
        }
    }

    func send(text: String, conversationID: String?, model: String?, effort: String?,
              attachments: [TapAttachment], tool: String?, gizmoID: String?, temporary: Bool,
              parentID: String?) -> AsyncStream<TapStreamEvent> {
        send(requestID: UUID().uuidString, text: text, conversationID: conversationID, model: model, effort: effort,
             attachments: attachments, tool: tool, gizmoID: gizmoID, temporary: temporary, parentID: parentID)
    }

    /// 只由本則對話明確選擇個人化的原生控制項呼叫；不存進偏好、不由選了外掛推定同意。
    func send(text: String, conversationID: String?, model: String?, effort: String?,
              attachments: [TapAttachment], tool: String?, gizmoID: String?, temporary: Bool,
              parentID: String?, temporaryPersonalized: Bool) -> AsyncStream<TapStreamEvent> {
        send(requestID: UUID().uuidString, text: text, conversationID: conversationID, model: model, effort: effort,
             attachments: attachments, tool: tool, gizmoID: gizmoID, temporary: temporary,
             parentID: parentID, temporaryPersonalized: temporaryPersonalized)
    }

    /// 呼叫者先持有代號，即使還沒開始讀串流也能取消自己的排隊項目。
    func send(requestID: String, text: String, conversationID: String?, model: String? = nil, effort: String? = nil,
              attachments: [TapAttachment] = [], tool: String? = nil, gizmoID: String? = nil,
              temporary: Bool = false, parentID: String? = nil,
              temporaryPersonalized: Bool = false) -> AsyncStream<TapStreamEvent> {
        var payload: [String: Any] = ["cmd": "send", "text": text]
        if let parentID { payload["parentID"] = parentID }
        if let tool { payload["hint"] = tool }
        if temporary { payload["temporary"] = true }
        if temporary && temporaryPersonalized { payload["temporaryPersonalized"] = true }
        if let gizmoID { payload["gizmoID"] = gizmoID }
        if !attachments.isEmpty {
            payload["files"] = attachments.map { ["name": $0.name, "mime": $0.mime, "base64": $0.data.base64EncodedString()] }
        }
        if let conversationID { payload["conversationID"] = conversationID }
        if let model { payload["model"] = model }
        if let effort { payload["effort"] = effort }
        return startStream(payload, id: requestID)
    }

    /// 重新產生；給模型／檔位＝換那個重答（網頁的 Switch model），沒給就是 Try again。
    func regenerate(conversationID: String, model: String?, effort: String?, temporary: Bool) -> AsyncStream<TapStreamEvent> {
        regenerate(conversationID: conversationID, model: model, effort: effort,
                   temporary: temporary, temporaryPersonalized: false)
    }

    func regenerate(conversationID: String, model: String?, effort: String?, temporary: Bool,
                    temporaryPersonalized: Bool) -> AsyncStream<TapStreamEvent> {
        var payload: [String: Any] = ["cmd": "regenerate", "conversationID": conversationID]
        if temporary { payload["temporary"] = true }
        if temporary && temporaryPersonalized { payload["temporaryPersonalized"] = true }
        if let model { payload["model"] = model }
        if let effort { payload["effort"] = effort }
        return startStream(payload)
    }

    private func startStream(_ base: [String: Any], id: String = UUID().uuidString) -> AsyncStream<TapStreamEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: TapStreamEvent.self)
        continuation.yield(.request(id: id))
        guard connection == .ready || connection == .sleeping || connection == .starting else {
            continuation.yield(.notSubmitted(TapError.notReady.localizedDescription))
            continuation.finish()
            return stream
        }
        guard streams[id] == nil, activeRequestID != id else {
            continuation.yield(.failed("請求代號重複"))
            continuation.finish()
            return stream
        }
        var payload = base
        payload["id"] = id
        guard let script = try? keyedCommandScript(payload) else {
            continuation.yield(.failed("送出內容無法編碼"))
            continuation.finish()
            return stream
        }
        streams[id] = continuation
        if (base["temporary"] as? Bool) == true {
            temporaryStreams.insert(id)
        } else if let conversationID = base["conversationID"] as? String {
            streamConversations[id] = conversationID
        }
        continuation.onTermination = { [weak self] reason in
            guard case .cancelled = reason else { return }
            Task { @MainActor in self?.stop(requestID: id) }
        }
        // 網頁一段時間什麼都沒回：判定沒送出，不讓畫面一直「思考中」（09-25 實機）。有附件時網頁要先上傳，等久一點。
        let silence: Duration = (base["files"] as? [Any])?.isEmpty == false ? .seconds(150) : .seconds(60)
        recoveryNotice = nil
        if connection != .ready || activeRequestID != nil || podHolder?.queuesSend == true { continuation.yield(.queued) }   // W183 R9 審查：「新增 ▾」拿著 Pod 時也排隊；W184 G3：語音開著也排隊
        sendQueue.append(QueuedSend(id: id, script: script, silence: silenceOverride ?? silence, payload: payload))
        if voiceClaim != nil || dotsLease != nil { scheduleQueueDeadline(id) }   // W184 G3 第三輪：排在語音後面不能無限期「打字中」
        updateUsage()
        if connection == .sleeping { start() }
        drainQueue()
        return stream
    }

    private func drainQueue() {
        // W183 R6b：連接器獨占時先排隊；W183 R9 審查（GPT-6 #9）：原生「新增 ▾」拿著 Pod 的操作租約時也先排隊。
        // W184 G3：即時語音拿著 Pod 時也先排隊（送出會換頁、打字，會切斷語音），放掉語音再送。
        guard podHolder == nil, activeRequestID == nil, connection == .ready, !sendQueue.isEmpty else { return }
        let next = sendQueue.removeFirst()
        let id = next.id
        // W184 G3 第三輪：用現在這一份網頁的鑰匙重新組指令（語音那一頁重開過，舊鑰匙新網頁不收）。
        let script = (try? keyedCommandScript(next.payload)) ?? next.script
        activeRequestID = id
        streams[id]?.yield(.accepted)
        // Both clocks start when the request owns the Pod; queued time does not consume them.
        let clock = ContinuousClock()
        streamActivity[id] = clock.now
        let channelSilence = progressSilence + min(.seconds(5), progressSilence / 4)
        streamWatchdog = Task { @MainActor [weak self, channelSilence, progressSilence] in
            do { try await Task.sleep(for: next.silence) } catch { return }
            guard let self, self.activeRequestID == id else { return }
            if !self.acceptedStreams.contains(id) {
                self.expireUnanswered(id)
                return
            }
            // JS owns progress/turn deadlines. Native only covers a lost event channel,
            // including its activity heartbeat, with a short scheduling grace.
            while self.activeRequestID == id {
                if let last = self.streamActivity[id], last.duration(to: clock.now) >= channelSilence {
                    self.streams[id]?.yield(.failed(Self.noProgressMessage, reason: "no_progress"))
                    self.streams[id]?.finish()
                    self.stop(requestID: id)
                    return
                }
                do { try await Task.sleep(for: min(.seconds(5), progressSilence / 4)) } catch { return }
            }
        }
        transport.run(script)
    }

    private func expireUnanswered(_ id: String) {
        guard let pending = streams[id], !acceptedStreams.contains(id) else { return }
        pending.yield(.failed("ChatGPT 網頁沒有回應，這則可能沒有送出"))
        stop(requestID: id)
    }

    /// 舊呼叫者的全域停止仍保留；Space／私訊框一律用指定代號版本。
    func stop() {
        if let activeRequestID { stop(requestID: activeRequestID) }
    }

    func stop(requestID: String) {
        guard streams[requestID] != nil, stoppingRequestID != requestID else { return }
        if activeRequestID != requestID {
            sendQueue.removeAll { $0.id == requestID }
            streams[requestID]?.yield(.notSubmitted("這句尚未送出，已停止"))
            finishStream(requestID)
            return
        }
        streamWatchdog?.cancel()
        stoppingRequestID = requestID
        // 停止期間不再收文字，但保留消費者等待回執：只有網站證明未送出才還草稿。
        // 槽位與使用計數留到回執或關掉舊 Pod，下一則不能覆蓋未知中的送出。
        let acknowledgement = UUID().uuidString
        stopAcknowledgementID = acknowledgement
        updateUsage()
        stopWatchdog = Task { @MainActor [weak self, stopDeadline] in
            do { try await Task.sleep(for: stopDeadline) } catch { return }
            guard let self, self.stopAcknowledgementID == acknowledgement else { return }
            self.resetAfterUnconfirmedStop()
        }
        if let script = try? keyedCommandScript(["cmd": "stop", "id": acknowledgement, "requestID": requestID]) {
            transport.run(script)
        }
    }

    private func resetAfterUnconfirmedStop() {
        // 先關掉舊網頁，再結束取消串流；未知送達狀態不能回草稿。
        transport.stop()
        if let stopped = stoppingRequestID { streams.removeValue(forKey: stopped)?.finish() }
        recoveryNotice = Self.stopRecoveryNotice
        connection = .sleeping
        failPending("ChatGPT 已重新整理，這句尚未送出；請再送一次")
    }

    /// Coder 把送出交給 runner 後才等待啟動；失敗會走未送出回稿，不需要重選模型。
    func readyForSend(timeout: Duration? = nil) async throws {
        try Task.checkCancellation()
        readinessWaiters += 1
        updateUsage()
        defer { readinessWaiters -= 1; updateUsage() }
        if connection == .sleeping { start() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout ?? startupTimeout)
        while connection == .starting, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        guard connection == .ready else {
            throw TapError.remote("ChatGPT 啟動未完成，這句沒有送出；草稿已保留，請稍後重試")
        }
    }

    private func finishStream(_ id: String) {
        streams.removeValue(forKey: id)?.finish()
        streamActivity.removeValue(forKey: id)
        streamConversations.removeValue(forKey: id)
        temporaryStreams.remove(id)
        temporaryConfirmed.remove(id)
        acceptedStreams.remove(id)
        websiteSubmittedStreams.remove(id)
        if activeRequestID == id {
            streamWatchdog?.cancel()
            streamWatchdog = nil
            activeRequestID = nil
        }
        updateUsage()
        drainQueue()
    }

    // MARK: - Pod 通訊

    /// owner＝這個指令是拿著「新增 ▾」操作租約的那一次送的（W183 R9 審查）。
    private func request(_ command: String, _ arguments: [String: Any] = [:], timeout: Duration = .seconds(20), owner: UUID? = nil) async throws -> Any {
        try await waitForDotsReturn()
        guard dotsLease == nil else { throw TapError.remote("Dots 還開著，先返回 ChatGPT") }
        guard connection == .ready else { throw TapError.notReady }
        // W183 R6b 審查：會換頁的指令在連接器獨占時不做（不把正在填的外掛表單、配對頁換掉）；在跑的會換頁指令也擋住獨占。
        let paging = Self.pageCommands.contains(command) && !(command == "voice" && arguments["stop"] as? Bool == true)
        if paging, connectorHold != nil { throw TapError.remote("ChatGPT 正在連接 TATWO（私訊框）；等它完成再試") }
        // W183 R9 審查（GPT-6 #9）：原生「新增 ▾」拿著 Pod 時，別人的會換頁指令一律不做（不把使用者正在填的對話框換掉）。
        if paging, let menuHold, owner != menuHold {
            throw TapError.remote("ChatGPT Dev 分頁的「新增」對話框還開著；關掉它（或等 10 分鐘）再試")
        }
        // W184 G3：語音開著時別的會換頁指令不做（不把語音那一頁換走）；語音自己的開始要先拿到語音（voice(start:claim:)）。
        if paging, command != "voice", voiceClaim != nil { throw TapError.remote("語音模式開著；結束語音再試") }
        if paging { pageRequests += 1; updateUsage() }
        defer { if paging { pageRequests -= 1; updateUsage() } }
        let id = UUID().uuidString
        var payload = arguments
        payload["cmd"] = command
        payload["id"] = id
        let script = try keyedCommandScript(payload)
        return try await withCheckedThrowingContinuation { continuation in
            results[id] = continuation
            transport.run(script)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                if let pending = self?.results.removeValue(forKey: id) { pending.resume(throwing: TapError.timeout) }
            }
        }
    }

    static func commandScript(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload)
        // 只在 chatgpt.com 執行：背景網頁若被導到外站，外站自己定義的 __tatwoPod 收不到任何指令（審查 #1）。
        return "location.host==='chatgpt.com'&&window.__tatwoPod&&window.__tatwoPod.command(" + String(decoding: data, as: UTF8.self) + ")"
    }

    private func receive(_ json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }
        if dotsLease != nil {
            if type == "dotsAvailability", !dotsReturning {
                if object["unavailable"] as? Bool == true { dotsState = .unavailable }
                return
            }
            guard dotsReturning, type == "hello" else { return }
            releaseDotsLease()
        }
        switch type {
        case "hello":
            helloCount &+= 1   // W183 R6b 審查：新的一份網頁報到了
            if let loggedIn = object["loggedIn"] as? Bool { connection = loggedIn ? .ready : .needsLogin }
            if connection == .ready, storesReadiness { UserDefaults.standard.set(true, forKey: Self.readyOnceKey) }
            if connection == .needsLogin { failPending("需要登入") }
            drainQueue()
        case "auth":
            connection = .ready
            if storesReadiness { UserDefaults.standard.set(true, forKey: Self.readyOnceKey) }
        case "selection":
            if let model = object["model"] as? String, !model.isEmpty {
                pageSelection = (model, object["effort"] as? String)
            }
        case "result":
            guard let id = object["id"] as? String else { return }
            if id == stopAcknowledgementID {
                let state = object["data"] as? [String: Any]
                guard (object["ok"] as? Bool) == true, state?["preparationPending"] as? Bool != true else {
                    resetAfterUnconfirmedStop()
                    return
                }
                stopWatchdog?.cancel()
                stopWatchdog = nil
                stopAcknowledgementID = nil
                let stopped = stoppingRequestID
                stoppingRequestID = nil
                if let stopped {
                    if let submitted = state?["submitted"] as? NSNumber,
                       CFGetTypeID(submitted) == CFBooleanGetTypeID(), !submitted.boolValue,
                       !websiteSubmittedStreams.contains(stopped) {
                        streams[stopped]?.yield(.notSubmitted("這句尚未送出，已停止"))
                    }
                    finishStream(stopped)
                }
                return
            }
            guard let continuation = results.removeValue(forKey: id) else { return }
            if (object["ok"] as? Bool) == true {
                continuation.resume(returning: object["data"] ?? NSNull())
            } else {
                continuation.resume(throwing: TapError.remote((object["message"] as? String) ?? "ChatGPT 回報錯誤"))
            }
        case "stream":
            guard let id = object["id"] as? String, let continuation = streams[id],
                  id == activeRequestID, stoppingRequestID == nil,
                  let kind = object["kind"] as? String else { return }
            if ["accepted", "text", "progress", "activity", "conversation"].contains(kind) { streamActivity[id] = ContinuousClock.now }
            acceptedStreams.insert(id)   // 回了任何事件都算有回應
            if ["accepted", "conversation", "text", "title", "progress", "activity"].contains(kind) {
                websiteSubmittedStreams.insert(id)
            }
            // W184 G3c（GPT-6 審查 #1）：臨時聊天要先有確認（網頁艙讀回實際送出的內容、看到旗標才發 temporary），才收送出之後的事件；
            // 沒確認就來了＝網頁走了不加旗標的路：說清楚、停下，不把它當成臨時聊天（對話代號不交給畫面）。
            if temporaryStreams.contains(id), !temporaryConfirmed.contains(id),
               ["accepted", "conversation", "text", "title", "progress", "activity", "finished"].contains(kind) {
                continuation.yield(.failed(Self.temporaryUnconfirmedReason))
                stop(requestID: id)
                return
            }
            switch kind {
            case "temporary":
                if temporaryStreams.contains(id) { temporaryConfirmed.insert(id) }
            case "accepted":
                continuation.yield(.accepted)
            case "conversation":
                if let conversationID = object["conversationID"] as? String {
                    if !temporaryStreams.contains(id) { streamConversations[id] = conversationID }
                    continuation.yield(.conversation(id: conversationID))
                }
            case "progress":
                continuation.yield(.progress(title: ChatGPTLocalText.clean((object["title"] as? String) ?? "", limit: 80), server: (object["server"] as? Bool) ?? false))
            case "text":
                continuation.yield(.text(messageID: (object["messageID"] as? String) ?? "", full: (object["full"] as? String) ?? ""))
            case "title":
                if let conversationID = object["conversationID"] as? String, let title = object["title"] as? String {
                    continuation.yield(.title(conversationID: conversationID, title: title))
                }
            case "finished":
                lastStreamShape = object["shape"] as? String
                lastStreamParsed = (object["parsed"] as? Bool) ?? false
                let updated = streamConversations[id]
                continuation.yield(.finished)
                finishStream(id)
                if let updated {
                    conversationUpdateSerial += 1
                    conversationUpdate = TapConversationUpdate(conversationID: updated, requestID: id, serial: conversationUpdateSerial)
                }
            case "failed":
                let message = ChatGPTLocalText.clean((object["message"] as? String) ?? "送出失敗", limit: 160)
                // JSON false 才是證據；NSNumber(0)、字串、null、缺欄位都不是。
                if let submitted = object["submitted"] as? NSNumber,
                   CFGetTypeID(submitted) == CFBooleanGetTypeID(), !submitted.boolValue,
                   !websiteSubmittedStreams.contains(id) {
                    continuation.yield(.notSubmitted(message))
                } else {
                    continuation.yield(.failed(message, reason: object["reason"] as? String))
                }
                finishStream(id)
            default:
                break
            }
        default:
            break
        }
    }

    private func failPending(_ message: String) {
        streamWatchdog?.cancel()
        streamWatchdog = nil
        stopWatchdog?.cancel()
        stopWatchdog = nil
        let undispatched = Set(sendQueue.map(\.id))
        sendQueue.removeAll()
        activeRequestID = nil
        stoppingRequestID = nil
        stopAcknowledgementID = nil
        acceptedStreams.removeAll()
        websiteSubmittedStreams.removeAll()
        for continuation in results.values { continuation.resume(throwing: TapError.remote(message)) }
        results.removeAll()
        for (id, continuation) in streams {
            continuation.yield(undispatched.contains(id) ? .notSubmitted(message) : .failed(message))
            continuation.finish()
        }
        streams.removeAll()
        streamConversations.removeAll()
        temporaryStreams.removeAll()
        temporaryConfirmed.removeAll()
        updateUsage()
    }

    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    /// 只在 ChatGPT Pod 的主框架執行（TatwoCEFBridge configurePod）。回報只有 hello／auth／result／stream 四種；
    /// 權杖只留在這個閉包裡，從不回報。送出一律走網頁自己的輸入框與送出鍵，安全檢查由網頁自己完成。
    static let podScript = #"""
    (function (report) {
      if (location.host !== 'chatgpt.com') return false;
      // W197：整份 Dots 文件（含導回的頁面）只顯示；不裝 fetch、串流或對話擷取器。
      // 返回一定整頁重載，先移除顯示旗標，再安裝原本的 ChatGPT TAP。
      if (location.hash === '#tatwo-dots-return' && !/^\/dots(?:\/|$)/.test(location.pathname)) {
        window.name = '';
        history.replaceState(null, '', location.pathname + location.search);
      }
      const dotsDisplay = /^\/dots(?:\/|$)/.test(location.pathname) || window.name === '__tatwoDotsDisplay';
      if (dotsDisplay) {
        const stringify = JSON.stringify;
        let reported = false;
        const unavailable = () => {
          if (reported) return;
          // 只核對頁級不可用提示；不讀 body、訊息節點、輸入框或請求回應。
          const marked = document.querySelector('[data-testid="dots-unavailable"], [data-testid="dots-access-denied"]');
          const alerts = document.querySelectorAll('[role="alert"]');
          let denied = !!marked;
          for (const alert of alerts) {
            if (alert.closest('[data-message-author-role], [data-testid*="message"], [data-testid*="conversation"], [contenteditable]')) continue;
            if (/dots.{0,80}(?:not available|unavailable|not yet|no access|尚未|無法|不可用)|(?:no access|don't have access|do not have access|not available|unavailable|not eligible).{0,80}dots|(?:沒有|無法|不可用|尚未).{0,40}dots/i.test((alert.textContent || '').slice(0, 240))) denied = true;
          }
          if (denied) {
            reported = true;
            watch.disconnect();
            try { report(stringify({type: 'dotsAvailability', unavailable: true})); } catch (_) {}
          }
        };
        document.addEventListener('DOMContentLoaded', unavailable, {once: true});
        const watch = new MutationObserver(unavailable);
        watch.observe(document, {childList: true, subtree: true});
        return true;
      }
      // W183 R9 審查（GPT-6 #3）：每一個指令都要帶 App 的鑰匙（App 每次建立 Pod 換一把，只在這個閉包裡；網頁自己的程式讀不到、
      // 叫 __tatwoPod.command 帶不出它）。App 用 keyedPodScript 換掉下面這個佔位字；不符（或沒換掉）＝安靜丟掉，不回任何結果。
      const POD_KEY = '__TATWO_POD_KEY__';
      // 先把要用的內建函式拿在手上：網頁之後改掉全域的 JSON 也不影響回報。
      const stringify = JSON.stringify;
      const post = (o) => { try { report(stringify(o)); } catch (e) {} };
      // ==== SAFE-CHAIN BEGIN：安全判斷用的工具箱（W183 R9 審查 GPT-6 N1；R9c C1） ====
      // 這個腳本比網頁自己的程式早跑（文件一建立就跑）：在這一刻把「安全判斷」會用到的內建函式與 DOM 取值器抓在閉包裡，之後只用抓好的版本
      // （Reflect.apply 呼叫；不經網頁改得到的原型查找）。「安全判斷」＝連接器與原生「新增 ▾」從收到指令到決定按不按（Create、連線、選單項、
      // Server URL、OAuth 選項）、收不收使用者的確認（真人勾選、表單紀錄、警語指紋）的整條路：
      // - 字串只用抓好的 toLowerCase、indexOf、slice、charCodeAt（不叫 replace／split／match／includes：它們會去查網頁改得到的 Symbol 方法）；
      // - RegExp 只用抓好的 exec（RegExpBuiltinExec：不查原型上的 exec、flags）；陣列一律自己用索引走（不叫 every／some／filter／map…）；
      // - JSON.parse、Object.keys、hasOwnProperty、Array.isArray、Promise 的 then、Date.now、setTimeout、decodeURIComponent、URL；
      // - DOM：父節點、子節點、節點種類與文字、標籤名、屬性、查詢、看不看得到（hidden、getClientRects、getComputedStyle）、欄位的值、
      //   勾選、停用、唯讀、表單歸屬、選項、事件的 target／type／key、派送事件、點擊、MutationObserver、History、fetch 回應。
      // - 紀錄容器用 null 原型物件＋defineProperty（不經原型鏈）；指令的參數只讀自己的屬性（own）。
      // 正式環境少了其中任何一個（KIT_OK＝false）＝連接器與「新增」一律拒絕（unsafe_env）、真人紀錄不收；不退回網頁的方法。
      // 殘餘（不宣稱已解）：CEF 沒有隔離世界——同源腳本在主世界還是能自己點、自己填網頁、改畫面騙人點；await 的排程（Promise 的
      // constructor／then）網頁改得到，最多讓 TATWO 卡住或提早醒來（醒來後的判斷一律重新讀，不採用 await 帶回來的值）。真正的界線是配對碼＋grant。
      const R_apply = Reflect.apply;
      const O_gopd = Object.getOwnPropertyDescriptor;
      const O_define = Object.defineProperty;
      const O_create = Object.create;
      const O_keys = Object.keys;
      const O_hasOwn = Object.prototype.hasOwnProperty;
      const A_isArray = Array.isArray;
      const J_parse = JSON.parse;
      const WM = WeakMap;
      const WM_get = WeakMap.prototype.get;
      const WM_set = WeakMap.prototype.set;
      const WM_has = WeakMap.prototype.has;
      const Str = String;
      const S_charCodeAt = String.prototype.charCodeAt;
      const SP_toLowerCase = String.prototype.toLowerCase;
      const SP_indexOf = String.prototype.indexOf;
      const SP_slice = String.prototype.slice;
      const RE_exec = RegExp.prototype.exec;
      const M_imul = Math.imul;
      const M_random = Math.random;
      const D_now = Date.now;
      const P = Promise;
      const P_then = Promise.prototype.then;
      const F_decode = decodeURIComponent;
      const S_setTimeout = window.setTimeout;
      const Q_micro = typeof window.queueMicrotask === 'function' ? window.queueMicrotask : null;
      const W_gcs = typeof window.getComputedStyle === 'function' ? window.getComputedStyle : null;
      const HIST = window.history || null;
      const NAV = window.navigation || null;
      const C_URL = window.URL;
      const C_Event = window.Event;
      const C_Mouse = window.MouseEvent;
      const C_Pointer = window.PointerEvent;
      const C_Keyboard = window.KeyboardEvent;
      const C_PopState = window.PopStateEvent;
      const descOf = (C, name) => { try { return C && C.prototype ? O_gopd(C.prototype, name) : null; } catch (e) { return null; } };
      const getterOf = (C, name) => { const d = descOf(C, name); return d && typeof d.get === 'function' ? d.get : null; };
      const setterOf = (C, name) => { const d = descOf(C, name); return d && typeof d.set === 'function' ? d.set : null; };
      const methodOf = (C, name) => { const d = descOf(C, name); return d && typeof d.value === 'function' ? d.value : null; };
      // 事件
      const G_evTarget = getterOf(window.Event, 'target');
      const G_evType = getterOf(window.Event, 'type');
      const G_evKey = getterOf(window.KeyboardEvent, 'key');
      const G_evCode = getterOf(window.KeyboardEvent, 'code');
      const G_navChangeType = getterOf(window.NavigationCurrentEntryChangeEvent, 'navigationType');
      const M_dispatch = methodOf(window.EventTarget, 'dispatchEvent');
      const M_addEvt = methodOf(window.EventTarget, 'addEventListener');
      // 節點、元素
      const G_parent = getterOf(window.Node, 'parentElement');
      const G_text = getterOf(window.Node, 'textContent');
      const G_childNodes = getterOf(window.Node, 'childNodes');
      const G_nodeType = getterOf(window.Node, 'nodeType');
      const G_nodeValue = getterOf(window.Node, 'nodeValue');
      // W183 R12：結構快照往 open shadow root 裡讀（沒有這個取值器＝不讀；不算進 KIT_OK）。
      const G_shadowRoot = getterOf(window.Element, 'shadowRoot');
      const M_contains = methodOf(window.Node, 'contains');
      const M_appendChild = methodOf(window.Node, 'appendChild');
      const G_tag = getterOf(window.Element, 'tagName');
      const M_getAttr = methodOf(window.Element, 'getAttribute');
      const M_setAttr = methodOf(window.Element, 'setAttribute');
      const M_qsaEl = methodOf(window.Element, 'querySelectorAll');
      const M_getClientRects = methodOf(window.Element, 'getClientRects');
      const M_getBCR = methodOf(window.Element, 'getBoundingClientRect');
      const M_remove = methodOf(window.Element, 'remove');
      const G_hidden = getterOf(window.HTMLElement, 'hidden');
      const M_click = methodOf(window.HTMLElement, 'click');
      const M_focus = methodOf(window.HTMLElement, 'focus');
      // 欄位
      const G_checked = getterOf(window.HTMLInputElement, 'checked');
      const G_inValue = getterOf(window.HTMLInputElement, 'value');
      const S_inValue = setterOf(window.HTMLInputElement, 'value');
      const G_inDisabled = getterOf(window.HTMLInputElement, 'disabled');
      const G_inReadOnly = getterOf(window.HTMLInputElement, 'readOnly');
      const G_inForm = getterOf(window.HTMLInputElement, 'form');
      const G_taValue = getterOf(window.HTMLTextAreaElement, 'value');
      const S_taValue = setterOf(window.HTMLTextAreaElement, 'value');
      const G_taDisabled = getterOf(window.HTMLTextAreaElement, 'disabled');
      const G_taReadOnly = getterOf(window.HTMLTextAreaElement, 'readOnly');
      const G_taForm = getterOf(window.HTMLTextAreaElement, 'form');
      const G_selValue = getterOf(window.HTMLSelectElement, 'value');
      const S_selValue = setterOf(window.HTMLSelectElement, 'value');
      const G_selDisabled = getterOf(window.HTMLSelectElement, 'disabled');
      const G_selForm = getterOf(window.HTMLSelectElement, 'form');
      const G_optValue = getterOf(window.HTMLOptionElement, 'value');
      const G_optSelected = getterOf(window.HTMLOptionElement, 'selected');
      const G_btnDisabled = getterOf(window.HTMLButtonElement, 'disabled');
      const G_btnForm = getterOf(window.HTMLButtonElement, 'form');
      // 文件
      const G_body = getterOf(window.Document, 'body');
      const M_qsaDoc = methodOf(window.Document, 'querySelectorAll');
      const M_getById = methodOf(window.Document, 'getElementById');
      const M_createElement = methodOf(window.Document, 'createElement');
      // 清單、框、樣式
      const G_nlLength = getterOf(window.NodeList, 'length');
      const M_nlItem = methodOf(window.NodeList, 'item');
      const G_rlLength = getterOf(window.DOMRectList, 'length');
      const G_rectLeft = getterOf(window.DOMRectReadOnly, 'left');
      const G_rectTop = getterOf(window.DOMRectReadOnly, 'top');
      const G_rectWidth = getterOf(window.DOMRectReadOnly, 'width');
      const G_rectHeight = getterOf(window.DOMRectReadOnly, 'height');
      const M_gpv = methodOf(window.CSSStyleDeclaration, 'getPropertyValue');
      // 變動觀察
      const MO = typeof window.MutationObserver === 'function' ? window.MutationObserver : null;
      const M_moObserve = methodOf(MO, 'observe');
      const M_moDisconnect = methodOf(MO, 'disconnect');
      const G_mrType = getterOf(window.MutationRecord, 'type');
      const G_mrTarget = getterOf(window.MutationRecord, 'target');
      const G_mrRemoved = getterOf(window.MutationRecord, 'removedNodes');
      const G_mrAttr = getterOf(window.MutationRecord, 'attributeName');
      const G_mrOld = getterOf(window.MutationRecord, 'oldValue');
      // 導頁、fetch 回應、網址
      const H_push = methodOf(window.History, 'pushState');
      const H_replace = methodOf(window.History, 'replaceState');
      const RS_ok = getterOf(window.Response, 'ok');
      const RS_text = methodOf(window.Response, 'text');
      const G_urlOrigin = getterOf(C_URL, 'origin');
      const G_urlPathname = getterOf(C_URL, 'pathname');
      const G_urlSearch = getterOf(C_URL, 'search');
      const G_urlHash = getterOf(C_URL, 'hash');
      // W183 R10：代勾要量那一格在畫面上的位置（選用：不在 KIT_OK 的必要清單；少了＝不代勾，照舊交給使用者）。
      // innerWidth／innerHeight／visualViewport 在 window 自己身上（網頁之後可以蓋掉成普通值）：現在就把取值器拿在手上。
      const ownGetter = (o, name) => { try { const d = O_gopd(o, name); return d && typeof d.get === 'function' ? d.get : null; } catch (e) { return null; } };
      const M_scrollIntoView = methodOf(window.Element, 'scrollIntoView');
      const M_elementFromPoint = methodOf(window.Document, 'elementFromPoint');
      const G_innerWidth = ownGetter(window, 'innerWidth');
      const G_innerHeight = ownGetter(window, 'innerHeight');
      const G_visualViewport = ownGetter(window, 'visualViewport');
      const G_vvScale = getterOf(window.VisualViewport, 'scale');
      const G_vvLeft = getterOf(window.VisualViewport, 'offsetLeft');
      const G_vvTop = getterOf(window.VisualViewport, 'offsetTop');
      // 必要的都要在（正式的 Chromium 都有）；少一個＝安全判斷一律拒絕，不退回網頁的方法。
      const KIT_OK = (() => {
        const need = [R_apply, O_gopd, O_define, O_create, O_keys, O_hasOwn, A_isArray, J_parse, WM, WM_get, WM_set, WM_has, S_charCodeAt,
          SP_toLowerCase, SP_indexOf, SP_slice, RE_exec, M_imul, M_random, D_now, P, P_then, F_decode, S_setTimeout, W_gcs, C_URL, C_Event,
          C_Mouse, C_Keyboard, C_PopState, G_evTarget, G_evType, G_evKey, G_evCode, M_dispatch, M_addEvt, G_parent, G_text, G_childNodes,
          G_nodeType, G_nodeValue, M_contains, M_appendChild, G_tag, M_getAttr, M_setAttr, M_qsaEl, M_getClientRects, M_getBCR, M_remove,
          G_hidden, M_click, M_focus, G_checked, G_inValue, S_inValue, G_inDisabled, G_inReadOnly, G_inForm, G_taValue, S_taValue,
          G_taDisabled, G_taReadOnly, G_taForm, G_selValue, S_selValue, G_selDisabled, G_selForm, G_optValue, G_optSelected, G_btnDisabled,
          G_btnForm, G_body, M_qsaDoc, M_getById, M_createElement, G_nlLength, M_nlItem, G_rlLength, G_rectLeft, G_rectTop, G_rectWidth,
          G_rectHeight, M_gpv, MO, M_moObserve, M_moDisconnect, G_mrType, G_mrTarget, G_mrRemoved, G_mrAttr, G_mrOld, H_push, H_replace,
          RS_ok, RS_text, G_urlOrigin, G_urlPathname, G_urlSearch, G_urlHash];
        for (let i = 0; i < need.length; i += 1) if (typeof need[i] !== 'function') return false;
        return !!HIST;
      })();
      // ---- 呼叫 ----
      const pget = (g, o) => R_apply(g, o, []);
      // 只讀自己的屬性（指令的參數、JSON 讀進來的物件：沒有＝undefined，不去原型上找網頁塞的東西）。
      const own = (o, k) => (o !== null && typeof o === 'object' && R_apply(O_hasOwn, o, [k]) ? o[k] : undefined);
      const nowMs = () => R_apply(D_now, Date, []);
      const later = (fn, ms) => { try { R_apply(S_setTimeout, window, [fn, ms || 0]); } catch (e) {} };
      // 微任務：網頁自己的程式那一段跑完就輪到（它叫的 click() 整段派送完之後）。
      const micro = (fn) => { try { if (Q_micro) R_apply(Q_micro, window, [fn]); else later(fn); } catch (e) {} };
      // 睡一下／等到條件成立（醒來之後的判斷一律重新讀：不採用 await 帶回來的值）。
      const ksleep = (ms) => new P((r) => { later(() => r(), ms); });
      const kwait = async (test, ms) => {
        const end = nowMs() + ms;
        for (;;) {
          let ok = false;
          try { ok = !!test(); } catch (e) { ok = false; }
          if (ok || nowMs() >= end) return;
          await ksleep(120);
        }
      };
      // ---- 容器（null 原型；清單只用 defineProperty 加、用索引讀，不經 Array.prototype） ----
      const bag = () => O_create(null);
      const listAdd = (list, v) => { O_define(list, list.length, { value: v, writable: true, enumerable: true, configurable: true }); return list; };
      const listIndex = (list, v) => { for (let i = 0; i < list.length; i += 1) if (list[i] === v) return i; return -1; };
      const listHas = (list, v) => listIndex(list, v) >= 0;
      const aEvery = (list, fn) => { for (let i = 0; i < list.length; i += 1) if (!fn(list[i])) return false; return true; };
      const aSome = (list, fn) => { for (let i = 0; i < list.length; i += 1) if (fn(list[i])) return true; return false; };
      const aFilter = (list, fn) => { const out = []; for (let i = 0; i < list.length; i += 1) if (fn(list[i])) listAdd(out, list[i]); return out; };
      const aMap = (list, fn) => { const out = []; for (let i = 0; i < list.length; i += 1) listAdd(out, fn(list[i])); return out; };
      const aFind = (list, fn) => { for (let i = 0; i < list.length; i += 1) if (fn(list[i])) return list[i]; return null; };
      const aJoin = (list, sep) => { let s = ''; for (let i = 0; i < list.length; i += 1) s += (i ? sep : '') + Str(list[i]); return s; };
      const aUniqAdd = (list, v) => { if (!listHas(list, v)) listAdd(list, v); return list; };
      const weakNew = () => new WM();
      const weakGet = (m, k) => R_apply(WM_get, m, [k]);
      const weakSet = (m, k, v) => { R_apply(WM_set, m, [k, v]); };
      const weakHas = (m, k) => R_apply(WM_has, m, [k]) === true;
      // ---- 字串 ----
      const sOf = (t) => (t == null ? '' : Str(t));
      const sLower = (t) => R_apply(SP_toLowerCase, sOf(t), []);
      const sIdx = (t, sub, from) => R_apply(SP_indexOf, sOf(t), [sOf(sub), from || 0]);
      const sSlice = (t, a, b) => R_apply(SP_slice, sOf(t), b === undefined ? [a] : [a, b]);
      const sHas = (t, sub) => sIdx(t, sub) >= 0;
      const sCode = (t, i) => R_apply(S_charCodeAt, t, [i]);
      // 壓空白（跟 replace(/\s+/g, ' ').trim() 一樣）。
      const blankCode = (c) => c === 32 || (c >= 9 && c <= 13) || c === 160 || c === 0x1680 || (c >= 0x2000 && c <= 0x200a)
        || c === 0x2028 || c === 0x2029 || c === 0x202f || c === 0x205f || c === 0x3000 || c === 0xfeff;
      const safeSquash = (t) => {
        const s = sOf(t);
        let out = '';
        let gap = false;
        for (let i = 0; i < s.length; i += 1) {
          if (blankCode(sCode(s, i))) { gap = out.length > 0; continue; }
          if (gap) { out += ' '; gap = false; }
          out += s[i];
        }
        return out;
      };
      // 用空白切成字（aria-labelledby 的 id 清單）。
      const sWords = (t) => { const out = []; const s = safeSquash(t); let w = ''; for (let i = 0; i < s.length; i += 1) { if (s[i] === ' ') { if (w) listAdd(out, w); w = ''; } else w += s[i]; } if (w) listAdd(out, w); return out; };
      // 一個字一個字換掉或拿掉（不用 replace）：map 回 null＝拿掉，回字串＝換成它。
      const sMapChars = (t, map) => { const s = sOf(t); let out = ''; for (let i = 0; i < s.length; i += 1) { const r = map(sCode(s, i), s[i]); if (r !== null) out += r; } return out; };
      // 把每一個 sub 換成 rep（純字串，不用 split／replace）。
      const sReplaceAll = (t, sub, rep) => {
        const s = sOf(t);
        if (!sub) return s;
        let out = '';
        let at = 0;
        for (let i = sIdx(s, sub, 0); i >= 0; i = sIdx(s, sub, at)) { out += sSlice(s, at, i) + rep; at = i + sub.length; }
        return out + sSlice(s, at);
      };
      // RegExp：只用抓好的 exec（自己的 regex 物件，網頁拿不到）。
      const reExec = (re, t) => { re.lastIndex = 0; return R_apply(RE_exec, re, [sOf(t)]); };
      const reTest = (re, t) => reExec(re, t) !== null;
      // ---- DOM ----
      const safeParent = (el) => { try { return el ? (pget(G_parent, el) || null) : null; } catch (e) { return null; } };
      // HTML 元素的 tagName 本來就是大寫（不叫 toUpperCase）。
      const safeTag = (el) => { try { return el ? sOf(pget(G_tag, el)) : ''; } catch (e) { return ''; } };
      const safeAttr = (el, name) => { try { const v = el ? R_apply(M_getAttr, el, [name]) : null; return v == null ? '' : Str(v); } catch (e) { return ''; } };
      const hasAttr = (el, name) => { try { return !!el && R_apply(M_getAttr, el, [name]) !== null; } catch (e) { return false; } };
      const safeText = (el) => { try { return el ? sOf(pget(G_text, el)) : ''; } catch (e) { return ''; } };
      const safeBody = () => { try { return pget(G_body, document) || null; } catch (e) { return null; } };
      const safeContains = (root, el) => {
        if (!root || !el) return false;
        try { return R_apply(M_contains, root, [el]) === true; } catch (e) { return false; }
      };
      const nodeList = (list) => {
        const out = [];
        if (!list) return out;
        const n = pget(G_nlLength, list);
        for (let i = 0; i < n; i += 1) listAdd(out, R_apply(M_nlItem, list, [i]));
        return out;
      };
      // 用抓好的 querySelectorAll 找，放進自己的清單。
      const safeAll = (root, selector) => {
        if (!root) return [];
        try { return nodeList(R_apply(root === document ? M_qsaDoc : M_qsaEl, root, [selector])); } catch (e) { return []; }
      };
      const dNodeType = (n) => { try { return pget(G_nodeType, n); } catch (e) { return 0; } };
      // 子元素（childNodes 裡的元素節點；不讀網頁改得到的 children）。
      const dKids = (el) => {
        const out = [];
        let nodes = [];
        try { nodes = nodeList(pget(G_childNodes, el)); } catch (e) { return out; }
        for (let i = 0; i < nodes.length; i += 1) if (dNodeType(nodes[i]) === 1) listAdd(out, nodes[i]);
        return out;
      };
      // 一個元素自己的字（不含子元素的字）。
      const dOwnText = (el) => {
        let nodes = [];
        try { nodes = nodeList(pget(G_childNodes, el)); } catch (e) { return ''; }
        let t = '';
        for (let i = 0; i < nodes.length; i += 1) if (dNodeType(nodes[i]) === 3) { try { t += ' ' + sOf(pget(G_nodeValue, nodes[i])); } catch (e) {} }
        return t;
      };
      const dValue = (el) => {
        try {
          const tag = safeTag(el);
          if (tag === 'INPUT') return sOf(pget(G_inValue, el));
          if (tag === 'TEXTAREA') return sOf(pget(G_taValue, el));
          if (tag === 'SELECT') return sOf(pget(G_selValue, el));
          if (tag === 'OPTION') return sOf(pget(G_optValue, el));
        } catch (e) {}
        return '';
      };
      const dSetValue = (el, v) => {
        const tag = safeTag(el);
        const setter = tag === 'INPUT' ? S_inValue : (tag === 'TEXTAREA' ? S_taValue : (tag === 'SELECT' ? S_selValue : null));
        if (setter) R_apply(setter, el, [v]);
      };
      const dDisabled = (el) => {
        try {
          const tag = safeTag(el);
          const g = tag === 'INPUT' ? G_inDisabled : tag === 'TEXTAREA' ? G_taDisabled : tag === 'SELECT' ? G_selDisabled : tag === 'BUTTON' ? G_btnDisabled : null;
          return g ? pget(g, el) === true : false;
        } catch (e) { return true; }
      };
      const dReadOnly = (el) => {
        try {
          const tag = safeTag(el);
          const g = tag === 'INPUT' ? G_inReadOnly : tag === 'TEXTAREA' ? G_taReadOnly : null;
          return g ? pget(g, el) === true : false;
        } catch (e) { return true; }
      };
      const dSelected = (opt) => { try { return pget(G_optSelected, opt) === true; } catch (e) { return false; } };
      const dHidden = (el) => { try { return pget(G_hidden, el) === true; } catch (e) { return false; } };
      const dById = (id) => { try { return R_apply(M_getById, document, [id]) || null; } catch (e) { return null; } };
      const dStyle = (el, prop) => { try { return sOf(R_apply(M_gpv, R_apply(W_gcs, window, [el]), [prop])); } catch (e) { return ''; } };
      const dRectCount = (el) => { try { return pget(G_rlLength, R_apply(M_getClientRects, el, [])); } catch (e) { return 0; } };
      const dRect = (el) => {
        const r = R_apply(M_getBCR, el, []);
        return { left: pget(G_rectLeft, r), top: pget(G_rectTop, r), width: pget(G_rectWidth, r), height: pget(G_rectHeight, r) };
      };
      // 勾了沒：原生勾選框看 checked；其他（role=checkbox）看 aria-checked。
      const safeChecked = (el) => {
        if (safeTag(el) === 'INPUT') { try { return pget(G_checked, el) === true; } catch (e) { return false; } }
        return safeAttr(el, 'aria-checked') === 'true';
      };
      // 看得到：自己與上層沒有 hidden／aria-hidden；有畫出來的框；算出來的樣式不是 display:none、visibility:hidden。
      const shown = (el) => {
        if (!el) return false;
        for (let p = el, i = 0; p && i < 40; p = safeParent(p), i += 1) {
          if (dHidden(p) || safeAttr(p, 'aria-hidden') === 'true') return false;
        }
        if (dRectCount(el) === 0) return false;
        const display = dStyle(el, 'display');
        const visibility = dStyle(el, 'visibility');
        return display !== 'none' && visibility !== 'hidden' && visibility !== 'collapse';
      };
      const visibleOf = (root, selector) => aFilter(safeAll(root, selector), shown);
      // 動作：派送事件、點擊、聚焦（抓好的版本）。
      const dDispatch = (target, ev) => { try { R_apply(M_dispatch, target, [ev]); } catch (e) {} };
      const kpress = (el) => {
        const opts = { bubbles: true, cancelable: true, view: window, button: 0, buttons: 1, pointerId: 1, pointerType: 'mouse', isPrimary: true };
        if (C_Pointer) dDispatch(el, new C_Pointer('pointerdown', opts));
        dDispatch(el, new C_Mouse('mousedown', opts));
        if (C_Pointer) dDispatch(el, new C_Pointer('pointerup', opts));
        dDispatch(el, new C_Mouse('mouseup', opts));
        try { R_apply(M_click, el, []); } catch (e) {}
      };
      const ksetValue = (el, value) => {
        try { R_apply(M_focus, el, []); } catch (e) {}
        dSetValue(el, value);
        dDispatch(el, new C_Event('input', { bubbles: true }));
        dDispatch(el, new C_Event('change', { bubbles: true }));
      };
      // ==== SAFE-CHAIN END ====
      // 終止事件要等導頁／上傳／選單流程離開後才回報；Swift 收到後才會派下一則。
      const preparing = new Map();
      const postTerminal = (event) => {
        const work = preparing.get(event.id);
        Promise.resolve().then(() => work && work.promise).then(() => {
          if (!work || !work.command.cancelled) post(event);
        });
      };
      const originalFetch = window.fetch.bind(window);
      const KEEP = /^(authorization|chatgpt-account-id|oai-device-id|oai-client-version|oai-client-build-number|oai-language)$/i;
      let auth = null;
      // Counts real account/token changes, so A→B→A during one destructive step is still a change.
      let authEpoch = 0;
      const authWaiters = [];
      let pendingSend = null;
      // 僅本文件、單一對話的證據；不保存內容／偏好，重載即失效。
      let personalizedProof = null;
      let personalizedRevocation = 'none';
      let personalizedIDDiagnostic = null; // 只持有當輪固定診斷值，不保存 turn、路徑或代號。
      // 證據撤銷不代表原生頁已重設；保留這個記憶體 latch，直到真的按原生新聊天並確認空頁。
      let nativeNewChatRequired = false;
      let preparingNewChat = null;
      let nativeResetWatch = null;
      let newChatEpoch = 0, newChatPath = location.pathname;
      const revokePersonalizedProof = (reason) => {
        if (!personalizedProof) return;
        personalizedRevocation = ['response_id_conflict', 'turn_failed', 'cancelled', 'request_guard',
          'origin_changed', 'route_changed', 'mode_changed', 'mode_reversal', 'new_initial'].includes(reason) ? reason : 'other';
        personalizedProof.revoked = true;
        personalizedDiagnostic('revoked');
        personalizedProof = null;
      };
      // 使用者選的模型／推理強度：送出前網頁會先 POST f/conversation/prepare（拿 x-conduit-token），兩個請求都要一致。
      let pendingModel = null;
      let pendingEffort = null;
      let pendingHint = null;
      let pendingTemporary = false;
      // 接在哪一支後面（切換過版本、或編輯訊息）：改寫網頁送出的上一層節點。
      let pendingParent = null;
      // 在專案／GPT 裡開新對話：送出內容要帶 conversation_mode（gizmo_interaction＋gizmo_id）。
      let pendingGizmo = null;
      // 停止時已按了送出、網頁還沒發出請求的那幾則：之後晚到的請求在 fetch 這裡擋掉（不轉發、不歸給下一則），
      // 所以停止不必等網頁、也不必收掉 Pod。指紋只有文字與對話代號，只在記憶體裡比對，不回報、不落地。
      let cancelledSends = [];
      const printText = (t) => (typeof t === 'string' && t.replace(/\s+/g, ' ').trim()) || null;
      // 網頁送出請求的指紋：最後一則訊息的文字＋對話代號。
      const sendPrint = (init) => {
        try {
          const body = JSON.parse(init && typeof init.body === 'string' ? init.body : '');
          const list = body && Array.isArray(body.messages) ? body.messages : [];
          const last = list[list.length - 1];
          const parts = last && last.content && Array.isArray(last.content.parts) ? last.content.parts : [];
          return { text: printText(parts[0]), conversationID: (body && typeof body.conversation_id === 'string' && body.conversation_id) || null };
        } catch (e) { return null; }
      };
      const samePrint = (job, print) => !!job && !!print && printText(job.text) === print.text
        && (job.conversationID || null) === print.conversationID;
      const abortError = () => {
        try { return new DOMException('The operation was aborted.', 'AbortError'); }
        catch (e) { const x = new Error('The operation was aborted.'); x.name = 'AbortError'; return x; }
      };
      // 語音結束後的保險（見 voice）。
      let voiceGuard = null;
      let voiceStopAt = 0;
      let voiceEpoch = 0;
      const voiceUsable = (b) => b && !b.disabled && !b.hidden && b.getAttribute('aria-disabled') !== 'true'
        && (typeof b.getClientRects !== 'function' || b.getClientRects().length > 0);
      const voiceEndButton = () => [...document.querySelectorAll('button')].find((b) => voiceUsable(b)
        && /end voice mode|end call|結束語音|结束语音/i.test(String(b.getAttribute('aria-label') || b.textContent || '')));
      // 診斷（只有欄位名稱與像代號的短值，沒有內容），設定 › Plugin › TAP 顯示。
      const diag = {};
      // 隱私旗標只記固定欄位的型別／布林值，不記請求正文、對話內容、帳號或登入資料。
      // 這是觀察，不是私有欄位語義的推測；既有送出 guard 保留。
      const privacyShape = (body) => ['history_and_training_disabled', 'is_do_not_remember',
        'is_temporary', 'temporary_chat'].map((key) => {
          const value = body && Object.prototype.hasOwnProperty.call(body, key) ? body[key] : undefined;
          return key + '=' + (value === true ? 'true' : value === false ? 'false' : value === undefined ? 'absent' : 'other');
        }).join(', ');
      const EFFORT_KEY = /^(thinking_effort|reasoning_effort|effort)$/;
      const withModel = (init, model, effort, label) => {
        if (!init || typeof init.body !== 'string') return init;
        try {
          const body = JSON.parse(init.body);
          if (!body || typeof body !== 'object') return init;
          if (label) {
            diag[label + '原生隱私'] = privacyShape(body);
            diag[label + '欄位'] = Object.keys(body).sort().join('+').slice(0, 200);
            const found = Object.keys(body).filter((k) => /model|effort|mode|thinking|reason/i.test(k));
            diag[label + '模型相關'] = found.map((k) => k + '=' + (typeof body[k] === 'string' && body[k].length <= 40 ? body[k] : typeof body[k])).join(', ') || '-';
          }
          if (label === '送出請求') reportSelection(body.model, typeof body.thinking_effort === 'string' ? body.thinking_effort : null);
          let changed = false;
          if (model && 'model' in body) { body.model = model; changed = true; }
          const effortKey = Object.keys(body).find((k) => EFFORT_KEY.test(k));
          if (effort) {
            // 網頁原本用沒有強度的模型（Auto、Instant）時請求裡沒有強度欄位：補上網頁送出時用的 thinking_effort（審查 #7）。
            body[effortKey || 'thinking_effort'] = effort;
            changed = true;
            if (label) diag[label + '推理強度'] = effortKey ? '已套用 ' + effortKey : '已補上 thinking_effort';
          } else if (model && effortKey && modelReasoning[model] === 'none') {
            // 換成沒有推理強度的模型（例如 Instant）：拿掉網頁原本帶的強度（09-24 實機：留著 max 會照樣用思考模型回答）。
            delete body[effortKey];
            changed = true;
          }
          // 「＋」選的工具（生圖、搜尋…）：跟網頁版一樣放進 system_hints。
          if (pendingHint) { body.system_hints = [pendingHint]; changed = true; }
          if (pendingParent && 'parent_message_id' in body) {
            body.parent_message_id = pendingParent;
            changed = true;
            if (label) diag['接續節點'] = label + '：已改寫';
          }
          // 專案／GPT 裡的新對話：沒有帶 conversation_mode 就會建成一般對話（09-25 實機：從專案送出，對話跑到一般清單）。
          // W180 A2（09-27 實機）：準備請求（/prepare）不帶 conversation_mode——網頁自己的準備請求沒有這欄，
          // 補上後網頁收到準備結果就不再送出（專案裡送出／生圖一律「沒有送出」）。只在真正的送出請求補。
          if (pendingGizmo && label !== '準備請求') {
            const mode = body.conversation_mode;
            const already = !!(mode && mode.kind === 'gizmo_interaction' && mode.gizmo_id === pendingGizmo);
            if (!already) { body.conversation_mode = { kind: 'gizmo_interaction', gizmo_id: pendingGizmo }; changed = true; }
            if (label) diag['專案／GPT'] = label + '：' + (already ? '網頁已帶' : '已補上 conversation_mode');
          }
          // 暫時對話（不存紀錄）：網頁版送出時帶的旗標。
          if (pendingTemporary) {
            body.history_and_training_disabled = true;
            changed = true;
            if (label) diag['暫時對話'] = '已帶 history_and_training_disabled（原本' + ('history_and_training_disabled' in JSON.parse(init.body) ? '就有' : '沒有') + '這個欄位）';
          }
          if (changed && label) {
            diag[label + '改寫隱私'] = privacyShape(body);
            const k = Object.keys(body).find((x) => EFFORT_KEY.test(x));
            diag[label + '改寫後'] = 'model=' + (typeof body.model === 'string' ? body.model.slice(0, 40) : '-') + '，強度=' + (k ? String(body[k]).slice(0, 12) : '無');
          }
          return changed ? Object.assign({}, init, { body: stringify(body) }) : init;
        } catch (e) { return init; }
      };
      // W184 G3c（GPT-6 審查 #1）：臨時聊天一定要確認「實際送出的內容」帶了不存紀錄的旗標才放行。網頁用非字串的 body（位元組、Blob、串流）
      // 先讀成字串（改寫才套得上）；改寫完讀回來確認 history_and_training_disabled === true，確認不了（讀不到、不是 JSON 物件、改寫出錯）
      // 就擋下不送、回報失敗——絕不照一般對話送出去。
      const TEMP_BLOCKED = '臨時聊天沒有送出：網頁的送出內容沒能確認帶上「不存紀錄」的旗標，已擋下（沒有送出）';
      const TEMP_UNCONFIRMED = '臨時聊天沒能確認帶上「不存紀錄」的旗標（網頁沒有走會加旗標的送出路徑），這一則可能存進了 ChatGPT 的紀錄';
      const textBody = async (init) => {
        const body = init && init.body;
        if (body == null || typeof body === 'string') return init;
        try {
          let text = null;
          if (typeof ArrayBuffer === 'function' && (ArrayBuffer.isView(body) || body instanceof ArrayBuffer)) text = new TextDecoder().decode(body);
          else if (typeof Blob === 'function' && body instanceof Blob) text = await body.text();
          else if (typeof ReadableStream === 'function' && body instanceof ReadableStream) text = await new Response(body).text();
          return typeof text === 'string' ? Object.assign({}, init, { body: text }) : init;
        } catch (e) { return init; }
      };
      const temporaryFlagged = (init) => {
        try {
          const body = init && typeof init.body === 'string' ? JSON.parse(init.body) : null;
          return !!body && typeof body === 'object' && !Array.isArray(body) && body.history_and_training_disabled === true;
        } catch (e) { return false; }
      };
      const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      const waitFor = async (test, ms) => {
        const end = Date.now() + ms;
        while (Date.now() < end) { const v = test(); if (v) return v; await sleep(120); }
        return null;
      };
      const captureAuth = (input, init) => {
        try {
          const headers = new Headers((init && init.headers) || (input && input.headers) || {});
          if (!headers.get('authorization')) return;
          const kept = {};
          headers.forEach((v, k) => { if (KEEP.test(k)) kept[k] = v; });
          const first = !auth;
          if (auth && (own(kept, 'authorization') !== own(auth, 'authorization')
            || own(kept, 'chatgpt-account-id') !== own(auth, 'chatgpt-account-id'))) authEpoch += 1;
          auth = kept;
          if (first) { post({ type: 'auth' }); authWaiters.splice(0).forEach((f) => f()); }
        } catch (e) {}
      };

      // 一次送出＝一個 turn（09-24 實機：串流解析全部落空，回答卻在網頁上；所以不只靠串流）：
      // ① 串流解析得到就用（保留 Markdown）；② 解析不到就讀網頁畫面上正在長出來的回答文字；
      // ③ 等網頁的停止鍵消失才算完成（生圖這種慢的也等得到）；對話編號拿不到就看網址 /c/<id>。
      // 串流格式只統計事件名稱與欄位名稱（shape），給設定頁診斷用；不含任何內容。
      const turns = {};
      // 按鈕標籤：只留短的字母／中文標籤，其他一律不回報（審查 #2）。
      const safeLabel = (v) => { const t = String(v || '').trim(); return /^[A-Za-z\u4e00-\u9fff][A-Za-z\u4e00-\u9fff -]{0,23}$/.test(t) ? t : (t ? '<label>' : ''); };
      // 連線只記「種類＋路徑」：去掉編號、長代碼與參數，不含內容。
      const maskPath = (u) => {
        try {
          const x = new URL(u, location.href);
          return (x.host === location.host ? '' : x.host) + x.pathname
            .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, '<id>')
            .replace(/\/[A-Za-z0-9_-]{20,}/g, '/<id>').slice(0, 64);
        } catch (e) { return '?'; }
      };
      const activeTurn = () => { for (const k in turns) { if (!turns[k].finished) return turns[k]; } return null; };
      const sockets = [];
      // 探查相簿頁時，記錄期間的後台請求路徑（去編號）。
      let libraryWatch = null;
      // 分享：按網頁自己的分享鈕時，攔下網頁產生的公開連結（網頁要寫進剪貼簿的、或回應裡的 /share/…）；不動使用者的剪貼簿。
      const shareCapture = { active: false, url: null };
      const SHARE_URL = /https:\/\/chatgpt\.com\/(?:share|s)\/[A-Za-z0-9_-]{6,}/;
      const SHARE_PATH = /"(\/(?:share|s)\/[0-9a-f]{8}-[0-9a-f-]{27,})"/i;
      try {
        const clip = navigator.clipboard;
        if (clip && typeof clip.writeText === 'function') {
          const originalWrite = clip.writeText.bind(clip);
          clip.writeText = (text) => {
            if (shareCapture.active) {
              const m = SHARE_URL.exec(String(text || ''));
              if (m) { shareCapture.url = m[0]; return Promise.resolve(); }
            }
            return originalWrite(text);
          };
        }
      } catch (e) {}
      const UUID_IN_PATH = /\/c\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/i;
      const conversationFromURL = () => { const m = UUID_IN_PATH.exec(location.pathname); return m ? m[1] : null; };
      const assistantNodes = () => document.querySelectorAll('[data-message-author-role="assistant"]');
      const stopVisible = () => !!document.querySelector('[data-testid="stop-button"]');
      const newShape = () => ({ events: 0, json: 0, other: 0, names: {}, types: {}, ops: {}, paths: {}, keys: {}, headers: '',
        net: {}, ws: {}, handoff: {} });
      const bump = (bag, key, cap = 8) => {
        if (key == null) return;
        const k = String(key).slice(0, 64);
        if (k in bag || Object.keys(bag).length < cap) bag[k] = (bag[k] || 0) + 1;
      };
      const diagnosticCode = (value) => typeof value === 'string' && /^[a-z0-9_.:-]{1,64}$/i.test(value)
        && !/(?:sk-|eyJ)[a-z0-9_-]+|[a-z0-9_-]{32,}/i.test(value) ? value : 'unknown_code';
      const shapeText = (s) => {
        const list = (bag) => Object.keys(bag).map((k) => k + '×' + bag[k]).join(', ') || '-';
        return '事件 ' + s.events + '（JSON ' + s.json + '、其他 ' + s.other + '）；event: ' + list(s.names) + '；type: ' + list(s.types)
          + '；o: ' + list(s.ops) + '；p: ' + list(s.paths) + '；欄位: ' + list(s.keys) + (s.headers ? '；' + s.headers : '')
          + '；交棒: ' + list(s.handoff) + '；連線: ' + list(s.net) + '；WS: ' + list(s.ws) + '；已開 WS: ' + (sockets.join(', ') || '-');
      };
      const setConversation = (turn, conversationID, fromSendResponse = false) => {
        if (!fromSendResponse && personalizedReadBlocked(turn)) return;
        const proof = turn.personalizedProof;
        const idDiagnostic = fromSendResponse ? notePersonalizedOriginalID(turn, conversationID) : null;
        const proofWasCurrent = !!proof && proof === personalizedProof;
        // URL、DOM、輪詢或別條 SSE 不可建立證據；也不能略過已回報代號之後的衝突。
        if (fromSendResponse && proof && proof === personalizedProof && !turn.finished && !turn.cancelled
            && turn.accepted && turn.personalizedOriginal && turn.temporaryConfirmed && proofPageOK(proof, location.pathname, 'response')) {
          if (!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(conversationID)
              || [turn.conversationID, turn.requestConversationID, proof.conversationID, proof.routeID]
                .some((id) => id && id !== conversationID)) {
            finishPersonalizedIDDiagnostic(idDiagnostic, 'id_conflict');
            revokePersonalizedProof('response_id_conflict');
            finishTurn(turn, '個人化臨時聊天的回應對話不符，已停止接續');
            return;
          }
          proof.conversationID = conversationID;
          finishPersonalizedIDDiagnostic(idDiagnostic, 'bound');
          personalizedDiagnostic('response_bound');
        } else if (fromSendResponse) {
          finishPersonalizedIDDiagnostic(idDiagnostic, !proofWasCurrent ? 'proof_missing'
            : turn.finished || turn.cancelled || !turn.accepted || !turn.personalizedOriginal || !turn.temporaryConfirmed
              ? 'turn_ineligible' : 'page_rejected');
        }
        if (!conversationID || typeof conversationID !== 'string' || turn.conversationPosted) return;
        // W184 G3c：臨時聊天沒確認帶了旗標（沒經過會加旗標的送出）＝不回報對話代號（App 不能把它當成臨時聊天）。
        if (turn.temporary && !turn.temporaryConfirmed) return;
        turn.conversationID = conversationID;
        turn.conversationPosted = true;
        post({ type: 'stream', id: turn.id, kind: 'conversation', conversationID });
      };
      // Error/progress content travels only to the local UI. Shape diagnostics never include it.
      const localText = (value, limit = 160) => {
        const rules = \#(ChatGPTLocalText.privacyRulesJSON);
        const safe = rules.reduce((text, rule) => text.replace(new RegExp(rule.pattern, 'gi'), rule.replacement), String(value || '')).trim();
        return Array.from(safe).slice(0, Math.max(0, limit)).join('');
      };
      const tooLong = (v) => /太長|过长|過長|超過.{0,12}(?:長度|上限)|超出.{0,12}(?:長度|上限)|(?:長度|长度).{0,12}(?:上限|限制)|too[ _-]?long|conversation_too_long|context[_ -]?length|max(?:imum)?[ _-]?length/i.test(String(v || ''));
      const errorValue = (v) => {
        if (typeof v === 'string') return v;
        if (!v || typeof v !== 'object') return '';
        return [v.message, v.detail, v.error, v.code].map((x) => typeof x === 'string' ? x
          : x && typeof x === 'object' ? (x.message || x.code || '') : '').find((x) => typeof x === 'string' && x.trim()) || '';
      };
      const extractError = (obj, marked = false, depth = 0) => {
        if (depth > 6 || obj == null || obj === false) return null;
        if (typeof obj === 'string') return marked && obj.trim() ? { message: obj, code: '' } : null;
        if (typeof obj !== 'object') return null;
        if (Array.isArray(obj)) {
          for (const item of obj) { const found = extractError(item, marked, depth + 1); if (found) return found; }
          return null;
        }
        const hasErrorField = Object.keys(obj).some((k) => /^(?:error|detail|error_message|error_code|finish_error)$/i.test(k)
          && obj[k] != null && obj[k] !== false && (obj[k] === true || typeof obj[k] === 'object' || (typeof obj[k] === 'string' && obj[k].trim())));
        const flag = marked || hasErrorField || /error|failed|failure/i.test([obj.type, obj.content_type, obj.status].join(' '))
          || obj.is_error === true || !!(obj.metadata && (obj.metadata.is_error === true || obj.metadata.error || obj.metadata.error_code));
        for (const k of Object.keys(obj)) {
          if (/^(?:error|detail|error_message|error_code|finish_error)$/i.test(k) && obj[k] != null && obj[k] !== false) {
            const message = errorValue(obj[k]) || (flag ? errorValue(obj) : '');
            if (message) return { message, code: String((obj[k] && obj[k].code) || obj.code || obj.error_code || [obj.type, obj.content_type, obj.status].join(' ')) };
          }
        }
        if (flag) {
          const metadataError = obj.metadata && obj.metadata.error;
          const metadataMessage = typeof metadataError === 'string' ? metadataError : metadataError && metadataError.message;
          const parts = obj.parts || (obj.content && obj.content.parts);
          const message = errorValue(obj) || metadataMessage || (parts && parts.filter((x) => typeof x === 'string').join(' '));
          if (message) return { message, code: String(obj.code || obj.error_code || (obj.metadata && (obj.metadata.error_code || metadataError && metadataError.code)) || [obj.type, obj.content_type, obj.status].join(' ')) };
        }
        for (const k of ['message', 'metadata', 'content', 'v', 'data', 'payload', 'finish_details']) {
          const found = extractError(obj[k], flag, depth + 1); if (found) return found;
        }
        return flag ? { message: 'ChatGPT 回報錯誤', code: String(obj.code || [obj.type, obj.content_type, obj.status].join(' ')) } : null;
      };
      const failProvider = (turn, error) => {
        if (!error || turn.finished) return false;
        const reason = tooLong(error.code + ' ' + error.message) ? 'conversation_too_long' : 'provider_failed';
        finishTurn(turn, 'ChatGPT：' + error.message, reason);
        return true;
      };
      const progress = (turn, title = '', server = false) => {
        if (turn.finished || turn.cancelled) return;
        turn.lastActivity = Date.now();
        turn.hasThinkingProgress = true;
        if (title) turn.progressTitle = localText(title, 80);
        if (server) turn.serverThinking = true;
        const text = turn.progressTitle || '', remote = !!turn.serverThinking;
        if (turn.postedProgressTitle === text && turn.postedProgressServer === remote) return;
        turn.postedProgressTitle = text; turn.postedProgressServer = remote;
        post({ type: 'stream', id: turn.id, kind: 'progress', title: text, server: remote });
      };
      const extractProgress = (turn, obj, eventName = '') => {
        const content = obj && obj.message && obj.message.content;
        const typed = /thought|reasoning_recap|reasoning_summary/i.test(String(eventName) + ' ' + String(obj && obj.type || '') + ' ' + String(content && content.content_type || ''));
        if (!typed) return;
        // Only explicit headings; text/summary/body fields can contain full reasoning.
        const heading = (v, depth = 0) => {
          if (depth > 8 || !v || typeof v !== 'object') return '';
          if (typeof v.title === 'string') return v.title;
          if (typeof v.summary_title === 'string') return v.summary_title;
          for (const k of ['thoughts', 'reasoning_recap', 'content', 'data', 'v']) {
            const candidates = Array.isArray(v[k]) ? v[k].slice().reverse() : [v[k]];
            for (const item of candidates) { const t = heading(item, depth + 1); if (t) return t; }
          }
          return '';
        };
        progress(turn, heading(obj) || heading(content));
      };
      const markedErrorNodes = () => Array.from(document.querySelectorAll('[role="alert"], [data-testid="conversation-error"], [data-testid="error-message"], [class*="text-error"], [class*="text-red-"], [class*="bg-error"], [class*="bg-red-"], [class*="border-red-"], [data-state="error"]'));
      const ERROR_WORDS = /出錯|錯誤|错误|無法繼續|无法继续|太長|过长|過長|something went wrong|error|failed|unable to|too long|max(?:imum)?[ _-]?length|context.length|reach.{0,40}(?:limit|length)|usage cap|rate limit|(?:長度|长度).{0,12}(?:上限|限制)|稍後再試|please try again|problem (?:generating|loading)/i;
      const errorNodes = () => {
        const nodes = markedErrorNodes();
        for (const button of document.querySelectorAll('button, [role="button"]')) {
          if (!/^(?:retry|try again|重新產生|重新生成|重試)$/i.test(String(button.innerText || button.getAttribute('aria-label') || '').trim())) continue;
          let box = button.parentElement;
          for (let i = 0; box && i < 3; i++, box = box.parentElement) {
            if ((box.matches('main') || box.matches('[role="main"]'))) break;
            // Regenerate actions under a normal Markdown answer are not error boxes.
            if (box.querySelectorAll('.markdown, .prose').length) break;
            if (ERROR_WORDS.test(String(box.innerText || box.textContent || ''))) { nodes.push(box); break; }
          }
        }
        return nodes;
      };
      const pageError = (turn) => {
        for (const node of errorNodes()) {
          if (!chatVisible(node) || !(node.closest('main, [role="main"], [data-message-author-role="assistant"]'))) continue;
          if (node.closest('[data-message-author-role="user"]')) continue;
          if (node.closest('.markdown, .prose') && node.getAttribute('role') !== 'alert') continue;
          const text = String(node.innerText || node.textContent || '').trim();
          if (!text || turn.oldErrors.get(node) === text) continue;
          // Ordinary answer text and the Pro thinking placeholder are never error evidence.
          if (!ERROR_WORDS.test(text)) continue;
          return { message: text, code: '' };
        }
        return null;
      };
      const thinkingPlaceholder = (text) => /^(?:(?:chatgpt|pro|gpt[ -]?[\d.]+)\s*)?(?:thinking|思考中|正在思考|正在深度思考)[\s.…]*$/i.test(text);
      const thinkingEvidence = (turn) => turn.hasThinkingProgress || turn.asyncThinking
        || (!personalizedReadBlocked(turn) && (stopVisible() || assistantNodes().length > turn.before));
      const NO_PROGRESS = '\#(noProgressMessage)';
      const inspectConversation = (turn, convo) => {
        if (failProvider(turn, extractError(convo))) return true;
        const head = convo && convo.mapping && convo.mapping[convo.current_node];
        const m = head && head.message;
        const fresh = !!m && convo.current_node !== turn.requestParentID && m.id !== turn.requestParentID
          && (!m.create_time || m.create_time * 1000 >= turn.started - 5000);
        if (fresh && failProvider(turn, extractError(m))) return true;
        if (fresh) extractProgress(turn, { message: m });
        if (fresh && /^(?:analysis|reasoning)$/.test(String(m.channel || ''))) progress(turn, '', true);
        const fingerprint = JSON.stringify([convo && convo.current_node, m && m.status, m && m.content, convo && convo.async_status]);
        if (fingerprint !== turn.pollFingerprint) {
          if (turn.pollFingerprint !== undefined || fresh) turn.lastActivity = Date.now();
          turn.pollFingerprint = fingerprint;
        }
        const async = convo && convo.async_status;
        turn.asyncThinking = !!async && !/^(?:done|completed|finished|failed|idle|none)$/i.test(String(async));
        if (turn.asyncThinking) progress(turn, '', true);
        return false;
      };
      async function confirmSilence(turn) {
        turn.confirmingSilence = true;
        const since = turn.lastActivity;
        const id = turn.conversationID || conversationFromURL();
        if (id && !personalizedReadBlocked(turn)) {
          try {
            const convo = await Promise.race([api(conversationPath(id)), sleep(3500).then(() => null)]);
            if (turn.finished) return;
            if (convo && inspectConversation(turn, convo)) return;
          } catch (e) { bump(turn.shape.types, 'silence-confirm-error'); }
        }
        turn.confirmingSilence = false;
        if (!turn.finished && turn.lastActivity === since && !thinkingEvidence(turn)) finishTurn(turn, NO_PROGRESS, 'no_progress');
      }
      async function responseError(response) {
        let reader;
        try {
          reader = response.clone().body.getReader();
          const deadline = Date.now() + 2500;
          const bytes = new Uint8Array(2048); let length = 0;
          while (length < bytes.length && Date.now() < deadline) {
            const next = await Promise.race([reader.read(), sleep(Math.max(1, deadline - Date.now())).then(() => ({ done: true }))]);
            if (next.done) break;
            const chunk = next.value.subarray(0, bytes.length - length);
            bytes.set(chunk, length); length += chunk.length;
          }
          if (typeof reader.cancel === 'function') reader.cancel().catch(() => {});
          const text = new TextDecoder().decode(bytes.subarray(0, length));
          try { const obj = JSON.parse(text); return extractError(obj) || (obj.code ? { message: String(obj.code), code: String(obj.code) } : null); }
          catch (e) { return null; }
        } catch (e) { return null; }
      }
      function finishTurn(turn, failure, reason) {
        if (turn.finished) return;
        // W184 G3c：臨時聊天的這一輪沒有經過確認帶了旗標的送出，卻在網頁上完成了（網頁走了別的路送出）＝失敗，說清楚可能存進了紀錄。
        if (!failure && turn.temporary && !turn.temporaryConfirmed) failure = TEMP_UNCONFIRMED;
        if (turn.personalizedProof === personalizedProof && personalizedProof) {
          if (failure || turn.cancelled) revokePersonalizedProof(turn.cancelled ? 'cancelled' : 'turn_failed');
          else if (personalizedProof.localPath && (!proofPageOK(personalizedProof, location.pathname, 'finish')
              || !personalizedProof || !personalizedProof.routeID
              || personalizedProof.routeID !== personalizedProof.conversationID
              || personalizedProof.path !== '/c/' + personalizedProof.conversationID
              || !turn.accepted || !turn.personalizedOriginal || !turn.originalSSEEnded)) {
            // 候選過渡不是完成證據；首句收尾仍缺原始 SSE 或 canonical 時永久撤銷，不等晚到導航復活。
            revokePersonalizedProof('turn_failed');
          }
          else {
            personalizedProof.complete = !!(turn.personalizedOriginal && personalizedProof.conversationID);
            personalizedDiagnostic('completed');
          }
        }
        turn.finished = true;
        clearInterval(turn.timer);
        delete turns[turn.id];
        if (pendingSend && pendingSend.id === turn.id) {
          pendingSend = null;
          pendingModel = pendingEffort = pendingHint = pendingParent = pendingGizmo = null;
          pendingTemporary = false;
        }
        if (!failure) setConversation(turn, turn.conversationID || conversationFromURL());
        if (failure) { postTerminal({ type: 'stream', id: turn.id, kind: 'failed', message: localText(failure), reason }); return; }
        postTerminal({ type: 'stream', id: turn.id, kind: 'finished', conversationID: turn.conversationID,
          parsed: turn.sseText, shape: shapeText(turn.shape) });
      }
      function tick(turn) {
        if (turn.finished) return;
        if (turn.personalizedProof) proofPageOK(turn.personalizedProof, location.pathname, 'tick');
        if (Date.now() - turn.started >= 35 * 60 * 1000) { finishTurn(turn, 'ChatGPT 回答逾時', 'timeout'); return; }
        const readBlocked = personalizedReadBlocked(turn);
        if (!readBlocked && turn.accepted && thinkingEvidence(turn)) turn.lastActivity = Date.now();
        if (turn.accepted && Date.now() - turn.lastActivity < 5000 && Date.now() - (turn.lastHeartbeat || 0) >= 2000) {
          turn.lastHeartbeat = Date.now();
          post({ type: 'stream', id: turn.id, kind: 'activity' });
        }
        if (turn.accepted && Date.now() - turn.lastActivity >= 180000 && !turn.confirmingSilence) confirmSilence(turn);
        // A personalized first turn still reads only its original stream.
        if (readBlocked) {
          if (turn.originalSSEEnded && turn.sseText) finishTurn(turn);
          return;
        }
        // Error boxes need a full DOM scan only once per second; stream errors remain immediate.
        if (turn.lastErrorScan == null || Date.now() - turn.lastErrorScan >= 1000) {
          turn.lastErrorScan = Date.now();
          if (failProvider(turn, pageError(turn))) return;
        }
        const stopping = stopVisible();
        if (stopping) turn.sawStop = true;
        // During known reasoning, page bubbles can contain recap bodies; only the
        // answer stream or authoritative conversation read may publish answer text.
        if (!turn.sseText && !turn.hasThinkingProgress) {
          const nodes = assistantNodes();
          if (nodes.length > turn.before) {
            const text = String(nodes[nodes.length - 1].innerText || '').trim();
            if (text && !thinkingPlaceholder(text) && text !== turn.domText) {
              turn.domText = text;
              post({ type: 'stream', id: turn.id, kind: 'text', messageID: 'page', full: text });
            }
          }
        }
        if (!turn.conversationPosted) setConversation(turn, conversationFromURL());
        // 送出的串流結束了卻沒有文字（回答走別的路：pubsub 等；09-25 實機：專案裡用 6 Pro，串流 0 個事件）：
        // 知道是哪則對話就跟轉線一樣改讀對話；還不知道就多等一下網址換過去。
        // 網頁畫面上的字不算答案：Pro 還在想時畫面上是「Pro thinking」這類佔位字（09-25 實機 .035：專案 6 Pro 被它提早收工）。
        // 網頁的停止鍵消失也不算：Pro 在伺服器上想的時候停止鍵會先不見，串流還開著（09-25 實機 .036：送出後十秒就被判完成）。
        const quiet = !turn.sseText && !turn.handoff
          && (turn.sseEnded || (turn.sawStop && !stopping && Date.now() - turn.started > 1500));
        if (quiet) {
          if (turn.conversationID || conversationFromURL()) turn.handoff = true;
          else if (turn.project && !turn.projectLookupEnded) { if (!turn.lookingUp) findProjectConversation(turn); return; }
          else if (turn.sseEnded && Date.now() - (turn.sseEndedAt || 0) < 1500) return;
        }
        // 轉線的回答（stream_handoff）：續傳串流把答案送完（有文字、串流結束）就算完成；沒有續傳就交給 pollTurn 讀對話判斷。
        // 串流還開著但一直沒有文字也照樣讀對話（伺服器說完成才算完成）。
        const done = !stopping && (turn.handoff ? (turn.sseText && turn.sseEnded)
          : (turn.sseEnded || (turn.sawStop && Date.now() - turn.started > 1500)));
        if (turn.handoff && !turn.polling && (turn.sseEnded || !turn.sseText)) pollTurn(turn);
        if (done && (turn.sseText || turn.domText) && !turn.handoff) finishTurn(turn);
        else if (done && turn.handoff && turn.sseText) finishTurn(turn);
      }
      // 專案裡送出後網頁不一定換網址：去專案清單找這一輪之後建立的那則，找到就改讀它（最多找 2 分鐘；09-25 實機）。
      async function findProjectConversation(turn) {
        turn.lookingUp = true;
        const deadline = Date.now() + 120000;
        while (!turn.finished && Date.now() < deadline) {
          await sleep(2000);
          const id = turn.conversationID || conversationFromURL();
          if (id) { setConversation(turn, id); turn.handoff = true; return; }
          try {
            const j = await api('/backend-api/gizmos/' + encodeURIComponent(turn.project) + '/conversations?cursor=0');
            const items = j && (Array.isArray(j.items) ? j.items : (j.conversations && Array.isArray(j.conversations.items) ? j.conversations.items : null));
            if (!items) { turn.projectLookupEnded = true; turn.lookingUp = false; return; }
            const newest = items.map((it) => (it && it.conversation) || it).filter((c) => c && typeof c.id === 'string')
              .map((c) => ({ id: c.id, t: Date.parse(c.create_time || c.update_time || '') || (typeof c.create_time === 'number' ? c.create_time * 1000 : 0) }))
              .filter((c) => c.t >= turn.started - 15000).sort((a, b) => b.t - a.t)[0];
            if (newest) { setConversation(turn, newest.id); turn.handoff = true; bump(turn.shape.types, 'project-found'); return; }
          } catch (e) { bump(turn.shape.types, 'project-lookup-error'); }
        }
        if (!turn.finished) finishTurn(turn);
      }
      // 轉線（stream_handoff，例如 Pro 在伺服器上慢慢想）：送出的串流很快就結束，回答要過一陣子才出來，
      // 背景網頁也不一定有停止鍵（09-25 實機：專案裡用 6 Pro，答案出來前就判定沒收到）。
      // 改成每幾秒讀一次這則對話，最新一則回答完成才算結束；中途的文字也照樣顯示。
      async function pollTurn(turn) {
        if (personalizedReadBlocked(turn)) return;
        turn.polling = true;
        if (!turn.serverThinking) progress(turn, '', true);
        let wait = 1200;
        while (!turn.finished) {
          await sleep(wait);
          if (personalizedReadBlocked(turn)) { turn.polling = false; return; }
          wait = Math.min(wait + 700, 3000);
          const id = turn.conversationID || conversationFromURL();
          if (!id || turn.finished) continue;
          setConversation(turn, id);
          let convo = null;
          try { convo = await api(conversationPath(id)); } catch (e) {
            bump(turn.shape.types, 'poll-error');
            // A failed read is not successful completion. The silence confirmation owns recovery.
            continue;
          }
          if (turn.finished || personalizedReadBlocked(turn)) { turn.polling = false; return; }
          bump(turn.shape.types, 'poll');
          // Error envelopes are checked before requiring a conversation mapping.
          if (inspectConversation(turn, convo)) return;
          if (!convo || typeof convo.mapping !== 'object' || !convo.mapping) continue;
          const head = convo.mapping[convo.current_node];
          const m = head && head.message;
          // 只認這一輪之後產生的回答：伺服器可能還回上一輪的節點（審查 #10）。
          const fresh = !!m && convo.current_node !== turn.requestParentID && m.id !== turn.requestParentID && (!m.create_time || m.create_time * 1000 >= turn.started - 5000);
          const role0 = m && m.author && m.author.role;
          // 診斷只記代號：讀到的最新節點是誰、什麼狀態、有沒有 async 狀態（不記內容）。
          const code = (v) => (v == null ? '-' : /^[a-z0-9_.-]{1,24}$/i.test(String(v)) ? String(v) : typeof v);
          bump(turn.shape.handoff, 'poll=' + code(role0) + '/' + code(m && m.status) + (fresh ? '' : '/old')
            + (convo.async_status != null ? '/async:' + code(convo.async_status) : ''));
          // A thinking bubble is positive evidence; tick keeps the three-minute clock alive.
          if (!fresh || /^(?:analysis|reasoning)$/.test(String(m.channel || ''))
              || /thought|reasoning/i.test(String(m.content && m.content.content_type || ''))) continue;
          const msgs = thread(convo).messages;
          const last = msgs.length && msgs[msgs.length - 1].role === 'assistant' ? msgs[msgs.length - 1] : null;
          if (last && last.text && !thinkingPlaceholder(last.text) && last.text !== turn.polledText && last.text !== turn.domText && !turn.sseText) {
            turn.polledText = last.text;
            post({ type: 'stream', id: turn.id, kind: 'text', messageID: last.id || 'poll', full: last.text });
          }
          const ended = !!m && m.author && m.author.role === 'assistant' && m.status === 'finished_successfully'
            && (m.end_turn === true || !!(m.metadata && m.metadata.finish_details));
          if (ended && !stopVisible()) { finishTurn(turn); return; }
        }
      }
      function startTurn(id) {
        const turn = { id, started: Date.now(), lastActivity: Date.now(), oldErrors: new Map(errorNodes().map((n) => [n, String(n.innerText || n.textContent || '').trim()])),
          requestParentID: pendingSend && pendingSend.parentID, conversationID: null, conversationPosted: false, sseText: false,
          sseEnded: false, domText: '', before: assistantNodes().length, sawStop: false, finished: false,
          submitted: false, posted: 0, accepted: false, shape: newShape(), timer: null,
          // W184 G3c：這一輪是臨時聊天（送出、重答都在 startTurn 之前放好 pendingSend）；送出的內容確認帶了旗標才 temporaryConfirmed。
          temporary: !!(pendingSend && pendingSend.id === id && pendingSend.temporary), temporaryConfirmed: false,
          personalizedProof: pendingSend && pendingSend.personalizedProof,
          requestConversationID: pendingSend && pendingSend.conversationID, personalizedOriginal: false,
          originalSendStarted: false, originalSSEEnded: false, cancelled: false };
        if (turn.personalizedProof === personalizedProof && personalizedProof
            && !turn.requestConversationID && !personalizedProof.sent && !personalizedProof.initialTurnID)
          personalizedProof.initialTurnID = id;
        beginPersonalizedIDDiagnostic(turn);
        turns[id] = turn;
        turn.timer = setInterval(() => tick(turn), 150);
        return turn;
      }

      async function readStream(turn, body, fromSendResponse = false) {
        if (!fromSendResponse && personalizedReadBlocked(turn)) return;
        turn.sseEnded = false;   // 每條串流（含轉線後的續傳）各自算結束
        const id = turn.id;
        const shape = turn.shape;
        const reader = body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';
        const messages = {};
        let current = null, lastPath = null, lastOp = null, lastSent = 0, dirty = false;
        const isText = (m) => m && m.channel !== 'analysis' && m.channel !== 'reasoning' && m.role === 'assistant' && (m.type === 'text' || m.type === 'multimodal_text');
        const emitText = (force) => {
          if (turn.finished || turn.cancelled || (!fromSendResponse && personalizedReadBlocked(turn))) return;
          if (!isText(current) || !current.text) return;
          const now = Date.now();
          if (!force && now - lastSent < 60) { dirty = true; return; }
          lastSent = now; dirty = false;
          turn.sseText = true;
          post({ type: 'stream', id, kind: 'text', messageID: current.id, full: stripMarkers(current.text) });
        };
        const addMessage = (v, c) => {
          const m = v && v.message;
          if (!m) return;
          const parts = (m.content && m.content.parts) || [];
          const entry = { id: m.id, role: m.author && m.author.role, channel: m.channel, type: m.content && m.content.content_type,
            text: typeof parts[0] === 'string' ? parts[0] : '' };
          messages[c != null ? c : m.id] = entry;
          current = entry;
          emitText(true);
        };
        const applyOne = (op) => {
          if (!op || typeof op !== 'object') return;
          if (failProvider(turn, extractError(op))) return;
          let p = op.p, o = op.o;
          const v = op.v;
          if (p === undefined) p = lastPath;
          if (o === undefined) o = lastOp;
          // 第一個事件可能省略 p/o：v 裡直接是一則訊息就當新增。
          if ((o == null) && v && typeof v === 'object' && v.message) o = 'add';
          if (typeof op.c === 'number' && messages[op.c]) current = messages[op.c];
          lastPath = p; lastOp = o;
          bump(shape.ops, o); bump(shape.paths, p);
          if (/error|detail/.test(String(p || '')) && failProvider(turn, extractError(v, true))) return;
          if (/thought|reasoning_recap/.test(String(p || '')) && /title$/.test(String(p)) && typeof v === 'string') progress(turn, v);
          if (o === 'patch' && Array.isArray(v)) { v.forEach(applyOne); return; }
          if ((p === '' || p == null) && o === 'add') { addMessage(v, op.c); return; }
          if (!current) return;
          if (p === '/message/content/parts/0') {
            if (o === 'append' && typeof v === 'string') current.text += v;
            else if (o === 'replace' && typeof v === 'string') current.text = v;
            emitText(false);
          } else if (p === '/message/status' && v === 'finished_successfully') {
            emitText(true);
          }
        };
        const handleData = (data, authoritative = false, eventName = '') => {
          if (data === '[DONE]') return;
          if (turn.finished || turn.cancelled || (!authoritative && personalizedReadBlocked(turn))) return;
          let obj;
          try { obj = JSON.parse(data); } catch (e) { shape.other += 1; if (/error/i.test(eventName)) failProvider(turn, { message: data, code: '' }); return; }
          if (failProvider(turn, extractError(obj, /error/i.test(eventName)))) return;
          extractProgress(turn, obj, eventName);
          shape.json += 1;
          if (!obj || typeof obj !== 'object') return;
          bump(shape.keys, Object.keys(obj).sort().join('+'));
          if (typeof obj.conversation_id === 'string') setConversation(turn, obj.conversation_id, authoritative);
          if (obj.v && typeof obj.v === 'object' && typeof obj.v.conversation_id === 'string') setConversation(turn, obj.v.conversation_id, authoritative);
          if (turn.finished) return;
          if (obj.type) bump(shape.types, diagnosticCode(obj.type));
          if (obj.type === 'stream_handoff') { turn.handoff = true; turn.sseText = false; progress(turn, '', true); }
          if (obj.type === 'stream_handoff' && obj.options && typeof obj.options === 'object') {
            // 交棒資訊只記欄位名稱與像代號的短值（例如傳輸方式），長字串一律只記型別。
            for (const k of Object.keys(obj.options)) {
              const v = obj.options[k];
              bump(shape.handoff, k + '=' + (typeof v === 'string' && /^[a-z0-9_.:-]{1,24}$/i.test(v) ? v : typeof v));
            }
          }
          if (obj.type === 'title_generation' && obj.title) {
            post({ type: 'stream', id, kind: 'title', conversationID: obj.conversation_id || turn.conversationID, title: obj.title });
            return;
          }
          if (obj.type) return;
          if (obj.message && !('o' in obj) && !('p' in obj)) { addMessage(obj, null); return; }
          applyOne(obj);
        };
        if (!turn.feed) turn.feed = handleData;
        try {
          for (;;) {
            const { value, done } = await reader.read();
            if (done) break;
            if (turn.finished) { if (typeof reader.cancel === 'function') reader.cancel().catch(() => {}); return; }
            turn.lastActivity = Date.now();
            buffer += decoder.decode(value, { stream: true }).replace(/\r\n/g, '\n');
            let index;
            while ((index = buffer.indexOf('\n\n')) >= 0) {
              const block = buffer.slice(0, index);
              buffer = buffer.slice(index + 2);
              shape.events += 1;
              const name = block.split('\n').find((l) => l.startsWith('event:'));
              if (name) bump(shape.names, diagnosticCode(name.slice(6).trim()));
              const data = block.split('\n').filter((l) => l.startsWith('data:')).map((l) => l.slice(5).replace(/^ /, '')).join('\n');
              if (data) handleData(data, fromSendResponse, name ? name.slice(6).trim() : '');
            }
          }
          if (buffer.trim()) {
            const name = buffer.split('\n').find((l) => l.startsWith('event:'));
            const data = buffer.split('\n').filter((l) => l.startsWith('data:')).map((l) => l.slice(5).replace(/^ /, '')).join('\n');
            if (data) handleData(data, fromSendResponse, name ? name.slice(6).trim() : '');
          }
          if (dirty) emitText(true);
        } catch (e) {
          bump(shape.types, 'read-error');
          if (fromSendResponse && personalizedReadBlocked(turn)) {
            finishTurn(turn, '原始回應串流中斷，已停止接續');
            return;
          }
        }
        if (fromSendResponse) turn.originalSSEEnded = true;
        if (fromSendResponse && personalizedReadBlocked(turn) && !turn.sseText
            && turn.personalizedProof && turn.personalizedProof === personalizedProof) revokePersonalizedProof('turn_failed');
        if (!fromSendResponse && personalizedReadBlocked(turn)) return;
        turn.sseEnded = true;
        turn.sseEndedAt = Date.now();
        if (fromSendResponse && turn.personalizedProof && turn.personalizedProof.localPath
            && personalizedReadBlocked(turn) && turn.sseText) finishTurn(turn);
      }

      window.fetch = async function (input, init) {
        const url = typeof input === 'string' ? input : (input && input.url) || String(input);
        if (url.indexOf('/backend-api/') >= 0) captureAuth(input, init);
        const method = ((init && init.method) || (input && input.method) || 'GET').toUpperCase();
        // 先綁這次 fetch 的 turn；Request／Blob 解碼期間不可換成下一輪或已取消的工作。
        const entryJob = pendingSend, entryTurn = entryJob && turns[entryJob.id];
        const entryNewChat = (entryJob && entryJob.newChat) || (!entryJob && preparingNewChat && preparingNewChat.newChat);
        const personalizedRequest = method === 'POST' && /\/backend-api\/(f\/)?conversation(\/prepare)?(\?|$)/.test(url)
          && entryJob && entryJob.temporaryPersonalized === true;
        if (method === 'POST' && /\/backend-api\/(f\/)?conversation(\/prepare)?(\?|$)/.test(url)
            && init && typeof init.body === 'string') {
          try {
            const body = JSON.parse(init.body);
            if (body && typeof body === 'object' && !Array.isArray(body)) {
              diag[/\/prepare(\?|$)/.test(url) ? '準備請求原生隱私' : '送出請求原生隱私'] = privacyShape(body);
            }
          } catch (e) {}
        }
        // 對話資料不進瀏覽器快取（憲法 v4.2：內容不落地）：網頁自己讀 /backend-api/ 一律 no-store。
        if (method === 'GET' && url.indexOf('/backend-api/') >= 0) init = Object.assign({}, init || {}, { cache: 'no-store' });
        let job = null;
        // 網頁若用 Request 物件送出（body 不在 init 裡）：先轉成網址＋init，改寫才套得上（審查 #8）。
        if (method === 'POST' && /\/backend-api\/(f\/)?conversation(\/prepare)?(\?|$)/.test(url)
            && typeof Request === 'function' && input instanceof Request && !(init && typeof init.body === 'string')) {
          try {
            const text = await input.clone().text();
            init = Object.assign({ method: input.method, headers: input.headers, credentials: input.credentials, mode: input.mode,
              signal: input.signal, body: text }, init || {});
            input = url;
          } catch (e) {}
        }
        // 新聊天的原始 prepare/send 必須自己是新 context；絕不靠改寫刪除舊代號或臨時旗標。
        // prepare 可能在插字時就發出，早於 pendingSend，因此也綁準備中的同一 command。
        if (entryNewChat && method === 'POST' && /\/backend-api\/(f\/)?conversation(\/prepare)?(\?|$)/.test(url)) {
          // 字串同步檢查，不額外 yield 到網頁送出後的正常換頁；非字串只讀副本，不改一般請求的傳輸型別。
          const inspected = init && typeof init.body === 'string' ? init : await textBody(init);
          const command = entryNewChat.command, turn = turns[command.id];
          const owned = (pendingSend && pendingSend.newChat === entryNewChat)
            || (!pendingSend && preparingNewChat === command);
          let valid = false, readable = false;
          try {
            const endpoint = new URL(url, location.origin);
            const body = JSON.parse(inspected.body);
            readable = !!body && typeof body === 'object' && !Array.isArray(body);
            valid = owned && newChatContextOK(entryNewChat) && !(turn && (turn.finished || turn.cancelled))
              && !(init.signal && init.signal.aborted)
              && endpoint.origin === (location.origin || 'https://' + location.host)
              && /^\/backend-api\/(f\/)?conversation(\/prepare)?$/.test(endpoint.pathname)
              && readable && body.conversation_id == null
              && (command.temporary === true || ['history_and_training_disabled', 'is_do_not_remember',
                'is_temporary', 'temporary_chat'].every((key) => body[key] === undefined || body[key] === false));
          } catch (e) {}
          diag['新聊天請求'] = (/\/prepare(\?|$)/.test(url) ? 'prepare' : 'send') + (valid ? ':validated' : ':blocked');
          if (!valid) {
            entryNewChat.invalid = true;
            if (command.personalizedProof === personalizedProof) revokePersonalizedProof('request_guard');
            if (turn && !turn.finished) finishTurn(turn, command.temporary === true && !readable ? TEMP_BLOCKED
              : '原生新聊天的對話或隱私旗標未確認，沒有送出');
            throw abortError();
          }
          // 串流讀一次就耗盡；臨時送出也沿用這次已驗證的解碼，不再等第二次解碼。
          if (command.temporary === true || (init && typeof ReadableStream === 'function' && init.body instanceof ReadableStream))
            init = inspected;
        }
        if (personalizedRequest) {
          init = await textBody(init);
          const prepare = /\/prepare(\?|$)/.test(url);
          const endpoint = new URL(url, location.origin);
          if (pendingSend !== entryJob || turns[entryJob.id] !== entryTurn || !entryTurn
              || entryTurn.finished || entryTurn.cancelled || !personalizedContextOK(entryJob)
              || endpoint.origin !== location.origin || !/^\/backend-api\/(f\/)?conversation(\/prepare)?$/.test(endpoint.pathname)
              || (init && init.signal && init.signal.aborted)
              || !originalPersonalizedFlags(init, entryJob, prepare)) {
            if (entryJob.personalizedProof === personalizedProof) revokePersonalizedProof('request_guard');
            if (entryTurn && !entryTurn.finished) finishTurn(entryTurn, '原生個人化臨時旗標或對話已變更，沒有送出');
            throw abortError();
          }
          if (!prepare) {
            entryTurn.personalizedOriginal = true;
            entryJob.personalizedProof.sent = true;
          }
          personalizedDiagnostic(prepare ? 'prepare_validated' : 'send_validated', entryJob);
        }
        // 網頁送訊息有兩條路：一般是 /f/conversation，旗標沒開時走舊的 /conversation（09-25 實機：專案裡送出走這條，
        // 以前只攔 /f/ 那條，模型、暫時對話、專案都沒套上，也沒解析到回答）。兩條都攔。
        if (method === 'POST' && (pendingModel || pendingEffort || pendingHint || pendingParent || pendingGizmo) && /\/backend-api\/(f\/)?conversation\/prepare(\?|$)/.test(url)) {
          init = withModel(init, pendingModel, pendingEffort, '準備請求');
          // W180 A2：記下準備請求的結果（只記狀態碼），送不出去時看得出是不是卡在這一步。
          return originalFetch(input, init).then((r) => { diag['準備回應'] = String(r.status); return r; },
            (e) => { diag['準備回應'] = '失敗'; throw e; });
        }
        // 停止時還沒發出的那則晚到了：擋掉，網頁收到的跟按了自己的停止鍵一樣（AbortError）。
        // 沒有人在等送出請求時晚到的一定是它；下一則已按送出時，只擋內容對得上被停那則、又對不上下一則的。
        if (method === 'POST' && cancelledSends.length && /\/backend-api\/(f\/)?conversation(\?|$)/.test(url)) {
          const now = Date.now();
          cancelledSends = cancelledSends.filter((c) => c.until > now);
          const print = sendPrint(init);
          const index = !pendingSend ? 0
            : cancelledSends.findIndex((c) => samePrint(c, print) && !samePrint(pendingSend, print));
          if (index >= 0 && index < cancelledSends.length) {
            cancelledSends.splice(index, 1);
            diag['停止'] = '已擋下停止後才發出的請求';
            throw abortError();
          }
        }
        if (method === 'POST' && /\/backend-api\/(f\/)?conversation(\?|$)/.test(url) && pendingSend) {
          job = pendingSend;
          if (turns[job.id]) turns[job.id].posted = Date.now();
          pendingSend = null;
          pendingModel = null;
          pendingEffort = null;
          if (job.temporaryPersonalized === true && !personalizedContextOK(job)) {
            const turn = turns[job.id];
            if (turn) finishTurn(turn, '個人化臨時模式在送出前變更，已擋下');
            throw abortError();
          }
          diag['送出路徑'] = /\/backend-api\/f\/conversation/.test(url) ? '/f/conversation' : '/conversation';
          // W184 G3c：臨時聊天：非字串的 body 先讀成字串，旗標才加得上。
          if (!personalizedRequest) {
            if (job.temporary) init = await textBody(init);
          }
          if (job.newChat && !newChatContextOK(job.newChat)) {
            const turn = turns[job.id];
            if (turn) finishTurn(turn, '原生新聊天的頁面或模式已變更，沒有送出');
            throw abortError();
          }
          pendingHint = job.hint || null;
          pendingTemporary = !!job.temporary;
          pendingParent = job.parentID || null;
          pendingGizmo = job.gizmo || null;
          init = withModel(init, job.model, job.effort, '送出請求');
          try {
            const sent = init && typeof init.body === 'string' ? JSON.parse(init.body) : null;
            if (sent && turns[job.id] && typeof sent.parent_message_id === 'string') turns[job.id].requestParentID = sent.parent_message_id;
          } catch (e) {}
          pendingHint = null;
          pendingTemporary = false;
          pendingParent = null;
          pendingGizmo = null;
          // W184 G3c：臨時聊天：讀回實際要送出的內容確認帶了旗標；確認不了就擋下（不送），回報失敗。確認了先告訴 App 再送。
          if (job.temporary) {
            const turn = turns[job.id];
            if (!temporaryFlagged(init) || (job.temporaryPersonalized === true && !personalizedContextOK(job))) {
              diag['暫時對話'] = '擋下：實際送出的內容確認不到 history_and_training_disabled（沒有送出）';
              if (turn) finishTurn(turn, TEMP_BLOCKED);
              else postTerminal({ type: 'stream', id: job.id, kind: 'failed', message: TEMP_BLOCKED });
              throw abortError();
            }
            if (turn) turn.temporaryConfirmed = true;
            post({ type: 'stream', id: job.id, kind: 'temporary' });
          }
        }
        if (libraryWatch && url.indexOf('/backend-api/') >= 0) libraryWatch.push(method + ' ' + maskPath(url));
        if (shareCapture.active && url.indexOf('/backend-api/') >= 0) {
          const watch = (async () => {
            try {
              const r = await originalFetch(input, init);
              const copy = r.clone();
              copy.text().then((t) => {
                const abs = SHARE_URL.exec(t);
                const rel = abs ? null : SHARE_PATH.exec(t);
                if (abs) shareCapture.url = shareCapture.url || abs[0];
                else if (rel) shareCapture.url = shareCapture.url || 'https://chatgpt.com' + rel[1];
              }).catch(() => {});
              return r;
            } catch (e) { throw e; }
          })();
          return watch;
        }
        const during = job ? null : activeTurn();
        if (during) bump(during.shape.net, method + ' ' + maskPath(url), 24);
        let response;
        try {
          if (job && job.temporaryPersonalized === true && turns[job.id]) turns[job.id].originalSendStarted = true;
          response = await originalFetch(input, init);
        } catch (e) {
          if (job && turns[job.id]) finishTurn(turns[job.id], String((e && e.message) || e));
          throw e;
        }
        if (!job) {
          // 交棒後回答可能從另一條串流過來：送出期間任何事件串流都一起解析（看得懂就用）。
          try {
            if (during && !during.finished && !personalizedReadBlocked(during) && response.body
                && /event-stream/i.test(String(response.headers.get('content-type') || ''))) {
              bump(during.shape.net, 'SSE ' + maskPath(url), 24);
              readStream(during, response.clone().body);
            }
          } catch (e) {}
          return response;
        }
        const turn = turns[job.id];
        if (!turn) return response;
        if (!response.ok || !response.body) {
          const error = !response.ok ? await responseError(response) : null;
          if (!failProvider(turn, error)) finishTurn(turn, 'HTTP ' + response.status);
          return response;
        }
        turn.accepted = true;
        turn.lastActivity = Date.now();
        post({ type: 'stream', id: job.id, kind: 'accepted' });
        try {
          const h = response.headers;
          const names = [];
          h.forEach((_, k) => { if (/compress|encoding/i.test(k)) names.push(k); });
          turn.shape.headers = 'ct=' + String(h.get('content-type') || '').split(';')[0]
            + (h.get('content-encoding') ? ' ce=' + h.get('content-encoding') : '') + (names.length ? ' h=' + names.join('+') : '');
        } catch (e) {}
        // 讀複製品，網頁拿回原本那個回應（網址、型別等屬性都不變）。
        readStream(turn, response.clone().body, true);
        return response;
      };

      // WebSocket：記錄開到哪裡（路徑）；送出期間的訊息只記結構，是 delta 格式就一起解析。
      const NativeWebSocket = window.WebSocket;
      if (typeof NativeWebSocket === 'function') {
        const Wrapped = function (url, protocols) {
          const ws = protocols === undefined ? new NativeWebSocket(url) : new NativeWebSocket(url, protocols);
          try {
            if (sockets.length < 6) sockets.push(maskPath(url));
            ws.addEventListener('message', (event) => {
              const turn = activeTurn();
              if (!turn || personalizedReadBlocked(turn) || typeof event.data !== 'string') return;
              let obj;
              try { obj = JSON.parse(event.data); } catch (e) { bump(turn.shape.ws, 'text'); return; }
              if (!obj || typeof obj !== 'object') return;
              bump(turn.shape.ws, Object.keys(obj).sort().join('+') + (typeof obj.type === 'string' ? ':' + diagnosticCode(obj.type) : ''));
              if (turn.feed) { turn.lastActivity = Date.now(); turn.feed(event.data); }
            });
          } catch (e) {}
          return ws;
        };
        Wrapped.prototype = NativeWebSocket.prototype;
        for (const k of ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED']) Wrapped[k] = NativeWebSocket[k];
        window.WebSocket = Wrapped;
      }

      const api = async (path, extraHeaders) => {
        if (!auth) await new Promise((resolve) => { authWaiters.push(resolve); setTimeout(resolve, 15000); });
        if (!auth) throw new Error('還沒登入 ChatGPT');
        const response = await originalFetch(path, { headers: extraHeaders ? Object.assign({}, auth, extraHeaders) : auth, credentials: 'include', cache: 'no-store' });
        if (!response.ok) throw new Error('HTTP ' + response.status);
        return response.json();
      };
      // 寫入（重新命名、封存、刪除）：跟網頁版一樣用 PATCH 對話。
      const apiSend = async (method, path, body) => {
        if (!auth) throw new Error('還沒登入 ChatGPT');
        const response = await originalFetch(path, { method, credentials: 'include',
          headers: Object.assign({ 'content-type': 'application/json' }, auth), body: stringify(body) });
        if (!response.ok) throw new Error('HTTP ' + response.status);
        try { return await response.json(); } catch (e) { return {}; }
      };
      const conversationPath = (id) => '/backend-api/conversation/' + encodeURIComponent(String(id || ''));
      // 回答是哪個模型給的（ChatGPT 自己記在 metadata.model_slug）：顯示名稱，換模型才有證據。
      const modelTitles = {};
      // W184 G3b 第二輪（審查 #8）：Work 模式專用的模型代號（models 讀過才有）與已經看過的對話是不是 Work（對話代號 → true／false）。
      const workModels = new Set();
      const workConversations = new Map();
      // 這則對話是不是 Work 模式開的：預設模型或任何一則回答用的是 Work 專用模型。
      const isWorkConversation = (conv) => {
        if (!conv || !workModels.size) return false;
        if (typeof conv.default_model_slug === 'string' && workModels.has(conv.default_model_slug)) return true;
        const map = conv.mapping || {};
        for (const key in map) {
          const m = map[key] && map[key].message;
          const slug = m && m.metadata && m.metadata.model_slug;
          if (typeof slug === 'string' && workModels.has(slug)) return true;
        }
        return false;
      };
      // 模型代號 → 推理類型（none＝沒有推理強度，例如 Instant）；models 讀過才有。
      const modelReasoning = {};
      // 名稱 → { main: 代表代號, options: [{ id, title, slug, effort }] }（models 讀過才有）。
      const modelGroups = new Map();
      // 新版選單的版本與檔位（models 讀過才有）。
      const pickerVersions = [];
      // 網頁自己送出時帶的模型與強度 → 對回選單上的（模型、強度選項），讓選單顯示實際會用的。
      const reportSelection = (slug, effort) => {
        if (typeof slug !== 'string' || !slug) return;
        // 先對新版選單的檔位（版本＋檔位），對不到再對舊的模型群組。
        for (const v of pickerVersions) {
          const preset = v.presets.find((p) => p.slug === slug && (p.effort || null) === (effort || null))
            || (effort ? null : v.presets.find((p) => p.slug === slug));
          if (preset) { post({ type: 'selection', model: 'version:' + v.id, effort: preset.id, title: v.title }); return; }
        }
        for (const [title, g] of modelGroups) {
          const option = g.options.find((o) => o.slug === slug && (o.effort === (effort || null) || (!o.effort && !effort)))
            || g.options.find((o) => o.slug === slug);
          if (option) { post({ type: 'selection', model: g.main, effort: g.options.length > 1 ? option.id : null, title }); return; }
        }
      };
      // 圖片（第 2 批）：只回傳圖片的指標與尺寸，App 要顯示時再用 image 指令取圖；文字照舊。
      const isImagePart = (x) => x && typeof x === 'object' && /image/i.test(String(x.content_type || '')) && typeof x.asset_pointer === 'string';
      const partsText = (parts) => (parts || []).filter((x) => typeof x === 'string').join('\n\n');
      const partsImages = (parts) => (parts || []).filter(isImagePart)
        .map((x) => ({ pointer: x.asset_pointer, width: x.width || null, height: x.height || null }));
      // 回答裡的私用區標記（\ue200cite\ue202turn0search0\ue201、genui 小工具…）：網頁換成來源小標籤或小工具。
      // 這裡把引用換成 ChatGPT 附的 Markdown 連結（alt），其他標記拿掉（09-24 實機：回答裡夾著 cite／genui 亂碼）。
      const stripMarkers = (text) => String(text || '').replace(/\ue200[^\ue201]*\ue201/g, '').replace(/[\ue200-\ue2ff]/g, '');
      // 只換掉真正的標記（私用區字元，或舊版的【…†…】引用）。matched_text 是一般文字的（例：來源註腳 sources_footnote
      // 的 " "）不能整段替換——09-25 實機：整則回答的空格被刪光（「OpenAIHelpCenter」「TATWOMCP」、### 標題與粗體失效）。
      const isMarker = (t) => /[\ue200-\ue2ff]/.test(t) || /^【[^】\n]{1,80}】$/.test(t);
      const cleanText = (text, meta) => {
        let out = String(text || '');
        const refs = meta && Array.isArray(meta.content_references) ? meta.content_references : [];
        for (const r of refs) {
          if (!r || typeof r.matched_text !== 'string' || !isMarker(r.matched_text) || out.indexOf(r.matched_text) < 0) continue;
          const alt = /cite/.test(r.matched_text) && typeof r.alt === 'string' ? r.alt : '';
          out = out.split(r.matched_text).join(alt);
        }
        return stripMarkers(out);
      };
      // 回答引用的網頁（網頁版回答下方的 Sources）：從 metadata 的引用資料收網址與標題，只收 http(s)，最多 30 個。
      const sourcesOf = (meta) => {
        const out = [];
        if (!meta || typeof meta !== 'object') return out;
        const seen = new Set();
        const add = (url, title) => {
          if (typeof url !== 'string' || !/^https?:\/\//i.test(url) || seen.has(url) || out.length >= 30) return;
          seen.add(url);
          out.push({ url: url.slice(0, 2000), title: String(typeof title === 'string' ? title : '').slice(0, 160) });
        };
        const walk = (x, depth) => {
          if (!x || typeof x !== 'object' || depth > 5) return;
          if (Array.isArray(x)) { x.forEach((y) => walk(y, depth + 1)); return; }
          // 圖片搜尋的縮圖也有 url，不算來源。
          if (typeof x.type === 'string' && /image|video/i.test(x.type)) return;
          if (typeof x.url === 'string') add(x.url, x.title || x.name || x.attribution);
          for (const k of ['items', 'entries', 'sources', 'fallback_items', 'metadata']) if (x[k] && typeof x[k] === 'object') walk(x[k], depth + 1);
        };
        walk(meta.content_references, 0);
        walk(meta.citations, 0);
        walk(meta.search_result_groups, 0);
        return out;
      };
      // 對話的一支：預設是 ChatGPT 記的目前節點；切換版本時（branch）從選的那個節點往下走到最新的一則。
      // 使用者訊息記下上一層節點（編輯＝從同一個上一層送出新版本）；有好幾個版本的，帶版本資訊（網頁的 ‹ 1/2 ›）。
      const thread = (conversation, branch) => {
        const map = conversation.mapping || {};
        let leaf = conversation.current_node;
        if (typeof branch === 'string' && branch && map[branch]) {
          leaf = branch;
          const walked = new Set();
          while (map[leaf] && Array.isArray(map[leaf].children) && map[leaf].children.length && !walked.has(leaf)) {
            walked.add(leaf);
            leaf = map[leaf].children[map[leaf].children.length - 1];
          }
        }
        const path = [];
        const seen = new Set();
        let node = leaf;
        while (node && map[node] && !seen.has(node)) { seen.add(node); path.push(node); node = map[node].parent; }
        path.reverse();
        const variantOf = (slot) => {
          const parent = slot && map[slot] && map[slot].parent;
          const kids = parent && map[parent] && Array.isArray(map[parent].children)
            ? map[parent].children.filter((k) => map[k] && map[k].message) : [];
          const index = kids.indexOf(slot);
          return kids.length > 1 && index >= 0 ? { index, count: kids.length, nodes: kids.slice(0, 50) } : null;
        };
        const result = [];
        const parents = {};
        // 一輪回答的分岔點＝使用者訊息之後的第一個節點；版本資訊掛在那一輪最後一個回答上（跟網頁一樣只顯示一次）。
        let slot = null;
        let turnLast = null;
        const closeTurn = () => { if (turnLast && slot) { const v = variantOf(slot); if (v) turnLast.variant = v; } };
        for (let i = 0; i < path.length; i++) {
          const m = map[path[i]].message;
          if (!m) continue;
          const role = m.author && m.author.role;
          const type = m.content && m.content.content_type;
          const hidden = m.metadata && (m.metadata.is_visually_hidden_from_conversation || m.metadata.is_redacted);
          if (role === 'user' && !hidden) { closeTurn(); slot = path[i + 1] || null; turnLast = null; }
          if (hidden || m.channel === 'analysis' || m.channel === 'reasoning'
              || /thought|reasoning/i.test(String(m.content && m.content.content_type || ''))) continue;
          if (type !== 'text' && type !== 'multimodal_text') continue;
          const text = role === 'assistant' ? cleanText(partsText(m.content.parts), m.metadata) : partsText(m.content.parts);
          const images = partsImages(m.content.parts);
          if (role === 'tool') {
            // 生圖的結果掛在工具訊息上：只留圖片（工具的文字是內部資料），接在前一個回答後面。
            if (!images.length) continue;
            const last = result[result.length - 1];
            if (last && last.role === 'assistant') { last.images = (last.images || []).concat(images); continue; }
            const entry = { id: m.id, role: 'assistant', text: '', images };
            result.push(entry);
            turnLast = entry;
            continue;
          }
          const fileNames = role === 'user' && m.metadata && Array.isArray(m.metadata.attachments)
            ? m.metadata.attachments.filter((a) => a && typeof a.name === 'string' && !/^image\//.test(String(a.mime_type || ''))).map((a) => a.name) : [];
          if ((role === 'user' || role === 'assistant') && (text.trim() || images.length || fileNames.length)) {
            const slug = role === 'assistant' && m.metadata && typeof m.metadata.model_slug === 'string' ? m.metadata.model_slug : null;
            const entry = { id: m.id, role, text };
            if (slug) entry.model = modelTitles[slug] || slug;
            if (images.length) entry.images = images;
            if (fileNames.length) entry.files = fileNames;
            if (role === 'assistant') {
              const sources = sourcesOf(m.metadata);
              if (sources.length) entry.sources = sources;
              turnLast = entry;
            } else {
              parents[m.id] = map[path[i]].parent || null;
              const v = variantOf(path[i]);
              if (v) entry.variant = v;
            }
            result.push(entry);
          }
        }
        closeTurn();
        return { messages: result, parents, leaf, current: leaf === conversation.current_node };
      };
      const linear = (conversation) => thread(conversation).messages;

      // 輸入框：網頁改版時代號可能換，#prompt-textarea 之外也認 textarea[name] 與表單裡的 ProseMirror（W180 A1）。
      // 只讀頁面的可用狀態，不解除 disabled；畫面外的 Pod 仍有 layout，不要求落在視窗內。
      const chatVisible = (el) => {
        if (!el || el.isConnected !== true || !el.getClientRects().length) return false;
        for (let node = el; node; node = node.parentElement) {
          const style = window.getComputedStyle(node);
          if (node.hidden || node.inert || node.getAttribute('aria-hidden') === 'true'
            || style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse'
            || style.opacity === '0') return false;
        }
        return true;
      };
      const chatEnabled = (el) => chatVisible(el) && !el.disabled && !el.matches(':disabled')
        && !el.closest('[aria-disabled="true"], [inert]');
      const chatForm = (el) => el && (el.form || el.closest('form'));
      const composer = () => {
        for (const selector of ['#prompt-textarea', 'textarea[name="prompt-textarea"]',
          '[data-testid="prompt-textarea"]', 'form .ProseMirror[contenteditable="true"]']) {
          const box = [...document.querySelectorAll(selector)].find((el) => chatEnabled(el)
            && !el.readOnly && el.getAttribute('aria-readonly') !== 'true'
            && (el.tagName === 'TEXTAREA' || el.isContentEditable === true));
          if (box) return box;
        }
        return null;
      };
      const chatBusy = (box) => !!box.closest('[aria-busy="true"]')
        || [...document.querySelectorAll('[data-testid="stop-button"]')].some(chatVisible);
      // 網址只留形狀（不含對話代號與標題），給診斷用。
      const pathShape = (p) => {
        if (p === '/') return '/';
        if (/\/c\/[^/]+$/.test(p)) return p.startsWith('/g/') ? '/g/…/c/…' : '/c/…';
        if (/^\/g\/[^/]+\/project$/.test(p)) return '/g/…/project';
        if (p.startsWith('/g/')) return '/g/…';
        return '/' + (p.split('/')[1] || '');
      };
      // 網頁此刻的樣子（只有結構：網址形狀、輸入框、訊息數、可編輯區、文字框），不含內容。
      const pageState = () => pathShape(location.pathname) + '・輸入框' + (composer() ? '有' : '無')
        + '・訊息 ' + document.querySelectorAll('[data-message-author-role]').length
        + '・可編輯 ' + document.querySelectorAll('[contenteditable="true"]').length
        + '・文字框 ' + document.querySelectorAll('textarea').length + '・' + document.readyState;
      // 送出鍵：網頁改版時代號可能換（W180 A1 實機：data-testid="send-button" 等不到）。依序認幾種寫法。
      const sendButton = (box = composer()) => {
        if (!box || !chatEnabled(box) || chatBusy(box)) return null;
        const form = chatForm(box);
        const root = form || document;
        // 有 form 就完全不找別張表單。無 form 時只認專用代號，不猜全頁 submit／Send。
        const selectors = ['[data-testid="send-button"]', '#composer-submit-button'];
        if (form) selectors.push('button[type="submit"]', 'button[aria-label]');
        for (const selector of selectors) {
          const button = [...root.querySelectorAll(selector)].find((b) => chatForm(b) === form && chatEnabled(b)
            && (selector !== 'button[aria-label]' || /^(send|傳送|送出|发送)/i.test(String(b.getAttribute('aria-label') || '').trim())));
          if (button) return button;
        }
        return null;
      };
      // 輸入列按鈕的樣子（介面標籤與停用狀態，不含內容）：診斷用。
      const sendState = () => {
        const c = composer();
        const form = c && typeof c.closest === 'function' ? c.closest('form') : null;
        const buttons = [...((form || document).querySelectorAll('button') || [])].slice(-8);
        const b = sendButton();
        const attr = (x, n) => (typeof x.getAttribute === 'function' ? x.getAttribute(n) : null);
        return '送出鍵' + (b ? (b.disabled || attr(b, 'aria-disabled') === 'true' ? '停用' : '可按') : '無')
          + '・按鈕 ' + buttons.map((x) => String(attr(x, 'data-testid') || attr(x, 'aria-label') || '?').slice(0, 24)
            + (x.disabled ? '(停用)' : '')).join('／');
      };
      // 換頁：先按網頁自己的連結（讓網頁的路由自己換頁）；沒有連結或按了沒到，才改網址＋popstate（W180 A1：ChatGPT 改版後
      // 假的 popstate 可能沒反應，停在原頁、找不到輸入框）。arrived() 判斷到了沒。
      async function routeTo(target, arrived, command = null) {
        const cancelled = () => !!(command && command.cancelled);
        if (cancelled()) return false;
        const same = (href) => {
          try {
            const u = new URL(href, location.origin);
            return u.origin === location.origin && (u.pathname === target || (target !== '/' && u.pathname.endsWith(target)));
          } catch (e) { return false; }
        };
        const link = [...document.querySelectorAll('a[href]')].find((a) => same(a.getAttribute('href')))
          || (target === '/' ? document.querySelector('[data-testid="create-new-chat-button"]') : null);
        if (link) {
          press(link);
          if (await waitFor(() => cancelled() || arrived(), 3000)) {
            if (cancelled()) return false;
            diag['換頁'] = '按網頁連結'; return true;
          }
        }
        if (cancelled()) return false;
        if (location.pathname !== target) {
          history.pushState({}, '', target);
          window.dispatchEvent(new PopStateEvent('popstate', { state: {} }));
        }
        const ok = await waitFor(() => cancelled() || arrived(), link ? 5000 : 8000);
        if (cancelled()) return false;
        diag['換頁'] = ok ? '改網址' : '沒到（' + pageState() + '）';
        return ok;
      }
      async function openConversation(conversationID, command = null) {
        const cancelled = () => !!(command && command.cancelled);
        if (cancelled()) return false;
        const target = conversationID ? '/c/' + conversationID : '/';
        // 專案裡的對話網址是 /g/<專案>/c/<id>，網頁可能自己改成那樣：結尾對得上就算。
        const urlReady = () => (conversationID ? location.pathname.endsWith(target) : location.pathname === '/') && composer();
        const arrived = () => urlReady() && (!conversationID || document.querySelector('[data-message-author-role]'));
        let ready = arrived() || (await routeTo(target, arrived, command));
        // W180 A2（.013 實機）：專案裡只有大圖的對話，網址與輸入框都到了，訊息卻慢很久才畫出來（訊息 0）。
        // 網址對了就再等 8 秒；還沒出現也照這個網址送（網頁送出時用的是網址上的對話）。
        let note = '';
        if (cancelled()) return false;
        if (!ready && conversationID && urlReady()) {
          ready = !!(await waitFor(() => cancelled() || arrived(), 8000));
          if (cancelled()) return false;
          if (!ready && urlReady()) { ready = true; note = '（網址對、訊息還沒畫出來，照網址送）'; }
        }
        diag['開啟對話'] = (ready ? '已開到' : '沒開到') + note + '：目標 ' + pathShape(target) + '；此刻 ' + pageState();
        if (!ready) return false;
        await sleep(conversationID ? 700 : 250);
        return !cancelled();
      }
      // 跟某個 GPT 開新對話：網頁的網址是 /g/<GPT 代號>（後面可能接名稱）；專案（g-p-…）是 /g/<專案>/project，在那裡送出就開在專案裡。
      async function openGizmo(gizmoID, command = null) {
        const cancelled = () => !!(command && command.cancelled);
        if (cancelled()) return false;
        const base = '/g/' + gizmoID;
        const project = /^g-p-/.test(gizmoID);
        const arrived = () => location.pathname.startsWith(base) && (!project || /\/project$/.test(location.pathname)) && composer();
        const ready = arrived() || (await routeTo(base + (project ? '/project' : ''), arrived, command));
        diag['GPT 對話'] = (ready ? '已開到 GPT 頁' : '沒有開到 GPT 頁') + '；此刻 ' + pageState();
        if (!ready) return false;
        await sleep(400);
        return !cancelled();
      }
      // 網頁的選單元件多半在「按下」（pointerdown）時才打開，光送 click 不會開：送完整的按壓順序。
      const press = (el) => {
        const opts = { bubbles: true, cancelable: true, view: window, button: 0, buttons: 1, pointerId: 1, pointerType: 'mouse', isPrimary: true };
        for (const [Type, name] of [['PointerEvent', 'pointerdown'], ['MouseEvent', 'mousedown'], ['PointerEvent', 'pointerup'], ['MouseEvent', 'mouseup']]) {
          try { const E = window[Type]; if (typeof E === 'function') el.dispatchEvent(new E(name, opts)); } catch (e) {}
        }
        try { el.click(); } catch (e) {}
      };
      // 只認網站真正畫出的模式控制項；網址 query、使用者訊息和「點過一次」都不算確認。
      // 個人化必須由這則原生對話明確授權；這裡不寫偏好、記憶或瀏覽器儲存。
      const temporaryControlLabel = (el) => String(el.getAttribute('aria-label') || el.textContent || '').trim();
      const temporaryControls = (selector) => [...document.querySelectorAll(selector)].filter((el) =>
        typeof el.getAttribute === 'function' && typeof el.closest === 'function'
        && !el.closest('[data-message-author-role]') && !el.closest('form')
        && !el.closest('[role="dialog"]') && chatVisible(el) && chatEnabled(el));
      const temporaryPersonalization = (label) =>
        /^(Personalized|個人化|个性化)$/.test(label) ? 'personalized'
          : /^(Unpersonalized|非個人化|不個人化|非个性化)$/.test(label) ? 'unpersonalized' : null;
      const nativeTemporaryUI = () => {
        const buttons = temporaryControls('button, [role="button"]');
        const off = buttons.filter((el) => /^(Turn off temporary chat|關閉臨時聊天|關閉暫時對話|关闭临时聊天)$/i.test(temporaryControlLabel(el)));
        const on = buttons.filter((el) => /^(Temporary chat|Turn on temporary chat|臨時聊天|開啟臨時聊天|暫時對話|临时聊天)$/i.test(temporaryControlLabel(el)));
        const modes = buttons.filter((el) => temporaryPersonalization(temporaryControlLabel(el)));
        if (off.length === 1 && on.length === 0 && modes.length === 1) {
          return { mode: temporaryPersonalization(temporaryControlLabel(modes[0])), toggle: off[0], picker: modes[0] };
        }
        if (on.length === 1 && off.length === 0 && modes.length === 0) return { mode: 'off', toggle: on[0] };
        return { mode: 'unknown', missingPicker: on.length === 0 && modes.length === 0 && off.length <= 1 };
      };
      const normalNewChatUIOK = () => {
        const state = nativeTemporaryUI();
        return state.mode === 'off' || state.missingPicker === true;
      };
      // 只辨識現場結構，不猜上游 prefix 契約；此形狀只能進隔離，不能提供身份。
      const pendingPrefixTokens = (prefix) => {
        if (typeof prefix !== 'string' || prefix.length !== 16) return { allowed: false, percent_type: 'not_16' };
        const pchar = /^[A-Za-z0-9._~!$&'()*+,;=:@-]$/;
        let allowed = true, percentType = 'none';
        for (let i = 0; i < prefix.length; i += 1) {
          if (prefix[i] !== '%') {
            if (!pchar.test(prefix[i])) allowed = false;
            continue;
          }
          const hex = prefix.slice(i + 1, i + 3);
          if (!/^[0-9a-fA-F]{2}$/.test(hex)) return { allowed: false, percent_type: 'malformed' };
          const byte = parseInt(hex, 16), char = String.fromCharCode(byte);
          const kind = pchar.test(char) ? 'pchar'
            : '/\\?#'.includes(char) ? 'delimiter' : char === '%' ? 'percent'
            : byte <= 32 || byte === 127 ? 'control_space' : byte >= 128 ? 'non_ascii' : 'other_ascii';
          if (kind !== 'pchar') allowed = false;
          percentType = percentType === 'none' || percentType === kind ? kind : 'mixed';
          i += 2;
        }
        // 只分類單一 token 的 ASCII 值，不 decode/normalize 路徑，也不組出解碼字串。
        return { allowed, percent_type: percentType };
      };
      const pendingRouteShape = (path) => {
        const m = typeof path === 'string'
          && /^\/c\/([^/]{16})[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$/.exec(path);
        return !!m && m[0] === path && pendingPrefixTokens(m[1]).allowed;
      };
      // 純函式，只回固定分類／布林／截頂長度；不 decode、正規化或輸出路徑片段，絕不參與 guard。
      const safeRouteShape = (path) => {
        const pathnameString = typeof path === 'string';
        const p = pathnameString ? path : '';
        const parts = !p || p === '/' ? [] : (p.startsWith('/') ? p.slice(1) : p).split('/');
        const last = parts.length ? parts[parts.length - 1] : '';
        const kind = p === '/' ? 'root'
          : /^\/c\/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(p) ? 'c_uuid'
          : /^\/c\/[^/]+$/.test(p) ? 'c_nonuuid' : /^\/g(?:\/|$)/.test(p) ? 'g' : 'other';
        const uuidSuffix = /[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(last);
        // 只分類單段 c route 在 UUID 尾綴之前的部分；不 decode、不輸出文字。
        const prefix = kind === 'c_nonuuid' && uuidSuffix ? last.slice(0, -36) : '';
        return { kind, pathnameString, empty: pathnameString && p === '',
          segment_count: parts.length > 8 ? '8+' : parts.length,
          segment_length: last.length > 256 ? '256+' : last.length,
          last_uuid_suffix: uuidSuffix,
          last_uuid_prefix: /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/i.test(last),
          last_has_hyphen: last.includes('-'), trailingSlash: p.endsWith('/'),
          bounded_pending_shape: pendingRouteShape(path),
          prefix_pchar: prefix.length === 16 && /^[A-Za-z0-9._~!$&'()*+,;=:@-]{16}$/.test(prefix),
          prefix_has_colon: prefix.includes(':'), prefix_has_percent: prefix.includes('%'),
          prefix_percent_type: prefix ? pendingPrefixTokens(prefix).percent_type : 'not_applicable' };
      };
      const routeShapeDiagnostic = (prefix, path) => {
        const shape = safeRouteShape(path);
        return Object.keys(shape).map((key) => prefix + '_' + key + '=' + shape[key]).join('; ');
      };
      // 首筆 route_changed 永久凍結到下一份 proof 建立；診斷失敗不能改變撤銷或送出的行為。
      const freezePersonalizedRouteDiagnostic = (proof, observed, source, id, navigationType = 'none') => {
        try {
          if (diag['個人化路由撤銷']) return;
          const current = location.pathname;
          const from = ['history_push', 'history_replace', 'popstate', 'currententrychange',
            'native', 'tick', 'observer', 'response', 'context', 'send', 'regenerate', 'finish'].includes(source) ? source : 'other';
          const nav = ['none', 'push', 'replace', 'traverse', 'reload'].includes(navigationType) ? navigationType : 'unknown';
          diag['個人化路由撤銷'] = 'source=' + from + '; ' + routeShapeDiagnostic('observed', observed)
            + '; ' + routeShapeDiagnostic('current', current) + '; ' + routeShapeDiagnostic('proof', proof.path)
            + '; observed_eq_current=' + (observed === current) + '; observed_eq_proof=' + (observed === proof.path)
            + '; sent=' + !!proof.sent + '; complete=' + !!proof.complete
            + '; server_bound=' + !!proof.conversationID + '; route_bound=' + !!proof.routeID
            + '; uuid_match=' + !!id + '; uuid_tail=' + !!(id && observed.endsWith('/c/' + id))
            + '; server_match=' + !!(id && id === proof.conversationID) + '; navigation_type=' + nav;
        } catch (e) {}
      };
      const beginPersonalizedIDDiagnostic = (turn) => {
        try {
          if (!turn.personalizedProof || turn.personalizedProof !== personalizedProof) return;
          turn.idDiagnostic = personalizedIDDiagnostic = { seen: false, first_id_shape: 'none',
            first_proof_revoked: false, first_bind_result: 'not_seen', bind_result: 'not_seen' };
          diag['個人化原始ID'] = 'seen=false; first_id_shape=none; first_proof_revoked=false; first_bind_result=not_seen; bind_result=not_seen';
        } catch (e) {}
      };
      const notePersonalizedOriginalID = (turn, id) => {
        try {
          const record = turn.idDiagnostic;
          if (!record || record !== personalizedIDDiagnostic) return null;
          if (!record.seen) {
            record.seen = true;
            record.first_id_shape = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(id) ? 'uuid' : 'other';
            record.first_proof_revoked = !!(turn.personalizedProof && turn.personalizedProof.revoked);
          }
          return record;
        } catch (e) { return null; }
      };
      const finishPersonalizedIDDiagnostic = (record, result) => {
        try {
          if (!record || record !== personalizedIDDiagnostic) return;
          const status = ['bound', 'proof_missing', 'page_rejected', 'id_conflict', 'turn_ineligible'].includes(result) ? result : 'other';
          if (record.first_bind_result === 'not_seen') record.first_bind_result = status;
          record.bind_result = status;
          diag['個人化原始ID'] = Object.keys(record).map((key) => key + '=' + record[key]).join('; ');
        } catch (e) {}
      };
      // 固定狀態＋布林值，不輸出代號、實際路徑、hash、請求或例外原文。
      const personalizedDiagnostic = (stage, command = null) => {
        const proof = personalizedProof;
        const state = proof ? (proof.revoked ? 'revoked' : proof.complete ? 'complete' : 'pending')
          : personalizedRevocation === 'none' ? 'none' : 'revoked';
        const route = UUID_IN_PATH.exec(location.pathname);
        const ui = nativeTemporaryUI();
        diag[stage === 'before_continuation' ? '個人化續聊前' : '個人化續聊證據'] = 'proof=' + state + '; reason=' + personalizedRevocation
          + '; stage=' + (['idle', 'created', 'response_bound', 'completed', 'revoked',
            'before_continuation', 'continuation_allowed', 'continuation_denied', 'prepare_validated', 'send_validated'].includes(stage) ? stage : 'other')
          + '; path=' + (location.pathname === '/' ? 'root' : route ? 'conversation' : 'other')
          + '; samePage=' + !!(proof && location.origin === proof.origin && location.pathname === proof.path)
          + '; serverID=' + !!(proof && proof.conversationID) + '; routeID=' + !!(proof && proof.routeID)
          + '; nativeOriginal=' + !!(proof && proof.sent)
          + '; routeMatch=' + !!(proof && route && route[1] === proof.conversationID)
          + '; commandID=' + !!(command && command.conversationID)
          + '; commandMatch=' + !!(proof && command && command.conversationID && command.conversationID === proof.conversationID)
          + '; consent=' + !!(command && command.temporary === true && command.temporaryPersonalized === true)
          + '; ui=' + (ui.missingPicker ? 'missing' : ui.mode);
      };
      const proofPageOK = (proof, path = location.pathname, source = 'other', navigationType = 'none') => {
        if (!proof || proof.revoked || proof !== personalizedProof) return false;
        const match = UUID_IN_PATH.exec(path), id = match && match[1];
        if (location.origin !== proof.origin) { revokePersonalizedProof('origin_changed'); return false; }
        const rejectRoute = () => {
          freezePersonalizedRouteDiagnostic(proof, path, source, id, navigationType);
          revokePersonalizedProof('route_changed'); return false;
        };
        // 同 pathname 的返回仍是離開原生頁；不能靠重複通知豁免 traverse 或未知事件。
        if (source === 'popstate' || (source === 'currententrychange'
            && !['push', 'replace'].includes(navigationType))) return rejectRoute();
        const turn = proof.initialTurnID && turns[proof.initialTurnID];
        const initialActive = proof.rootStart && !proof.complete && proof.sent
          && turn && turn === activeTurn() && turn.personalizedProof === proof
          && !turn.requestConversationID && !turn.finished && !turn.cancelled
          && turn.submitted && turn.personalizedOriginal && turn.temporaryConfirmed && turn.originalSendStarted;
        if (proof.localPath && (path !== location.pathname || (!proof.complete && !initialActive))) return rejectRoute();
        if (path !== proof.path) {
          // 只准 root 首句進入一次固定形狀；整條只留記憶體比對，suffix 不當作 server ID。
          if (!proof.localPath && !proof.routeID && proof.path === '/' && initialActive
              && !turn.originalSSEEnded && path === location.pathname && pendingRouteShape(path)) {
            proof.localPath = path; proof.path = path;
            diag['個人化首句過渡'] = 'bounded_pending_shape=true';
          // 走過候選者 canonical 必須整條相符且仍為同一首句；未走候選的既有 /g/.../c/ 路徑不改。
          } else if (!proof.routeID && proof.sent && !proof.complete && id
              && (proof.localPath ? path === '/c/' + id : path.endsWith('/c/' + id))
              && (!proof.conversationID || proof.conversationID === id) && (!proof.localPath || initialActive)) {
            proof.routeID = id; proof.path = path;
          } else {
            return rejectRoute();
          }
        }
        const state = nativeTemporaryUI();
        if (state.mode !== 'personalized' && !state.missingPicker) {
          revokePersonalizedProof('mode_changed'); return false;
        }
        return true;
      };
      // 無原始 ID 的 root 首句先隔離；進過 Q 者必須 exact canonical 交會。
      // 未走 Q 的既有 root／g 路徑仍沿用原始 ID + proofPageOK；撤銷不可回落讀取。
      const personalizedReadBlocked = (turn) => {
        const proof = turn.personalizedProof;
        if (!proof || !proof.rootStart || proof.initialTurnID !== turn.id) return false;
        return turn.cancelled || proof.revoked || proof !== personalizedProof
          || !proofPageOK(proof, location.pathname, 'tick')
          || !turn.accepted || !turn.personalizedOriginal || !proof.conversationID
          || (proof.localPath && (proof.routeID !== proof.conversationID
            || location.pathname !== '/c/' + proof.conversationID));
      };
      const personalizedContextOK = (context) => {
        const proof = context.personalizedProof;
        if (context.cancelled || context.temporary !== true || context.temporaryPersonalized !== true
            || !proofPageOK(proof, location.pathname, 'context') || (proof.localPath && !proof.complete)) return false;
        return context.conversationID
          // routeID 尚空＝仍在首輪原生頁；同文件／未離開由 proofPageOK 保證。
          // 身分來自首輪原始回應，後續每個原始 send body 仍必須精確核對同一代號。
          ? proof.conversationID === context.conversationID && (!proof.routeID || proof.routeID === context.conversationID)
          : nativeTemporaryUI().mode === 'personalized';
      };
      const originalPersonalizedFlags = (init, job, prepare) => {
        try {
          const body = JSON.parse(init.body);
          if (!body || Array.isArray(body) || body.history_and_training_disabled !== true
              || body.is_do_not_remember !== false) return false;
          const id = body.conversation_id == null ? null : body.conversation_id;
          return (prepare && id === null) || id === (job.conversationID || null);
        } catch (e) { return false; }
      };
      // 對話間不保留全域同意；即使 picker 消失，已知個人化對話也不能被當成一般送出。
      const lacksPersonalizedConsent = (command) => {
        const known = personalizedProof && command.conversationID === personalizedProof.conversationID;
        return (known || nativeTemporaryUI().mode === 'personalized')
          && (command.temporary !== true || command.temporaryPersonalized !== true);
      };
      // 觀察到 mode 改變就永久作廢；消失的 picker 本身不是相反模式。
      let personalizedObserver = null;
      try {
        if (MO) {
          personalizedObserver = new MO((records) => {
            const controls = temporaryControls('button, [role="button"]');
            const fresh = (pendingSend && pendingSend.newChat) || (preparingNewChat && preparingNewChat.newChat);
            if (fresh && fresh.command.temporary !== true
                && (!normalNewChatUIOK()
                  || records.some((r) => r.type === 'attributes' && r.attributeName === 'aria-label'
                    && controls.includes(r.target) && temporaryPersonalization(String(r.oldValue || '').trim()))))
              fresh.invalid = true;
            if (!personalizedProof) return;
            if (records.some((r) => r.type === 'attributes' && r.attributeName === 'aria-label'
                && controls.includes(r.target) && (temporaryPersonalization(String(r.oldValue || '').trim()) === 'unpersonalized'
                  || /^(Temporary chat|Turn on temporary chat|臨時聊天|開啟臨時聊天|暫時對話|临时聊天)$/i.test(String(r.oldValue || '').trim()))))
              revokePersonalizedProof('mode_reversal');
            if (personalizedProof) proofPageOK(personalizedProof, location.pathname, 'observer');
          });
          personalizedObserver.observe(document, { subtree: true, childList: true, attributes: true,
            attributeOldValue: true, attributeFilter: ['aria-label', 'aria-pressed', 'aria-checked'] });
        }
      } catch (e) {}
      const nativeContinuationRequested = (command) => !!command.conversationID
        && (command.temporaryPersonalized === true
          || !!(personalizedProof && personalizedProof.conversationID === command.conversationID));
      const newChatContextOK = (context) => !context.invalid && !context.command.cancelled
        && context.epoch === newChatEpoch && context.origin === location.origin && context.path === location.pathname
        && (context.command.temporary === true || normalNewChatUIOK());
      // 診斷純函式：只回固定布林／enum，不回報內容、字數、DOM label、路由或代號。
      const nativeResetComposerShape = (current) => {
        const result = { state: 'unknown', composer_kind: 'missing', composer_text_shape: 'unknown',
          composer_textcontent_empty: false, composer_structure: 'unknown', text_node_nonempty: false };
        if (!current) return result;
        try {
          const textarea = current.tagName === 'TEXTAREA';
          result.composer_kind = textarea ? 'value' : 'contenteditable';
          if (!textarea && current.isContentEditable !== true) return result;
          // 不 trim，不把 getter 失敗當成空字串；文字節點中的空白也是使用者草稿。
          const text = textarea ? current.value : current.innerText, content = current.textContent;
          if (typeof text !== 'string' || typeof content !== 'string') return result;
          result.composer_text_shape = text === '' ? 'empty' : /^\s*$/.test(text) ? 'whitespace' : 'nonempty';
          result.composer_textcontent_empty = content === '';
          result.text_node_nonempty = content !== '';
          if (textarea) {
            result.state = text === '' ? 'empty' : 'draft';
            result.composer_structure = text === '' ? 'empty' : 'other';
            return result;
          }
          result.state = 'draft'; result.composer_structure = 'other';
          if (content !== '') return result;
          const children = current.childNodes;
          if (!children || !Number.isInteger(children.length)) throw new Error();
          if (children.length === 0 && text === '') {
            result.state = 'empty'; result.composer_structure = 'empty';
          } else if (children.length === 1) {
            const p = children[0];
            if (p.nodeType !== 1 || p.tagName !== 'P' || p.getAttribute('contenteditable') === 'false') return result;
            const inside = p.childNodes;
            if (!inside || !Number.isInteger(inside.length)) throw new Error();
            if (inside.length !== 1) return result;
            const br = inside[0];
            if (br.nodeType !== 1 || br.tagName !== 'BR' || br.getAttribute('contenteditable') === 'false') return result;
            const leaf = br.childNodes;
            if (!leaf || !Number.isInteger(leaf.length)) throw new Error();
            if (leaf.length === 0 && (text === '' || text === '\n')) {
              result.state = 'empty'; result.composer_structure = 'p_br';
            }
          }
        } catch (e) { result.state = 'unknown'; result.composer_structure = 'unknown'; }
        return result;
      };
      const nativeResetDialogState = () => {
        const result = { dialog_any: false, dialog_definitely_hidden_only: false,
          dialog_blocking_or_unknown: true, dialog_state: 'unknown' };
        try {
          const dialogs = document.querySelectorAll('[role="dialog"], dialog');
          result.dialog_any = dialogs.length > 0;
          let blocking = false;
          for (const dialog of dialogs) {
            // 原生 open/modal 即使 display:none 仍不可當成無作用的骨架。
            if (dialog.tagName === 'DIALOG') {
              const open = dialog.open;
              if (typeof open !== 'boolean') throw new Error();
              if (open || dialog.matches(':modal')) { blocking = true; continue; }
            }
            let hidden = false, node = dialog, depth = 0;
            for (; node && depth < 80; node = node.parentElement, depth += 1) {
              const display = R_apply(W_gcs, window, [node]).display;
              if (typeof display !== 'string' || !display) throw new Error();
              // aria-hidden/inert/透明/零 rect 都不是沒有阻擋作用的證據。
              if (display === 'none') { hidden = true; break; }
            }
            if (!hidden && node) throw new Error(); // 無法完整判斷祖先，保守拒絕。
            if (!hidden) blocking = true;
          }
          result.dialog_definitely_hidden_only = result.dialog_any && !blocking;
          result.dialog_blocking_or_unknown = blocking;
          result.dialog_state = blocking ? 'blocking' : result.dialog_any ? 'hidden_only' : 'none';
        } catch (e) {} // 固定 unknown；不輸出 exception、label 或 DOM。
        return result;
      };
      const nativeResetBlockDiagnostic = (flags) => ['cancelled', 'origin_changed', 'stop', 'dialog',
        'composer_missing', 'has_draft', 'watch_invalid'].map((key) => key + '=' + (flags[key] === true)).join('; ')
        + '; composer_kind=' + (['value', 'contenteditable'].includes(flags.composer_kind) ? flags.composer_kind : 'missing')
        + '; composer_text_shape=' + (['empty', 'whitespace', 'nonempty'].includes(flags.composer_text_shape) ? flags.composer_text_shape : 'unknown')
        + '; composer_textcontent_empty=' + (flags.composer_textcontent_empty === true)
        + '; composer_structure=' + (['empty', 'p_br', 'other'].includes(flags.composer_structure) ? flags.composer_structure : 'unknown')
        + '; text_node_nonempty=' + (flags.text_node_nonempty === true)
        + '; dialog_any=' + (flags.dialog_any === true)
        + '; dialog_definitely_hidden_only=' + (flags.dialog_definitely_hidden_only === true)
        + '; dialog_blocking_or_unknown=' + (flags.dialog_blocking_or_unknown === true)
        + '; dialog_state=' + (['none', 'hidden_only', 'blocking'].includes(flags.dialog_state) ? flags.dialog_state : 'unknown');
      // 純分類只回布林／固定語義；原生 BUTTON 可作唯一 fallback，role-only 不授權點擊。
      const nativeResetControlClass = (control, origin) => {
        const testid = control.testid === 'create-new-chat-button';
        const named = typeof control.label === 'string' && /^(New chat|新聊天|新對話)$/.test(control.label);
        let anchor = false;
        if (control.tag === 'A' && typeof control.href === 'string' && named) {
          try {
            const url = new URL(control.href, origin);
            anchor = url.origin === origin && url.pathname === '/' && !url.search && !url.hash;
          } catch (e) {}
        }
        return { candidate: testid || anchor, testid_hit: testid,
          native_button: named && control.tag === 'BUTTON',
          role_only: named && control.tag !== 'BUTTON' && control.role === 'button',
          semantic: anchor ? 'anchor_new_chat'
            : named && (control.tag === 'BUTTON' || control.role === 'button') ? 'button_new_chat' : 'other' };
      };
      const nativeResetControlDiagnostic = (rows, state = 'scanned') => {
        const count = (predicate) => {
          const n = rows.filter(predicate).length;
          return n > 1 ? '2+' : String(n);
        };
        return 'scan_state=' + (['not_scanned', 'scanned', 'unknown'].includes(state) ? state : 'unknown')
          + '; candidate_count=' + count((r) => r.candidate === true)
          + '; testid_hit=' + rows.some((r) => r.testid_hit === true)
          + '; anchor_semantic_count=' + count((r) => r.semantic === 'anchor_new_chat')
          + '; button_semantic_count=' + count((r) => r.semantic === 'button_new_chat')
          + '; native_button_count=' + count((r) => r.native_button === true)
          + '; role_only_count=' + count((r) => r.role_only === true);
      };
      async function resetNativeChat(command) {
        delete diag['新聊天重設阻擋'];
        diag['新聊天控制'] = nativeResetControlDiagnostic([], 'not_scanned');
        revokePersonalizedProof('new_initial');
        nativeNewChatRequired = true; // 失敗、取消、picker 消失都不能把舊頁當成新頁。
        const box = composer(), origin = location.origin, path = location.pathname;
        const watch = { path, rootReached: path === '/', invalid: false };
        const noDraft = () => {
          const current = composer();
          return nativeResetComposerShape(current).state === 'empty';
        };
        const blocked = () => {
          if (command.cancelled || location.origin !== origin || stopVisible()
              || nativeResetDialogState().dialog_blocking_or_unknown || (composer() && !noDraft())) watch.invalid = true;
          return watch.invalid || !noDraft();
        };
        const recordBlock = () => {
          try {
            const current = composer();
            const shape = nativeResetComposerShape(current), dialogs = nativeResetDialogState();
            diag['新聊天重設阻擋'] = nativeResetBlockDiagnostic({
              cancelled: !!command.cancelled, origin_changed: location.origin !== origin,
              stop: !!stopVisible(), dialog: dialogs.dialog_blocking_or_unknown,
              composer_missing: !current,
              has_draft: !!current && shape.state !== 'empty',
              watch_invalid: !!watch.invalid,
              ...shape, ...dialogs,
            });
          } catch (e) {}
        };
        if (!box || blocked()) { diag['新聊天重設'] = 'blocked'; recordBlock(); return false; }
        let controls = [];
        try {
          // 先保留既有候選；只在沒有既有候選且無任何同語義衝突時，接受唯一原生 BUTTON。
          const observed = temporaryControls('[data-testid="create-new-chat-button"], a[href], button, [role="button"]');
          const rows = observed.map((el) => nativeResetControlClass({
            tag: el.tagName, role: el.getAttribute('role'), testid: el.getAttribute('data-testid'),
            href: el.getAttribute('href'), label: temporaryControlLabel(el),
          }, location.origin));
          controls = observed.filter((el, i) => rows[i].candidate);
          const contenders = observed.filter((el, i) =>
            rows[i].candidate || rows[i].native_button || rows[i].role_only);
          if (contenders.length !== 1) controls = [];
          else if (controls.length === 0)
            controls = observed.filter((el, i) => rows[i].native_button === true);
          diag['新聊天控制'] = nativeResetControlDiagnostic(rows);
        } catch (e) {
          diag['新聊天控制'] = nativeResetControlDiagnostic([], 'unknown');
        }
        if (controls.length !== 1) { diag['新聊天重設'] = 'control_unconfirmed'; recordBlock(); return false; }
        const beforeMessages = document.querySelectorAll('[data-message-author-role]').length;
        const beforeMode = nativeTemporaryUI().mode;
        nativeResetWatch = watch;
        try {
        diag['新聊天重設'] = 'requested';
        press(controls[0]);
        const ready = () => !blocked() && location.pathname === '/'
          && !document.querySelector('[data-message-author-role]')
          && nativeTemporaryUI().mode === 'off'
          && (path !== '/' || beforeMessages > 0 || beforeMode !== 'off' || composer() !== box);
        await waitFor(() => command.cancelled || ready(), 5000);
        if (!ready()) { diag['新聊天重設'] = 'unconfirmed'; recordBlock(); return false; }
        await sleep(120);
        if (!ready()) { diag['新聊天重設'] = 'unconfirmed'; recordBlock(); return false; }
        nativeNewChatRequired = false;
        command.nativeReset = { epoch: newChatEpoch, origin };
        diag['新聊天重設'] = 'confirmed';
        return true;
        } finally { if (nativeResetWatch === watch) nativeResetWatch = null; }
      }
      const personalizedPrepareSnapshot = () => {
        let current = null, shape = nativeResetComposerShape(null), dialogs = nativeResetDialogState();
        try {
          current = composer();
          shape = nativeResetComposerShape(current);
          return { current, ...shape, ...dialogs, dialog: dialogs.dialog_blocking_or_unknown, composer_missing: !current,
            has_draft: !!current && shape.state !== 'empty', stop: !!stopVisible(),
            messages: !!document.querySelector('[data-message-author-role]'), read_failed: shape.state === 'unknown' };
        } catch (e) {
          return { current, ...shape, ...dialogs, dialog: dialogs.dialog_blocking_or_unknown, composer_missing: !current, has_draft: true,
            stop: true, messages: true, read_failed: true };
        }
      };
      const personalizedPrepareDiagnostic = (stage, flags) => 'stage='
        + (['entry', 'before_toggle', 'toggle_wait', 'after_toggle', 'before_picker', 'picker_wait',
          'before_selection', 'selection_wait', 'confirm', 'current'].includes(stage) ? stage : 'unknown')
        + (stage === 'current' ? '' : '; composer_same=' + (flags.composer_same === true)
          + '; route_changed=' + (flags.route_changed === true))
        + '; messages=' + (flags.messages === true)
        + '; read_failed=' + (flags.read_failed === true)
        + '; ' + nativeResetBlockDiagnostic(flags);
      async function prepareNativePersonalizedTemporary(command) {
        if (command.cancelled || command.temporary !== true || command.temporaryPersonalized !== true) {
          personalizedDiagnostic('continuation_denied', command);
          return false;
        }
        let state = nativeTemporaryUI();
        if (command.conversationID) {
          command.personalizedProof = personalizedProof;
          const confirmed = !!(personalizedProof && personalizedProof.complete && personalizedContextOK(command));
          personalizedDiagnostic(confirmed ? 'continuation_allowed' : 'continuation_denied', command);
          return confirmed;
        }
        revokePersonalizedProof('new_initial');
        const initial = personalizedPrepareSnapshot(), box = initial.current;
        const origin = location.origin, path = location.pathname, epoch = newChatEpoch;
        let invalid = false;
        const emptyPage = (stage, rejected = false, snapshot = personalizedPrepareSnapshot()) => {
          // toggle / picker 可以合法重繪空框；每次驗當前框，不把舊節點當身分證據。
          const flags = { ...snapshot, composer_same: !!box && snapshot.current === box,
            cancelled: !!command.cancelled, origin_changed: location.origin !== origin,
            route_changed: location.pathname !== path || newChatEpoch !== epoch,
            dialog: snapshot.dialog_blocking_or_unknown };
          const safe = !rejected && !flags.cancelled && !flags.origin_changed && !flags.route_changed
            && !flags.stop && !flags.messages && !flags.read_failed
            && snapshot.state === 'empty' && !flags.dialog;
          if (!safe || invalid) {
            if (!invalid) diag['個人化準備阻擋'] = personalizedPrepareDiagnostic(stage, { ...flags, watch_invalid: true });
            invalid = true; // 看過不安全狀態後，即使回到空框也不能恢復此輪。
            return false;
          }
          return true;
        };
        if (!emptyPage('entry', false, initial)) return false;
        if (state.mode === 'off') {
          if (!emptyPage('before_toggle')) return false;
          press(state.toggle);
          await waitFor(() => !emptyPage('toggle_wait') || ['personalized', 'unpersonalized'].includes(nativeTemporaryUI().mode), 5000);
          if (!emptyPage('after_toggle')) return false;
          state = nativeTemporaryUI();
        }
        if (state.mode === 'unpersonalized') {
          if (!emptyPage('before_picker')) return false;
          press(state.picker);
          const item = await waitFor(() => {
            if (!emptyPage('picker_wait')) return true;
            const items = temporaryControls('[role="menuitemradio"], [role="menuitem"], [role="option"]')
              .filter((el) => /^(Personalized|個人化|个性化)(?:\s|$)/.test(temporaryControlLabel(el)));
            return items.length === 1 ? items[0] : null;
          }, 3000);
          if (!emptyPage('before_selection', !item || !chatVisible(item) || !chatEnabled(item))) return false;
          press(item);
          await waitFor(() => !emptyPage('selection_wait') || nativeTemporaryUI().mode === 'personalized', 3000);
        }
        const confirmed = emptyPage('confirm', nativeTemporaryUI().mode !== 'personalized');
        if (confirmed) {
          delete diag['個人化準備阻擋'];
          // 丟棄建立證據之前的 toggle／picker 變更；延後的 callback 不可誤判為之後反轉。
          if (personalizedObserver) personalizedObserver.takeRecords();
          personalizedRevocation = 'none';
          nativeNewChatRequired = true;
          command.personalizedProof = personalizedProof = { origin: location.origin, path: location.pathname,
            rootStart: location.pathname === '/', initialTurnID: null, localPath: null,
            routeID: null, conversationID: null, sent: false, complete: false, revoked: false };
          personalizedIDDiagnostic = null;
          delete diag['個人化路由撤銷'];
          delete diag['個人化原始ID'];
          delete diag['個人化首句過渡'];
          personalizedDiagnostic('created', command);
        }
        diag['原生臨時模式'] = confirmed ? 'personalized' : 'unconfirmed';
        return confirmed;
      }
      // Space 只做 Chat（使用者 09-24 裁決）：Work 跟 Codex 共用額度。新對話頁頂端的「Chat／Work」切到 Chat。
      const modeButton = (names) => [...document.querySelectorAll('button, [role="tab"], [role="radio"]')]
        .find((b) => names.includes(String(b.textContent || '').trim()));
      // 回傳 'chat'／'work'（確定還在 Work）／'unknown'（沒有切換鈕或看不出來，例如專案頁、沒有 Work 的帳號）。
      async function ensureChatMode() {
        const chat = modeButton(['Chat', '聊天', '對話']);
        if (!chat) { diag['Chat 切換'] = '找不到切換鈕'; return 'unknown'; }
        const work = modeButton(['Work', '工作']);
        // W180 A2：只有「Chat／Work」成對出現才是模式切換；專案頁的「對話」分頁不是，按了會把輸入框換掉。
        if (!work) { diag['Chat 切換'] = '沒有 Work 鈕，不是模式切換，沒按'; return 'unknown'; }
        const on = (b) => b && (b.getAttribute('aria-selected') === 'true' || b.getAttribute('aria-checked') === 'true'
          || b.getAttribute('aria-pressed') === 'true' || b.getAttribute('data-state') === 'active' || b.getAttribute('data-state') === 'on');
        if (on(chat)) { diag['Chat 切換'] = '已在 Chat'; return 'chat'; }
        chat.click();
        await sleep(350);
        if (on(chat)) { diag['Chat 切換'] = '已切到 Chat'; return 'chat'; }
        if (on(work)) { diag['Chat 切換'] = '切不過去（仍在 Work）'; return 'work'; }
        diag['Chat 切換'] = '已點 Chat（狀態看不出來）';
        return 'unknown';
      }
      async function regenerate(command) {
        const fail = (message) => postTerminal({ type: 'stream', id: command.id, kind: 'failed', message });
        if (nativeContinuationRequested(command)) personalizedDiagnostic('before_continuation', command);
        if (personalizedProof) proofPageOK(personalizedProof, location.pathname, 'regenerate');
        const nativeContinuation = nativeContinuationRequested(command);
        if (nativeContinuation && !(await prepareNativePersonalizedTemporary(command))) {
          if (!command.cancelled) fail('網頁尚未確認個人化臨時聊天，沒有重新產生');
          return;
        }
        if (!nativeContinuation && !(await openConversation(command.conversationID, command))) { fail('ChatGPT 網頁沒有開到這則對話（' + pageState() + '）'); return; }
        if (command.cancelled) return;
        if (command.cancelled) return;
        if (command.temporaryPersonalized === true) {
          if (!nativeContinuation && !(await prepareNativePersonalizedTemporary(command))) {
            if (!command.cancelled) fail('網頁尚未確認個人化臨時聊天，沒有重新產生');
            return;
          }
        } else if (lacksPersonalizedConsent(command)) {
          fail('沒有這則個人化臨時聊天的同意，沒有重新產生');
          return;
        }
        if (command.cancelled) return;
        const REGEN = /try again|regenerate|retry|重新產生|重新生成|再試一次/i;
        // 只看最後一個回答所在那一輪的按鈕（往上找到有好幾個按鈕的容器為止）。
        const nodes = assistantNodes();
        let scope = nodes[nodes.length - 1] || null;
        for (let i = 0; i < 8 && scope && scope.parentElement; i++) {
          scope = scope.parentElement;
          if (scope.querySelectorAll('button').length >= 3) break;
        }
        const buttons = [...(scope || document).querySelectorAll('button')];
        const labelOf = (b) => String(b.getAttribute('aria-label') || '') + ' ' + String(b.getAttribute('data-testid') || '');
        // 診斷只記按鈕的 aria-label／data-testid（介面名稱），不記按鈕裡的文字。
        diag['回答下方按鈕'] = buttons.map((b) => labelOf(b).trim()).filter(Boolean).map((t) => t.slice(0, 40)).join(', ').slice(0, 400) || '（沒有）';
        // 09-24 實機：回答下方是 Copy response／Share／Switch model／More actions；↻＝「Switch model」，會先跳選單再選 Try again。
        const SWITCH = /switch model|切換模型|更換模型/i;
        let button = buttons.slice().reverse().find((b) => REGEN.test(labelOf(b)));
        let viaMenu = false;
        if (!button) { button = buttons.slice().reverse().find((b) => SWITCH.test(labelOf(b))); viaMenu = !!button; }
        diag['重新產生'] = button ? '找到：' + labelOf(button).trim().slice(0, 40) : '找不到重新產生鈕';
        if (!button) { fail('找不到 ChatGPT 的重新產生鈕'); return; }
        // 換模型重答（網頁的 Switch model）：跟送出一樣改寫網頁送出的模型與強度；檔位代號＝「模型代號|強度」。
        let model = typeof command.model === 'string' && command.model ? command.model : null;
        let effort = null;
        if (typeof command.effort === 'string' && command.effort) {
          const parts = command.effort.split('|');
          model = parts[0] || model;
          effort = parts.length > 1 ? parts[1] : null;
        }
        if (model) diag['重新產生'] += '（換 ' + model + (effort ? '・' + effort : '') + '）';
        pendingModel = model;
        pendingEffort = effort;
        pendingSend = { id: command.id, model, effort, temporary: command.temporary === true,
          temporaryPersonalized: command.temporaryPersonalized === true,
          personalizedProof: command.personalizedProof,
          text: null, conversationID: command.conversationID || null };
        const turn = startTurn(command.id);
        turn.before = Math.max(0, turn.before - 1);
        // 經選單時這一下只是打開選單，按「Try again」才算送出。
        turn.submitted = !viaMenu;
        press(button);
        // ↻ 會先跳一個選單（換模型重答／Try again）：按「Try again」。
        const item = await waitFor(() => command.cancelled || [...document.querySelectorAll('[role="menuitem"], [role="menu"] button, [role="option"]')]
          .find((x) => REGEN.test(String(x.textContent || '')) || REGEN.test(String(x.getAttribute('aria-label') || ''))), viaMenu ? 2000 : 400);
        if (command.cancelled) return;
        if (item) {
          if (command.temporaryPersonalized === true && !personalizedContextOK(command)) {
            finishTurn(turn, '個人化臨時模式在送出前變更，已擋下');
            return;
          }
          diag['重新產生'] += '（經選單）';
          turn.submitted = true;
          press(item);
        } else if (viaMenu) {
          // 選單項目只記介面名稱（模型名、Try again 之類），不含對話內容。
          const items = [...document.querySelectorAll('[role="menuitem"], [role="option"]')].map((x) => String(x.textContent || '').trim().slice(0, 30));
          diag['重新產生選單'] = items.join(', ').slice(0, 300) || '（選單沒打開）';
          pendingSend = null;
          pendingModel = null;
          pendingEffort = null;
          finishTurn(turn, '找不到「Try again」');
          return;
        }
        setTimeout(() => {
          if (!pendingSend || pendingSend.id !== command.id) return;
          pendingSend = null;
          pendingModel = null;
          pendingEffort = null;
          if (!turn.finished && !turn.domText && !turn.sawStop) finishTurn(turn, 'ChatGPT 沒有重新產生（可能跳出了選單）');
        }, 15000);
      }
      // 附件（第 2 批）：交給網頁自己的上傳欄位，由 ChatGPT 自己上傳（格式、大小限制都跟網頁版一樣）。
      const attachFiles = async (files) => {
        const inputs = [...document.querySelectorAll('input[type="file"]')];
        diag['上傳欄位'] = inputs.map((i) => (i.getAttribute('accept') || '*') + (i.multiple ? '+multi' : '')).join(', ').slice(0, 200) || '（沒有）';
        const input = inputs.find((i) => !i.getAttribute('accept') || i.getAttribute('accept') === '*') || inputs[0];
        if (!input || typeof DataTransfer !== 'function') { diag['上傳'] = '找不到上傳欄位'; return false; }
        const transfer = new DataTransfer();
        for (const f of files) {
          const binary = atob(String(f.base64 || ''));
          const bytes = new Uint8Array(binary.length);
          for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
          transfer.items.add(new File([bytes], String(f.name || 'file'), { type: String(f.mime || 'application/octet-stream') }));
        }
        input.files = transfer.files;
        input.dispatchEvent(new Event('change', { bubbles: true }));
        diag['上傳'] = '已交給網頁 ' + files.length + ' 個';
        return true;
      };
      async function send(command) {
        let clickAttempted = false;
        const fail = (message) => postTerminal({ type: 'stream', id: command.id, kind: 'failed', submitted: false, message });
        try {
        if (nativeContinuationRequested(command)) personalizedDiagnostic('before_continuation', command);
        if (personalizedProof) proofPageOK(personalizedProof, location.pathname, 'send');
        // 續聊／編輯先驗證原生頁證據，不為了驗證而先導航破壞它；不足就原地拒絕。
        const nativeContinuation = nativeContinuationRequested(command);
        if (nativeContinuation && !(await prepareNativePersonalizedTemporary(command))) {
          if (!command.cancelled) fail('網頁尚未確認個人化臨時聊天，沒有送出');
          return;
        }
        if (!command.conversationID && (nativeNewChatRequired
            || (location.pathname === '/' && document.querySelectorAll('[data-message-author-role]').length > 0))) {
          if (!(await resetNativeChat(command))) {
            if (!command.cancelled) fail('網頁尚未確認原生新聊天，沒有送出；既有草稿保留');
            return;
          }
        }
        if (command.cancelled) return;
        const opened = nativeContinuation || (!command.conversationID && typeof command.gizmoID === 'string' && command.gizmoID
          ? await openGizmo(command.gizmoID, command) : await openConversation(command.conversationID, command));
        if (command.cancelled) return;
        if (!opened) { fail('ChatGPT 網頁沒有開到這則對話（' + pageState() + '）'); return; }
        // Space 只做 Chat：確定還停在 Work（跟 Codex 共用額度）就不送（審查 #6）。
        if (!command.conversationID && (await ensureChatMode()) === 'work') { fail('ChatGPT 停在 Work 模式（跟 Codex 共用額度），這則沒有送出'); return; }
        if (command.cancelled) return;
        if (command.temporaryPersonalized === true) {
          if (!nativeContinuation && !(await prepareNativePersonalizedTemporary(command))) {
            if (!command.cancelled) fail('網頁尚未確認個人化臨時聊天，沒有送出');
            return;
          }
        } else if (lacksPersonalizedConsent(command)) {
          // 上一則曾明確同意，不代表這一則也同意。不得把個人化狀態帶給另一則。
          fail('網頁仍在上一則個人化臨時聊天，沒有送出；請先在網頁開新聊天');
          return;
        }
        // W184 G3b 第二輪（審查 #8）：接著舊對話送（抽屜、側欄點的歷史）也只做 Chat：那一則是 Work 模式開的就不送。
        // 讀過的對話直接查（Space／私訊框開對話時都讀過）；沒讀過才讀一次。
        if (command.conversationID) {
          const cid = String(command.conversationID);
          let work = workConversations.get(cid);
          if (work === undefined) {
            if (!workModels.size) { try { await handlers.models(); } catch (e) {} }
            if (command.cancelled) return;
            try { work = isWorkConversation(await api('/backend-api/conversation/' + encodeURIComponent(cid))); } catch (e) { work = false; }
            workConversations.set(cid, work);
          }
          if (work) { fail('這則是 Work 模式的對話（跟 Codex 共用額度），這裡只做 Chat，不能接著聊'); return; }
          if (command.cancelled) return;
        }
        if (command.cancelled) return;
        if (!command.conversationID) {
          if (command.nativeReset) {
            const current = composer();
            if (command.nativeReset.epoch !== newChatEpoch || command.nativeReset.origin !== location.origin
                || nativeResetComposerShape(current).state !== 'empty' || nativeResetDialogState().dialog_blocking_or_unknown) {
              fail('原生新聊天的頁面或草稿已變更，沒有送出'); return;
            }
          }
          if (command.temporary !== true && personalizedObserver) personalizedObserver.takeRecords();
          command.newChat = { command, origin: location.origin, path: location.pathname, epoch: newChatEpoch, invalid: false };
          preparingNewChat = command;
        }
        const files = Array.isArray(command.files) ? command.files : [];
        if (files.length && !(await attachFiles(files))) { fail('找不到 ChatGPT 的上傳欄位'); return; }
        if (command.cancelled) return;
        // W180 A2：專案頁換頁後網頁可能重畫輸入框，等它回來（最多 5 秒）再找。
        const readyComposer = () => {
          const box = composer();
          return box && !chatBusy(box) ? box : null;
        };
        const readyDeadline = Date.now() + (files.length ? 90000 : 5000);
        let box = await waitFor(() => command.cancelled || readyComposer(), readyDeadline - Date.now());
        if (command.cancelled) return;
        // 強度選項的代號是「模型代號|強度」或單純「模型代號」（沒有強度的版本）。
        let model = command.model || null;
        let effort = null;
        if (command.effort) {
          const parts = String(command.effort).split('|');
          model = parts[0] || model;
          effort = parts.length > 1 ? parts[1] : null;
        }
        command.model = model;
        command.effort = effort;
        pendingModel = model;
        pendingEffort = effort;
        pendingHint = typeof command.hint === 'string' && command.hint ? command.hint : null;
        pendingParent = command.conversationID && typeof command.parentID === 'string' && command.parentID ? command.parentID : null;
        pendingGizmo = !command.conversationID && typeof command.gizmoID === 'string' && /^g-/.test(command.gizmoID) ? command.gizmoID : null;
        if (!box) {
          pendingModel = null; pendingEffort = null; pendingParent = null; pendingGizmo = null;
          fail('找不到 ChatGPT 的輸入框（' + pageState() + (diag['Chat 切換'] ? '・Chat 切換：' + diag['Chat 切換'] : '') + '）');
          return;
        }
        // 只選輸入框裡的字（網頁可能把上次沒送出的字當草稿恢復；對整頁全選蓋不掉它；09-25 實機）。
        const selectComposer = () => {
          if (command.cancelled || (command.newChat && !newChatContextOK(command.newChat)) || composer() !== box || chatBusy(box)) return false;
          if (command.nativeReset && (nativeResetComposerShape(box).state !== 'empty' || nativeResetDialogState().dialog_blocking_or_unknown)) return false;
          box.focus();
          if (command.cancelled || composer() !== box || (document.activeElement !== box && !box.contains(document.activeElement))) return false;
          if (command.nativeReset && (nativeResetComposerShape(box).state !== 'empty' || nativeResetDialogState().dialog_blocking_or_unknown)) return false;
          try {
            if (typeof box.select === 'function') box.select();
            else {
              const range = document.createRange();
              range.selectNodeContents(box);
              const selection = window.getSelection();
              selection.removeAllRanges();
              selection.addRange(range);
            }
          } catch (e) { return false; }
          return !command.cancelled && composer() === box && !chatBusy(box)
            && (document.activeElement === box || box.contains(document.activeElement));
        };
        const wanted = String(command.text || '').trim();
        const composerText = (el) => String(el.value != null ? el.value : (el.innerText || '')).trim();
        // 主導 10-03 實機：多段文字放進 ChatGPT 輸入框後，網頁會改寫段落與換行（innerText 的換行數不同），
        // 逐字比對就判定「打不進」，連 ChatGPT Space 送兩段話都失敗。比對時忽略所有空白與換行，只比字的內容。
        const sameText = (a, b) => String(a || '').replace(/\s+/g, '') === String(b || '').replace(/\s+/g, '');
        if (!wanted && !files.length) { fail('訊息是空白，沒有送出'); return; }
        // 最多重試插字一次；每次重找仍可編輯的框。空白也是插入失敗，不能略過。
        let inserted = false;
        for (let attempt = 0; attempt < 2; attempt += 1) {
          box = readyComposer();
          if (!box || !selectComposer()) break;
          document.execCommand(wanted ? 'insertText' : 'delete', false, command.text || '');
          if (command.cancelled) return;
          if (composer() === box && sameText(composerText(box), wanted)) { inserted = true; break; }
        }
        if (!inserted || !box || composer() !== box || !sameText(composerText(box), wanted)) {
          fail('ChatGPT 的輸入框打不進這段字'); return;
        }
        const form = chatForm(box);
        // 有附件時網頁要先上傳完才讓送出：等久一點。
        const candidate = await waitFor(() => {
          if (command.cancelled) return true;
          const current = composer();
          if (!current) return null;
          if (chatForm(current) !== form || !sameText(composerText(current), wanted)) return { changed: true };
          const button = sendButton(current);
          return button ? { box: current, button } : null;
        }, Math.max(1, readyDeadline - Date.now()));
        if (command.cancelled) return;
        if (!candidate) {
          diag['送出鍵'] = sendState();
          fail('ChatGPT 的送出鍵尚不可用，沒有送出（' + sendState() + '）'); return;
        }
        const button = candidate.button;
        box = candidate.box;
        const stillReady = () => !command.cancelled && box && composer() === box && chatForm(box) === form
          && sendButton(box) === button && sameText(composerText(box), wanted) && !command.cancelled
          && (!command.newChat || newChatContextOK(command.newChat))
          && (command.temporaryPersonalized !== true || personalizedContextOK(command));
        if (!stillReady()) { fail('ChatGPT 的輸入框或送出鍵已變更，沒有送出'); return; }
        // 暫時對話的每一則（不只第一則）都要帶暫時旗標，否則伺服器找不到那則對話（09-24 實機：第二則 HTTP 404）。
        pendingSend = { id: command.id, model: command.model || null, effort: command.effort || null, hint: pendingHint,
          temporary: command.temporary === true, parentID: pendingParent, gizmo: pendingGizmo,
          temporaryPersonalized: command.temporaryPersonalized === true,
          personalizedProof: command.personalizedProof,
          newChat: command.newChat,
          text: command.text, conversationID: command.conversationID || null };
        const turn = startTurn(command.id);
        turn.project = pendingGizmo && /^g-p-/.test(pendingGizmo) ? pendingGizmo : null;
        if (!stillReady()) {
          clearInterval(turn.timer);
          delete turns[turn.id];
          pendingSend = null;
          if (!command.cancelled) fail('ChatGPT 的輸入框或送出鍵已變更，沒有送出');
          return;
        }
        // 從呼叫 click 起就可能已送出；包括 click 丟例外也不再宣稱 not submitted。
        clickAttempted = true;
        turn.submitted = true;
        button.click();
        setTimeout(() => {
          if (!pendingSend || pendingSend.id !== command.id) return;
          pendingSend = null;
          pendingModel = null;
          pendingEffort = null;
          pendingHint = null;
          pendingParent = null;
          pendingGizmo = null;
          // 沒攔到送出請求但網頁上已經在回答：照樣靠網頁畫面與網址完成，不算失敗。
          if (!turn.finished && !turn.domText && !turn.sawStop) {
            finishTurn(turn, 'ChatGPT 送出結果不明，請先確認對話，勿直接重送' + (diag['準備回應'] ? '（準備請求 ' + diag['準備回應'] + '；' + pageState() + '）' : '（' + pageState() + '）'));
          }
        }, 20000);
        } catch (e) {
          if (clickAttempted) throw e;
          fail('ChatGPT 送出前發生錯誤，沒有送出');
        } finally {
          if (preparingNewChat === command) preparingNewChat = null;
          if (!clickAttempted) {
            if (pendingSend && pendingSend.id === command.id) pendingSend = null;
            const turn = turns[command.id];
            if (turn && !turn.submitted) { clearInterval(turn.timer); delete turns[command.id]; }
            pendingModel = pendingEffort = pendingHint = pendingParent = pendingGizmo = null;
            pendingTemporary = false;
          }
        }
      }

      // 推理強度：欄位名稱沒有公開文件，寬鬆地認幾種常見寫法；認不出來就不列（診斷會寫原因）。
      const effortList = (m) => m.thinking_efforts || m.reasoning_efforts || m.efforts
        || (m.thinking && (m.thinking.efforts || m.thinking.options)) || null;
      // 沒有強度等級的版本，照推理類型取名（網頁版滑桿上的叫法）。
      const VARIANT_LABELS = { none: 'Instant', auto: 'Auto', reasoning: 'Thinking', pro: 'Pro' };
      const effortsOf = (m) => {
        const list = effortList(m);
        if (!Array.isArray(list)) return [];
        return list.map((e) => (typeof e === 'string' ? { id: e, title: e }
          : { id: e && (e.thinking_effort || e.reasoning_effort || e.effort || e.id || e.value || e.slug),
              // 網頁版彈出框用完整標籤（09-24：max 的 short_label 是 Heavy，網頁顯示 Extra High）。
              title: e && (e.full_label || e.short_label || e.label || e.title || e.name || e.display_name) }))
          .filter((e) => typeof e.id === 'string' && e.id)
          .map((e) => ({ id: e.id, title: typeof e.title === 'string' && e.title ? e.title : e.id }));
      };
      const effortSource = (m) => {
        const list = effortList(m);
        const first = Array.isArray(list) ? list[0] : null;
        return (m.thinking_efforts ? 'thinking_efforts' : m.reasoning_efforts ? 'reasoning_efforts' : m.efforts ? 'efforts' : 'thinking.*')
          + '（' + (first && typeof first === 'object' ? Object.keys(first).sort().join('+') : typeof first) + '）';
      };
      const keysOf = (list) => { const k = new Set(); (list || []).forEach((x) => x && typeof x === 'object' && Object.keys(x).forEach((y) => k.add(y))); return [...k].sort().join('+').slice(0, 200); };
      // GPT／專案：有的包在 gizmo.gizmo，GPTs 清單包在 resource（09-24 實機：gizmos/bootstrap 是 flair＋resource）。
      const gizmoOf = (it) => {
        if (!it || typeof it !== 'object') return it;
        const r = it.resource && typeof it.resource === 'object' ? it.resource : it;
        return (r.gizmo && (r.gizmo.gizmo || r.gizmo)) || r;
      };
      const nameOf = (g) => g && ((g.display && (g.display.name || g.display.title)) || g.name || g.title);
      const projectOf = (it) => {
        const g = gizmoOf(it);
        const id = g && (g.id || g.gizmo_id);
        const title = nameOf(g);
        const description = g && ((g.display && g.display.description) || g.description) || '';
        return id && title ? { id, title, kind: 'project', ...(description ? { description } : {}) } : null;
      };
      const pinOf = (p) => {
        if (!p || typeof p !== 'object') return null;
        const inner = p.item || p.pinned_item || p;
        const conv = inner.conversation || null;
        const g = inner.gizmo ? gizmoOf(inner) : null;
        const id = (conv && conv.id) || inner.conversation_id || (g && g.id) || inner.gizmo_id || inner.id;
        const title = (conv && conv.title) || inner.title || nameOf(g) || nameOf(inner);
        if (typeof id !== 'string' || !id || !title) return null;
        const kind = /^g-p-/.test(id) ? 'project' : UUID_IN_PATH.test('/c/' + id) ? 'conversation' : 'other';
        return { id, title, kind };
      };

      // 取檔：同網域就在這裡抓（要網頁的登入）轉成 base64；別的網域（有簽章、會過期）把網址交給 App 用不落地的連線下載。
      const fetchBytes = async (url, label, limitMB) => {
        const absolute = new URL(url, location.href);
        if (absolute.origin !== location.origin) { diag[label] = '外部網址交給 App 下載'; return { url: absolute.href }; }
        const r = await originalFetch(absolute.href, { credentials: 'include', headers: auth || {}, cache: 'no-store' });
        if (!r.ok) { diag[label] = '同網域下載 HTTP ' + r.status; throw new Error('HTTP ' + r.status); }
        const blob = await r.blob();
        if (blob.size > limitMB * 1024 * 1024) { diag[label] = '檔案太大'; throw new Error('file too large'); }
        const base64 = await new Promise((resolve, reject) => {
          const reader = new FileReader();
          reader.onload = () => resolve(String(reader.result).split(',')[1] || '');
          reader.onerror = () => reject(new Error('read failed'));
          reader.readAsDataURL(blob);
        });
        diag[label] = '同網域下載成功';
        return { mime: blob.type, base64 };
      };
      // 資料庫的一筆：只留檔名、類型、時間、大小（資料夾與其他收藏先不列）。
      const libraryItemOf = (x) => {
        if (!x || typeof x !== 'object' || (x.kind && x.kind !== 'file')) return null;
        const id = x.id || x.library_item_id || x.library_file_id;
        const name = x.file_name || x.name || x.title;
        if (typeof id !== 'string' || !id || typeof name !== 'string' || !name) return null;
        const mime = typeof x.mime_type === 'string' ? x.mime_type : '';
        const category = typeof x.library_file_category === 'string' && x.library_file_category ? x.library_file_category
          : /^image\//.test(mime) ? 'image' : mime === 'application/pdf' ? 'pdf' : /^text\//.test(mime) ? 'text' : 'file';
        return { id, name: name.slice(0, 200), mime, category,
          time: x.last_used_at || x.updated_at || x.file_upload_time || x.record_creation_time || x.created_at || null,
          size: typeof x.file_size_bytes === 'number' ? x.file_size_bytes : null };
      };
      // 新對話頁的大標題：網頁從一組句子裡挑一句（例如 Ready when you are.）；不在新對話頁時用上次看到的。
      let lastHeadline = null;

      // ---- W183 R6b：ChatGPT 手腳的連接器（使用者在 TATWO 私訊框按「連線」才跑；App 以 runPodCommand 下指令） ----
      // 以「完整 MCP 網址＋OAuth」辨識既有的，不以名字；按建立前讀回網址完全相等、驗證方式是 OAuth、表單唯一；
      // 找不到或不只一個就停（不猜按鈕、不降成免驗證）；開發者模式、要打勾的警語一律交給使用者（不代按、不勾選）。
      // 只回報結果代碼、找到的外掛 id 與名字；不回報頁面內容或網址參數（帳號身分只給 connectorAccount：登入編號、工作區、信箱，App 只拿來比對）。
      // W183 R6b 審查（GPT-6、Claude）：
      // - 世代：會換頁或改表單的指令一開始就換一個世代；舊的指令在下一個動作（按、填）之前發現世代換了就停手（App 放掉獨占前送 connectorAbort）。
      // - 使用者「看過」的警語綁在那一張表單（data-tatwo-form 記號）與那一段警語的指紋；表單換了、警語變了＝還沒看過，再交給使用者。
      // - 清單要讀得出完整的樣子（認得的清單欄位、沒有下一頁）才能說「沒有既有的」；否則當成不知道。
      // - 重新連線只認清單用完整網址認出來的那個 id 的連結，在它的詳情區（對話框或區塊）裡讀回完整網址、驗證方式、警語，只按那一區唯一的連線鈕；
      //   沒有 id、找不到那一區、不只一個＝停（不靠整頁文字、不按別的外掛的鈕）。
      // W183 R9（ChatGPT 改版，09-29 實機：外掛頁右上角是「新增 ▾」，選單三項「建立外掛程式」「上傳外掛程式封存檔」「建立 MCP 應用程式」）：
      // - 先找舊的單一建立鈕（＋）；找不到才找「新增」下拉（字正好是 新增／New／Add、要是選單鈕 aria-haspopup；只能剛好一顆），
      //   在選單裡選剛好一個「建立 MCP 應用程式」（大小寫、空白寬鬆）；絕不選另外兩項。
      // - New Plugin 表單：Name、Connection（分段 Server URL｜Tunnel：一定要 Server URL，按完讀回；確認不了＝拒絕，不用 Tunnel）、
      //   Authentication（「按鈕上寫 OAuth」的下拉；預設就是 OAuth＝不碰）；Description、Icon、Advanced OAuth settings 不碰。
      // - 「I understand and want to continue」照舊一律不代勾（needs_user、reason risk_ack），使用者勾完按繼續＝同一張表單讀回才按 Create。
      // - pluginNewMenu：原生外掛頁的「新增 ▾」只把網頁的對話框打開（不填、不勾、不按 Create）。
      // W183 R9 審查（GPT-6、Claude）：
      // - 表單身分看節點本身（記在這個閉包裡：同一個對話框、同一個 Name／網址欄），不看網頁上的屬性；按了 Create 就作廢（一次性）。
      // - 交給使用者勾的那幾格（和「I understand and want to continue」）要有使用者真的按過的紀錄（isTrusted 的點擊或按鍵），網頁自己勾的不算。
      // - 選單只認按「新增」之後打開的那一個；Connection 要讀得出 Server URL＝選了、Tunnel＝沒選（矛盾、讀不出來＝拒絕）；
      //   驗證方式只認剛好一個控制項、每個值來源都正好是 OAuth；網址欄只認明確的網址欄；Name 在按 Create 前讀回。
      // - 警語指紋收每一段含警語字的整段文字（含裡面的連結字）與勾選那一列的說明。
      // ==== SAFE-CHAIN BEGIN：連接器與「新增 ▾」的安全判斷（只用上面工具箱裡抓好的版本） ====
      const CONNECTOR_NAME = 'TATWO';
      // W183 R8c：多台時每台一個連接器「TATWO（<設備名稱>）」；只收這個樣子（沒有控制字元、括號、最多 40 字），不合就用 TATWO。
      const connectorName = (raw) => {
        const n = sOf(raw);
        // Historical numbered duplicates are recognised for reuse and explicit cleanup only.
        return reTest(/^TATWO（[^\u0000-\u001f（）]{1,40}）(?:[2-9]|[1-9][0-9]+)?$/, n) ? n : CONNECTOR_NAME;
      };
      const connectorURL = (raw) => {
        const u = sOf(raw);
        const m = reExec(/^https:\/\/([a-z0-9-]+(?:\.[a-z0-9-]+)+)\/mcp$/, u);
        if (!m || reTest(/(^|\.)(chatgpt\.com|openai\.com)$/, m[1])) throw new Error('bad connector url');
        return u;
      };
      const attrOf = safeAttr;
      const squash = safeSquash;
      const allOf = safeAll;
      const labelOf = (el) => safeSquash(safeAttr(el, 'aria-label') || safeText(el));
      // W183 R9：欄位（或按鈕）本身、或裡面有欄位的一格。
      const isControl = (el) => reTest(/^(INPUT|TEXTAREA|SELECT|BUTTON)$/, safeTag(el)) || reTest(/^(combobox|checkbox|switch|radio|button|textbox)$/, safeAttr(el, 'role'));
      const CONTROL_SELECTOR = 'input, textarea, select, button, [role="combobox"], [role="checkbox"], [role="switch"], [role="radio"], [role="button"], [role="textbox"]';
      const hasControl = (el) => isControl(el) || safeAll(el, CONTROL_SELECTOR).length > 0;
      const controlCount = (el) => (isControl(el) ? 1 : 0) + safeAll(el, CONTROL_SELECTOR).length;
      const isDialog = (el) => safeTag(el) === 'DIALOG' || safeAttr(el, 'role') === 'dialog';
      // W183 R9 審查（GPT-6 #2、N1–N3；R9c C2）：使用者真的按的（isTrusted：網頁的程式、TATWO 自己的 press 都做不出來）。
      // 這個腳本比網頁自己的程式早跑，所以在 window 的捕獲階段第一個收到。事件發生的當下就綁「這一輪交給使用者勾的那幾格」
      // （這一輪開始時記下的那一格與它的 label；label 的 for 當下還要指著它），只收兩種啟動：點擊（在那一格、或這一輪記下的 label 上），
      // 焦點在那一格上的空白鍵（按下與放開算同一次）。
      // - 每一次有效的啟動：先同步拿掉那一格的舊證據、那一格的啟動序號加一；事件整段跑完之後（setTimeout 0）只有「還是最新的那一次、
      //   而且從沒勾變成勾」才重新給證據（R9c C2：使用者取消之後網頁在處理程式或微任務裡再勾回去＝沒有證據）。
      // - 原生勾選框：瀏覽器在點擊事件之前就先翻轉（事件裡讀到的已經是新狀態）；其他（role=checkbox）在網頁自己的處理之後才翻轉。
      // - 網頁自己的程式送的點擊（label.click()、dispatchEvent）派送中＝這一段裡的點擊一律不算（Chromium 替 label 轉給欄位的那一下
      //   會被當成真人），網頁那一段程式跑完（微任務）才解除。
      // - 瀏覽器從 <label> 轉過來的那一下：只認這一輪記下的 label（網頁臨時蓋一個 <label for> 在別處＝不算）。
      // - Enter 帶出來的點擊（焦點被放到那一格上、使用者按 Enter，按鈕式的勾選框會被點一下）＝不算。
      let taint = 0;
      let labelHop = null;
      let enterHop = null;
      let keyOp = null;   // 按下空白鍵開始的那一次（放開時接著算同一次）
      const labelAround = (el) => { for (let p = el, i = 0; p && i < 16; p = safeParent(p), i += 1) if (safeTag(p) === 'LABEL') return p; return null; };
      // 包著的 <label> 標的是它裡面第一個能被標的欄位（瀏覽器的規則；hidden 的 input 不算）：要剛好是這一格。
      const LABELABLE = 'button, input, meter, output, progress, select, textarea';
      const labelsControl = (label, box) => {
        const all = safeAll(label, LABELABLE);
        for (let i = 0; i < all.length; i += 1) {
          if (safeTag(all[i]) === 'INPUT' && safeAttr(all[i], 'type') === 'hidden') continue;
          return all[i] === box;
        }
        return false;
      };
      // 這一輪記下的 label 還是它的 label：for 指著它的＝for 還指著它；包著它的＝沒有 for 而且它是裡面第一個欄位（或 for 指著它）。
      const labelStill = (zone, label) => {
        const f = safeAttr(label.node, 'for');
        return label.viaFor ? f === zone.id : (f ? f === zone.id : labelsControl(label.node, zone.box));
      };
      const spaceKey = (e) => { try { return pget(G_evKey, e) === ' ' || pget(G_evCode, e) === 'Space'; } catch (err) { return false; } };
      const enterKey = (e) => {
        try { const k = pget(G_evKey, e); const c = pget(G_evCode, e); return k === 'Enter' || c === 'Enter' || c === 'NumpadEnter'; } catch (err) { return false; }
      };
      // 一次有效啟動：拿掉舊證據、序號加一，記下「開始時勾了沒」。
      const startOp = (rec, box, before) => {
        const seq = (weakGet(rec.seq, box) || 0) + 1;
        weakSet(rec.seq, box, seq);
        weakSet(rec.proof, box, 0);
        const op = bag();
        op.rec = rec; op.box = box; op.round = rec.round; op.seq = seq; op.before = before;
        return op;
      };
      // 事件整段跑完之後看：還是這一格最新的那一次、這一輪沒換、沒作廢，而且從沒勾變成勾＝給證據。
      const settleOp = (op) => {
        later(() => {
          const rec = op.rec;
          if (rec.void || rec.round !== op.round || weakGet(rec.seq, op.box) !== op.seq) return;
          if (!op.before && safeChecked(op.box)) weakSet(rec.proof, op.box, op.round);
        });
      };
      // W183 R12（.035 實機：程式按 Create 沒有真人手勢）：最近一次真的點擊（isTrusted）落在哪裡、什麼時候（App 用 CEF 真的滑鼠點 Create 之後核）。
      let lastTrustedClick = null;
      let lastTrustedAt = 0;
      let aimedPress = null;
      const noteTrusted = (e) => {
        try {
          if (!e || !KIT_OK) return;
          const type = pget(G_evType, e);
          if (e.isTrusted !== true) {
            if (type === 'click') { taint += 1; micro(() => { taint -= 1; }); }
            return;
          }
          if (taint > 0) return;
          if (type === 'click') { lastTrustedClick = pget(G_evTarget, e); lastTrustedAt = nowMs(); }
          const click = type === 'click';
          if (type === 'keydown' && enterKey(e)) {
            const focused = pget(G_evTarget, e);
            enterHop = focused;
            later(() => { if (enterHop === focused) enterHop = null; });
            return;
          }
          const space = (type === 'keydown' || type === 'keyup') && spaceKey(e);
          if (!click && !space) return;
          const target = pget(G_evTarget, e);
          if (!target) return;
          if (click && enterHop && (enterHop === target || safeContains(enterHop, target))) return;
          // 放開空白鍵：只接著算同一格按下時開始的那一次（沒有按下的放開＝不算）。
          if (type === 'keyup') {
            const k = keyOp;
            keyOp = null;
            if (k && (k.box === target || safeContains(k.box, target))) settleOp(k);
            return;
          }
          const hop = click ? labelHop : null;
          if (click) {
            const label = labelAround(target);
            if (label) { labelHop = label; later(() => { if (labelHop === label) labelHop = null; }); }
          }
          if (type === 'keydown') keyOp = null;
          for (const mark in ownForms) {
            const rec = ownForms[mark];
            if (!rec || rec.void || !(rec.round >= 1)) continue;
            const zones = rec.zones;
            for (let i = 0; i < zones.length; i += 1) {
              const zone = zones[i];
              const box = zone.box;
              const direct = safeContains(box, target);
              let hit = direct;
              if (direct && hop) {
                hit = false;
                for (let j = 0; j < zone.labels.length; j += 1) if (zone.labels[j].node === hop && labelStill(zone, zone.labels[j])) hit = true;
              }
              if (!direct && click) {
                for (let j = 0; !hit && j < zone.labels.length; j += 1) {
                  const label = zone.labels[j];
                  if (labelStill(zone, label)) hit = safeContains(label.node, target);
                }
              }
              if (!hit) continue;
              const now = safeChecked(box);
              const op = startOp(rec, box, click && direct && safeTag(box) === 'INPUT' ? !now : now);
              if (type === 'keydown') keyOp = op;
              settleOp(op);
            }
          }
        } catch (err) {}
      };
      try {
        R_apply(M_addEvt, window, ['click', noteTrusted, true]);
        R_apply(M_addEvt, window, ['keydown', noteTrusted, true]);
        R_apply(M_addEvt, window, ['keyup', noteTrusted, true]);
      } catch (e) {}
      // W183 R9：新表單的欄位名稱常是欄位前面緊鄰的那一格字（不是 <label for>）：往上最多 3 層，看緊鄰的前一格；
      // 前一格裡有欄位、沒有字、字太長＝不算，而且不再往前找（只認緊鄰的，不會拿到別的欄位的名稱）。
      const nearLabel = (el) => {
        for (let node = el, i = 0; node && safeParent(node) && i < 3; node = safeParent(node), i += 1) {
          const siblings = dKids(safeParent(node));
          const at = listIndex(siblings, node);
          if (at > 0) {
            const prev = siblings[at - 1];
            const text = safeSquash(safeText(prev));
            return !hasControl(prev) && text.length > 0 && text.length <= 40 ? text : '';
          }
        }
        return '';
      };
      // <label for> 指著它、aria-labelledby、包著它的 <label> 的字（各自一段）。
      const forLabels = (el) => {
        const out = [];
        const id = safeAttr(el, 'id');
        if (id) {
          const labels = safeAll(document, 'label');
          for (let i = 0; i < labels.length; i += 1) if (safeAttr(labels[i], 'for') === id) listAdd(out, safeText(labels[i]));
        }
        return out;
      };
      const labelledByText = (el) => {
        const ids = sWords(safeAttr(el, 'aria-labelledby'));
        let t = '';
        for (let i = 0; i < ids.length; i += 1) { const e = dById(ids[i]); if (e) t += ' ' + safeText(e); }
        return safeSquash(t);
      };
      const fieldLabel = (input) => {
        const bits = [safeAttr(input, 'aria-label'), safeAttr(input, 'placeholder'), safeAttr(input, 'name')];
        const fors = forLabels(input);
        for (let i = 0; i < fors.length; i += 1) listAdd(bits, fors[i]);
        listAdd(bits, labelledByText(input));
        for (let p = safeParent(input), i = 0; p && i < 2; p = safeParent(p), i += 1) if (safeTag(p) === 'LABEL') listAdd(bits, safeText(p));
        listAdd(bits, nearLabel(input));   // W183 R9
        return safeSquash(aJoin(bits, ' '));
      };
      const textInputs = (root) => aFilter(visibleOf(root, 'input, textarea'),
        (x) => !reTest(/^(hidden|checkbox|radio|submit|button|file|image|reset)$/i, safeAttr(x, 'type')));
      // W183 R9 審查（GPT-6）：網址欄只認明確的網址欄——type=url、placeholder 是 https://…、或欄位名稱寫著 URL／網址／MCP 伺服器；
      // 只寫「Connection」「MCP」不夠（說明欄也可能寫 MCP）；說明、圖示、搜尋欄、textarea、不能改的欄位一律不算。
      const URL_LABEL = /(server\s*url|\burl\b|網址|伺服器\s*(url|網址|位址)|mcp\s*(server|伺服器|endpoint|端點))/i;
      const NOT_URL_FIELD = /(description|describe|說明|描述|icon|圖示|search|搜尋)/i;
      const NAME_FIELD = /(^|\s)(name|名稱|名字)(\s|\*|:|：|$)/i;
      const editable = (x) => !dDisabled(x) && !dReadOnly(x) && safeAttr(x, 'aria-readonly') !== 'true' && safeAttr(x, 'aria-disabled') !== 'true';
      const plainInput = (x) => safeTag(x) === 'INPUT' && editable(x)
        && !reTest(/^(search)$/i, safeAttr(x, 'type')) && !reTest(/^(searchbox|combobox)$/, safeAttr(x, 'role'));
      // 欄位名稱（去掉 placeholder 本身，placeholder 的網址不拿來判斷「是不是說明、搜尋欄」）。
      const namesOf = (x) => { const ph = safeAttr(x, 'placeholder'); const all = fieldLabel(x); return ph ? safeSquash(sReplaceAll(all, ph, ' ')) : all; };
      const urlFields = (root) => aFilter(textInputs(root), (x) => plainInput(x) && !reTest(NOT_URL_FIELD, namesOf(x))
        && (reTest(/^url$/i, safeAttr(x, 'type')) || reTest(/^\s*https?:\/\//i, safeAttr(x, 'placeholder')) || reTest(URL_LABEL, namesOf(x))));
      const nameFields = (root) => {
        const urls = urlFields(root);
        return aFilter(textInputs(root), (x) => plainInput(x) && !reTest(/^url$/i, safeAttr(x, 'type')) && !listHas(urls, x)
          && !reTest(NOT_URL_FIELD, namesOf(x)) && reTest(NAME_FIELD, fieldLabel(x)));
      };
      const AUTH_FIELD = /(auth|驗證|認證)/i;
      const OAUTH = /^\s*oauth\s*$/i;
      const OAUTH_WORD = /\boauth\b/i;
      const NOT_OAUTH = /(no auth|none|免驗證|不驗證|無驗證|mixed|混合|api\s*key|bearer)/i;
      const ADVANCED = /(advanced|進階)/i;
      // W183 R9：「按鈕上寫著驗證方式」的下拉（沒標成下拉的按鈕也認；字要正好是一種驗證方式）。
      const AUTH_VALUE = /^(oauth|oauth\s*2(\.0)?|no auth|no authentication|none|mixed|api key|bearer token|免驗證|不驗證|無驗證|混合)$/i;
      const PLUS = /^(\+|＋|create|建立|create app|new app|建立應用程式|新增應用程式|create plugin|new plugin|create connector|new connector|建立外掛|新增外掛)$/i;
      // W183 R9：改版後的「新增 ▾」（字正好是這幾個，可帶 ▾ 之類的箭頭字）與它選單裡的三項（大小寫、空白寬鬆）。
      const NEW_BUTTON = /^(新增|new|add)$/i;
      const CHEVRON_CODES = [0x25be, 0x25bc, 0x2304, 0x02c5, 0x23f7, 0xfe40];
      const noChevrons = (t) => sMapChars(t, (c, ch) => (listHas(CHEVRON_CODES, c) ? null : ch));
      const MENU_ITEMS = bag();
      MENU_ITEMS.plugin = /^(建立\s*外掛程式|建立\s*外掛|create\s*(a\s+)?plugin)$/i;
      MENU_ITEMS.archive = /^(上傳\s*外掛程式\s*封存檔|上傳\s*外掛\s*封存檔|upload\s*(a\s+)?plugin\s*archive)$/i;
      MENU_ITEMS.mcp = /^(建立\s*mcp\s*應用程式|建立\s*mcp\s*應用|create\s*(an\s+)?mcp\s*app(lication)?)$/i;
      const MENU_KEYS = ['plugin', 'archive', 'mcp'];
      // W183 R9：Connection 的分段（Server URL｜Tunnel）與「I understand and want to continue」那一格（中英兩種介面）。
      const SERVER_SEG = /^(server\s*url|伺服器\s*(url|網址|位址)|服務\s*(url|網址))$/i;
      const TUNNEL_SEG = /^(tunnel|通道|隧道)$/i;
      const TUNNEL_TEXT = /(tunnel|通道|隧道)/i;
      const SEG_SELECTOR = 'button, [role="button"], [role="radio"], [role="tab"], input[type="radio"]';
      const RISK_ACK = /(understand.{0,24}continue|了解.{0,12}繼續|瞭解.{0,12}繼續|理解.{0,12}繼續)/i;
      const CREATE = /^(create|建立|save|儲存|create app|建立應用程式)$/i;
      const RECONNECT = /^(connect|reconnect|連線|重新連線|連接|重新連接)$/i;
      const DEV = /(developer mode|開發者模式|開發人員模式)/i;
      const WARNING = /(high[- ]?risk|risk|warning|unverified|not verified|trust|高風險|風險|警告|未經驗證|未驗證|信任)/i;
      // W183 R9：在對話框裡＝整個對話框（勾選框、Create 常在對話框的底部、表單外面）；沒有對話框才用最近的 <form>。
      const formOf = (el) => {
        let form = null;
        for (let p = safeParent(el), i = 0; p && i < 200; p = safeParent(p), i += 1) {
          if (isDialog(p)) return p;
          if (!form && safeTag(p) === 'FORM') form = p;
        }
        return form;
      };
      // 連接器表單：放 MCP 網址欄的那個表單／對話框（只算看得到的；網址欄不在表單裡的不算）。
      const connectorForms = () => {
        const out = [];
        const urls = urlFields(document);
        for (let i = 0; i < urls.length; i += 1) { const f = formOf(urls[i]); if (f) aUniqAdd(out, f); }
        return out;
      };
      // 在選單、清單裡（或自己就是選單項）。
      const inMenu = (el) => {
        for (let p = el, i = 0; p && i < 40; p = safeParent(p), i += 1) {
          if (reTest(/^(menu|menubar|menuitem|menuitemradio|menuitemcheckbox|listbox|option)$/, safeAttr(p, 'role'))) return true;
        }
        return false;
      };
      // W183 R9：表單、對話框裡的鈕不算（新表單 Icon 那一格也是「＋」，按了是選檔）。
      // W183 R9 審查（GPT-6）：選單裡的項目（例如「新增」選單裡的「Create plugin」）、選單鈕也不算舊的「＋」。
      const plusButtons = () => aFilter(visibleOf(document, 'button, [role="button"], a'), (b) => reTest(PLUS, labelOf(b)) && !formOf(b) && !inMenu(b)
        && !reTest(/^(menu|true|listbox)$/i, safeAttr(b, 'aria-haspopup')));
      // W183 R9：改版後的「新增 ▾」：選單鈕（aria-haspopup＝menu／true）、字正好是 新增／New／Add；表單、對話框、選單裡的不算。
      // 目錄裡別的外掛的「新增」鈕不是選單鈕，不會被當成它。
      const newButtons = () => aFilter(visibleOf(document, 'button, [role="button"]'), (b) => reTest(/^(menu|true)$/i, safeAttr(b, 'aria-haspopup'))
        && !formOf(b) && !inMenu(b)
        && (reTest(NEW_BUTTON, safeSquash(noChevrons(safeAttr(b, 'aria-label')))) || reTest(NEW_BUTTON, safeSquash(noChevrons(safeText(b))))));
      const ZERO_WIDTH = [0x200b, 0x200c, 0x200d, 0xfeff];
      const menuLabels = (el) => aFilter(aMap([safeAttr(el, 'aria-label'), safeText(el)],
        (t) => safeSquash(sMapChars(t, (c, ch) => (listHas(ZERO_WIDTH, c) ? null : ch)))), (t) => !!t);
      const menusShown = () => visibleOf(document, '[role="menu"]');
      // W183 R9 審查（GPT-6 #5）：按「新增」之後打開的那一個選單——新增鈕寫了 aria-controls＝只認它指的那一個（看得到、role＝menu、
      // 按之前不在）；沒寫＝按之前不在、按之後才出現的選單。全頁其他地方的同字項目、按之前就開著的選單都不算。
      const openedMenus = (button, before) => {
        const id = safeAttr(button, 'aria-controls');
        if (id) {
          const m = dById(id);
          return m && shown(m) && safeAttr(m, 'role') === 'menu' && !listHas(before, m) ? [m] : [];
        }
        return aFilter(menusShown(), (m) => !listHas(before, m));
      };
      // 那個選單裡的項目（role＝menuitem 類；沒有就看裡面的鈕與連結）。
      const itemsIn = (menu) => {
        const items = visibleOf(menu, '[role="menuitem"], [role="menuitemradio"], [role="menuitemcheckbox"]');
        return items.length ? items : visibleOf(menu, 'button, a, [role="option"]');
      };
      const closeMenu = () => { dDispatch(document, new C_Keyboard('keydown', { key: 'Escape', code: 'Escape', bubbles: true })); };
      // 按「新增」、在它打開的那一個選單裡找剛好一個 key 那一項（寫著另外兩項的一律不算）。結果寫進呼叫端自己的容器 out：
      // out.item／out.menu＝找到了（選單開著）；out.stop＝停下的結果。等的時候被撤銷（世代換了）＝馬上停；醒來之後一律重新讀
      // （不採用 await 帶回來的值）。
      const findNewItem = async (out, button, key, step, live) => {
        out.item = null; out.menu = null; out.stop = null;
        const stop = (r) => { out.stop = r; };
        const want = MENU_ITEMS[key];
        const others = aMap(aFilter(MENU_KEYS, (k) => k !== key), (k) => MENU_ITEMS[k]);
        if (!live()) return stop({ status: 'aborted' });
        // 已經開著的選單（上一次留下的、別的選單）：先關掉；關不掉＝不猜。
        if (menusShown().length) { closeMenu(); await kwait(() => menusShown().length === 0, 1500); }
        if (menusShown().length) return stop({ status: 'ambiguous', step: 'new_menu' });
        if (!live()) return stop({ status: 'aborted' });
        const before = menusShown();
        kpress(button);
        await kwait(() => !live() || openedMenus(button, before).length > 0, 4000);
        if (!live()) { closeMenu(); return stop({ status: 'aborted' }); }
        const menus = openedMenus(button, before);
        if (!menus.length) return stop({ status: 'not_found', step: 'new_menu' });
        if (menus.length !== 1) { closeMenu(); return stop({ status: 'ambiguous', step: 'new_menu' }); }
        await kwait(() => !live() || itemsIn(menus[0]).length > 0, 1500);
        if (!live()) { closeMenu(); return stop({ status: 'aborted' }); }
        const items = itemsIn(menus[0]);
        const hits = aFilter(items, (x) => {
          const t = menuLabels(x);
          return aSome(t, (s) => reTest(want, s)) && !aSome(t, (s) => aSome(others, (r) => reTest(r, s)));
        });
        if (hits.length !== 1) { closeMenu(); return stop({ status: hits.length ? 'ambiguous' : 'not_found', step }); }
        if (!live()) { closeMenu(); return stop({ status: 'aborted' }); }
        out.item = hits[0];
        out.menu = menus[0];
      };
      // 找到就按那一項（out.pressed＝按下去了；out.stop＝停下的結果）。
      const pickNewItem = async (out, button, key, step, live) => {
        out.pressed = false;
        await findNewItem(out, button, key, step, live);
        if (!out.item || out.stop) return;
        if (!live()) { out.stop = { status: 'aborted' }; return; }
        kpress(out.item);
        out.pressed = true;
      };
      const removeHighlights = () => {
        const old = safeAll(document, '[data-tatwo-highlight]');
        for (let i = 0; i < old.length; i += 1) { try { R_apply(M_remove, old[i], []); } catch (e) {} }
      };
      // 標出一個元素（橘框，2 分鐘後自己拿掉；只標、不按）。
      const drawHighlight = (el) => {
        removeHighlights();
        if (!el) return false;
        let r = null;
        try { r = dRect(el); } catch (e) { return false; }
        let box = null;
        try { box = R_apply(M_createElement, document, ['div']); } catch (e) { return false; }
        R_apply(M_setAttr, box, ['data-tatwo-highlight', '1']);
        R_apply(M_setAttr, box, ['style', 'position:fixed;pointer-events:none;z-index:2147483647;border:3px solid #ffb020;border-radius:10px;'
          + 'left:' + (r.left - 6) + 'px;top:' + (r.top - 6) + 'px;width:' + (r.width + 12) + 'px;height:' + (r.height + 12) + 'px']);
        const body = safeBody();
        if (!body) return false;
        R_apply(M_appendChild, body, [box]);
        later(() => { try { R_apply(M_remove, box, []); } catch (e) {} }, 120000);
        return true;
      };
      // W183 R9c（GPT-6 C5）：一個控制項的每一個名字來源各自一段——aria-label、aria-labelledby、<label for>、包著它的 <label>、
      // 自己的字（不是 input 的時候）。不以優先序挑一個（挑了就蓋掉矛盾）。
      const nameSources = (el) => {
        const out = [];
        const aria = safeSquash(safeAttr(el, 'aria-label'));
        if (aria) listAdd(out, aria);
        const by = labelledByText(el);
        if (by) listAdd(out, by);
        const fors = forLabels(el);
        for (let i = 0; i < fors.length; i += 1) { const t = safeSquash(fors[i]); if (t) listAdd(out, t); }
        const p = safeParent(el);
        if (p && safeTag(p) === 'LABEL') { const t = safeSquash(safeText(p)); if (t) listAdd(out, t); }
        if (safeTag(el) !== 'INPUT') { const t = safeSquash(safeText(el)); if (t) listAdd(out, t); }
        return out;
      };
      // W183 R9：Connection 的分段（Server URL｜Tunnel）。R9c：每一個名字來源都要說同一件事（有一個說 Tunnel、一個說 Server URL＝認不出來）。
      const segKind = (el) => {
        const names = nameSources(el);
        if (!names.length) return '';
        if (aEvery(names, (t) => reTest(SERVER_SEG, t))) return 'server';
        if (aEvery(names, (t) => reTest(TUNNEL_SEG, t))) return 'tunnel';
        return aSome(names, (t) => reTest(SERVER_SEG, t) || reTest(TUNNEL_SEG, t)) ? 'conflict' : '';
      };
      const segments = (root) => {
        const all = visibleOf(root, SEG_SELECTOR);
        const out = bag();
        out.server = []; out.tunnel = []; out.conflict = [];
        for (let i = 0; i < all.length; i += 1) {
          const kind = segKind(all[i]);
          if (kind) listAdd(out[kind], all[i]);
        }
        return out;
      };
      // 選了沒：true／false；讀不出來＝null（不猜）。W183 R9 審查（GPT-6 N6；R9c C6）：每一個會參與判斷的來源都完整解析成
      // 選了／沒選／讀不出來——原生 input 的 checked（抓好的取值器）；aria-checked、aria-selected、aria-pressed（true／false，其他值＝讀不出來）；
      // aria-current（page、step、location、date、time、true＝選了；false＝沒選；其他值＝讀不出來）；
      // data-state（on、active、checked、selected＝選了；off、inactive、unchecked＝沒選；open、closed、delayed-open、instant-open 是
      // 彈出框的狀態＝不參與；其他值＝讀不出來）。有任何一個讀不出來、或同時有說選了跟沒選＝null；都沒有＝null。
      const STATE_ATTRS = ['aria-checked', 'aria-selected', 'aria-pressed'];
      const CURRENT_ON = ['page', 'step', 'location', 'date', 'time', 'true'];
      const STATE_ON = ['on', 'active', 'checked', 'selected'];
      const STATE_OFF = ['off', 'inactive', 'unchecked'];
      const STATE_POPUP = ['open', 'closed', 'delayed-open', 'instant-open'];
      const stateOf = (el) => {
        let on = false;
        let off = false;
        let unknown = false;
        if (safeTag(el) === 'INPUT') { if (safeChecked(el)) on = true; else off = true; }
        for (let i = 0; i < STATE_ATTRS.length; i += 1) {
          if (!hasAttr(el, STATE_ATTRS[i])) continue;
          const v = safeAttr(el, STATE_ATTRS[i]);
          if (v === 'true') on = true; else if (v === 'false') off = true; else unknown = true;
        }
        if (hasAttr(el, 'aria-current')) {
          const v = sLower(safeAttr(el, 'aria-current'));
          if (listHas(CURRENT_ON, v)) on = true; else if (v === 'false') off = true; else unknown = true;
        }
        if (hasAttr(el, 'data-state')) {
          const v = sLower(safeAttr(el, 'data-state'));
          if (listHas(STATE_ON, v)) on = true; else if (listHas(STATE_OFF, v)) off = true; else if (!listHas(STATE_POPUP, v)) unknown = true;
        }
        if (unknown || (on && off)) return null;
        return on ? true : (off ? false : null);
      };
      // 'none'＝認得的舊表單（舊的「＋」開的，legacy）沒有分段；'server'＝Server URL 讀得出「選了」、Tunnel 讀得出「沒選」；
      // 'other'＝讀得出 Server URL 沒選（可以按它）；'ambiguous'＝不只一組。
      // W183 R9 審查（GPT-6 #4）：其他一律不能用——新表單沒有分段（'missing'）、只有一邊、讀不出來、矛盾（'unknown'）、只有 Tunnel。
      // 舊表單只在「舊的＋開的、而且整張表單沒有任何 Tunnel／通道字樣」時才算（新表單的分段認不出來＝不當舊表單放行）。
      // R9c：分段的名字來源互相矛盾（aria-label 說 Server URL、看得到的字說 Tunnel）＝'unknown'。
      const connectionState = (root, legacy) => {
        const s = segments(root);
        if (s.conflict.length) return 'unknown';
        if (!s.server.length && !s.tunnel.length) return legacy && !reTest(TUNNEL_TEXT, safeSquash(safeText(root))) ? 'none' : 'missing';
        if (s.server.length > 1 || s.tunnel.length > 1) return 'ambiguous';
        if (!s.server.length) return 'tunnel_only';
        if (!s.tunnel.length) return 'unknown';
        const server = stateOf(s.server[0]);
        const tunnel = stateOf(s.tunnel[0]);
        if (server === true && tunnel === false) return 'server';
        if (server === false && tunnel !== null) return 'other';
        return 'unknown';
      };
      // 沒選 Server URL＝按 Server URL，按完讀回；讀不出來、按了沒變＝'refused'（不用 Tunnel）。結果寫進 out.result。
      const chooseServerURL = async (out, root, legacy, live) => {
        out.result = '';
        const state = connectionState(root, legacy);
        if (state === 'none' || state === 'server') { out.result = 'ok'; return; }
        if (state === 'ambiguous') { out.result = 'ambiguous'; return; }
        if (state !== 'other') { out.result = 'refused'; return; }
        if (!live()) { out.result = 'aborted'; return; }
        kpress(segments(root).server[0]);
        await kwait(() => connectionState(root, legacy) === 'server', 1500);
        out.result = connectionState(root, legacy) === 'server' ? 'ok' : 'refused';
      };
      // 表單：放網址欄的那一個；新表單預設 Tunnel 時還沒有網址欄＝放 Server URL／Tunnel 分段的那一個。
      const newForms = () => {
        const out = connectorForms();
        const segs = visibleOf(document, SEG_SELECTOR);
        for (let i = 0; i < segs.length; i += 1) {
          if (!segKind(segs[i])) continue;
          const f = formOf(segs[i]);
          if (f) aUniqAdd(out, f);
        }
        return out;
      };
      const radioLabel = (r) => safeSquash(fieldLabel(r) + ' ' + labelOf(r) + ' ' + (safeParent(r) ? labelOf(safeParent(r)) : ''));
      // W183 R9 審查（GPT-6 #1）：一個值來源正規化（底線、連字號當空白）；「OAuth API key」「api_key」都不是 OAuth。
      const normAuth = (t) => safeSquash(sMapChars(t, (c, ch) => (c === 95 || c === 45 ? ' ' : ch)));
      // W183 R9 審查（GPT-6 N5）：已知的 OAuth 值（正規化、小寫之後正好是其中一個）；正面表列——其他的（basic、api key、空的、認不得的）一律不是。
      const OAUTH_VALUES = ['oauth', 'oauth2', 'oauth 2', 'oauth2.0', 'oauth 2.0'];
      const isOAuthValue = (v) => listHas(OAUTH_VALUES, sLower(normAuth(v)));
      // 同一組單選（同 name 的 input、或同一個 radiogroup 裡的）。
      const radioGroup = (r, root) => {
        const name = safeAttr(r, 'name');
        if (name) return aFilter(visibleOf(root, 'input[type="radio"]'), (x) => safeAttr(x, 'name') === name);
        for (let p = safeParent(r), i = 0; p && i < 4; p = safeParent(p), i += 1) {
          if (safeAttr(p, 'role') === 'radiogroup') return visibleOf(p, '[role="radio"], input[type="radio"]');
        }
        return [r];
      };
      // 下拉鈕上的字（去掉 ▾ 之類的箭頭字）。
      const comboText = (b) => safeSquash(noChevrons(safeText(b)));
      const authControls = (root) => {
        const out = bag();
        out.selects = aFilter(visibleOf(root, 'select'), (s) => !reTest(ADVANCED, fieldLabel(s))
          && (reTest(AUTH_FIELD, fieldLabel(s)) || aSome(safeAll(s, 'option'), (o) => reTest(OAUTH, safeText(o)))));
        out.radios = aFilter(visibleOf(root, 'input[type="radio"], [role="radio"]'), (r) => reTest(OAUTH_WORD, radioLabel(r)) && !reTest(NOT_OAUTH, radioLabel(r))
          && !reTest(ADVANCED, radioLabel(r)));
        // W183 R9：下拉（combobox、選單鈕）：字不長（「Advanced OAuth settings …」那一格不算）、開對話框的不算；
        // 沒標成下拉的按鈕：按鈕上的字正好是一種驗證方式、欄位名稱寫著驗證（新表單「按鈕上寫 OAuth」的下拉）。
        out.combos = aFilter(visibleOf(root, '[role="combobox"], button'), (b) => {
          const popup = safeAttr(b, 'aria-haspopup');
          if (reTest(/^dialog$/i, popup)) return false;
          const value = safeTag(b) === 'INPUT' ? safeSquash(dValue(b)) : comboText(b);
          // W183 R9 審查（GPT-6）：「Advanced OAuth settings」那一格不是驗證方式。
          if (reTest(ADVANCED, fieldLabel(b) + ' ' + labelOf(b) + ' ' + value)) return false;
          if (safeAttr(b, 'role') === 'combobox' || popup) {
            const whole = fieldLabel(b) + ' ' + labelOf(b) + ' ' + value;
            return value.length <= 40 && (reTest(AUTH_FIELD, whole) || reTest(OAUTH_WORD, whole) || reTest(NOT_OAUTH, whole));
          }
          return reTest(AUTH_VALUE, value) && reTest(AUTH_FIELD, fieldLabel(b));
        });
        return out;
      };
      // W183 R9 審查（GPT-6 #1；R9c C5）：下拉現在選的值——照控制項種類列出有效值來源，各自正規化、各自看：
      // 輸入框式（<input role=combobox>）＝即時的值（抓好的 value 取值器；一定要有）＋寫了的 aria-valuetext、value 屬性、data-value；
      // 按鈕式＝按鈕上看得到的字（一定要有）＋寫了的 aria-valuetext、value 屬性、data-value。
      const comboValues = (b) => {
        const out = [];
        const main = safeTag(b) === 'INPUT' ? normAuth(dValue(b)) : normAuth(comboText(b));
        if (!main) return out;
        listAdd(out, main);
        const extra = [safeAttr(b, 'aria-valuetext'), safeAttr(b, 'value'), safeAttr(b, 'data-value')];
        for (let i = 0; i < extra.length; i += 1) { const v = normAuth(extra[i]); if (v) listAdd(out, v); }
        return out;
      };
      // 選 OAuth（結果寫進 out.result：ok、not_found、ambiguous、aborted）；按完一律由呼叫端讀回 authState。
      const chooseOAuth = async (out, root, live) => {
        out.result = '';
        if (authState(root) === 'oauth') { out.result = 'ok'; return; }   // W183 R9：已經是 OAuth（新表單預設）：不碰
        const c = authControls(root);
        const kinds = c.selects.length + (c.radios.length ? 1 : 0) + c.combos.length;
        if (!kinds) { out.result = 'not_found'; return; }
        if (kinds > 1 || c.radios.length > 1) { out.result = 'ambiguous'; return; }
        if (!live()) { out.result = 'aborted'; return; }
        if (c.selects.length) {
          const options = aFilter(safeAll(c.selects[0], 'option'), (o) => isOAuthValue(safeText(o)));
          if (options.length !== 1) { out.result = options.length ? 'ambiguous' : 'not_found'; return; }
          ksetValue(c.selects[0], dValue(options[0]));
          out.result = 'ok';
          return;
        }
        if (c.radios.length) { kpress(c.radios[0]); await ksleep(150); out.result = 'ok'; return; }
        kpress(c.combos[0]);
        const pickable = () => aFilter(visibleOf(document, '[role="option"], [role="menuitemradio"], [role="menuitem"]'), (x) => reTest(OAUTH, labelOf(x)));
        await kwait(() => pickable().length > 0, 3000);
        const picked = pickable();
        if (!picked.length) { out.result = 'not_found'; return; }
        if (picked.length > 1) { out.result = 'ambiguous'; return; }
        if (!live()) { out.result = 'aborted'; return; }
        kpress(picked[0]);
        await ksleep(200);
        out.result = 'ok';
      };
      // W183 R9 審查（GPT-6 #1、N5；R9c C5）：只認「剛好一個」驗證方式控制項（下拉、單選、選單鈕加起來；Advanced OAuth settings 那一格不算）；
      // 不只一個＝unknown（不挑一個相信）。每一種控制項都正面驗證（已知的 OAuth 值），有一個來源不是、選中的不只一個、狀態讀不出來或矛盾＝不是 OAuth。
      const authState = (root) => {
        const c = authControls(root);
        const kinds = c.selects.length + (c.radios.length ? 1 : 0) + c.combos.length;
        if (kinds !== 1) return 'unknown';
        if (c.selects.length) {
          // 下拉：value 對得上的那一項剛好一個、標成選了的不超過一個且就是它；那一項的字與 value 都是 OAuth；
          // 寫了的 option label、下拉的 aria-valuetext、data-value、option 的 aria-valuetext 也都是。
          const s = c.selects[0];
          const options = safeAll(s, 'option');
          const value = dValue(s);
          const byValue = aFilter(options, (x) => dValue(x) === value);
          const marked = aFilter(options, dSelected);
          if (byValue.length !== 1 || marked.length > 1 || (marked.length === 1 && marked[0] !== byValue[0])) return 'other';
          const o = byValue[0];
          if (!isOAuthValue(safeText(o)) || !isOAuthValue(dValue(o))) return 'other';
          const extra = aFilter([safeAttr(o, 'label'), safeAttr(s, 'aria-valuetext'), safeAttr(s, 'data-value'), safeAttr(o, 'aria-valuetext')], (t) => !!t);
          return aEvery(extra, isOAuthValue) ? 'oauth' : 'other';
        }
        if (c.radios.length) {
          if (c.radios.length !== 1) return 'unknown';
          const r = c.radios[0];
          // 單選：每一個名字來源（看得到的 label、aria-label、aria-labelledby）都要正好是 OAuth；寫了的 value、aria-valuetext、data-value 也要是。
          const names = nameSources(r);
          if (!names.length || !aEvery(names, isOAuthValue)) return 'other';
          if (!aEvery(aFilter([safeAttr(r, 'value'), safeAttr(r, 'aria-valuetext'), safeAttr(r, 'data-value')], (t) => !!t), isOAuthValue)) return 'other';
          if (stateOf(r) !== true) return 'other';
          // 同一組的其他每一個都要讀得出「沒選」（也選著、讀不出來、矛盾＝不是 OAuth）。
          return aEvery(aFilter(radioGroup(r, root), (x) => x !== r), (x) => stateOf(x) === false) ? 'oauth' : 'other';
        }
        const b = c.combos[0];
        if (reTest(NOT_OAUTH, normAuth(safeAttr(b, 'aria-label')))) return 'other';
        const values = comboValues(b);
        return values.length > 0 && aEvery(values, isOAuthValue) ? 'oauth' : 'other';
      };
      // 連接器指令的世代（見上面）。
      let connectorGen = 0;
      const connectorStep = () => { connectorGen += 1; const mine = connectorGen; return () => mine === connectorGen; };
      // W183 R9 審查（GPT-6 #8）：原生「新增 ▾」的世代：新的一次、或 App 送 pluginNewMenuAbort（分頁關掉、私訊框收起來、逾時）＝舊的在下一個按之前停手。
      let menuGen = 0;
      const menuStep = () => { menuGen += 1; const mine = menuGen; return () => mine === menuGen; };
      // 原生發的一次性操作序號：用過就不再收（重放＝拒絕）；打開了的那一次記著它打開的對話框（或選單），App 問「還開著嗎」只看這一個。
      // W183 R9 審查（GPT-6 N1）：null 原型的容器（網頁改 Set／Map 的方法拿不到、改不了）。
      const usedOps = bag();
      let menuOps = bag();
      let currentOp = '';
      const ABORTED = { status: 'aborted' };
      const UNSAFE = { status: 'refused', reason: 'unsafe_env' };
      // 警語文字的指紋（不是秘密：只用來確認使用者看過的就是現在這一段）。只用抓好的 charCodeAt／imul，十六進位自己轉。
      const HEX = '0123456789abcdef';
      const textDigest = (t) => {
        const s = sOf(t);
        let h = 0x811c9dc5;
        for (let i = 0; i < s.length; i += 1) { h ^= sCode(s, i); h = R_apply(M_imul, null, [h, 0x01000193]) >>> 0; }
        let hex = '';
        for (let k = 7; k >= 0; k -= 1) hex += HEX[(h >>> (k * 4)) & 15];
        return hex + '-' + Str(s.length);
      };
      const markOK = (v) => reTest(/^f[a-z0-9]{6,20}$/, sOf(v));
      // 指令參數只讀自己的屬性（沒有＝沒有，不去原型上找網頁塞的 ack）。
      const ackOf = (c) => {
        const a = own(c, 'ack');
        const form = own(a, 'form');
        const warning = own(a, 'warning');
        return markOK(form) && typeof warning === 'string' && warning.length <= 40 ? { form: Str(form), warning } : null;
      };
      // W183 R9 審查（GPT-6 #2、N1–N4；R9c C3、C4）：TATWO 自己開的表單（建立）、讀回的詳情區（重新連線）記在這個閉包裡（null 原型的容器）。
      // - 身分看節點本身（同一個對話框、同一個 Name／網址欄、這一輪交給使用者勾的那幾格；=== 比對、還掛在頁面上）、Name／網址欄與
      //   每一個確認框實際所屬的 <form>、登記時的頁面路徑與操作世代（只有 connectorAbort 換）；不看網頁上的屬性。
      // - 記號只是給 App 帶回來的編號：每交回一次換一個、開新的一輪（上一輪的確認與勾選都不算）；按了 Create／連線就用掉（再帶一次＝拒絕）。
      // - 永久作廢：取消（connectorAbort）、離開登記時那一頁（任何一次路徑變了：同文件導頁 pushState／replaceState、上一頁、Navigation API、
      //   原生觀察到的導頁；之後回來也不算）、登記的節點被拆下來過（MutationObserver；拆了再掛回去也算）、表單歸屬變了（換了內層 <form>、
      //   form 屬性、外面那張 form 的 id 變了）。頁面換一份＝閉包重來、全部作廢。
      const ownForms = bag();     // 記號 → 紀錄
      const spentMarks = bag();   // 記號 → 'used'｜'stale'｜'aborted'｜'left'｜'detached'
      const voidForms = bag();    // 節點被拆下來或表單歸屬變了而作廢的紀錄（記號 → 紀錄；分辨「表單被換掉」）
      let connectorEpoch = 0;
      const attached = (el) => !!el && safeContains(safeBody(), el) && shown(el);
      // 記號：遞增的序號＋一段亂數（序號保證不重複；亂數只是讓它不好猜）。
      let markSeq = 0;
      const newMark = () => {
        markSeq += 1;
        let digits = '';
        try {
          const r = Str(R_apply(M_random, null, []));
          for (let i = 2; i < r.length && digits.length < 8; i += 1) { const c = sCode(r, i); if (c >= 48 && c <= 57) digits += r[i]; }
        } catch (e) {}
        while (digits.length < 8) digits += '0';
        return 'f' + Str(markSeq) + 'x' + digits;
      };
      // 看得到的勾選框。
      const boxesIn = (root) => visibleOf(root, 'input[type="checkbox"], [role="checkbox"]');
      const isChecked = (b) => safeChecked(b);
      const formAround = (el) => {
        for (let p = safeParent(el), i = 0; p && i < 200; p = safeParent(p), i += 1) if (safeTag(p) === 'FORM') return p;
        return null;
      };
      // 實際屬於哪一個 <form>（瀏覽器的 form 取值器，含 form 屬性指定的）；不是表單欄位（例如 div 的 role=checkbox）才看上層。
      const formOwner = (el) => {
        const tag = safeTag(el);
        const g = tag === 'INPUT' ? G_inForm : tag === 'TEXTAREA' ? G_taForm : tag === 'SELECT' ? G_selForm : tag === 'BUTTON' ? G_btnForm : null;
        if (g) { try { return pget(g, el) || null; } catch (e) { return null; } }
        return formAround(el);
      };
      // Name／網址欄、這一輪每一個確認框的表單歸屬都跟記下的一樣（R9c C4）。
      const ownersIntact = (rec) => {
        if (rec.name && formOwner(rec.name) !== rec.nameForm) return false;
        if (rec.url && formOwner(rec.url) !== rec.urlForm) return false;
        for (let i = 0; i < rec.zones.length; i += 1) if (formOwner(rec.zones[i].box) !== rec.zones[i].form) return false;
        return true;
      };
      // 一筆紀錄在意的節點（被拆下來＝作廢）。
      const trackedNodes = (rec) => {
        const out = [];
        if (rec.root) listAdd(out, rec.root);
        if (rec.name) listAdd(out, rec.name);
        if (rec.url) listAdd(out, rec.url);
        for (let i = 0; i < rec.zones.length; i += 1) {
          listAdd(out, rec.zones[i].box);
          for (let j = 0; j < rec.zones[i].labels.length; j += 1) listAdd(out, rec.zones[i].labels[j].node);
        }
        return out;
      };
      const markOf = (rec) => { for (const mark in ownForms) if (ownForms[mark] === rec) return mark; return ''; };
      const voidRecord = (mark, why) => {
        const rec = mark ? ownForms[mark] : null;
        if (!rec) return;
        rec.void = why;
        if (rec.observer) { try { R_apply(M_moDisconnect, rec.observer, []); } catch (e) {} }
        rec.observer = null;
        spentMarks[mark] = why;
        if (why === 'detached') voidForms[mark] = rec;
        delete ownForms[mark];
      };
      // R9c（GPT-6 C3）：任何一次看到的路徑（同文件導頁、上一頁、Navigation API、原生回報的導頁）跟登記時不一樣＝那筆紀錄永久作廢
      // （之後又回到原來的路徑也不算）。
      const pathSeen = (path, source = 'other', navigationType = 'none') => {
        if (nativeResetWatch) {
          if (sOf(path) === '/') nativeResetWatch.rootReached = true;
          else if (nativeResetWatch.rootReached || sOf(path) !== nativeResetWatch.path) nativeResetWatch.invalid = true;
        }
        if (newChatPath !== sOf(path)) { newChatPath = sOf(path); newChatEpoch += 1; }
        if (personalizedProof) proofPageOK(personalizedProof, sOf(path), source, navigationType);
        const p = sOf(path);
        for (const mark in ownForms) { const r = ownForms[mark]; if (r && r.path !== p) voidRecord(mark, 'left'); }
      };
      const pathNow = (source, navigationType = 'none') => pathSeen(location.pathname, source, navigationType);
      // 同文件導頁：History 的 pushState／replaceState 包一層（這個腳本比網頁早跑，網頁拿到的就是包過的）；包裡用抓好的原版。
      try {
        const HP = window.History && window.History.prototype;
        if (HP && H_push && H_replace) {
          const wrap = (original, source) => function (...args) { const out = R_apply(original, this, args); pathNow(source); return out; };
          O_define(HP, 'pushState', { value: wrap(H_push, 'history_push'), writable: true, configurable: true, enumerable: true });
          O_define(HP, 'replaceState', { value: wrap(H_replace, 'history_replace'), writable: true, configurable: true, enumerable: true });
        }
      } catch (e) {}
      // 上一頁／下一頁，與 Navigation API（網頁用別的方式換了同一份文件的網址也會發）。
      try { R_apply(M_addEvt, window, ['popstate', () => pathNow('popstate'), true]); } catch (e) {}
      try { if (NAV) R_apply(M_addEvt, NAV, ['currententrychange', (event) => {
        let type = 'unknown';
        try {
          const value = pget(G_navChangeType, event);
          if (value === 'push' || value === 'replace' || value === 'traverse' || value === 'reload') type = value;
        } catch (e) {}
        pathNow('currententrychange', type);
      }]); } catch (e) {}
      // 拆下來的節點（或它的上層）是這筆紀錄在意的＝作廢；for／id 動到這一輪那幾格的關聯＝這一輪作廢；表單歸屬變了＝作廢。
      const onMutations = (rec, records) => {
        if (rec.void) return;
        // 同一份網頁裡換了路徑（單頁應用換頁）＝離開了登記時那一頁。
        if (sOf(location.pathname) !== rec.path) { voidRecord(markOf(rec), 'left'); return; }
        const count = records ? records.length : 0;
        for (let i = 0; i < count; i += 1) {
          const r = records[i];
          const type = pget(G_mrType, r);
          if (type === 'childList') {
            const removed = nodeList(pget(G_mrRemoved, r));
            const nodes = trackedNodes(rec);
            for (let j = 0; j < removed.length; j += 1) {
              const node = removed[j];
              for (let k = 0; node && k < nodes.length; k += 1) {
                if (node === nodes[k] || safeContains(node, nodes[k])) { voidRecord(markOf(rec), 'detached'); return; }
              }
            }
          } else if (type === 'attributes') {
            const target = pget(G_mrTarget, r);
            const name = pget(G_mrAttr, r);
            if (name !== 'for' && name !== 'id' && name !== 'form') continue;
            // Name／網址欄、這一輪的確認框的 form 屬性動過＝換了（或想換）所屬的表單：永久作廢（就算最後的歸屬剛好一樣）。
            if (name === 'form' && target && (target === rec.name || target === rec.url || aSome(rec.zones, (z) => z.box === target))) {
              voidRecord(markOf(rec), 'detached');
              return;
            }
            const old = pget(G_mrOld, r);
            for (let j = 0; j < rec.zones.length; j += 1) {
              const zone = rec.zones[j];
              if (name === 'id' && target === zone.box) rec.roundVoid = true;
              if (name === 'for' && zone.id && (old === zone.id || safeAttr(target, 'for') === zone.id)) rec.roundVoid = true;
              // 這一輪記下的 label 自己的 for 動過（包著它的被加上 for 指別處也算）。
              for (let k = 0; name === 'for' && k < zone.labels.length; k += 1) if (zone.labels[k].node === target) rec.roundVoid = true;
            }
          }
        }
        // 表單歸屬（Name、網址欄、每一個確認框）：form 屬性、外面那張 form 的 id、插進一張同 id 的 form 都會讓它變。
        if (!ownersIntact(rec)) voidRecord(markOf(rec), 'detached');
      };
      // 看整份文件（連 body 被換掉都看得到）：子節點增刪與所有屬性（只處理 for／id／form）。不給 attributeFilter
      // （它要經過網頁改得到的陣列疊代），在回呼裡自己挑。
      const watchRecord = (rec) => {
        try {
          const observer = new MO((records) => onMutations(rec, records));
          R_apply(M_moObserve, observer, [document, { childList: true, subtree: true, attributes: true, attributeOldValue: true }]);
          rec.observer = observer;
        } catch (e) {}
      };
      // 找這個節點的紀錄（還有效的：同一個操作世代、還在登記時那一頁；不是＝永久作廢）。
      const recordOf = (root) => {
        const path = sOf(location.pathname);
        for (const mark in ownForms) {
          const rec = ownForms[mark];
          if (!rec) continue;
          if (rec.epoch !== connectorEpoch) { voidRecord(mark, 'aborted'); continue; }
          if (rec.path !== path) { voidRecord(mark, 'left'); continue; }
          if (rec.root === root) return { mark, rec };
        }
        return null;
      };
      const register = (root, legacy, expectedName, reconnect) => {
        for (const mark in ownForms) { const r = ownForms[mark]; if (!r || !attached(r.root)) voidRecord(mark, 'detached'); }
        const mark = newMark();
        const rec = bag();
        rec.root = root; rec.legacy = legacy === true; rec.expectedName = sOf(expectedName); rec.reconnect = reconnect === true;
        rec.filled = false; rec.name = null; rec.url = null; rec.nameForm = null; rec.urlForm = null;
        rec.epoch = connectorEpoch; rec.path = sOf(location.pathname);
        rec.round = 0; rec.zones = []; rec.roundVoid = false; rec.proof = weakNew(); rec.seq = weakNew(); rec.void = ''; rec.observer = null;
        ownForms[mark] = rec;
        watchRecord(rec);
        return { mark, rec };
      };
      // 按了會勾到這一格的地方：這一格本身、包著它的 <label>、<label for> 指著它的字（按旁邊的說明文字不算）。
      const labelsOf = (box) => {
        const out = [];
        const id = safeAttr(box, 'id');
        const seen = [];
        // 包著它的 <label>（沒有 for 而且它是裡面第一個欄位、或 for 指著它；for 指著別的＝它標的是別的欄位）。
        for (let p = safeParent(box), i = 0; p && i < 16; p = safeParent(p), i += 1) {
          if (safeTag(p) !== 'LABEL') continue;
          const f = safeAttr(p, 'for');
          if (f ? f === id : labelsControl(p, box)) { listAdd(out, { node: p, viaFor: false }); listAdd(seen, p); }
        }
        if (id) {
          const labels = safeAll(document, 'label');
          for (let i = 0; i < labels.length; i += 1) {
            if (safeTag(labels[i]) === 'LABEL' && safeAttr(labels[i], 'for') === id && !listHas(seen, labels[i])) listAdd(out, { node: labels[i], viaFor: true });
          }
        }
        return out;
      };
      // W183 R9 審查（GPT-6 N2、N3；R9c C4）：交回給使用者＝開新的一輪。這一輪要人確認的＝這張表單上看得到的每一個勾選框（勾著的也算）；
      // 記下每一格當時的 label 關聯、id、上一層、實際所屬的 form。
      const roundOpen = (rec) => {
        rec.round += 1;
        rec.roundVoid = false;
        rec.consent = '';   // W183 R10 第三輪：代勾綁住的同意內容只屬於那一輪（交回使用者＝他自己看、自己勾）
        const zones = [];
        const all = boxesIn(rec.root);
        for (let i = 0; i < all.length; i += 1) {
          const box = all[i];
          listAdd(zones, { box, id: safeAttr(box, 'id'), parent: safeParent(box), labels: labelsOf(box), form: formOwner(box) });
        }
        rec.zones = zones;
      };
      // 這一輪的關聯與結構還是當時那樣（每一格還在、上一層沒換、id 沒換、label 還是那幾個）；變了＝這一輪作廢（再交給使用者）。
      const roundIntact = (rec) => {
        if (rec.roundVoid || !(rec.round >= 1)) return false;
        const present = boxesIn(rec.root);
        if (present.length !== rec.zones.length) return false;
        for (let i = 0; i < rec.zones.length; i += 1) {
          const zone = rec.zones[i];
          if (!listHas(present, zone.box) || safeParent(zone.box) !== zone.parent || safeAttr(zone.box, 'id') !== zone.id) return false;
          const labels = labelsOf(zone.box);
          if (labels.length !== zone.labels.length) return false;
          for (let j = 0; j < labels.length; j += 1) if (labels[j].node !== zone.labels[j].node) return false;
        }
        return true;
      };
      // W183 R9 審查（GPT-6 #2）：交回給使用者＝換一個新記號（上一次的確認作廢：一次交回只收一次「繼續」）。
      const rekey = (own) => {
        own.rec.armed = null;   // W183 R10 第二輪：交回給使用者＝之前的 armed 作廢
        spentMarks[own.mark] = 'stale';
        delete ownForms[own.mark];
        const mark = newMark();
        ownForms[mark] = own.rec;
        own.mark = mark;
        return mark;
      };
      const handBack = (own, reason, digest) => { roundOpen(own.rec); return { status: 'needs_user', reason, form: rekey(own), warning: digest }; };
      // 按下去之前用掉（這一張的紀錄拿掉：同一張表單不會再被按第二次）。
      const consume = (own) => { voidRecord(own.mark, 'used'); };
      // W183 R10 第二輪（GPT-6 1；主導裁決「記下 Create 送出的那一刻」）：按 Create／重新連線分兩步。指令核對完不按，交回 armed＋新的一次性記號
      //（帶來的確認同時用掉：再帶一次＝ack_replayed）；App 先記下「送出按」的那一刻（主框架的導頁世代與網址＝來源證據的錨點），才送
      // connectorPress——再核一次（同一張表單、同一顆鈕、還能按、警語指紋與勾選證據照舊成立），用掉記號才按。之前任何時候出現的配對頁都不算。
      const armPress = (owned, button, kind, check) => {
        const token = newMark();
        spentMarks[owned.mark] = 'used';
        delete ownForms[owned.mark];
        ownForms[token] = owned.rec;
        owned.mark = token;
        const a = bag();
        a.button = button; a.kind = kind;
        a.desc = describeEl(button);   // W183 R12：arm 那一刻那一顆長什麼樣（press_stale 時跟現在的按鈕清單一起進結構快照）
        a.check = () => {
          staleWhy = '';
          if (check()) return true;
          noteStale('check:' + (staleWhy || '?'), owned.rec, a);
          return false;
        };
        owned.rec.armed = a;
        return { status: 'armed', form: token };
      };
      // 帶回來的確認的狀態：''＝可以用；'used'／'stale'／'aborted'／'left'＝用過、過期、取消、離開了；'detached'＝節點被拆下來或表單歸屬變了。
      const ackState = (ack) => (ack ? (spentMarks[ack.form] || '') : '');
      // 勾選框那一列：往上找只放著這一格（沒有別的欄位、按鈕）的最大那一格（最多 4 層，不跨出表單、對話框）。
      const tickZone = (box) => {
        let zone = box;
        for (let p = safeParent(box), i = 0; p && i < 4; p = safeParent(p), i += 1) {
          if (isDialog(p) || safeTag(p) === 'FORM' || controlCount(p) !== 1) break;
          zone = p;
        }
        return zone;
      };
      const ownText = dOwnText;
      const leaves = (root) => aFilter(safeAll(root, '*'), (el) => dKids(el).length === 0);
      // W183 R9：勾選框那一格的字（欄位名稱＋它自己那一列）：看是不是「I understand and want to continue」。
      // W183 R9 審查（Claude #10）：只看它自己那一列（tickZone）——以前往上兩層會讀到整個對話框，別的勾選框也被當成風險那一格。
      const boxText = (b) => safeSquash(fieldLabel(b) + ' ' + labelOf(b) + ' ' + safeText(tickZone(b)));
      // W183 R9 審查（GPT-6 #7、N9；R9c C8）：警語的範圍不再往上找「碰到欄位、按鈕就停」的那一段（碰到控制項不是可信的邊界：
      // 同一個警語容器裡可能有 Learn more 按鈕、勾選框、展開鈕，停在那裡就會漏掉容器裡其他沒有警語字的條款）。
      // 明確的容器規則：這一張表單／這一個詳情區（登記時的那一個節點）整個就是範圍——指紋收它全部的字（按鈕、連結、說明、條款都在內；
      // 欄位的值不算字）；超過 4000 字＝看不出使用者看完了沒＝warning_unbounded（不自動按，App 請使用者改用手動），不靜默只取一段。
      const WARNING_LIMIT = 4000;
      // 要使用者自己看的：沒勾的勾選框（腳本一律不勾；W183 R10 的代勾只經 tickFor 量位置、由 App 原生點擊）、警語文字（只有使用者看過的就是這一整張的字，才算看過）。
      // - 勾著的每一格都要在這一輪由使用者自己按到「從沒勾變成勾」（網頁自己勾的、上一輪勾的、交回之前勾的都不算）；
      //   這一輪的關聯被動過（label 的 for、id、結構）＝這一輪作廢：untrusted_tick，再交給使用者。
      const warningsIn = (root, ackDigest, rec) => {
        const all = boxesIn(root);
        const unchecked = aFilter(all, (b) => !isChecked(b));
        const whole = safeSquash(safeText(root));
        const flagged = reTest(WARNING, whole) || all.length > 0;
        if (flagged && whole.length > WARNING_LIMIT) return { reason: 'warning_unbounded', digest: '' };
        const digest = flagged ? textDigest(whole) : '';
        // W183 R9：沒勾的全是「I understand and want to continue」那一格（中英兩種介面）＝risk_ack（卡片講清楚要勾哪一格）；腳本照樣不勾（R10：connectorCreate 再經 tickFor 決定能不能讓 App 原生代勾）。
        if (unchecked.length) return { reason: aEvery(unchecked, (b) => reTest(RISK_ACK, boxText(b))) ? 'risk_ack' : 'checkbox', digest };
        // 警語變了（或還沒看過）先交回（卡片說：再看一次、勾選框在這一輪自己再勾一次）；沒變才看勾選是不是這一輪使用者自己按的。
        if (flagged && digest !== ackDigest) return { reason: 'warning', digest };
        if (rec && all.length) {
          if (!roundIntact(rec)) return { reason: 'untrusted_tick', digest };
          if (!aEvery(all, (b) => weakGet(rec.proof, b) === rec.round)) return { reason: 'untrusted_tick', digest };
        }
        return null;
      };
      // W183 R10（使用者 09-29「就要給他用了還要多一個勾選」；裁決：按［連線］＝同意，「I understand」由 TATWO 代勾，只限 TATWO 自己開的那一頁）：
      // 這裡只**量**那一格在畫面上的位置交給 App（needs_user＋tick），由 App 走 CEF 的「節點驗證點擊」點下去（App 先用畫面快照找到同一個位置的
      // 那一個控制項；CEF 送出之前再核一次：那一點最上面還是它、沒被蓋、位置沒變、同一份文件）——網頁看到的是 isTrusted；腳本從不改
      // checked、不派送假的點擊。只認這一格：這一輪（handBack 開的）記下的唯一那一格、它那一列的字是 RISK_ACK、表單上沒有別的勾選框、
      // 整張表單的字對得上核實過的版本（consentVersion）。任何一個不成立＝照舊交給使用者（checkbox／warning_changed；卡片一句話說原因）。
      // 那一下落沒落在那一格，照舊由 noteTrusted 判（R9 的證據鏈、一次性記號、表單換了就重來全部原封不動，只是按的人換成 TATWO）。
      // W183 R10 第二輪（GPT-6 3；主導裁決）：認得的同意內容改成**版本化的完整文字白名單**——整張表單看得到的字照文件順序（每一段壓空白、
      // 只有符號的圖示字不算），連結照順序、目的地只收 OpenAI 的網域；整段一字不差才代勾。英文照 09-29 實機截圖；中文沒有核實過＝沒有
      //（中文介面一律交給使用者勾）。不再用關鍵字或詞集合相似度：多一句、少一句、換順序、連結換網站都算不認得，交給使用者。
      const CONSENT_LINK_ORIGINS = ['https://help.openai.com', 'https://platform.openai.com', 'https://developers.openai.com', 'https://openai.com',
        'https://chatgpt.com'];
      // W183 R12（.037 實機）：en-2026-09-30-risk＝只比對風險說明那一段（area：改名、錯誤提示出現之後照樣認得）。
      const CONSENT_VERSIONS = [
        { id: 'en-2026-09-29',
          text: 'New Plugin Icon (optional) PNG only. Best results at 256 x 256 px or larger. Max file size: 10 KB Name Description (optional) '
            + 'Connection Server URL Tunnel Authentication OAuth Advanced OAuth settings Review discovered OAuth settings, or enter them manually, '
            + 'then choose a client setup method and configure default scopes Custom MCP servers introduce risk. Learn more '
            + 'I understand and want to continue Only connect to MCP servers you trust. An untrusted server may access or steal information shared '
            + 'through app use, or trick ChatGPT into using tools in unintended ways, including changing or deleting data. Read the guide Cancel Create',
          links: ['Learn more', 'Read the guide'] },
        { id: 'en-2026-09-30-risk', area: true,
          text: 'Custom MCP servers introduce risk. Learn more I understand and want to continue Only connect to MCP servers you trust. '
            + 'An untrusted server may access or steal information shared through app use, or trick ChatGPT into using tools in unintended ways, '
            + 'including changing or deleting data.',
          links: ['Learn more'] },
      ];
      // W183 R12（主導 3：「ChatGPT 改了說明文字：在 TATWO 的卡片上直接顯示讀到的新說明全文，配一顆［同意並繼續］」）：使用者在 TATWO 卡片上
      // 看過、按了同意的那一份（App 帶回來的 print；整份一字不差才算認得）。只在 App 的指令帶來時換（同一次操作世代裡留著），connectorAbort 清掉。
      let approvedConsent = '';
      // 字母或數字（拉丁、希臘、西里爾字母與中日韓字）：只有符號的一段（圖示的「＋」「×」）不算字。
      const WORD_CHAR = /[A-Za-z0-9À-ÖØ-öø-ɏͰ-ϿЀ-ӿ぀-ヿ㐀-鿿가-힯豈-﫿]/;
      const hiddenForText = (el) => {
        if (dHidden(el)) return true;
        const display = dStyle(el, 'display');
        const visibility = dStyle(el, 'visibility');
        return display === 'none' || visibility === 'hidden' || visibility === 'collapse';
      };
      // 整張表單看得到的字（照文件順序一段一段；欄位裡的值、藏起來的、只有符號的不算）與看得到的連結（字、href），照順序。
      // aria-hidden 不跳過（看得到的字就要核對）。
      const consentScan = (root) => {
        const out = bag();
        out.chunks = [];
        out.links = [];
        out.deep = false;
        const walk = (node, depth) => {
          if (depth > 80) { out.deep = true; return; }
          const type = dNodeType(node);
          if (type === 3) {
            let v = '';
            try { v = sOf(pget(G_nodeValue, node)); } catch (e) {}
            const piece = safeSquash(v);
            if (piece && reTest(WORD_CHAR, piece)) listAdd(out.chunks, piece);
            return;
          }
          if (type !== 1) return;
          const tag = safeTag(node);
          if (reTest(/^(SCRIPT|STYLE|TEMPLATE|NOSCRIPT|INPUT|TEXTAREA|SELECT|OPTION)$/, tag) || hiddenForText(node)) return;
          if (tag === 'A' && hasAttr(node, 'href')) {
            const link = bag();
            link.text = safeSquash(safeText(node));
            link.href = safeAttr(node, 'href');
            listAdd(out.links, link);
          }
          let kids = [];
          try { kids = nodeList(pget(G_childNodes, node)); } catch (e) { return; }
          for (let i = 0; i < kids.length; i += 1) walk(kids[i], depth + 1);
        };
        walk(root, 0);
        let text = '';
        for (let i = 0; i < out.chunks.length; i += 1) text += (i ? ' ' : '') + out.chunks[i];
        out.text = text;
        return out;
      };
      const linkOriginOK = (href) => {
        let origin = '';
        try { origin = sOf(pget(G_urlOrigin, new C_URL(href, 'https://chatgpt.com/'))); } catch (e) { return false; }
        return listHas(CONSENT_LINK_ORIGINS, origin);
      };
      // W183 R12：沒核實過的一份同意內容綁成一整份（'user'＋照順序的文字＋每一個連結的字與網域；跟 consentPrint 同一個樣子）。
      // 看不出範圍（太深、太長）、有連結不在 OpenAI 的網域＝''（不給使用者一鍵同意：照舊請他自己勾）。
      const userPrint = (seen) => {
        if (seen.deep || !seen.text || seen.text.length > WARNING_LIMIT || seen.links.length > 16) return '';
        let out = 'user\n' + seen.text;
        for (let i = 0; i < seen.links.length; i += 1) {
          if (!linkOriginOK(seen.links[i].href)) return '';
          let origin = '';
          try { origin = sOf(pget(G_urlOrigin, new C_URL(seen.links[i].href, 'https://chatgpt.com/'))); } catch (e) { return ''; }
          out += '\n' + seen.links[i].text + ' -> ' + origin;
        }
        return out;
      };
      // 對得上哪一個核實過的版本（回版本名；對不上＝''）。W183 R12：使用者在 TATWO 卡片上同意過的那一份（整份一字不差）＝'user'。
      // W183 R12（.037 實機：改名之後整張表單的字變了（Name、alert「An app with this name already exists」），同意過的那一份就對不上）：
      // 同意內容只看風險說明那一段——那一格勾選框（字是「I understand and want to continue」）與風險警語（introduce risk…）最近的共同上層；
      // 欄位、標籤、錯誤提示不算。找不到那一段（或它就是整張表單）＝照舊整張。
      const RISK_BLOCK_HINT = /(introduce risk|may introduce risk|risk\.|風險)/i;
      const riskArea = (root) => {
        const boxes = aFilter(boxesIn(root), (b) => reTest(RISK_ACK, boxText(b)));
        if (boxes.length !== 1) return root;
        const box = boxes[0];
        const warns = aFilter(safeAll(root, '*'), (el) => shown(el) && reTest(RISK_BLOCK_HINT, dOwnText(el)) && !safeContains(box, el) && !reTest(RISK_ACK, dOwnText(el)));
        if (!warns.length) return root;
        const up = [];
        for (let p = box, i = 0; p && i < 60; p = safeParent(p), i += 1) { listAdd(up, p); if (p === root) break; }
        for (let p = warns[0], i = 0; p && i < 60; p = safeParent(p), i += 1) {
          if (listHas(up, p)) return p;
          if (p === root) return root;
        }
        return root;
      };
      const consentMatch = (seen, full) => {
        for (let v = 0; v < CONSENT_VERSIONS.length; v += 1) {
          const entry = CONSENT_VERSIONS[v];
          if ((entry.area === true) === full) continue;
          if (seen.text !== entry.text || seen.links.length !== entry.links.length) continue;
          let ok = true;
          for (let i = 0; ok && i < entry.links.length; i += 1) ok = seen.links[i].text === entry.links[i] && linkOriginOK(seen.links[i].href);
          if (ok) return entry.id;
        }
        return '';
      };
      // 對得上哪一個版本（id；整張的版本或風險那一段的版本）＋用哪一段（area）。
      const consentFind = (root) => {
        const out = bag();
        out.id = ''; out.area = root;
        const whole = consentScan(root);
        if (!whole.deep) { const id = consentMatch(whole, true); if (id) { out.id = id; return out; } }
        const area = riskArea(root);
        const seen = area === root ? whole : consentScan(area);
        out.area = area;
        if (seen.deep) return out;
        if (area !== root) { const id = consentMatch(seen, false); if (id) { out.id = id; return out; } }
        if (approvedConsent && userPrint(seen) === approvedConsent) out.id = 'user';
        return out;
      };
      const consentVersion = (root) => consentFind(root).id;
      // W183 R12：不認得的那一份交給 App 顯示（純文字：只收文字節點，網頁的 HTML 不帶；連結只帶字與網域）＋綁住它的 print。
      // 讀不出來（太深、太長、連結不在 OpenAI 的網域）＝null（App 照舊請使用者自己勾）。
      const consentOffer = (root) => {
        const seen = consentScan(riskArea(root));   // W183 R12（.037）：只顯示風險說明那一段
        const print = userPrint(seen);
        if (!print) return null;
        const links = [];
        for (let i = 0; i < seen.links.length; i += 1) {
          let origin = '';
          try { origin = sOf(pget(G_urlOrigin, new C_URL(seen.links[i].href, 'https://chatgpt.com/'))); } catch (e) { return null; }
          const link = bag();
          link.text = sSlice(seen.links[i].text, 0, 200);
          link.origin = origin;
          listAdd(links, link);
        }
        const out = bag();
        out.text = seen.text; out.links = links; out.print = print;
        return out;
      };
      // W183 R12：指令帶來的同意過的那一份（只收 'user' 開頭、有上限的字串；沒帶＝不動）。
      const noteApproved = (c) => {
        const raw = own(c, 'approved');
        if (typeof raw === 'string' && raw.length <= 12000 && sIdx(raw, 'user\n', 0) === 0) approvedConsent = raw;
      };
      // W183 R10 第三輪（GPT-6 發現 3；主導裁決）：代勾那一刻綁住的同意內容——對上的版本、照順序的文字、每一個連結的字與解析後的網域。
      // 派送前（connectorConsent）、按之前（connectorCreate 帶回確認時、connectorPress）各再核一次；不一樣＝交回使用者。對不上任何版本＝''。
      const consentPrint = (root) => {
        const found = consentFind(root);
        const id = found.id;
        if (!id) return '';
        const seen = consentScan(found.area);
        let out = id + '\n' + seen.text;
        for (let i = 0; i < seen.links.length; i += 1) {
          let origin = '';
          try { origin = sOf(pget(G_urlOrigin, new C_URL(seen.links[i].href, 'https://chatgpt.com/'))); } catch (e) { return ''; }
          out += '\n' + seen.links[i].text + ' -> ' + origin;
        }
        return out;
      };
      // 那一格在畫面上的位置（CSS px、相對於畫面左上＋當時的畫面大小）；算不出來＝null（交給使用者）。
      // 先捲到畫面中間（私訊框的 Browser 是手機大小，對話框常要往下捲）。只量那一格本身（W183 R10 第二輪：不再改點它的 label——
      // CEF 的節點驗證點擊要的是那一個節點）：太小、藏起來、被蓋住、雙指縮放、視覺視窗有位移＝不代勾。
      // W183 R12（.036 實機：量 Create 失敗、紀錄只有 aim_failed）：量一顆按鈕，量不到＝寫出原因（why）與那一刻的位置、蓋在上面的是誰。
      // 按鈕只有一部分在畫面裡（對話框底部被切掉）＝點看得到的那一部分的中間（至少 8×8；最上面還是它才算）。
      const measureWhy = (el, noScroll) => {
        const out = bag();
        if (!G_innerWidth || !G_innerHeight || !M_elementFromPoint) { out.why = 'no_viewport_api'; return out; }
        if (M_scrollIntoView && !noScroll) {
          const how = bag();
          how.block = 'center'; how.inline = 'nearest'; how.behavior = 'instant';
          try { R_apply(M_scrollIntoView, el, [how]); } catch (e) {}
        }
        let vw = 0;
        let vh = 0;
        try { vw = R_apply(G_innerWidth, window, []); vh = R_apply(G_innerHeight, window, []); } catch (e) { out.why = 'viewport'; return out; }
        if (!(vw >= 1 && vh >= 1)) { out.why = 'viewport'; return out; }
        if (G_visualViewport && G_vvScale && G_vvLeft && G_vvTop) {
          try {
            const v = R_apply(G_visualViewport, window, []);
            if (v && (pget(G_vvScale, v) !== 1 || pget(G_vvLeft, v) !== 0 || pget(G_vvTop, v) !== 0)) { out.why = 'pinch_zoom'; return out; }
          } catch (e) { out.why = 'visual_viewport'; return out; }
        }
        if (!shown(el)) { out.why = 'hidden'; return out; }
        let r = null;
        try { r = dRect(el); } catch (e) { out.why = 'rect'; return out; }
        out.rect = Str(r.left) + ',' + Str(r.top) + ' ' + Str(r.width) + 'x' + Str(r.height) + ' in ' + Str(vw) + 'x' + Str(vh);
        const left = r.left < 0 ? 0 : r.left;
        const top = r.top < 0 ? 0 : r.top;
        const right = r.left + r.width > vw ? vw : r.left + r.width;
        const bottom = r.top + r.height > vh ? vh : r.top + r.height;
        if (!(r.width >= 8 && r.height >= 8)) { out.why = 'too_small'; return out; }
        if (!(right - left >= 8 && bottom - top >= 4)) { out.why = 'off_screen'; return out; }
        const cx = (left + right) / 2;
        const cy = (top + bottom) / 2;
        let hit = null;
        try { hit = R_apply(M_elementFromPoint, document, [cx - (cx % 1), cy - (cy % 1)]); } catch (e) { out.why = 'hit_test'; return out; }
        if (!hit || !(hit === el || safeContains(el, hit))) { out.why = 'covered'; out.top = hit ? describeEl(hit) : 'none'; return out; }
        for (let p = hit, i = 0; p && p !== el && i < 40; p = safeParent(p), i += 1) {
          if (reTest(/^(A|BUTTON|INPUT|SELECT|TEXTAREA|SUMMARY|LABEL)$/, safeTag(p))
            || reTest(/^(link|button|checkbox|switch|menuitem|tab|radio|option)$/, safeAttr(p, 'role'))) {
            out.why = 'nested_control'; out.top = describeEl(p); return out;
          }
        }
        const t = bag();
        t.x = left; t.y = top; t.w = right - left; t.h = bottom - top; t.vw = vw; t.vh = vh;
        out.tick = t;
        return out;
      };
      // W183 R12（.037 實機：Create 在 617 高的畫面外，只露 6px）：先照各種捲法試（nearest、end、center）、每次等位置穩定再量；
      // 看得到的那一條至少 4px 高（寬 8px）也算（最上面還是它才點）。
      const measureSettled = async (el) => {
        let last = null;
        const blocks = ['nearest', 'end', 'center'];
        for (let b = 0; b < blocks.length; b += 1) {
          if (M_scrollIntoView) {
            const how = bag();
            how.block = blocks[b]; how.inline = 'nearest'; how.behavior = 'instant';
            try { R_apply(M_scrollIntoView, el, [how]); } catch (e) {}
          }
          let prev = '';
          for (let i = 0; i < 5; i += 1) {
            await ksleep(60);
            let r = null;
            try { r = dRect(el); } catch (e) { break; }
            const key = Str(r.left) + ',' + Str(r.top);
            if (key === prev) break;
            prev = key;
          }
          last = measureWhy(el, true);
          if (last.tick) return last;
        }
        return last || measureWhy(el, true);
      };
      // ChatGPT 在對話框裡用 role=alert 講的錯（例：「An app with this name already exists」）：只讀字（最多 80 字）。
      // ChatGPT 說「這個名字的 App 已經有了」（英文、中文）。
      const NAME_TAKEN = /(name already exists|already exists|名稱已存在|名稱已經存在|已經有同名|已有同名|名稱已被使用)/i;
      const dialogAlert = () => {
        const dialogs = visibleOf(document, '[role="dialog"], dialog');
        for (let i = 0; i < dialogs.length; i += 1) {
          const alerts = visibleOf(dialogs[i], '[role="alert"]');
          for (let j = 0; j < alerts.length; j += 1) { const words = clip80(safeText(alerts[j])); if (words) return words; }
        }
        return '';
      };
      const tickPoint = (zone) => {
        if (!G_innerWidth || !G_innerHeight || !M_elementFromPoint) return null;
        if (M_scrollIntoView) {
          // 立刻捲到位（behavior instant：不照網頁的 scroll-behavior 慢慢捲——量完 App 就點，捲到一半量到的位置是錯的）；
          // 選項用沒有原型的袋子（網頁在 Object.prototype 塞的東西讀不到）。
          const how = bag();
          how.block = 'center'; how.inline = 'nearest'; how.behavior = 'instant';
          try { R_apply(M_scrollIntoView, zone.box, [how]); } catch (e) {}
        }
        let vw = 0;
        let vh = 0;
        try { vw = R_apply(G_innerWidth, window, []); vh = R_apply(G_innerHeight, window, []); } catch (e) { return null; }
        if (!(vw >= 1 && vh >= 1)) return null;
        if (G_visualViewport && G_vvScale && G_vvLeft && G_vvTop) {
          try {
            const v = R_apply(G_visualViewport, window, []);
            if (v && (pget(G_vvScale, v) !== 1 || pget(G_vvLeft, v) !== 0 || pget(G_vvTop, v) !== 0)) return null;
          } catch (e) { return null; }
        }
        const el = zone.box;
        if (!shown(el)) return null;
        let r = null;
        try { r = dRect(el); } catch (e) { return null; }
        if (!(r.width >= 8 && r.height >= 8) || r.left < 0 || r.top < 0 || r.left + r.width > vw || r.top + r.height > vh) return null;
        // 正中間那一點（往下取整數，跟 HandsTickTarget.point 一樣）最上面的元素要是它自己或它裡面的（沒有別的東西蓋在上面——提示框、遮罩、
        // 捲到一半）；落點在它裡面的連結、按鈕、別的欄位上也不點。CEF 送出之前還會用節點再核一次（App 那邊）。
        const cx = r.left + r.width / 2;
        const cy = r.top + r.height / 2;
        let top = null;
        try { top = R_apply(M_elementFromPoint, document, [cx - (cx % 1), cy - (cy % 1)]); } catch (e) { return null; }
        if (!top || !(top === el || safeContains(el, top))) return null;
        for (let p = top, i = 0; p && p !== el && i < 40; p = safeParent(p), i += 1) {
          if (reTest(/^(A|BUTTON|INPUT|SELECT|TEXTAREA|SUMMARY|LABEL)$/, safeTag(p))
            || reTest(/^(link|button|checkbox|switch|menuitem|tab|radio|option)$/, safeAttr(p, 'role'))) return null;
        }
        const t = bag();
        t.x = r.left; t.y = r.top; t.w = r.width; t.h = r.height; t.vw = vw; t.vh = vh;
        return t;
      };
      // 交回給使用者的是 risk_ack 時：是不是只剩 TATWO 認得的那一格（可以代勾）。out.reason＝改成交給使用者的原因；out.tick＝可以代勾。
      const tickFor = (rec, root) => {
        const out = bag();
        const boxes = boxesIn(root);
        if (boxes.length !== 1 || rec.zones.length !== 1 || rec.zones[0].box !== boxes[0]) { out.reason = 'checkbox'; return out; }
        const box = boxes[0];
        if (isChecked(box) || !reTest(RISK_ACK, boxText(box))) { out.reason = 'checkbox'; return out; }
        if (!consentVersion(root)) { out.reason = 'warning_changed'; out.offer = consentOffer(root); return out; }   // W183 R12：帶那一份給 App 顯示
        out.tick = tickPoint(rec.zones[0]);
        rec.consent = out.tick ? consentPrint(root) : '';   // W183 R10 第三輪：綁住代勾那一刻的同意內容
        return out;
      };
      // W183 R10 第二輪：connectorPress 之前再核一次（跟 armed 那一刻一樣的條件；任何一個不成立＝不按、記號作廢）。
      // W183 R12（.033 實機：按之前的再核一次失敗＝press_stale，卻查不到是哪一條）：每一條不成立都記下是哪一條（staleWhy，進結構快照）。
      let staleWhy = '';
      const stale = (why) => { staleWhy = why; return false; };
      const createStillReady = (rec, url, button, seen) => {
        const root = rec.root;
        if (!attached(root)) return stale('root_detached');
        const forms = connectorForms();
        if (forms.length !== 1 || forms[0] !== root) return stale(forms.length === 1 ? 'form_replaced' : 'forms_' + Str(forms.length));
        const connectionNow = connectionState(root, rec.legacy);
        if (connectionNow !== 'none' && connectionNow !== 'server') return stale('connection_' + connectionNow);
        const urls = urlFields(root);
        const names = nameFields(root);
        if (urls.length !== 1 || names.length !== 1 || urls[0] !== rec.url || names[0] !== rec.name) return stale('fields_replaced');
        if (!ownersIntact(rec)) return stale('owners_changed');
        const present = boxesIn(root);
        if (!aEvery(rec.zones, (z) => listHas(present, z.box))) return stale('checkbox_replaced');
        if (dValue(urls[0]) !== url || dValue(names[0]) !== rec.expectedName) return stale('field_values_changed');
        if (authState(root) !== 'oauth') return stale('auth_not_oauth');
        if (warningsIn(root, seen, rec)) return stale('warning_changed');
        const submit = aFilter(visibleOf(root, 'button, [role="button"], input[type="submit"]'), (b) => reTest(CREATE, labelOf(b) || safeAttr(b, 'value')));
        if (submit.length !== 1) return stale('create_buttons_' + Str(submit.length));
        // W183 R12（.034 實機：勾完之後 React 整段重畫，Create 換成新的節點＝以前一律 press_stale）：同一張表單（root、欄位、勾選框、
        // 同意內容上面都核過）裡剛好一顆、同樣的字、同一種元素＝就是它，按現在這一顆；不是同一種元素＝不認。
        const now = submit[0];
        if (now !== button && safeTag(now) !== safeTag(button)) return stale('create_button_replaced');
        if (dDisabled(now) || safeAttr(now, 'aria-disabled') === 'true') return stale('create_disabled');
        if (now !== button && rec.armed) { rec.armed.button = now; rec.armed.refound = true; }
        return true;
      };
      const reconnectStillReady = (rec, url, button, seen, requireOAuth) => {
        const root = rec.root;
        if (!attached(root) || !ownersIntact(rec)) return stale(attached(root) ? 'owners_changed' : 'root_detached');
        const here = aSome(leaves(root), (el) => hasURLToken(safeText(el), url) && shown(el)) || aSome(textInputs(root), (x) => dValue(x) === url);
        const auth = authShown(root);
        if (!here || (requireOAuth ? auth !== 'oauth' : auth === 'other')) return stale(here ? 'auth_not_oauth' : 'url_missing');
        const present = boxesIn(root);
        if (!aEvery(rec.zones, (z) => listHas(present, z.box))) return stale('checkbox_replaced');
        if (warningsIn(root, seen, rec)) return stale('warning_changed');
        const buttons = aFilter(visibleOf(root, 'button, [role="button"]'), (x) => reTest(RECONNECT, labelOf(x)));
        if (buttons.length !== 1) return stale('connect_buttons_' + Str(buttons.length));
        // W183 R12：同上（那一區裡剛好一顆、同樣的字、同一種元素＝重畫過的同一顆）。
        const now = buttons[0];
        if (now !== button && safeTag(now) !== safeTag(button)) return stale('connect_button_replaced');
        if (dDisabled(now) || safeAttr(now, 'aria-disabled') === 'true') return stale('connect_disabled');
        if (now !== button && rec.armed) { rec.armed.button = now; rec.armed.refound = true; }
        return true;
      };
      // 網址要整個出現（前後不是網址字元）：https://x/mcp 不算出現在 https://x/mcp/extra、https://x/mcpx 裡。
      const hasURLToken = (text, url) => {
        const t = sOf(text);
        for (let i = sIdx(t, url, 0); i >= 0; i = sIdx(t, url, i + 1)) {
          const before = i === 0 ? '' : t[i - 1];
          const after = sSlice(t, i + url.length, i + url.length + 2);
          if ((!before || !reTest(/[A-Za-z0-9._~:/?#@!$&'*+,;=%-]/, before)) && (!after || reTest(/^(\s|["'<>)\]}]|[.,;:!?](\s|$))/, after))) return true;
        }
        return false;
      };
      const containerOf = (el) => {
        for (let p = safeParent(el), i = 0; p && i < 200; p = safeParent(p), i += 1) {
          if (isDialog(p) || reTest(/^(FORM|SECTION|ARTICLE|MAIN|ASIDE)$/, safeTag(p)) || safeAttr(p, 'role') === 'region') return p;
        }
        return null;
      };
      // 放著這個完整 MCP 網址的詳情區：只算看得到、網址整個出現的；有對話框就只看對話框。
      const detailBoxes = (url) => {
        const hits = aFilter(leaves(document), (el) => hasURLToken(safeText(el), url) && shown(el));
        const inputs = aFilter(textInputs(document), (x) => dValue(x) === url);
        for (let i = 0; i < inputs.length; i += 1) listAdd(hits, inputs[i]);
        const out = [];
        for (let i = 0; i < hits.length; i += 1) { const box = containerOf(hits[i]); if (box) aUniqAdd(out, box); }
        const dialogs = aFilter(out, isDialog);
        return dialogs.length ? dialogs : out;
      };
      // W183 R12（主導 2：要真人點的那一步指給他看）：ChatGPT 開授權視窗要真的手勢（那一顆 Connect／連接／授權）：TATWO 不按、只指路。
      // 找：放著這個完整網址的那一區（detailBoxes）裡剛好一顆；沒有那一區＝畫面上剛好一個對話框、裡面剛好一顆。多顆、沒有、停用＝null
      //（不指；卡片照舊那一句）。
      // W183 R12（.034 實機：亮框沒出現）：放寬——同一個外掛（網址整個出現、或名稱對得上）的區塊裡，字是 Connect／Connect to…／連接／授權
      // 的唯一一顆 button 或 link；都沒有＝畫面上剛好一個對話框、裡面唯一一顆。
      const GESTURE = /^(connect|connect to .{1,80}|reconnect|authorize|連線|重新連線|連接|連接到.{1,80}|重新連接|授權|重新授權)$/i;
      const GESTURE_SELECTOR = 'button, [role="button"], a[href], [role="link"]';
      // W183 R12（.037 實機：建成之後 ChatGPT 開的是「Connect <名字>」對話框，唯一一顆「Continue to <名字>」）：這一步 TATWO 自己真的點擊
      //（使用者按［連線］＝同意連線；ChatGPT 要的只是真人手勢）。名字要對得上這一次的名字。
      const CONTINUE = /^(continue to |繼續前往|繼續到|繼續使用|前往)(.{1,80})$/i;
      const continueButton = (name) => {
        if (!name) return null;
        const dialogs = visibleOf(document, '[role="dialog"], dialog');
        if (dialogs.length !== 1) return null;
        const d = dialogs[0];
        const heads = aFilter(visibleOf(d, 'h1, h2, h3, [role="heading"]'), (h) => sIdx(safeSquash(safeText(h)), name, 0) >= 0);
        if (!heads.length) return null;
        const hits = aFilter(visibleOf(d, 'button, [role="button"]'), (b) => {
          const m = reExec(CONTINUE, labelOf(b));
          return !!m && safeSquash(m[2]) === name;
        });
        if (hits.length !== 1 || dDisabled(hits[0]) || safeAttr(hits[0], 'aria-disabled') === 'true') return null;
        return hits[0];
      };
      const nameBoxes = (name) => {
        const out = [];
        if (!name) return out;
        const hits = aFilter(leaves(document), (el) => shown(el) && sIdx(safeSquash(safeText(el)), name, 0) >= 0);
        for (let i = 0; i < hits.length; i += 1) { const box = containerOf(hits[i]); if (box) aUniqAdd(out, box); }
        return out;
      };
      const gestureButton = (url, name) => {
        const usable = (b) => !(dDisabled(b) || safeAttr(b, 'aria-disabled') === 'true');
        const inBoxes = (boxes) => {
          const found = [];
          for (let i = 0; i < boxes.length; i += 1) {
            const hits = aFilter(visibleOf(boxes[i], GESTURE_SELECTOR), (x) => reTest(GESTURE, labelOf(x)));
            for (let j = 0; j < hits.length; j += 1) aUniqAdd(found, hits[j]);
          }
          return found;
        };
        let found = inBoxes(detailBoxes(url));
        if (!found.length) found = inBoxes(nameBoxes(name));
        if (!found.length) {
          const dialogs = visibleOf(document, '[role="dialog"], dialog');
          if (dialogs.length === 1) found = inBoxes(dialogs);
        }
        return found.length === 1 && usable(found[0]) ? found[0] : null;
      };
      const near = (a, b) => a - b < 1 && b - a < 1;
      // 亮框＋箭頭：畫在網頁最上層、點得穿過去（pointer-events:none：使用者真的按到的是那一顆），跟著它（捲動、版面變了每 150ms 重算；
      // 它不見了、取消、換一次指路＝拿掉；最多 10 分鐘）。只標、不按。
      let gestureEl = null;
      let gestureMark = '';
      let gestureAt = null;
      let gestureEpoch = -1;
      let gesturePath = '';
      let gestureGen = 0;
      let gestureDrawn = null;   // 亮框現在跟著的那一顆（沒有＝null）
      let gestureFoundAt = 0;
      const RING_STYLE = 'position:fixed;pointer-events:none;z-index:2147483647;box-sizing:border-box;border:3px solid #ff7a1a;'
        + 'border-radius:12px;box-shadow:0 0 0 4px rgba(255,122,26,0.28),0 0 22px rgba(255,122,26,0.55);';
      const ARROW_STYLE = 'position:fixed;pointer-events:none;z-index:2147483647;width:0;height:0;border-left:13px solid transparent;'
        + 'border-right:13px solid transparent;border-top:18px solid #ff7a1a;filter:drop-shadow(0 2px 3px rgba(0,0,0,0.25));';
      const clearGesture = () => {
        gestureGen += 1;
        gestureEl = null;
        gestureMark = '';
        gestureAt = null;
        gestureDrawn = null;
        removeHighlights();
      };
      const drawGesture = (el) => {
        removeHighlights();
        const body = safeBody();
        if (!body || !el) return false;
        let ring = null;
        let arrow = null;
        try { ring = R_apply(M_createElement, document, ['div']); arrow = R_apply(M_createElement, document, ['div']); } catch (e) { return false; }
        R_apply(M_setAttr, ring, ['data-tatwo-highlight', 'gesture']);
        R_apply(M_setAttr, arrow, ['data-tatwo-highlight', 'gesture-arrow']);
        R_apply(M_setAttr, ring, ['aria-hidden', 'true']);
        R_apply(M_setAttr, arrow, ['aria-hidden', 'true']);
        gestureGen += 1;
        const mine = gestureGen;
        const place = () => {
          if (mine !== gestureGen) return;
          // 亮框被別的拿掉了（回首頁、手動模式的標示）＝不再跟（不去動別人的標示）。
          if (!safeContains(safeBody(), ring)) { gestureGen += 1; gestureDrawn = null; return; }
          if (!attached(el)) { clearGesture(); return; }
          let r = null;
          try { r = dRect(el); } catch (e) { clearGesture(); return; }
          R_apply(M_setAttr, ring, ['style', RING_STYLE + 'left:' + Str(r.left - 6) + 'px;top:' + Str(r.top - 6) + 'px;width:'
            + Str(r.width + 12) + 'px;height:' + Str(r.height + 12) + 'px']);
          // 箭頭在它上面、尖端朝下指著它（上面放不下＝放下面、尖端朝上）。
          const above = r.top >= 36;
          R_apply(M_setAttr, arrow, ['style', ARROW_STYLE + 'left:' + Str(r.left + r.width / 2 - 13) + 'px;top:'
            + Str(above ? r.top - 30 : r.top + r.height + 12) + 'px;' + (above ? '' : 'transform:rotate(180deg);')]);
          later(place, 150);
        };
        R_apply(M_appendChild, body, [ring]);
        R_apply(M_appendChild, body, [arrow]);
        gestureDrawn = el;
        place();
        later(() => { if (mine === gestureGen) clearGesture(); }, 600000);
        return gestureDrawn === el;
      };
      // W183 R12（.033 實機：連線失敗、查不到 ChatGPT 的頁面長什麼樣）：結構快照（DOM 文字，不是截圖；不讀任何欄位的值、不含帳號與秘密）。
      // 只記連接器區域的元素樹，不退回整頁（隱藏側欄可能有私人對話標題，也會擠掉真正的錯誤）。
      // 每個元素一行：深度縮排、tag、role、input 的 type／name／checked、停用、aria-label、
      // 按鈕與 label 的字、葉子的字（每段最多 80 字）；iframe 只記來源網域（不往下讀）；open shadow root 往下讀、標 #shadow。截在 16 KB。
      const OUTLINE_MAX = 16384;
      const clip80 = (t) => { const x = safeSquash(t); return x.length > 80 ? sSlice(x, 0, 80) + '…' : x; };
      const dShadow = (el) => { if (!G_shadowRoot) return null; try { return pget(G_shadowRoot, el) || null; } catch (e) { return null; } };
      const TEXTY_TAG = /^(BUTTON|LABEL|A|SUMMARY|LEGEND|H1|H2|H3|H4|H5|H6|OPTION)$/;
      const TEXTY_ROLE = /^(button|link|checkbox|switch|tab|menuitem|radio|option|heading)$/;
      const FIELD_TAG = /^(INPUT|TEXTAREA|SELECT)$/;
      const describeEl = (el) => {
        const tag = safeTag(el);
        let line = sLower(tag);
        const role = safeAttr(el, 'role');
        if (role) line += ' role=' + clip80(role);
        if (reTest(FIELD_TAG, tag)) {
          const type = safeAttr(el, 'type');
          if (type) line += ' type=' + clip80(type);
          const name = safeAttr(el, 'name');
          if (name) line += ' name=' + clip80(name);
          if (tag === 'INPUT' && reTest(/^(checkbox|radio)$/i, type)) line += ' checked=' + (safeChecked(el) ? '1' : '0');
        } else if (reTest(/^(checkbox|switch|radio)$/, role)) {
          line += ' checked=' + (safeChecked(el) ? '1' : '0');
        }
        if (dDisabled(el) || safeAttr(el, 'aria-disabled') === 'true') line += ' disabled';
        const aria = safeAttr(el, 'aria-label');
        if (aria) line += ' aria="' + clip80(aria) + '"';
        if (!reTest(FIELD_TAG, tag)) {
          const words = reTest(TEXTY_TAG, tag) || reTest(TEXTY_ROLE, role) || dKids(el).length === 0 ? clip80(safeText(el)) : clip80(dOwnText(el));
          if (words) line += ' "' + words + '"';
        }
        if (!shown(el)) line += ' hidden';
        return line;
      };
      const outlineRootOf = (preferred) => {
        if (sOf(location.pathname) !== '/plugins' && sIdx(location.pathname, '/plugins/', 0) !== 0) return null;
        if (preferred && attached(preferred) && shown(preferred)) return preferred;
        const forms = connectorForms();
        const connectorHeading = (root) => aSome(visibleOf(root, 'h1, h2, h3, [role="heading"]'), (h) =>
          reTest(/^(plugins|apps|外掛|應用程式|new plugin|create MCP app|建立 MCP 應用程式|(?:connect |連接 |連線 )?TATWO(?:（[^（）]{1,40}）[2-9]?)?)$/i, safeSquash(safeText(h))));
        const dialogs = visibleOf(document, '[role="dialog"], dialog');
        if (dialogs.length === 1) return listHas(forms, dialogs[0]) || connectorHeading(dialogs[0]) ? dialogs[0] : null;
        if (dialogs.length > 1) return null;
        const mains = visibleOf(document, 'main, [role="main"]');
        return mains.length === 1 && connectorHeading(mains[0]) ? mains[0] : null;
      };
      const outlineOf = (root) => {
        if (!root) return '(no unambiguous visible connector surface)';
        let out = '';
        let full = false;
        const walk = (el, depth, mark) => {
          if (!el || full || !shown(el)) return;
          if (out.length >= OUTLINE_MAX) { full = true; return; }
          const tag = safeTag(el);
          if (reTest(/^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|SVG|PATH|META|LINK|ASIDE|NAV)$/, tag)
              || safeAttr(el, 'data-message-author-role') || safeAttr(el, 'contenteditable') === 'true') return;
          let pad = '';
          for (let i = 0; i < depth && i < 30; i += 1) pad += ' ';
          const line = pad + mark + describeEl(el);
          if (tag === 'IFRAME') {
            let origin = '?';
            try { origin = sOf(pget(G_urlOrigin, new C_URL(safeAttr(el, 'src'), location.origin))); } catch (e) { origin = '?'; }
            out += line + ' #iframe src=' + clip80(origin) + '\n';
            return;
          }
          out += line + '\n';
          if (depth >= 60) return;
          const kids = dKids(el);
          for (let i = 0; i < kids.length; i += 1) walk(kids[i], depth + 1, '');
          const shadow = dShadow(el);
          if (shadow) {
            const inner = dKids(shadow);
            for (let i = 0; i < inner.length; i += 1) walk(inner[i], depth + 1, '#shadow ');
          }
        };
        walk(root, 0, '');
        if (full || out.length > OUTLINE_MAX) out = sSlice(out, 0, OUTLINE_MAX) + '\n…（截斷在 16 KB）';
        return out;
      };
      // W183 R12：真的點擊落在要按的那一顆上（那一顆本身、它裡面；或重畫過、同樣的字的那一顆）。
      const pressHit = (arm, target) => {
        if (!target) return false;
        if (target === arm.button || safeContains(arm.button, target)) return true;
        for (let p = target, i = 0; p && i < 8; p = safeParent(p), i += 1) {
          if (safeTag(p) === 'BUTTON' || safeAttr(p, 'role') === 'button') return reTest(arm.kind === 'reconnect' ? RECONNECT : CREATE, labelOf(p));
        }
        return false;
      };
      // press_stale 那一刻（主導：arm.check() 失敗那一刻也要留一份）：為什麼、arm 的時候那一顆長什麼樣 vs. 現在這一區的按鈕清單、結構快照。
      // 記在閉包裡，App 用 connectorOutline 拿（按的結果本身照舊）。
      let lastStale = null;
      const noteStale = (why, rec, arm) => {
        const root = outlineRootOf(rec && rec.root);
        const x = bag();
        x.why = why;
        if (arm) {
          x.armed = sOf(arm.desc);
          x.armedNow = attached(arm.button) ? describeEl(arm.button) : 'detached';
        }
        const buttons = root ? visibleOf(root, 'button, [role="button"], input[type="submit"]') : [];
        let list = '';
        for (let i = 0; i < buttons.length && i < 30; i += 1) list += describeEl(buttons[i]) + '\n';
        x.buttons = list;
        x.structure = outlineOf(root);
        lastStale = x;
      };
      // 網址的路徑段或查詢值裡有這個 id（解碼後完全相等）；只算同一個網站的連結。
      const formDecode = (t) => { try { return R_apply(F_decode, null, [sMapChars(t, (c, ch) => (c === 43 ? ' ' : ch))]); } catch (e) { return null; } };
      const hrefHasID = (href, id) => {
        try {
          const u = new C_URL(href, location.origin);
          if (pget(G_urlOrigin, u) !== location.origin) return false;
          const path = sOf(pget(G_urlPathname, u));
          let seg = '';
          for (let i = 0; i <= path.length; i += 1) {
            if (i === path.length || path[i] === '/') {
              if (seg) { let d = null; try { d = R_apply(F_decode, null, [seg]); } catch (e) { d = null; } if (d === id) return true; }
              seg = '';
            } else seg += path[i];
          }
          const search = sOf(pget(G_urlSearch, u));
          let part = '';
          for (let i = 1; i <= search.length; i += 1) {
            if (i === search.length || search[i] === '&') {
              const eq = sIdx(part, '=', 0);
              if (eq >= 0 && formDecode(sSlice(part, eq + 1)) === id) return true;
              part = '';
            } else part += search[i];
          }
          return false;
        } catch (e) { return false; }
      };
      // 詳情區寫的驗證方式：有控制項照控制項；沒有就看寫著驗證方式的那幾行（免驗證＝other）。
      const authShown = (root) => {
        const state = authState(root);
        if (state !== 'unknown') return state;
        const t = aJoin(aFilter(aMap(leaves(root), (el) => safeSquash(safeText(el))), (x) => reTest(AUTH_FIELD, x) || reTest(OAUTH_WORD, x)), ' ');
        if (reTest(NOT_OAUTH, t)) return 'other';
        return reTest(OAUTH_WORD, t) ? 'oauth' : 'unknown';
      };
      // 外掛清單要讀得出完整的樣子：認得的清單欄位只有一個、沒有下一頁、每一筆都是物件；否則＝不知道（App 不會按建立）。
      // （JSON 由抓好的 JSON.parse 讀進來；只讀自己的屬性。）
      const isObj = (v) => v !== null && typeof v === 'object';
      const listOf = (j) => {
        if (R_apply(A_isArray, null, [j])) return j;
        if (!isObj(j)) return null;
        const keys = aFilter(['items', 'plugins', 'installed', 'data', 'results'], (k) => R_apply(A_isArray, null, [own(j, k)]));
        return keys.length === 1 ? own(j, keys[0]) : null;
      };
      const pagedList = (j, list) => isObj(j) && !R_apply(A_isArray, null, [j]) && (own(j, 'has_more') === true || own(j, 'hasMore') === true
        || aSome(['cursor', 'next_cursor', 'nextCursor', 'next', 'next_page', 'nextPage'], (k) => { const v = own(j, k); return (typeof v === 'string' && v.length > 0) || typeof v === 'number'; })
        || (typeof own(j, 'total') === 'number' && R_apply(A_isArray, null, [list]) && own(j, 'total') > list.length));
      const devModeState = () => {
        const switches = aFilter(visibleOf(document, '[role="switch"], input[type="checkbox"]'),
          (s) => reTest(DEV, fieldLabel(s) + ' ' + labelOf(s) + ' ' + (safeParent(s) ? labelOf(safeParent(s)) : '')));
        if (switches.length === 1) return safeChecked(switches[0]) || safeAttr(switches[0], 'aria-checked') === 'true';
        if (reTest(/(enable|turn on|開啟|打開|啟用).{0,24}(developer mode|開發者模式|開發人員模式)/i, safeText(safeBody()))) return false;
        return null;
      };
      // 值裡所有的字（欄位名與字串值；不經 JSON.stringify：它會去查網頁改得到的 toJSON）。
      const flatText = (v, depth) => {
        if (typeof v === 'string') return v;
        if (typeof v === 'number' || typeof v === 'boolean') return Str(v);
        if (!isObj(v) || depth > 4) return '';
        let t = '';
        if (R_apply(A_isArray, null, [v])) { for (let i = 0; i < v.length; i += 1) t += ' ' + flatText(v[i], depth + 1); return t; }
        const keys = R_apply(O_keys, null, [v]);
        for (let i = 0; i < keys.length; i += 1) t += ' ' + keys[i] + ' ' + flatText(own(v, keys[i]), depth + 1);
        return t;
      };
      // 清單裡指向「完整 MCP 網址」的外掛（id、名字、驗證方式從它自己或上層找；只看自己的屬性）。
      const connectorMatches = (value, url, out, trail, conflicts) => {
        if (!isObj(value) || trail.length > 8 || out.length > 256) return;
        if (R_apply(A_isArray, null, [value])) { for (let i = 0; i < value.length; i += 1) connectorMatches(value[i], url, out, trail, conflicts); return; }
        const keys = R_apply(O_keys, null, [value]);
        const server = aFind(aMap(keys, (k) => own(value, k)), (v) => v === url || (typeof v === 'string' && reTest(/^https:\/\/[a-z0-9.-]+\/mcp$/, v)));
        if (server) {
          const chain = [value];
          for (let i = trail.length - 1; i >= 0; i -= 1) listAdd(chain, trail[i]);
          const pick = (names, test) => {
            for (let i = 0; i < chain.length; i += 1) for (let j = 0; j < names.length; j += 1) { const v = own(chain[i], names[j]); if (test(v)) return v; }
            return null;
          };
          const id = pick(['id', 'connector_id', 'plugin_id', 'app_id'], (v) => typeof v === 'string' && reTest(/^[A-Za-z0-9_.:-]{2,200}$/, v));
          const name = pick(['display_name', 'name', 'title'], (v) => typeof v === 'string' && v.length > 0);
          if (server !== url) {
            if (typeof name === 'string' && connectorName(name) === name) listAdd(conflicts, name);
            return;
          }
          const authRaw = pick(['auth', 'authentication', 'auth_type', 'authorization_type', 'auth_method'], (v) => v !== undefined && v !== null);
          const authText = sLower(flatText(authRaw, 0));
          const authKind = reTest(/oauth/, authText) ? 'oauth' : reTest(/none|no_auth|noauth|unauthenticated/, authText) ? 'none' : 'unknown';
          listAdd(out, { id, name: sSlice(sOf(name), 0, 80), auth: authKind, serverURL: url, detailPath: id ? '/plugins/' + id : null });
          return;
        }
        const next = [];
        for (let i = 0; i < trail.length; i += 1) listAdd(next, trail[i]);
        listAdd(next, value);
        for (let i = 0; i < keys.length; i += 1) connectorMatches(own(value, keys[i]), url, out, next, conflicts);
      };
      // W208: discover the rendered self-created section, including unfinished OAuth apps.
      // A missing/virtualised/paged section is unknown, never an empty list.
      const createdSection = () => {
        const headings = aFilter(visibleOf(document, 'h1, h2, h3, h4, [role="heading"]'),
          (h) => reTest(/^(created by you|your apps|apps you created|self.created apps|自己建立的|自行建立的|你建立的|您建立的|已建立的應用程式)$/i, safeSquash(safeText(h))));
        if (headings.length !== 1) return null;
        for (let p = safeParent(headings[0]), n = 0; p && n < 5; p = safeParent(p), n += 1) {
          if (safeTag(p) === 'BODY' || safeTag(p) === 'MAIN' || safeAttr(p, 'role') === 'main') return null;
          const links = visibleOf(p, 'a[href]');
          const empty = aSome(leaves(p), (el) => reTest(/^(no apps|no connectors|no apps created yet|you haven't created any apps yet|尚未建立任何應用程式|沒有應用程式|尚未建立)$/i, safeSquash(safeText(el))));
          if ((links.length || empty) && visibleOf(p, 'h1, h2, h3, h4, [role="heading"]').length === 1) return p;
        }
        return null;
      };
      const openCreatedSection = async (live) => {
        const section = createdSection();
        if (section) return section;
        // Follow the page's own Apps tab; do not guess a private API or a settings URL.
        const panels = aFilter(visibleOf(document, 'main, [role="main"], [role="dialog"], dialog'),
          (root) => aSome(visibleOf(root, 'h1, h2, h3, [role="heading"]'), (h) => reTest(/^(apps|plugins|應用程式|外掛)$/i, safeSquash(safeText(h)))));
        if (panels.length !== 1 || !live()) return null;
        const tabs = aFilter(visibleOf(panels[0], 'button, [role="tab"], a[href]'),
          (el) => reTest(/^(created by you|your apps|apps you created|自己建立的|自行建立的|你建立的|您建立的)$/i, labelOf(el)) && !dDisabled(el));
        if (tabs.length !== 1) return null;
        if (safeTag(tabs[0]) === 'A') {
          try { if (pget(G_urlOrigin, new C_URL(safeAttr(tabs[0], 'href'), location.origin)) !== location.origin) return null; }
          catch (e) { return null; }
        }
        kpress(tabs[0]);
        await kwait(() => createdSection() !== null || !live(), 3000);
        return live() ? createdSection() : null;
      };
      const detailPathOf = (href, id) => {
        try {
          const u = new C_URL(href, location.origin);
          const path = pget(G_urlPathname, u);
          return pget(G_urlOrigin, u) === location.origin && hrefHasID(href, id) && !pget(G_urlSearch, u) && !pget(G_urlHash, u) ? path : '';
        } catch (e) { return ''; }
      };
      const createdLinks = (root) => {
        const out = [];
        const anchors = visibleOf(root, 'a[href]');
        for (let i = 0; i < anchors.length; i += 1) {
          const a = anchors[i];
          const href = safeAttr(a, 'href');
          let id = '';
          try {
            const u = new C_URL(href, location.origin);
            const match = reExec(/\/([^/]+)$/, pget(G_urlPathname, u));
            id = match ? match[1] : '';
          } catch (e) {}
          const name = safeSquash(safeText(a));
          if (!reTest(/^[A-Za-z0-9_.:-]{2,200}$/, id) || !detailPathOf(href, id)) return null;
          if (name && !aSome(out, (x) => x.id === id)) listAdd(out, { id, name: sSlice(name, 0, 80), detailPath: detailPathOf(href, id), node: a });
        }
        return out;
      };
      const completeCreatedList = (section) => {
        const links = section && createdLinks(section);
        return links && links.length <= 256
          && !visibleOf(section, '[aria-busy="true"], [role="progressbar"], [aria-rowcount], [data-virtualized]').length
          && !aSome(visibleOf(section, 'button, [role="button"], a'), (el) => reTest(/^(load more|show more|next|載入更多|顯示更多|下一頁)$/i, labelOf(el))) ? links : null;
      };
      const authorizationOf = (root) => {
        const buttons = visibleOf(root, 'button, [role="button"]');
        const connect = aFilter(buttons, (b) => reTest(RECONNECT, labelOf(b)) && !dDisabled(b));
        const disconnect = aFilter(buttons, (b) => reTest(/^(disconnect|斷線|中斷連線|取消連接)$/i, labelOf(b)) && !dDisabled(b));
        const connected = aSome(leaves(root), (el) => reTest(/^(connected|已連線|已連接)$/i, safeSquash(safeText(el))));
        return connected && disconnect.length === 1 && !connect.length ? 'connected'
          : connect.length === 1 && !disconnect.length && !connected ? 'needs_reconnect' : 'unknown';
      };
      const detailIdentity = (root, id, path) => {
        const headings = aFilter(visibleOf(root, 'h1, h2, h3, [role="heading"]'), (h) => connectorName(safeSquash(safeText(h))) === safeSquash(safeText(h)));
        const urls = aFilter(aMap(leaves(root), (el) => safeSquash(safeText(el))), (t) => reTest(/^https:\/\/[a-z0-9.-]+\/mcp$/, t));
        const fields = textInputs(root);
        for (let i = 0; i < fields.length; i += 1) { const v = dValue(fields[i]); if (reTest(/^https:\/\/[a-z0-9.-]+\/mcp$/, v) && !listHas(urls, v)) listAdd(urls, v); }
        if (headings.length !== 1 || urls.length !== 1) return null;
        return { id, name: safeSquash(safeText(headings[0])), serverURL: urls[0], auth: authShown(root), detailPath: path, connected: authorizationOf(root) === 'connected' };
      };
      const openKnownConnector = async (box, c, live, requireOAuth = true) => {
        box.root = null;
        const url = connectorURL(own(c, 'url'));
        const id = own(c, 'connectorID');
        if (typeof id !== 'string' || !reTest(/^[A-Za-z0-9_.:-]{2,200}$/, id)) return;
        const rawPath = own(c, 'detailPath');
        const path = detailPathOf(typeof rawPath === 'string' ? rawPath : '/plugins/' + id, id);
        if (!path || !live()) return;
        if (sOf(location.pathname) !== path) {
          const routed = bag();
          await kroute(routed, path, () => sOf(location.pathname) === path);
          if (!routed.ok) return;
        }
        await kwait(() => detailBoxes(url).length > 0 || !live(), 5000);
        const boxes = detailBoxes(url);
        if (!live() || boxes.length !== 1 || !hrefHasID(location.href, id)) return;
        const record = detailIdentity(boxes[0], id, path);
        if (!record || record.serverURL !== url || (requireOAuth && record.auth !== 'oauth')) return;
        box.root = boxes[0]; box.connector = record;
      };
      // 換頁（連接器指令用；抓好的版本）：先按網頁上指向那一頁的連結，沒有才改網址。醒來之後重新讀。
      const sEnds = (t, tail) => t.length >= tail.length && sSlice(t, t.length - tail.length) === tail;
      const kroute = async (out, target, arrived) => {
        out.ok = false;
        const same = (href) => {
          try {
            const u = new C_URL(href, location.origin);
            const p = sOf(pget(G_urlPathname, u));
            return pget(G_urlOrigin, u) === location.origin && (p === target || (target !== '/' && sEnds(p, target)));
          } catch (e) { return false; }
        };
        const link = aFind(safeAll(document, 'a[href]'), (a) => same(safeAttr(a, 'href')))
          || (target === '/' ? (safeAll(document, '[data-testid="create-new-chat-button"]')[0] || null) : null);
        if (link) {
          kpress(link);
          await kwait(arrived, 3000);
          if (arrived()) { diag['換頁'] = '按網頁連結'; out.ok = true; return; }
        }
        if (sOf(location.pathname) !== target) {
          R_apply(H_push, HIST, [{}, '', target]);
          dDispatch(window, new C_PopState('popstate', { state: {} }));
        }
        await kwait(arrived, link ? 5000 : 8000);
        out.ok = !!arrived();
        diag['換頁'] = out.ok ? '改網址' : '沒到';
      };
      // 讀 ChatGPT 的 JSON（連接器指令用）：抓好的 fetch、then、Response.text、JSON.parse；結果放進呼叫端自己的容器
      // （不採用 await 帶回來的值）。
      const kfetchInto = async (box, path) => {
        box.done = false; box.data = null; box.error = '';
        if (!auth) await kwait(() => !!auth, 15000);
        if (!auth) { box.done = true; box.error = '還沒登入 ChatGPT'; return; }
        const finish = (v, err) => { if (!box.done) { box.done = true; box.data = v; box.error = err || ''; } };
        try {
          const request = originalFetch(path, { headers: auth, credentials: 'include', cache: 'no-store' });
          R_apply(P_then, request, [(res) => {
            let ok = false;
            try { ok = pget(RS_ok, res) === true; } catch (e) { ok = false; }
            if (!ok) { finish(null, 'HTTP'); return; }
            R_apply(P_then, R_apply(RS_text, res, []), [(text) => {
              try { finish(R_apply(J_parse, null, [text]), ''); } catch (e) { finish(null, 'JSON'); }
            }, () => finish(null, 'read')]);
          }, () => finish(null, 'fetch')]);
        } catch (e) { finish(null, 'fetch'); }
        await kwait(() => box.done, 30000);
        if (!box.done) finish(null, 'ChatGPT 網頁沒有回應');
      };
      // 回報連接器與「新增」的結果：自己寫的 JSON（不經 JSON.stringify：它會去查網頁改得到的 toJSON，網頁能換掉回給 App 的結果）。
      const jsonText = (t) => {
        let out = '"';
        for (let i = 0; i < t.length; i += 1) {
          const c = sCode(t, i);
          if (c === 34) out += '\\"';
          else if (c === 92) out += '\\\\';
          else if (c < 32 || c === 0x2028 || c === 0x2029) { let hex = ''; for (let k = 3; k >= 0; k -= 1) hex += HEX[(c >>> (k * 4)) & 15]; out += '\\u' + hex; }
          else out += t[i];
        }
        return out + '"';
      };
      const kjson = (v, depth) => {
        if (v === null || v === undefined) return 'null';
        if (typeof v === 'string') return jsonText(v);
        if (typeof v === 'number') return v === v && v !== 1 / 0 && v !== -1 / 0 ? Str(v) : 'null';
        if (typeof v === 'boolean') return v ? 'true' : 'false';
        if (typeof v !== 'object' || depth > 8) return 'null';
        if (R_apply(A_isArray, null, [v])) {
          let s = '[';
          for (let i = 0; i < v.length; i += 1) s += (i ? ',' : '') + kjson(v[i], depth + 1);
          return s + ']';
        }
        const keys = R_apply(O_keys, null, [v]);
        let s = '{';
        let first = true;
        for (let i = 0; i < keys.length; i += 1) {
          const val = own(v, keys[i]);
          if (val === undefined || typeof val === 'function') continue;
          s += (first ? '' : ',') + jsonText(keys[i]) + ':' + kjson(val, depth + 1);
          first = false;
        }
        return s + '}';
      };
      const postSafe = (o) => { try { report(kjson(o, 0)); } catch (e) {} };
      // ==== SAFE-CHAIN END ====
      // 走安全回報的指令（連接器與「新增 ▾」）。
      const SAFE_COMMANDS = ['connectorScan', 'connectorDevMode', 'connectorAccount', 'connectorAbort', 'connectorNavigated', 'connectorSettings',
        'connectorCreate', 'connectorReconnect', 'connectorPress', 'connectorConsent', 'connectorHighlight', 'connectorHome', 'pluginNewMenu',
        'pluginNewMenuWatch', 'pluginNewMenuAbort', 'connectorGesture', 'connectorOutline', 'connectorTick', 'connectorInspect', 'connectorDelete'];
      const handlers = {
        list: async (c) => {
          const j = await api('/backend-api/conversations?offset=' + (c.offset || 0) + '&limit=' + (c.limit || 50) + '&order=updated');
          if (!j || !Array.isArray(j.items)) throw new Error('讀不到對話清單');
          return { total: j.total, items: j.items.map((i) => ({ id: i.id, title: i.title, update_time: i.update_time })) };
        },
        get: async (c) => {
          if (!Object.keys(modelTitles).length) { try { await handlers.models(); } catch (e) {} }
          const conv = await api('/backend-api/conversation/' + encodeURIComponent(c.conversationID));
          const t = thread(conv, typeof c.branch === 'string' ? c.branch : null);
          const work = isWorkConversation(conv);
          workConversations.set(String(c.conversationID), work);
          return { messages: t.messages, parents: t.parents, leaf: t.leaf, current: t.current, work,
            projectID: conv.gizmo_id || (conv.conversation_mode && conv.conversation_mode.gizmo_id) || null };
        },
        models: async () => {
          // 要中文的檔位名稱與說明（使用者 09-25「調節應中文」）：跟網頁切成繁體中文時一樣帶語言標頭。
          const j = await api('/backend-api/models', { 'oai-language': 'zh-TW', 'accept-language': 'zh-TW,zh;q=0.9' });
          const all = (j.models || []).filter((m) => m && typeof m.slug === 'string' && m.slug);
          // 同名的不同版本（09-24 實機：gpt-5-6、-instant、-thinking 都叫 GPT-5.6 Sol）加上檔位名，回答下方才分得出是哪個回答的。
          const sameTitle = {};
          all.forEach((m) => { const t = m.title || m.slug; sameTitle[t] = (sameTitle[t] || 0) + 1; });
          for (const m of all) {
            const t = m.title || m.slug;
            const variant = VARIANT_LABELS[m.reasoning_type || 'none'];
            modelTitles[m.slug] = sameTitle[t] > 1 && variant ? t + ' ' + variant : t;
            modelReasoning[m.slug] = m.reasoning_type || 'none';
            if (m.is_work_mode_model === true) workModels.add(m.slug);
          }
          const keys = new Set(); all.forEach((m) => Object.keys(m).forEach((k) => keys.add(k)));
          diag['模型欄位'] = [...keys].sort().join('+').slice(0, 300);
          const withEfforts = all.find((m) => effortsOf(m).length);
          diag['推理強度來源'] = withEfforts ? effortSource(withEfforts) : '模型清單沒有推理強度欄位';
          // 模型表只有代號、名稱、旗標與強度標籤（網頁公開的選單資料），沒有使用者內容。
          diag['模型表'] = all.map((m) => [m.slug, m.title, m.is_work_mode_model ? 'W' : '-', m.configurable_thinking_effort ? 'E' : '-',
            m.reasoning_type || '-', (Array.isArray(effortList(m)) ? effortList(m) : []).map((e) => e && typeof e === 'object'
              ? (e.thinking_effort || e.effort || '?') + '=' + (e.short_label || '-') + '/' + (e.full_label || '-') : String(e)).join(',') || '-'].join('|')).join(' ; ').slice(0, 2400);
          // 新版選單（model_picker_version／versions）：只記結構與短標籤，找網頁滑桿的顯示名稱（例如 Extra High）。
          const short = (v) => (typeof v === 'string' ? (v.length <= 32 ? v : 'str') : Array.isArray(v) ? '[' + v.length + ']' : v && typeof v === 'object' ? '{}' : String(v));
          const labelsOf = (arr) => (Array.isArray(arr) ? arr : []).map((x) => (x && typeof x === 'object'
            ? (x.label || x.title || x.name || x.display_name || x.short_label || x.id || x.slug || '?') : String(x))).map((t) => String(t).slice(0, 24)).join('/');
          const describe = (o) => Object.keys(o || {}).map((k) => { const v = o[k];
            return k + '=' + (Array.isArray(v) && v.length && typeof v[0] === 'object' ? '[' + labelsOf(v) + ']' : short(v)); }).join(',');
          diag['選單版本'] = String(j.model_picker_version == null ? '-' : j.model_picker_version);
          diag['選單 versions'] = (Array.isArray(j.versions) ? j.versions.slice(0, 8).map((v) => '{' + describe(v) + '}').join(' ')
            : j.versions && typeof j.versions === 'object' ? Object.keys(j.versions).slice(0, 8).map((k) => k + ':{' + describe(j.versions[k]) + '}').join(' ') : short(j.versions)).slice(0, 1600);
          diag['選單 categories'] = (Array.isArray(j.categories) ? j.categories.slice(0, 8).map((c) => '{' + describe(c) + '}').join(' ') : short(j.categories)).slice(0, 1200);
          // Space 只做 Chat（使用者 09-24）：Work 專用模型不列。
          const chat = all.filter((m) => m.is_work_mode_model !== true);
          const preferred = new Set([j.default_model_slug]);
          (j.categories || []).forEach((c) => { if (c && typeof c.default_model === 'string') preferred.add(c.default_model); });
          // 同名的各版本合成一條強度選項（跟網頁版滑桿一樣）：沒強度的版本＝一個選項，有強度的版本＝每級一個選項。
          const order = [];
          const groups = new Map();
          for (const m of chat) {
            const title = m.title || m.slug;
            if (!groups.has(title)) { groups.set(title, []); order.push(title); }
            groups.get(title).push(m);
          }
          // 新版選單（model_picker_version ≥ 2）：網頁的選單＝版本（Latest／Legacy • 5.6…）× 強度檔位（Instant／Medium／High／Extra High／Pro）。
          const bySlug = new Map(all.map((m) => [m.slug, m]));
          const presetKeys = new Set();
          const enabledVersions = (Array.isArray(j.versions) ? j.versions : []).filter((v) => v && v.enabled !== false);
          // 「最新」那一版：網頁上的名字不帶版本號（High），只有 show_version_in_latest 的（6 Pro）才帶；舊版一律帶（5.6 High）。
          const latestID = (enabledVersions.find((v) => v.id === 'latest') || enabledVersions[0] || {}).id;
          const versions = enabledVersions.map((v) => {
            const variants = (Array.isArray(v.slugs) ? v.slugs : []).map((x) => bySlug.get(x)).filter((m) => m && m.is_work_mode_model !== true);
            const find = (test) => variants.find(test);
            const instant = find((m) => (m.reasoning_type || 'none') === 'none');
            const thinking = find((m) => m.reasoning_type === 'reasoning');
            const pro = find((m) => m.reasoning_type === 'pro');
            const presets = (Array.isArray(v.intelligence_presets) ? v.intelligence_presets : []).map((p) => {
              if (p && typeof p === 'object') Object.keys(p).forEach((k) => presetKeys.add(k));
              const label = String(typeof p === 'string' ? p : (p && (p.label || p.display_text || p.title || p.name || p.id)) || '');
              let slug = p && typeof p === 'object' ? (p.model_slug || p.slug || p.model || null) : null;
              let effort = p && typeof p === 'object' ? (p.thinking_effort || p.effort || p.reasoning_effort || null) : null;
              if (!slug) {
                // 檔位沒寫對應的模型：照名稱對到這個版本的一般／Thinking／Pro 版。
                const l = label.toLowerCase();
                if (/instant/.test(l)) slug = instant && instant.slug;
                else if (/pro/.test(l)) { slug = pro && pro.slug; effort = effort || null; }
                else {
                  slug = thinking && thinking.slug;
                  effort = effort || (/extra/.test(l) ? 'max' : /high/.test(l) ? 'extended' : /medium|standard/.test(l) ? 'standard' : /light|low/.test(l) ? 'min' : null);
                }
              }
              // 面板上方的「6 Pro」＝檔位自己的顯示版本＋顯示名稱；說明（subtitle）帶中文語言標頭時是中文。
              const str = (v) => (typeof v === 'string' ? v : '');
              return slug && label ? { id: slug + (effort ? '|' + effort : ''), title: label, slug, effort,
                version: str(p && p.selected_display_version), level: str(p && p.selected_display_title) || label,
                detail: str(p && (p.subtitle || p.description)),
                // Pro（lane＝pro）是滑桿最高檔：網頁用紫色與星點；版本號要不要顯示照網頁的規則。
                max: !!(p && p.lane === 'pro') || (!(p && p.lane) && !!pro && slug === pro.slug),
                showVersion: v.id !== latestID || !!(p && p.show_version_in_latest === true) } : null;
            }).filter(Boolean);
            return { id: String(v.id || ''), title: String(v.display_text_full || v.display_text || v.id || ''), presets };
          }).filter((v) => v.id && v.presets.length);
          diag['檔位欄位'] = [...presetKeys].sort().join('+') || '（檔位是純文字）';
          diag['檔位對應'] = versions.map((v) => v.id + ':' + v.presets.map((p) => p.title + '=' + p.id).join('/')).join(' ; ').slice(0, 900);
          pickerVersions.length = 0;
          versions.forEach((v) => pickerVersions.push(v));
          modelGroups.clear();
          const models = order.map((title) => {
            const variants = groups.get(title);
            const options = [];
            for (const v of variants) {
              const efforts = v.configurable_thinking_effort === false ? [] : effortsOf(v);
              if (efforts.length) efforts.forEach((e) => options.push({ id: v.slug + '|' + e.id, title: e.title, slug: v.slug, effort: e.id }));
              else options.push({ id: v.slug, title: VARIANT_LABELS[v.reasoning_type || 'none'] || v.title, slug: v.slug, effort: null });
            }
            const seenTitles = new Set();
            const unique = options.filter((o) => (seenTitles.has(o.title) ? false : (seenTitles.add(o.title), true)));
            const main = variants.find((v) => preferred.has(v.slug)) || variants[0];
            modelGroups.set(title, { main: main.slug, options: unique });
            return { slug: main.slug, title, description: main.description,
              efforts: unique.length > 1 ? unique.map((o) => ({ id: o.id, title: o.title })) : [] };
          });
          // 已經出現在版本檔位裡的模型，不再重複列在「其他模型」。
          const covered = new Set();
          versions.forEach((v) => v.presets.forEach((p) => covered.add(p.slug)));
          const others = models.filter((m) => !(groups.get(m.title) || []).some((x) => covered.has(x.slug)));
          // 目前的檔位＝ChatGPT 伺服器記的「上次使用」（網頁、桌面版、手機共用；09-25 讀網頁程式：web 優先，沒有才用 default，
          // 強度一樣 default 之上蓋 web）。Space 沒特別選時就用它，送出也用它，畫面上看到的就是實際用的。
          let current = null;
          try {
            const st = await api('/backend-api/settings/user');
            const set = (st && st.settings) || {};
            const last = set.last_used_model_config || {};
            const slugs = last.slugs || {};
            const slug = slugs.web || slugs.default || null;
            const juices = Object.assign({}, (last.juices || {}).default || {}, (last.juices || {}).web || {});
            const juice = slug && typeof juices[slug] === 'string' ? juices[slug] : null;
            if (slug) {
              for (const v of versions) {
                const hit = v.presets.find((x) => x.slug === slug && (x.effort || null) === juice) || v.presets.find((x) => x.slug === slug && !x.effort);
                if (hit) { current = { version: v.id, preset: hit.id }; break; }
              }
            }
            diag['上次使用'] = (slug || '（沒有）') + (juice ? '｜' + juice : '') + (current ? ' → ' + current.preset : '（選單上沒有）')
              + '；新對話沿用：' + (set.model_sticky_for_new_chats === true ? '是' : '否');
          } catch (e) {
            diag['上次使用'] = '讀不到：' + e.message;
          }
          return { default: j.default_model_slug || null, models: versions.length ? others : models, current,
            versions: versions.map((v) => ({ id: v.id, title: v.title, presets: v.presets.map((p) => ({ id: p.id, title: p.title,
              version: p.version || '', level: p.level || p.title, detail: p.detail || '', max: p.max === true, showVersion: p.showVersion === true })) })) };
        },
        pins: async () => {
          const j = await api('/backend-api/pins');
          const list = Array.isArray(j) ? j : (j && (j.items || j.pins)) || [];
          diag['釘選欄位'] = keysOf(list);
          return { items: list.map(pinOf).filter(Boolean) };
        },
        projects: async () => {
          const list = [], seen = new Set();
          let cursor = null;
          for (let page = 0; page < 100; page++) {
            const j = await api('/backend-api/gizmos/snorlax/sidebar' + (cursor ? '?cursor=' + encodeURIComponent(cursor) : ''));
            if (!j || !Array.isArray(j.items)) throw new Error('讀不到專案清單');
            list.push(...j.items);
            const next = j && j.cursor;
            if (!next) break;
            if (seen.has(next) || page === 99) throw new Error('ChatGPT 專案清單未讀完');
            seen.add(next); cursor = next;
          }
          diag['專案欄位'] = keysOf(list) + '｜' + keysOf(list.map(gizmoOf));
          return { items: list.map(projectOf).filter(Boolean) };
        },
        createProject: async (c) => {
          const name = typeof c.name === 'string' ? c.name.trim() : '';
          const description = typeof c.description === 'string' ? c.description.trim() : '';
          if (!name) throw new Error('建立 ChatGPT 專案需要名稱');
          // 公開網頁 bundle 4813494d-e92j2n507f9wyyhk / ee0c200a-eumdxp2ptugtorgo：
          // 新專案走 projects；description 是 legacy display 欄位，以原生 upsert 補寫。
          // 只在 Pod 內用網頁自己的登入；不把登入標頭帶回 OS。不共享新專案。
          const j = await apiSend('POST', '/backend-api/projects', { name, instructions: '', memory_scope: 'unset' });
          if (j && j.error) throw new Error('ChatGPT 建專案失敗（伺服器拒絕）');
          const created = projectOf(j);
          if (!created || !/^g-p-/.test(created.id)) throw new Error('ChatGPT 建專案失敗：沒有專案 ID');
          if (!description) return created;
          const resource = j.resource, g = resource && resource.gizmo;
          if (!g || !g.display) throw new Error('ChatGPT 建專案失敗：沒有專案資料');
          const saved = await apiSend('POST', '/backend-api/gizmos/snorlax/upsert', {
            gizmo_id: created.id, instructions: g.instructions || '',
            display: Object.assign({}, g.display, { name, description }), tools: [],
            files: (resource.files || []).map((f) => ({ file_id: f.file_id, name: f.name, location: 'fs' })),
            training_disabled: g.training_disabled || false,
            sharing: [{ type: 'private', capabilities: {
              can_read: true, can_view_config: false, can_write: false, can_delete: false, can_export: false, can_share: false
            } }]
          });
          if (saved && saved.error) throw new Error('ChatGPT 專案描述寫入失敗（伺服器拒絕）');
          const project = projectOf(saved);
          if (!project || project.id !== created.id || project.description !== description)
            throw new Error('ChatGPT 專案描述未確認；這句未送出');
          return project;
        },
        projectDetails: async (c) => {
          if (typeof c.projectID !== 'string' || !/^g-p-/.test(c.projectID)) throw new Error('ChatGPT 專案 ID 無效');
          const project = projectOf(await api('/backend-api/gizmos/' + encodeURIComponent(c.projectID)));
          if (!project || project.id !== c.projectID) throw new Error('找不到 ChatGPT 專案');
          return project;
        },
        projectConversations: async (c) => {
          const list = [], seen = new Set();
          let cursor = '0';
          for (let page = 0; page < 100; page++) {
            const j = await api('/backend-api/gizmos/' + encodeURIComponent(c.projectID) + '/conversations?cursor=' + encodeURIComponent(cursor));
            if (!j || !Array.isArray(j.items)) throw new Error('讀不到這個專案的對話');
            list.push(...j.items);
            const next = j && j.cursor;
            if (!next) break;
            if (seen.has(next) || page === 99) throw new Error('ChatGPT 專案對話清單未讀完');
            seen.add(next); cursor = next;
          }
          return { items: list.map((i) => ({ id: i.id, title: i.title, update_time: i.update_time })) };
        },
        rename: async (c) => { await apiSend('PATCH', conversationPath(c.conversationID), { title: String(c.title || '').slice(0, 200) }); return { ok: true }; },
        archive: async (c) => { await apiSend('PATCH', conversationPath(c.conversationID), { is_archived: true }); return { ok: true }; },
        remove: async (c) => { await apiSend('PATCH', conversationPath(c.conversationID), { is_visible: false }); return { ok: true }; },
        search: async (c) => {
          const j = await api('/backend-api/conversations/search?query=' + encodeURIComponent(String(c.query || '').slice(0, 200)) + '&cursor=');
          if (!j || !Array.isArray(j.items)) throw new Error('讀不到搜尋結果');
          const list = j.items;
          diag['搜尋欄位'] = keysOf(list);
          return { items: list.map((i) => ({ id: i.conversation_id || i.id, title: i.title,
            update_time: i.update_time || i.create_time })).filter((i) => typeof i.id === 'string' && i.id) };
        },
        // 取一張圖：先問網頁版用的下載接口；同網域就在這裡抓（要網頁的登入），別的網域把有簽章的網址交給 App 下載。
        // 指標有 file-service://file-XXXX、sediment://file_XXXX、sediment://…#file_XXXX#thumbnail（網頁自己也這樣拆）。
        // 暫時對話沒有對話編號：不帶 conversation_id（09-24 實機：暫時對話裡自己上傳的圖讀不到）。
        image: async (c) => {
          const pointer = String(c.pointer || '');
          const m = /^(?:file-service|sediment):\/\/(.+)$/.exec(pointer);
          if (!m) { diag['圖片'] = '看不懂的圖片指標：' + pointer.split(':')[0]; throw new Error('unsupported image pointer'); }
          // 跟網頁版取檔一樣：去掉前面的 file-service:// 或 sediment://，? 後面的參數照帶，# 換成 *（網頁程式 fUt）。
          const parts = /^(.*?)(\?.*)?$/.exec(m[1]) || [];
          const fileID = String(parts[1] || '').split('#').join('*');
          const shape = pointer.split(':')[0] + (pointer.indexOf('#') >= 0 ? '#' : '') + (pointer.indexOf('?') >= 0 ? '?' : '');
          const conversation = String(c.conversationID || '');
          const attempt = (withConversation) => {
            const q = new URLSearchParams(parts[2] || '');
            if (withConversation && conversation) q.set('conversation_id', conversation);
            q.set('inline', 'false');
            return api('/backend-api/files/download/' + encodeURIComponent(fileID) + '?' + q.toString());
          };
          let j;
          try {
            j = await attempt(true);
          } catch (e) {
            const first = String((e && e.message) || e).slice(0, 30);
            if (!conversation) { diag['圖片'] = '下載接口 ' + first + '（指標 ' + shape + '）'; throw e; }
            // 帶對話編號找不到（例如暫時對話）：再試一次不帶。
            try { j = await attempt(false); diag['圖片'] = '帶對話 ' + first + '，不帶對話才拿到'; }
            catch (e2) { diag['圖片'] = '下載接口 ' + first + '／不帶對話 ' + String((e2 && e2.message) || e2).slice(0, 30) + '（指標 ' + shape + '）'; throw e2; }
          }
          const url = j && (j.download_url || j.url);
          if (typeof url !== 'string' || !url) { diag['圖片'] = '沒有下載網址（' + keysOf([j]) + '）'; throw new Error('no download url'); }
          return fetchBytes(url, '圖片', 15);
        },
        // 資料庫（網頁的 Library，POST /backend-api/files/library）：分頁跟網頁版一樣——建議（ranking=suggested）、圖片、全部。
        library: async (c) => {
          const tab = String(c.tab || 'suggested');
          const body = { limit: 40, cursor: typeof c.cursor === 'string' && c.cursor ? c.cursor : null };
          const q = String(c.query || '').trim().slice(0, 200);
          if (q) body.q = q;
          if (tab === 'suggested') { body.ranking = 'suggested'; body.include_saved_entities = true; }
          if (tab === 'images') body.categories = ['image'];
          let j;
          let filterImages = false;
          try {
            j = await apiSend('POST', '/backend-api/files/library', body);
          } catch (e) {
            diag['資料庫'] = tab + '：' + String((e && e.message) || e).slice(0, 40);
            if (tab !== 'images') throw e;
            // 圖片分類的寫法對不上：拿全部，自己挑圖片。
            delete body.categories;
            j = await apiSend('POST', '/backend-api/files/library', body);
            filterImages = true;
          }
          const list = Array.isArray(j && j.items) ? j.items : [];
          diag['資料庫欄位'] = keysOf(list);
          let items = list.map(libraryItemOf).filter(Boolean);
          if (filterImages) items = items.filter((i) => i.category === 'image');
          diag['資料庫'] = tab + '：' + list.length + ' 筆（可顯示 ' + items.length + '）' + (j && j.cursor ? '，還有下一頁' : '');
          return { items, cursor: j && typeof j.cursor === 'string' ? j.cursor : null };
        },
        // 資料庫檔案的縮圖或原檔：先問網頁版用的網址接口，再照 fetchBytes 的規則取。
        libraryData: async (c) => {
          const id = String(c.itemID || '');
          if (!/^[A-Za-z0-9_-]{4,128}$/.test(id)) throw new Error('bad library id');
          const kind = c.full ? 'content_url' : 'thumbnail_url';
          let j;
          try { j = await api('/backend-api/files/library/files/' + encodeURIComponent(id) + '/' + kind); }
          catch (e) { diag['資料庫檔案'] = kind + ' ' + String((e && e.message) || e).slice(0, 40); throw e; }
          const url = j && (j[kind] || j.url);
          if (typeof url !== 'string' || !url) { diag['資料庫檔案'] = '沒有網址（' + keysOf([j]) + '）'; throw new Error('no url'); }
          return fetchBytes(url, '資料庫檔案', c.full ? 40 : 8);
        },
        tools: async () => {
          const j = await api('/backend-api/system_hints');
          // 讀不到／上游格式變動不是「已移除全部工具」；讓共用目錄保留上一份並可重試。
          const list = j && j.system_hints;
          if (!Array.isArray(list)) throw new Error('讀不到 ChatGPT 的工具清單');
          diag['工具欄位'] = keysOf(list);
          // 網頁的「＋」第一層只放常用工具，其他（連接的 App 等）在下一層：用 hide_from_initial_selection／category 分。
          diag['工具分類'] = list.map((h) => h && (String(h.name || '?').slice(0, 14) + ':' + String(h.system_hint || '?').slice(0, 24)
            + ':' + String(h.category || '-').slice(0, 12) + (h.hide_from_initial_selection ? ':hide' : '')
            + (h.is_connector || h.is_plugin ? ':app' : '') + (h.is_head_plugin ? ':head' : '') + (h.is_connected ? ':on' : ''))).join(', ').slice(0, 1200);
          // 網頁「＋」第一層的名次（網頁程式裡的名次表：生圖 0、搜尋 1、購物 1.6、深入研究 3、筆記 4；Sketch 實機排第 4）。
          // 深入研究在清單裡是連接器（connector:connector_openai_deep_research），網頁仍當工具排第 3。
          // OpenAI 自家的連接器（connector_openai_…：Documents、PDF…）網頁不列在第一層的 App 裡。
          const RANK = { picture_v2: 0, picture: 0, search: 1, shopping: 1.6, research: 3, note: 4, sketch: 4.5 };
          const DEEP = /deep_research/i;
          // 網頁顯示的名稱（名單上叫 Search，網頁寫 Web search）。
          const LABELS = { search: 'Web search' };
          return { items: list.map((h) => {
            const id = h && (h.system_hint || h.id || h.slug);
            const deep = typeof id === 'string' && DEEP.test(id);
            const app = !!(h && (h.is_connector || h.is_plugin)) && !deep;
            const rank = typeof id === 'string' && Object.prototype.hasOwnProperty.call(RANK, id) ? RANK[id] : deep ? 3 : null;
            return { id, title: (typeof id === 'string' && LABELS[id]) || (h && (h.name || h.title || h.label)),
              description: (h && (h.description || h.subtitle)) || '',
              primary: !(h && h.hide_from_initial_selection), hidden: !!(h && h.hide_from_initial_selection),
              rank: app ? null : rank, app, head: !!(h && h.is_head_plugin),
              firstParty: app && typeof id === 'string' && /^connector:connector_openai_/.test(id) };
          }).filter((h) => typeof h.id === 'string' && h.id && typeof h.title === 'string' && h.title) };
        },
        home: async () => {
          const j = await api('/backend-api/prompt_library/?limit=4&offset=0', { 'oai-language': 'zh-TW', 'accept-language': 'zh-TW,zh;q=0.9' });
          const list = (j && j.items) || [];
          diag['首頁建議欄位'] = keysOf(list);
          const text = (v) => (typeof v === 'string' ? v : v && typeof v === 'object' ? (v.text || v.title || v.message || v.content || '') : '');
          if (location.pathname === '/' && !/temporary-chat/.test(location.search)) {
            const h = [...document.querySelectorAll('main h1')].find((x) => !/sr-only/.test(String(x.className || '')) && String(x.textContent || '').trim());
            const t = h && String(h.textContent || '').trim();
            if (t && t.length <= 80) lastHeadline = t;
          }
          const greeting = text(j && j.greeting) || lastHeadline || null;
          const items = list.map((i) => ({ id: String((i && i.id) || ''), title: text(i && i.title) || text(i && i.oneliner) || text(i && i.prompt),
            prompt: text(i && i.prompt) || text(i && i.title) })).filter((i) => i.title);
          diag['首頁建議'] = '問候語：' + typeof (j && j.greeting) + '，建議 ' + items.length + '／' + list.length + ' 筆，title 型別 '
            + [...new Set(list.map((i) => typeof (i && i.title)))].join('/');
          return { greeting, items };
        },
        gpts: async () => {
          const j = await api('/backend-api/gizmos/bootstrap');
          const list = (j && j.gizmos) || [];
          diag['GPTs 欄位'] = keysOf(list) + '｜' + keysOf(list.map(gizmoOf));
          return { items: list.map((it) => { const g = gizmoOf(it); const id = g && g.id; const title = nameOf(g);
            return id && title ? { id, title, kind: 'other' } : null; }).filter(Boolean) };
        },
        // 回答回饋（網頁版的讚／倒讚）。
        feedback: async (c) => {
          const rating = c.rating === 'thumbsDown' ? 'thumbsDown' : 'thumbsUp';
          await apiSend('POST', '/backend-api/conversation/message_feedback',
            { message_id: String(c.messageID || ''), conversation_id: String(c.conversationID || ''), rating });
          diag['回饋'] = '已送出 ' + rating;
          return { ok: true };
        },
        // 探查網頁自己的選單（只打開、記選項名稱、再關掉；不按任何項目）：側欄對話選項、回答的更多、網頁側欄導覽。
        probe: async (c) => {
          const close = async () => {
            try { document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', bubbles: true })); } catch (e) {}
            await sleep(250);
          };
          const menuItems = () => [...document.querySelectorAll('[role="menuitem"], [role="menuitemradio"], [role="menuitemcheckbox"]')]
            .map((x) => String(x.textContent || '').trim().slice(0, 30)).filter(Boolean);
          const out = {};
          if (c.conversationID) await openConversation(String(c.conversationID));
          // 側欄這則對話的按鈕：只記名稱；只按「選項」鈕（09-24 教訓：第一顆是 Pin，直接按下去就釘選了）。
          const row = document.querySelector('a[href$="/c/' + String(c.conversationID || '') + '"]');
          const rowButtons = row ? [...(row.parentElement || row).querySelectorAll('button')] : [];
          out['網頁對話按鈕'] = rowButtons.map((b) => String(b.getAttribute('aria-label') || b.getAttribute('data-testid') || '').slice(0, 40)).join(', ') || '（找不到）';
          const UNSAFE = /^(pin|unpin|delete|archive|share|rename|remove|刪除|封存|分享|釘選)/i;
          const options = rowButtons.find((b) => /option|more|選項|更多/i.test(String(b.getAttribute('aria-label') || '') + String(b.getAttribute('data-testid') || ''))
            && !UNSAFE.test(String(b.getAttribute('aria-label') || '')));
          if (options) { press(options); await sleep(500); out['網頁對話選單'] = menuItems().join(', ') || '（沒打開）'; await close(); }
          else out['網頁對話選單'] = '（沒有選項鈕，沒按任何東西）';
          // 最後一個回答的「More actions」。
          const nodes = assistantNodes();
          let scope = nodes[nodes.length - 1] || null;
          for (let i = 0; i < 8 && scope && scope.parentElement; i++) { scope = scope.parentElement; if (scope.querySelectorAll('button').length >= 3) break; }
          const more = scope && [...scope.querySelectorAll('button')].find((b) => /more actions|更多/i.test(String(b.getAttribute('aria-label') || '')));
          if (more) { press(more); await sleep(500); out['回答更多選單'] = menuItems().join(', ') || '（沒打開）'; await close(); }
          // 使用者訊息的按鈕（編輯等）。
          const users = document.querySelectorAll('[data-message-author-role="user"]');
          let uscope = users[users.length - 1] || null;
          for (let i = 0; i < 6 && uscope && uscope.parentElement; i++) { uscope = uscope.parentElement; if (uscope.querySelectorAll('button').length >= 2) break; }
          out['使用者訊息按鈕'] = uscope ? [...uscope.querySelectorAll('button')].map((b) => safeLabel(b.getAttribute('aria-label') || b.getAttribute('data-testid') || '')).filter(Boolean).join(', ') : '（找不到）';
          // 網頁側欄導覽（Library、Scheduled…）的連結。
          // 只回報固定的路由分類，不回報完整網址、參數或名稱（審查 #2：自訂 GPT 名稱、查詢參數可能是私人資料）。
          const ROUTES = new Set(['library', 'gpts', 'plugins', 'apps', 'sites', 'scheduled', 'tasks', 'images', 'projects', 'codex', 'sora', 'search', 'settings', 'project', 'c']);
          const routeOf = (h) => {
            try {
              const u = new URL(h, location.href);
              if (u.host !== location.host) return 'external';
              const seg = u.pathname.split('/').filter(Boolean);
              if (!seg.length) return '/';
              if (seg[0] === 'g') return '/g/' + (/^g-p-/.test(seg[1] || '') ? '<project>' : '<gpt>') + (seg[2] ? '/' + (ROUTES.has(seg[2]) ? seg[2] : '<other>') : '');
              return '/' + (ROUTES.has(seg[0]) ? seg[0] : '<other>');
            } catch (e) { return '?'; }
          };
          out['網頁導覽'] = [...new Set([...document.querySelectorAll('nav a[href]')].map((a) => a.getAttribute('href')).filter((h) => h && !/\/c\//.test(h)).map(routeOf))].slice(0, 20).join(', ');
          // 相簿頁用到哪些接口：開一下 /library，記下期間的後台請求路徑（去編號），再回來。
          if (c.library) {
            libraryWatch = [];
            history.pushState({}, '', '/library');
            window.dispatchEvent(new PopStateEvent('popstate', { state: {} }));
            await sleep(4000);
            out['相簿接口'] = [...new Set(libraryWatch)].join(', ').slice(0, 600) || '（沒有看到請求）';
            libraryWatch = null;
            history.pushState({}, '', '/');
            window.dispatchEvent(new PopStateEvent('popstate', { state: {} }));
            await sleep(800);
          }
          Object.assign(diag, out);
          return out;
        },
        // 釘選／取消釘選：按網頁側欄那則對話上的 Pin／Unpin（網頁版就是這顆鈕）。
        pin: async (c) => {
          const row = document.querySelector('a[href$="/c/' + String(c.conversationID || '') + '"]');
          const want = c.pinned === true ? /^pin\b/i : /^unpin\b/i;
          const button = row && [...(row.parentElement || row).querySelectorAll('button')]
            .find((b) => want.test(String(b.getAttribute('aria-label') || '')));
          diag['釘選'] = button ? '按了 ' + String(button.getAttribute('aria-label') || '').split(' ')[0] : '找不到 ' + (c.pinned ? 'Pin' : 'Unpin') + ' 鈕';
          if (!button) throw new Error('找不到網頁的' + (c.pinned ? '釘選' : '取消釘選') + '鈕');
          press(button);
          await sleep(600);
          return { ok: true };
        },
        // 在新對話分支（網頁 More actions → Branch in new chat）；回傳新對話的編號。
        branch: async (c) => {
          if (!(await openConversation(String(c.conversationID || '')))) throw new Error('沒有開到這則對話');
          const nodes = assistantNodes();
          let scope = nodes[nodes.length - 1] || null;
          for (let i = 0; i < 8 && scope && scope.parentElement; i++) { scope = scope.parentElement; if (scope.querySelectorAll('button').length >= 3) break; }
          const more = scope && [...scope.querySelectorAll('button')].find((b) => /more actions|更多/i.test(String(b.getAttribute('aria-label') || '')));
          if (!more) throw new Error('找不到 More actions');
          press(more);
          const item = await waitFor(() => [...document.querySelectorAll('[role="menuitem"]')].find((x) => /branch|分支/i.test(String(x.textContent || ''))), 2000);
          if (!item) { try { document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); } catch (e) {} throw new Error('選單裡沒有 Branch'); }
          const before = location.pathname;
          press(item);
          const moved = await waitFor(() => location.pathname !== before && conversationFromURL(), 10000);
          diag['分支'] = moved ? '已開新分支' : '按了但網址沒變';
          if (!moved) throw new Error('分支沒有開成');
          return { conversationID: conversationFromURL() };
        },
        // 分享（網頁的 Share chat／使用者訊息的 Share prompt）：按網頁自己的分享鈕，連結由網頁建立；有的版本會跳出視窗再按「建立／拷貝連結」。
        share: async (c) => {
          if (!(await openConversation(String(c.conversationID || '')))) throw new Error('沒有開到這則對話');
          shareCapture.url = null;
          shareCapture.active = true;
          try {
            let button = null;
            const labelOf = (b) => String(b.getAttribute('aria-label') || '') + ' ' + String(b.getAttribute('data-testid') || '');
            if (c.messageID) {
              const node = document.querySelector('[data-message-id="' + String(c.messageID).replace(/[^A-Za-z0-9_-]/g, '') + '"]');
              let scope = node;
              for (let i = 0; i < 6 && scope && scope.parentElement; i++) { scope = scope.parentElement; if (scope.querySelectorAll('button').length >= 2) break; }
              button = scope && [...scope.querySelectorAll('button')].find((b) => /share/i.test(labelOf(b)));
            } else {
              button = [...document.querySelectorAll('button')].find((b) => /share chat|share-chat|^\s*share\s*$/i.test(labelOf(b)));
            }
            diag['分享'] = button ? '找到：' + labelOf(button).trim().slice(0, 30) : '找不到分享鈕';
            if (!button) throw new Error('找不到 ChatGPT 的分享鈕');
            press(button);
            let link = await waitFor(() => shareCapture.url, 5000);
            if (!link) {
              const item = await waitFor(() => [...document.querySelectorAll('button, [role="menuitem"]')]
                .find((b) => /create link|copy link|建立連結|拷貝連結|複製連結/i.test(String(b.textContent || '') + ' ' + labelOf(b))), 4000);
              if (item) { press(item); link = await waitFor(() => shareCapture.url, 15000); }
            }
            try { document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', bubbles: true })); } catch (e) {}
            diag['分享'] += link ? '，拿到連結' : '，沒拿到連結';
            if (!link) throw new Error('ChatGPT 沒有給分享連結');
            return { url: link };
          } finally {
            shareCapture.active = false;
          }
        },
        // 停止分享（09-25 讀網頁程式＋實機）：對話分享（/share/<編號>）＝網頁「已分享的連結」的垃圾桶：DELETE /share/{編號}
        // （只 PATCH 成不公開沒有用，公開頁照樣打得開）；新式貼文（/s/<編號>）＝DELETE /share/post/{編號}。
        // 刪完用不帶登入的請求打開公開頁確認：刪掉的頁面仍回 200，但標題不再是「ChatGPT - 對話標題」。
        shareDelete: async (c) => {
          const id = String(c.shareID || '');
          if (!/^[A-Za-z0-9_-]{4,128}$/.test(id)) throw new Error('bad share id');
          const kind = c.kind === 'share' ? 'share' : 's';
          const errors = [];
          const attempt = async (method, path, body) => {
            try { await apiSend(method, path, body); return true; } catch (e) { errors.push(method + ' ' + e.message); return false; }
          };
          let done = kind === 'share' ? await attempt('DELETE', '/backend-api/share/' + encodeURIComponent(id)) : false;
          if (!done && kind === 'share') done = await attempt('PATCH', '/backend-api/share/' + encodeURIComponent(id), { is_public: false, is_visible: false });
          if (!done) done = await attempt('DELETE', '/backend-api/share/post/' + encodeURIComponent(id));
          let gone = null;
          try {
            const page = await originalFetch('/' + kind + '/' + encodeURIComponent(id), { credentials: 'omit', cache: 'no-store' });
            const html = page.status === 200 ? await page.text() : '';
            gone = page.status === 404 || page.status === 410 || (page.status === 200 && !/<title>\s*ChatGPT\s*-\s*[^<]/i.test(html));
          } catch (e) {}
          diag['分享'] = (done ? '已送出停止分享' : '停止分享失敗：' + errors.join('；')) + (gone === null ? '' : gone ? '，公開頁已打不開' : '，公開頁還打得開');
          if (!done) throw new Error(errors.join('；'));
          return { ok: true, gone };
        },
        // 排程（網頁的 Scheduled）：GET /automations；開關 set_status；刪除 remove。
        automations: async () => {
          const j = await api('/backend-api/automations');
          const list = Array.isArray(j) ? j : (j && (j.items || j.automations || j.data)) || [];
          diag['排程欄位'] = keysOf(list);
          return { items: list.map((a) => a && typeof a === 'object' ? {
            id: String(a.id || a.automation_id || a.jawbone_id || ''), title: String(a.title || a.name || ''),
            prompt: typeof a.prompt === 'string' ? a.prompt.slice(0, 600) : '',
            schedule: typeof a.schedule === 'string' ? a.schedule.slice(0, 400) : String(a.schedule_description || a.schedule_text || ''),
            enabled: a.is_enabled !== false && a.status !== 'disabled' && a.status !== 'paused',
            next: (Array.isArray(a.next_run_times) && a.next_run_times[0]) || a.next_run_time || a.next_run_at || a.next_scheduled_time || null,
            conversationID: typeof a.conversation_id === 'string' ? a.conversation_id : null,
            // 網頁的判斷（09-25 讀網頁程式）：不是本機執行、不是條件監控、又沒有下一次＝已完成。
            display: typeof a.display_schedule === 'string' ? a.display_schedule.slice(0, 120) : '',
            completed: a.executor !== 'local' && a.timing_mode !== 'condition_watch' && Array.isArray(a.next_run_times) && a.next_run_times.length === 0,
            watching: a.timing_mode === 'condition_watch' } : null).filter((a) => a && a.id) };
        },
        // 注意：c.id 是這個請求自己的編號；項目編號用專用欄位（automationID…）。
        automationStatus: async (c) => { await apiSend('POST', '/backend-api/automations/set_status', { jawbone_id: String(c.automationID || ''), is_enabled: c.enabled === true }); return { ok: true }; },
        automationRemove: async (c) => { await apiSend('POST', '/backend-api/automations/remove', { automation_id: String(c.automationID || '') }); return { ok: true }; },
        // 外掛（網頁的 Plugins）：外掛服務在 /backend-api/ps/（09-25 從網頁快取的請求網址確認；少了 ps 讀不到）。
        // 已安裝＝/ps/plugins/installed（名字、圖示在 release 裡）；目錄＝/ps/plugins/home 的各分類（精選、新上架…）。
        plugins: async () => {
          const zh = { 'oai-language': 'zh-TW', 'accept-language': 'zh-TW,zh;q=0.9' };
          const pluginOf = (p) => {
            const q = (p && typeof p === 'object' && (p.plugin || p)) || {};
            const release = q.release && typeof q.release === 'object' ? q.release : {};
            const face = release.interface && typeof release.interface === 'object' ? release.interface
              : q.interface && typeof q.interface === 'object' ? q.interface : {};
            const id = q.id;
            const name = release.display_name || q.display_name || face.display_name || q.name;
            const icon = q.icon_url || face.logo_url || face.composer_icon_url || face.logo || face.icon || null;
            if (typeof id !== 'string' || !id || typeof name !== 'string' || !name) return null;
            return { id, name: name.slice(0, 80),
              description: String(face.short_description || q.short_description || release.description || q.description || '').slice(0, 200),
              enabled: q.enabled !== false, icon: typeof icon === 'string' && /^https:/.test(icon) ? icon : null, installed: false };
          };
          const errors = [];
          const installedRaw = [];
          let token = null;
          for (let page = 0; page < 5; page++) {
            const j = await api('/backend-api/ps/plugins/installed?limit=1000' + (token ? '&pageToken=' + encodeURIComponent(token) : ''), zh)
              .catch((e) => { errors.push('已安裝 ' + e.message); return null; });
            if (!j) break;
            if (Array.isArray(j.plugins)) installedRaw.push(...j.plugins);
            token = j.pagination && typeof j.pagination.next_page_token === 'string' && j.pagination.next_page_token ? j.pagination.next_page_token : null;
            if (!token) break;
          }
          const installed = installedRaw.map(pluginOf).filter(Boolean).map((p) => Object.assign(p, { installed: true }));
          const mine = new Map(installed.map((p) => [p.id, p]));
          const home = await api('/backend-api/ps/plugins/home', zh).catch((e) => { errors.push('目錄 ' + e.message); return null; });
          const sections = (home && Array.isArray(home.sections) ? home.sections : []).map((sec) => ({
            id: String((sec && (sec.id || sec.url_slug)) || ''), title: String((sec && sec.title) || ''),
            plugins: (sec && Array.isArray(sec.plugins) ? sec.plugins : []).map(pluginOf).filter(Boolean)
              .map((p) => mine.has(p.id) ? Object.assign(p, { installed: true, enabled: mine.get(p.id).enabled }) : p) }))
            .filter((sec) => sec.id && sec.title && sec.plugins.length);
          diag['外掛'] = '已安裝 ' + installed.length + '／' + installedRaw.length + '，分類 ' + sections.length + (errors.length ? '；' + errors.join('；') : '');
          diag['外掛欄位'] = keysOf(installedRaw) + '｜' + keysOf(sections.length && home ? (home.sections[0].plugins || []) : []);
          // 兩個都讀不到才算失敗（畫面顯示原因）；讀到一個就照常顯示。
          if (!installedRaw.length && !sections.length && errors.length) throw new Error(errors.join('；'));
          return { installed, sections };
        },
        // 外掛詳細頁（網頁 /plugins/<編號>，09-25 使用者「mcp的部分無法點擊進去」）：GET /ps/plugins/{編號}；
        // 有連接器時再讀它的工具（GET /aip/connectors/{連接器}/actions），讀取／寫入照網頁的分法：
        // is_read_only 或 is_consequential === false ＝讀取，其他＝寫入；停用的、私人的、同名的不列。
        pluginDetail: async (c) => {
          const id = String(c.pluginID || '');
          if (!/^[A-Za-z0-9_.:-]{2,200}$/.test(id)) throw new Error('bad plugin id');
          const zh = { 'oai-language': 'zh-TW', 'accept-language': 'zh-TW,zh;q=0.9' };
          const p = await api('/backend-api/ps/plugins/' + encodeURIComponent(id), zh);
          const release = (p && p.release) || {};
          const face = (release && release.interface) || {};
          const str = (v, n) => (typeof v === 'string' ? v.slice(0, n) : '');
          const https = (v) => (typeof v === 'string' && /^https:\/\//.test(v) ? v : null);
          const list = (v) => (Array.isArray(v) ? v : []);
          const detail = {
            id, name: str(release.display_name || (p && p.name), 120), developer: str(face.developer_name || (p && p.creator_name), 120),
            category: str(face.category, 80), summary: str(face.short_description || release.description, 500),
            about: str(face.long_description, 4000),
            capabilities: list(face.capabilities).filter((x) => typeof x === 'string').map((x) => x.slice(0, 60)).slice(0, 12),
            prompts: list(face.default_prompts).filter((x) => typeof x === 'string').map((x) => x.slice(0, 300)).slice(0, 6),
            website: https(face.website_url), privacy: https(face.privacy_policy_url), terms: https(face.terms_of_service_url),
            icon: https(face.logo_url), screenshots: list(face.screenshot_urls).map(https).filter(Boolean).slice(0, 6),
            skills: list(release.skills).map((k) => (k && typeof k === 'object' ? {
              name: str((k.interface && k.interface.display_name) || k.name, 120),
              description: str((k.interface && k.interface.short_description) || k.description, 500) } : null)).filter((k) => k && k.name).slice(0, 80),
            tools: [], tools_state: 'none' };
          const connector = p && typeof p.connector_id === 'string' && /^[A-Za-z0-9_.:-]{2,200}$/.test(p.connector_id) ? p.connector_id : null;
          if (connector) {
            try {
              const j = await api('/backend-api/aip/connectors/' + encodeURIComponent(connector) + '/actions', zh);
              const seen = new Set();
              detail.tools = list(j && j.actions)
                .filter((a) => a && typeof a.name === 'string' && a.name && a.is_enabled !== false && a.visibility !== 'private' && !seen.has(a.name) && seen.add(a.name))
                .map((a) => {
                  const read = a.is_read_only === true || a.is_consequential === false;
                  return { name: a.name.slice(0, 120), description: str(a.description, 500), read, destructive: !read && a.is_destructive === true };
                }).slice(0, 300);
              detail.tools_state = 'ok';
            } catch (e) {
              detail.tools_state = 'failed';
              diag['外掛工具'] = e.message;
            }
          }
          diag['外掛詳細'] = '技能 ' + detail.skills.length + '，工具 ' + detail.tools.length + '（' + detail.tools_state + '）';
          return detail;
        },
        // 安裝／解除安裝／啟用（網頁沒有「停用」：要停就解除安裝）；外掛服務在 /ps/，舊路徑留作備援。
        pluginAction: async (c) => {
          const action = { install: 'install', uninstall: 'uninstall', enable: 'enable' }[String(c.action || '')];
          if (!action) throw new Error('bad plugin action');
          const id = encodeURIComponent(String(c.pluginID || ''));
          let j;
          try {
            j = await apiSend('POST', '/backend-api/ps/plugins/' + id + '/' + action);
          } catch (e) {
            if (!/HTTP 404/.test(String(e && e.message))) throw e;
            j = await apiSend('POST', '/backend-api/plugins/' + id + '/' + action);
          }
          diag['外掛動作'] = action + '：' + keysOf([j]);
          // 需要登入那個 App（OAuth）時，網頁會給一個網址；交給 App 用網頁版打開。
          const auth = j && (j.oauth_url || j.authorization_url || j.redirect_url || j.url);
          return { ok: true, authURL: typeof auth === 'string' && /^https:/.test(auth) ? auth : null };
        },
        // 網站（網頁的 Sites）：GET /websites；網址用 preferred_live_url。
        sites: async () => {
          const j = await api('/backend-api/websites');
          const list = Array.isArray(j) ? j : (j && (j.items || j.websites || j.projects || j.sites || j.data)) || [];
          diag['網站欄位'] = keysOf(list);
          return { items: list.map((w) => w && typeof w === 'object' ? { id: String(w.id || w.project_id || ''), name: String(w.name || w.title || w.subdomain || ''),
            url: typeof (w.live_url || w.preferred_live_url || w.url) === 'string' ? (w.live_url || w.preferred_live_url || w.url) : null,
            updated: w.updated_at || w.last_published_at || w.published_at || w.created_at || null, status: String(w.status || w.publish_status || '') } : null)
            .filter((w) => w && w.id) };
        },
        siteURL: async (c) => {
          const j = await api('/backend-api/websites/' + encodeURIComponent(String(c.siteID || '')) + '/preferred_live_url');
          const url = j && (j.url || j.preferred_live_url || j.live_url);
          return { url: typeof url === 'string' ? url : null };
        },
        // 記憶與自訂指令（網頁的 Personalization）。
        memories: async () => {
          const j = await api('/backend-api/memories?include_memory_entries=true');
          const list = (j && j.memories) || [];
          diag['記憶欄位'] = keysOf(list);
          return { items: list.map((m) => m && typeof m === 'object' ? { id: String(m.id || ''), text: String(m.content || m.text || ''),
            updated: m.updated_at || m.last_updated || m.created_at || null } : null).filter((m) => m && m.id),
            usage: j && j.memory_max_tokens ? Math.min(100, Math.floor(100 * (j.memory_num_tokens || 0) / j.memory_max_tokens)) : null };
        },
        memoryDelete: async (c) => { await apiSend('DELETE', '/backend-api/memories/' + encodeURIComponent(String(c.memoryID || ''))); return { ok: true }; },
        memoryClear: async () => { await apiSend('DELETE', '/backend-api/settings/clear_account_user_memory'); return { ok: true }; },
        instructions: async () => {
          const j = await api('/backend-api/user_system_messages');
          diag['自訂指令欄位'] = keysOf([j]);
          const str = (v) => (typeof v === 'string' ? v : '');
          return { enabled: !(j && j.enabled === false), nickname: str(j && j.name_user_message), occupation: str(j && j.role_user_message),
            traits: str(j && (j.traits_model_message || j.about_model_message)), about: str(j && (j.other_user_message || j.about_user_message)) };
        },
        saveInstructions: async (c) => {
          const str = (v) => String(v || '').slice(0, 3000);
          await apiSend('PATCH', '/backend-api/user_system_messages', { enabled: c.enabled !== false, name_user_message: str(c.nickname),
            role_user_message: str(c.occupation), traits_model_message: str(c.traits), other_user_message: str(c.about),
            about_model_message: str(c.traits), about_user_message: str(c.about) });
          return { ok: true };
        },
        // 帳號（左下角）：名字、信箱、方案；只回這幾樣。
        account: async () => {
          const me = await api('/backend-api/me');
          let plan = null;
          let personal = true;
          let workspace = null;
          try {
            const a = await api('/backend-api/accounts/check/v4-2023-04-27');
            const order = (a && a.account_ordering) || [];
            const acc = a && a.accounts && (a.accounts[order[0]] || a.accounts.default);
            plan = (acc && acc.account && (acc.account.plan_type || acc.account.subscription_plan)) || null;
            personal = !(acc && acc.account && acc.account.structure && acc.account.structure !== 'personal');
            workspace = acc && acc.account && !personal ? acc.account : null;
          } catch (e) {}
          // 網頁左下角（09-25 讀網頁程式）：個人帳號顯示 ChatGPT 個人檔案的名字（/calpico/chatgpt/profile/<登入編號>），
          // 讀不到才用登入名字；工作區帳號顯示工作區名字與圖示。
          let profile = null;
          if (personal && me && typeof me.id === 'string' && me.id) {
            try { profile = await api('/backend-api/calpico/chatgpt/profile/' + encodeURIComponent(me.id)); } catch (e) {}
          }
          const profileName = profile && typeof profile.display_name === 'string' ? profile.display_name.trim() : '';
          const name = profileName || (workspace && typeof workspace.name === 'string' && workspace.name) || (me && (me.name || me.display_name)) || '';
          const picture = (profile && profile.profile_picture_url) || (workspace && workspace.profile_picture_url) || null;
          diag['帳號'] = (personal ? '個人' : '工作區') + '，個人檔案' + (profile ? '有' : '沒有') + '，名字取自' + (profileName ? '個人檔案' : '登入資料')
            + '，大頭貼' + (picture ? '有' : '沒有');
          return { name: String(name), email: String((me && me.email) || ''),
            picture: typeof picture === 'string' && /^https:/.test(picture) ? picture : null, plan: typeof plan === 'string' ? plan : null };
        },
        // 資料庫刪除（跟網頁一樣移到資料庫的垃圾桶，可還原）。
        libraryDelete: async (c) => {
          const id = String(c.itemID || '');
          if (!/^[A-Za-z0-9_-]{4,128}$/.test(id)) throw new Error('bad library id');
          await apiSend('DELETE', '/backend-api/files/library/files/' + encodeURIComponent(id));
          return { ok: true };
        },
        // 即時語音（網頁的語音模式）：聲音要在網頁裡跑，App 蓋原生畫面；開始＝按網頁的 Start Voice，結束＝End voice mode。
        voice: async (c) => {
          const endButton = voiceEndButton;
          if (c.stop) {
            voiceEpoch += 1;
            const end = endButton();
            if (end) press(end);
            diag['語音'] = end ? '已按結束' : '找不到結束鈕';
            // 還在等麥克風權限時按了結束：之後 60 秒內若變成語音中就自動結束，不讓麥克風在背景開著（09-25 實機）。
            // 保險一直守到下次開語音（不設時限；審查 #13：之後才按了麥克風「允許」也一樣會被關掉）。
            voiceStopAt = Date.now();
            if (!voiceGuard) voiceGuard = setInterval(() => {
              const e = endButton();
              if (e) { press(e); diag['語音'] = '結束後才開始，已自動結束'; }
            }, 1000);
            return { live: false, conversationID: conversationFromURL() };
          }
          const epoch = ++voiceEpoch;
          if (voiceGuard) { clearInterval(voiceGuard); voiceGuard = null; }
          if (!(await openConversation(c.conversationID ? String(c.conversationID) : null))) throw new Error('沒有開到對話');
          if (!c.conversationID) await ensureChatMode();
          if (epoch !== voiceEpoch) throw new Error('語音已取消');
          // 網頁輸入框有字時，語音鈕（composer-speech-button）會換成送出鍵（09-25 實機：找不到語音鈕）。先清空再找。
          const box = composer();
          const hadText = !!(box && String(box.innerText || box.value || '').trim());
          if (hadText) {
            box.focus();
            document.execCommand('selectAll', false);
            document.execCommand('delete', false);
          }
          const start = await waitFor(() => {
            const speech = document.querySelector('[data-testid="composer-speech-button"]');
            return epoch !== voiceEpoch || (voiceUsable(speech) ? speech : null) || [...document.querySelectorAll('button')].find((b) => {
              const l = String(b.getAttribute('aria-label') || '');
              return voiceUsable(b) && /start voice|voice mode|開始語音|开始语音/i.test(l) && !/end voice|結束|结束/i.test(l);
            });
          }, 4000);
          if (epoch !== voiceEpoch) throw new Error('語音已取消');
          diag['語音輸入框'] = hadText ? '原本有字，已清空' : '原本是空的';
          diag['語音'] = start ? '找到：' + String(start.getAttribute('aria-label') || start.getAttribute('data-testid') || '').slice(0, 30) : '找不到語音鈕';
          if (!start) throw new Error('找不到 ChatGPT 的語音模式鈕');
          press(start);
          const live = await waitFor(() => epoch !== voiceEpoch || !!endButton(), 8000);
          if (epoch !== voiceEpoch) throw new Error('語音已取消');
          if (!live) throw new Error('網頁沒有進入語音模式，請確認網站及麥克風權限');
          diag['語音'] += live ? '，已開始' : '，還沒進入語音模式（可能在等麥克風權限）';
          return { live: !!live, conversationID: conversationFromURL() };
        },
        // 網頁版小視窗（設定、外掛授權、網站管理）：切到指定的頁；外部網址（授權頁）整頁換過去，回到 chatgpt.com 時腳本會再注入。
        navigate: async (c) => {
          const raw = String(c.url || '/');
          if (/^https:\/\//i.test(raw) && !/^https:\/\/chatgpt\.com(\/|$)/i.test(raw)) {
            setTimeout(() => { location.href = raw; }, 60);
            return { ok: true };
          }
          const path = raw.replace(/^https:\/\/chatgpt\.com/i, '') || '/';
          const hash = /#(.*)$/.exec(path);
          const bare = path.replace(/#.*$/, '') || '/';
          if (location.pathname !== bare) {
            history.pushState({}, '', bare);
            window.dispatchEvent(new PopStateEvent('popstate', { state: {} }));
          }
          if (hash) location.hash = hash[1];
          else if (location.hash) history.replaceState({}, '', bare);
          return { ok: true };
        },
        voiceState: async () => ({ live: !!voiceEndButton(),
          conversationID: conversationFromURL() }),
        diagnostics: async () => {
          diag['原生臨時模式'] = nativeTemporaryUI().mode;
          diag['個人化目前頁面'] = personalizedPrepareDiagnostic('current', personalizedPrepareSnapshot());
          try { diag['個人化目前路由'] = routeShapeDiagnostic('current', location.pathname); } catch (e) {}
          if (!diag['個人化續聊證據']) personalizedDiagnostic('idle');
          return diag;
        },
        // W183 R6b：連接器（見上面 connector 的說明）。
        // ==== SAFE-CHAIN BEGIN：連接器與「新增 ▾」的指令（只用工具箱與上面的安全判斷；參數只讀自己的屬性） ====
        // W183 R6b：連接器（見上面 connector 的說明）。
        connectorScan: async (c) => {
          if (!KIT_OK) return { loggedIn: !!auth, listKnown: false, devMode: null, matches: [] };
          const live = connectorStep();
          const url = connectorURL(own(c, 'url'));
          const loggedIn = !!auth || !safeAll(document, '[data-testid="login-button"]').length;
          if (!loggedIn) return { loggedIn: false, listKnown: false, devMode: null, matches: [] };
          // 已經在外掛頁（例如使用者剛看完警語、表單還開著）就不換頁，免得把表單關掉。
          if (!createdSection() && sIdx(location.pathname, '/plugins', 0) !== 0) {
            if (!live()) return ABORTED;
            await kroute(bag(), '/plugins', () => sIdx(location.pathname, '/plugins', 0) === 0);
            await ksleep(300);
          }
          let listKnown = false;
          const matches = [];
          const conflicts = [];
          const got = bag();
          await kfetchInto(got, '/backend-api/ps/plugins/installed');
          if (got.done && !got.error) {
            const j = got.data;
            const list = listOf(j);
            listKnown = !!list && !pagedList(j, list) && aEvery(list, (x) => isObj(x) && !R_apply(A_isArray, null, [x]));
            if (!listKnown) diag['連接器清單'] = '看不懂清單的樣子（當成不知道）';
            connectorMatches(list || j, url, matches, [], conflicts);
          } else {
            diag['連接器清單'] = sSlice(sOf(got.error), 0, 60);
          }
          const section = await openCreatedSection(live);
          const links = completeCreatedList(section);
          listKnown = listKnown && links !== null;
          if (links) {
            for (let i = 0; i < links.length; i += 1) {
              const link = links[i];
              if (!live()) return ABORTED;
              // Read every TATWO detail, including namesakes on another server.
              if (connectorName(link.name) !== link.name) continue;
              const routed = bag();
              await kroute(routed, link.detailPath, () => sOf(location.pathname) === link.detailPath);
              await kwait(() => visibleOf(document, 'h1, h2, h3, [role="heading"]').length > 0 || !live(), 3000);
              const boxes = visibleOf(document, '[role="dialog"], dialog, main, [role="main"]');
              const root = aFind(boxes, (box) => detailIdentity(box, link.id, link.detailPath) !== null);
              const record = routed.ok && root ? detailIdentity(root, link.id, link.detailPath) : null;
              if (!record || record.name !== link.name) { listKnown = false; continue; }
              if (record.serverURL === url) listAdd(matches, record);
              else listAdd(conflicts, record.name);
            }
          }
          if (!matches.length && hasURLToken(safeText(safeBody()), url)) listAdd(matches, { id: null, name: '', auth: 'unknown', serverURL: url });
          const unique = [];
          for (let i = 0; i < matches.length; i += 1) {
            const m = matches[i];
            let found = -1;
            for (let j = 0; j < unique.length; j += 1) { if (m.id && unique[j].id === m.id) { found = j; break; } }
            // Replace an owned array slot: never invoke an inherited metadata setter.
            if (found >= 0) unique[found] = m;
            else listAdd(unique, m);
          }
          if (unique.length > 256) return { loggedIn: true, listKnown: false, devMode: null, matches: [] };
          return { loggedIn: true, listKnown, devMode: devModeState(), matches: unique, conflictingNames: conflicts };
        },
        connectorDevMode: async () => (KIT_OK ? { devMode: devModeState() } : { devMode: null }),
        // 帳號身分（只給 App 比對：登入編號、工作區、信箱）。
        connectorAccount: async () => {
          if (!KIT_OK) return UNSAFE;
          const me = bag();
          await kfetchInto(me, '/backend-api/me');
          if (!me.done || me.error) throw new Error(me.error || 'ChatGPT 網頁沒有回應');
          let workspace = null;
          const acc = bag();
          await kfetchInto(acc, '/backend-api/accounts/check/v4-2023-04-27');
          if (acc.done && !acc.error) {
            const order = own(acc.data, 'account_ordering');
            const first = R_apply(A_isArray, null, [order]) ? order[0] : null;
            workspace = typeof first === 'string' ? sSlice(first, 0, 120) : null;
          }
          const id = own(me.data, 'id');
          const email = own(me.data, 'email');
          return { user: typeof id === 'string' ? sSlice(id, 0, 120) : null, workspace, email: sSlice(sOf(email), 0, 200) };
        },
        // W183 R9 審查（GPT-6 N4）：真的取消（App 放掉獨占前送）＝這之前登記的表單紀錄全部永久作廢；正常的［繼續］不會送這個。
        connectorAbort: async () => {
          connectorGen += 1;
          connectorEpoch += 1;
          approvedConsent = '';   // W183 R12：取消＝同意過的那一份也不留
          clearGesture();   // W183 R12：取消＝指路的亮框也拿掉
          for (const mark in ownForms) voidRecord(mark, 'aborted');
          return { ok: true };
        },
        // W183 R9c（GPT-6 C3）：原生（CEF）看到主框架的網址換了（含同一份文件裡的導頁）：那一個路徑跟登記時不一樣的紀錄永久作廢
        // （就算這個指令到的時候網頁已經回到原來的路徑）。
        connectorNavigated: async (c) => {
          const path = own(c, 'path');
          if (typeof path === 'string' && path.length > 0 && path.length <= 2048) pathSeen(path, 'native');
          return { ok: true };
        },
        connectorSettings: async () => {
          if (!KIT_OK) return UNSAFE;
          const live = connectorStep();
          if (!live()) return ABORTED;
          if (sOf(location.pathname) !== '/') {
            R_apply(H_push, HIST, [{}, '', '/']);
            dDispatch(window, new C_PopState('popstate', { state: {} }));
          }
          location.hash = 'settings';
          return { ok: true };
        },
        connectorCreate: async (c) => {
          if (!KIT_OK) return UNSAFE;
          const live = connectorStep();
          const url = connectorURL(own(c, 'url'));
          const wantName = connectorName(own(c, 'name'));
          const ack = ackOf(c);
          noteApproved(c);   // W183 R12：使用者同意過的那一份（App 帶來才換）
          // W183 R9 審查（GPT-6 #2、N4）：按過 Create 的確認、之後又交回過一次的舊確認、取消或離開這一頁之前的確認＝重放，拒絕（不按、不開新的一張）。
          const spent = ackState(ack);
          if (spent && spent !== 'detached') return { status: 'refused', reason: 'ack_replayed' };
          const replaced = spent === 'detached' ? voidForms[ack.form] : null;
          let owned = null;   // { mark, rec }：TATWO 自己開的那一張
          // 已經開著的連接器表單（網址欄、或 Server URL／Tunnel 分段那一張）。使用者看完警語按「繼續」＝接著用他看的那一張；
          // 不見了＝新的表單（它的警語他還沒看過）。W183 R9：也認網址欄不見了的那一張（使用者換成 Tunnel）：讀回時拒絕，不再開一張新的。
          // W183 R9 審查（GPT-6、Claude）：只接著用 TATWO 自己開、填好的那一張（同一個對話框節點，不看網頁上的記號）；
          // 別的表單開著＝不在它下面按任何東西（不再按「新增」、不按到表單裡 Icon 的「＋」）。
          const open = newForms();
          if (open.length > 1) return { status: 'ambiguous', step: 'form' };
          if (open.length === 1) {
            // 確認的那一張有節點被拆下來過（拆了再掛回去也算）或表單歸屬變了、對話框還是同一個＝表單被換掉：拒絕。
            if (replaced && open[0] === replaced.root) return { status: 'refused', reason: 'form_replaced' };
            owned = recordOf(open[0]);
            if (!owned || !owned.rec.filled) return { status: 'ambiguous', step: 'form_open' };
          }
          if (!owned) {
            if (!live()) return ABORTED;
            await kroute(bag(), '/plugins', () => sIdx(location.pathname, '/plugins', 0) === 0);
            if (!live()) return ABORTED;
            if (newForms().length) return { status: 'ambiguous', step: 'form_open' };
            // W183 R9：先找舊的單一建立鈕（＋，照舊）；找不到才找改版後的「新增 ▾」，在選單裡選「建立 MCP 應用程式」。
            await kwait(() => plusButtons().length > 0 || newButtons().length > 0, 6000);
            const plus = plusButtons();
            const menu = plus.length ? [] : newButtons();
            if (!plus.length && !menu.length) return { status: 'not_found', step: 'new_button' };
            if (plus.length) {
              if (plus.length !== 1) return { status: 'ambiguous', step: 'plus' };
              if (!live()) return ABORTED;
              kpress(plus[0]);
            } else {
              if (menu.length !== 1) return { status: 'ambiguous', step: 'new_button' };
              const pick = bag();
              await pickNewItem(pick, menu[0], 'mcp', 'mcp_item', live);
              if (pick.stop) return pick.stop;
              if (!pick.pressed) return ABORTED;
            }
            await kwait(() => newForms().length > 0, 6000);
            const opened = newForms();
            if (!opened.length) return { status: 'not_found', step: 'form' };
            if (opened.length !== 1) return { status: 'ambiguous', step: 'form' };
            // legacy＝舊的「＋」開的（沒有 Connection 分段是正常的）；改版的「新增 ▾」開的一定要讀得出 Server URL。
            owned = register(opened[0], plus.length > 0, wantName, false);
            const root = owned.rec.root;
            // W183 R9：Connection 一定是 Server URL（有分段就按 Server URL、讀回確認；確認不了＝拒絕，不用 Tunnel）。網址欄在這之後才找。
            const conn = bag();
            await chooseServerURL(conn, root, owned.rec.legacy, live);
            if (conn.result === 'aborted' || !conn.result) return ABORTED;
            if (conn.result === 'ambiguous') return { status: 'ambiguous', step: 'connection' };
            if (conn.result !== 'ok') return { status: 'refused', reason: 'connection_not_server_url' };
            const names = nameFields(root);
            if (names.length !== 1) return { status: names.length ? 'ambiguous' : 'not_found', step: 'name' };
            const urls = urlFields(root);
            if (urls.length !== 1) return { status: urls.length ? 'ambiguous' : 'not_found', step: 'url' };
            if (!live()) return ABORTED;
            ksetValue(names[0], wantName);
            ksetValue(urls[0], url);
            owned.rec.name = names[0];
            owned.rec.url = urls[0];
            owned.rec.nameForm = formOwner(names[0]);   // W183 R9 審查（GPT-6 N4）：記下它們實際所屬的 <form>
            owned.rec.urlForm = formOwner(urls[0]);
            const auth2 = bag();
            await chooseOAuth(auth2, root, live);
            if (auth2.result === 'aborted' || !auth2.result) return ABORTED;
            if (auth2.result !== 'ok') return { status: auth2.result === 'ambiguous' ? 'ambiguous' : 'not_found', step: 'auth' };
            owned.rec.filled = true;
            await ksleep(200);
          }
          const mark = owned.mark;
          const rec = owned.rec;
          const root = rec.root;
          rec.armed = null;   // W183 R10 第二輪：重新走一次核對＝之前 armed 的那一個不再算
          // 按建立前讀回：表單唯一、還是 TATWO 填的那兩格、網址完全相等、Name 是填的那個、驗證方式是 OAuth；要使用者看的交給使用者。
          // W183 R9：先看 Connection 還是 Server URL（使用者看警語時換成 Tunnel＝拒絕，不按 Create；換了網址欄可能不見）。
          const connectionNow = connectionState(root, rec.legacy);
          if (connectionNow === 'ambiguous') return { status: 'ambiguous', step: 'connection' };
          if (connectionNow !== 'none' && connectionNow !== 'server') return { status: 'refused', reason: 'connection_not_server_url' };
          const forms = connectorForms();
          if (forms.length !== 1 || forms[0] !== root || !attached(root)) return { status: 'ambiguous', step: 'form' };
          const urls = urlFields(root);
          if (urls.length !== 1) return { status: urls.length ? 'ambiguous' : 'not_found', step: 'url' };
          const names = nameFields(root);
          if (names.length !== 1) return { status: names.length ? 'ambiguous' : 'not_found', step: 'name' };
          // W183 R9 審查（GPT-6 #2、#6）：欄位節點換了＝表單被換掉（對話框留著、裡面換一張）：不按。交給使用者勾的那幾格也要還是同一格。
          if (urls[0] !== rec.url || names[0] !== rec.name) return { status: 'refused', reason: 'form_replaced' };
          // W183 R9 審查（GPT-6 N4；R9c C4）：Name、網址欄、這一輪每一個確認框都還在登記時那一個 <form>（換了＝表單被換掉，永久作廢）；
          // 這一輪交給使用者的那幾格也還在。
          if (!ownersIntact(rec)) { voidRecord(mark, 'detached'); return { status: 'refused', reason: 'form_replaced' }; }
          const present = boxesIn(root);
          if (!aEvery(rec.zones, (z) => listHas(present, z.box))) return { status: 'refused', reason: 'form_replaced' };
          if (dValue(urls[0]) !== url) return { status: 'refused', reason: 'url_mismatch' };
          if (dValue(names[0]) !== rec.expectedName) return { status: 'refused', reason: 'name_mismatch' };
          if (authState(root) !== 'oauth') return { status: 'refused', reason: 'auth_not_oauth' };
          const seen = ack && ack.form === mark ? ack.warning : null;
          const warning = warningsIn(root, seen, rec);
          if (warning) {
            const back = handBack(owned, warning.reason, warning.digest);
            // W183 R10：只剩「I understand and want to continue」那一格＝量出位置讓 App 代勾（見 tickFor）；別的情況照舊交給使用者。
            // W183 R10 第二輪：同意內容對不上核實過的版本＝原因照舊是 risk_ack（那一格還是那一格），另外標 consent: 'unknown'
            //（App 的卡片說「ChatGPT 的說明跟 TATWO 認得的不一樣」、不代勾）；多了勾選框＝checkbox。
            if (warning.reason === 'risk_ack') {
              const t = tickFor(rec, root);
              if (t.reason === 'checkbox') back.reason = 'checkbox';
              else if (t.reason === 'warning_changed') { back.consent = 'unknown'; if (t.offer) back.offer = t.offer; }   // W183 R12
              else if (t.tick) back.tick = t.tick;
            }
            return back;
          }
          // W183 R10 第三輪（GPT-6 發現 3）：TATWO 代勾的那一輪，同意內容要跟代勾那一刻綁住的一樣（文字沒變、連結換了網址也算變了）；
          // 不一樣＝交回使用者（新的一輪：他自己看、自己勾），不按。
          if (rec.consent && consentPrint(root) !== rec.consent) {
            const now = warningsIn(root, null, rec);
            const back = handBack(owned, 'risk_ack', now ? now.digest : '');
            back.consent = 'unknown';
            return back;
          }
          const submit = aFilter(visibleOf(root, 'button, [role="button"], input[type="submit"]'), (b) => reTest(CREATE, labelOf(b) || safeAttr(b, 'value')));
          if (submit.length !== 1) return { status: submit.length ? 'ambiguous' : 'not_found', step: 'create' };
          if (dDisabled(submit[0]) || safeAttr(submit[0], 'aria-disabled') === 'true') return handBack(owned, 'create_disabled', seen || '');
          if (!live()) return ABORTED;
          if (rec.void || rec.epoch !== connectorEpoch) return { status: 'refused', reason: 'form_replaced' };   // 讀回的時候剛好被作廢
          // W183 R9 審查：一次性（這個確認用掉；同一個確認再帶一次＝ack_replayed）。W183 R10 第二輪：這裡不按——交回 armed，App 記下錨點再按。
          const button = submit[0];
          return armPress(owned, button, 'create', () => createStillReady(rec, url, button, seen));
        },
        connectorReconnect: async (c) => {
          if (!KIT_OK) return UNSAFE;
          const live = connectorStep();
          const url = connectorURL(own(c, 'url'));
          const rawID = own(c, 'connectorID');
          const id = typeof rawID === 'string' && reTest(/^[A-Za-z0-9_.:-]{2,200}$/, rawID) ? rawID : '';
          noteApproved(c);   // W183 R12
          // 只認清單用完整網址認出來的那一個（它的 id）：沒有 id 就不猜。
          // W183 R12（.037 實機：建成、還沒授權的「TATWO（Mac mini）2」清單讀不到）：App 帶本機記下的名字＝外掛頁上字剛好是這個名字的
          // 唯一一個連結；打開之後照舊核完整網址與 OAuth 才按（名字只是找的方法，不是認的方法）。
          const rawName = own(c, 'name');
          const byName = !id && typeof rawName === 'string' && connectorName(rawName) === rawName && rawName !== CONNECTOR_NAME ? rawName : '';
          if (!id && !byName) return { status: 'not_found', step: 'id' };
          const ack = ackOf(c);
          // W183 R9 審查：用過、過期、取消前、離開頁面前的確認不收；讀回的那一區有節點被拆下來過或表單歸屬變了＝被換掉。
          const spent = ackState(ack);
          if (spent === 'detached') return { status: 'refused', reason: 'form_replaced' };
          if (spent) return { status: 'refused', reason: 'ack_replayed' };
          let owned = null;
          if (id && own(c, 'detailPath') && !ack) {
            const direct = bag();
            await openKnownConnector(direct, c, live);
            if (!direct.root) return { status: 'not_found', step: 'verify' };
            owned = register(direct.root, false, '', true);
          }
          if (ack) {
            // W183 R9 審查（GPT-6 #2、N4）：只認 TATWO 自己讀回過的那一區（記在閉包裡的節點、同一個操作世代、同一頁），不認網頁上的記號。
            const hit = ownForms[ack.form];
            if (hit && hit.reconnect && !hit.void && hit.epoch === connectorEpoch && hit.path === sOf(location.pathname) && attached(hit.root)) {
              owned = { mark: ack.form, rec: hit };
            }
          }
          if (!owned) {
            // 重連可能已經停在外掛詳情：先核完整網址＋同一個 id／名稱，不能要求詳情頁還有清單連結。
            const onPlugins = sOf(location.pathname) === '/plugins' || sIdx(location.pathname, '/plugins/', 0) === 0;
            const current = onPlugins ? aFilter(detailBoxes(url), (box) => byName
              ? aSome(visibleOf(box, 'h1, h2, h3, [role="heading"]'), (h) => safeSquash(safeText(h)) === byName)
              : hrefHasID(location.href, id)) : [];
            if (current.length > 1) return { status: 'ambiguous', step: 'verify' };
            if (current.length === 1) owned = register(current[0], false, '', true);
          }
          if (!owned) {
            // /plugins/<id> 不是清單；只比前綴會一直在詳情頁找不存在的清單連結。
            if (sOf(location.pathname) !== '/plugins') {
              if (!live()) return ABORTED;
              const route = bag();
              await kroute(route, '/plugins', () => sOf(location.pathname) === '/plugins');
              if (!route.ok) return { status: 'not_found', step: 'navigate' };
            }
            const namedLink = (a) => {
              try {
                const u = new C_URL(safeAttr(a, 'href'), location.origin);
                if (pget(G_urlOrigin, u) !== location.origin) return false;
                return safeSquash(safeText(a)) === byName
                  || aSome(leaves(a), (el) => safeSquash(safeText(el)) === byName);
              } catch (e) { return false; }
            };
            if (byName) await openCreatedSection(live);
            const candidates = () => aFilter(visibleOf(document, 'a[href]'), (a) =>
              byName ? namedLink(a) : hrefHasID(safeAttr(a, 'href'), id));
            // id 與名稱兩條路都等清單載入，不能只等網址改了就判定「沒有」。
            await kwait(() => candidates().length > 0 || !live(), 4000);
            if (!live()) return ABORTED;
            const links = candidates();
            if (links.length > 1) return { status: 'ambiguous', step: 'open' };
            if (!links.length) return { status: 'not_found', step: 'open' };
            if (!live()) return ABORTED;
            kpress(links[0]);
            await kwait(() => detailBoxes(url).length > 0, 5000);
            const boxes = detailBoxes(url);
            if (!boxes.length) return { status: 'not_found', step: 'verify' };
            if (boxes.length !== 1) return { status: 'ambiguous', step: 'verify' };
            const known = recordOf(boxes[0]);
            owned = known && known.rec.reconnect ? known : register(boxes[0], false, '', true);
          }
          const mark = owned.mark;
          const rec = owned.rec;
          const root = rec.root;
          rec.armed = null;   // W183 R10 第二輪：重新走一次核對＝之前 armed 的那一個不再算
          // 讀回（只在那一區）：網址整個出現、驗證方式不是免驗證、警語交給使用者、只有一顆連線鈕。
          const here = aSome(leaves(root), (el) => hasURLToken(safeText(el), url) && shown(el)) || aSome(textInputs(root), (x) => dValue(x) === url);
          if (!here) return { status: 'not_found', step: 'verify' };
          // 名稱只是查找線索，沒有清單的 OAuth 證據；這條路必須在詳情裡正面確認。
          // 按 id 重連仍沿用清單已確認 OAuth 的契約，但詳情明示其他驗證方式一律拒絕。
          const detailAuth = authShown(root);
          if (detailAuth !== 'oauth') return { status: 'refused', reason: 'auth_not_oauth' };
          if (!ownersIntact(rec)) { voidRecord(mark, 'detached'); return { status: 'refused', reason: 'form_replaced' }; }
          const present = boxesIn(root);
          if (!aEvery(rec.zones, (z) => listHas(present, z.box))) return { status: 'refused', reason: 'form_replaced' };
          const seen = ack && ack.form === mark ? ack.warning : null;
          const warning = warningsIn(root, seen, rec);
          if (warning) return handBack(owned, warning.reason, warning.digest);
          const buttons = aFilter(visibleOf(root, 'button, [role="button"]'), (x) => reTest(RECONNECT, labelOf(x)));
          if (!buttons.length) return { status: 'not_found', step: 'connect' };
          if (buttons.length !== 1) return { status: 'ambiguous', step: 'connect' };
          if (dDisabled(buttons[0]) || safeAttr(buttons[0], 'aria-disabled') === 'true') return handBack(owned, 'create_disabled', seen || '');
          if (!live()) return ABORTED;
          if (rec.void || rec.epoch !== connectorEpoch) return { status: 'refused', reason: 'form_replaced' };
          const button = buttons[0];
          const armed = armPress(owned, button, 'reconnect', () => reconnectStillReady(rec, url, button, seen, true));
          const path = sOf(location.pathname);
          const pathID = reExec(/\/([^/]+)$/, path);
          const resolvedID = id || (pathID ? pathID[1] : '');
          const record = detailIdentity(root, resolvedID, path);
          if (record) armed.connector = record;
          return armed;
        },
        // W183 R10 第二輪：真的按（App 記下錨點之後才送）。記號要是 armed 的那一個、同一個操作世代、同一頁；再核一次才按，按了就用掉。
        connectorPress: async (cmd) => {
          if (!KIT_OK) return UNSAFE;
          const live = connectorStep();
          const token = own(cmd, 'form');
          const t = typeof token === 'string' ? token : '';
          // W183 R12（.035 實機：TATWO 用程式按 Create＝沒有真人手勢，ChatGPT 開授權視窗被擋、對話框一直等）：分成 aim（全部照舊核完、量那一顆
          // 的位置，不按）→ App 用 CEF 真的滑鼠點中心 → confirm（那一下真的落在那一顆上＝按了；沒落上＝照舊核完由腳本按，回報 native:false）。
          const phase = own(cmd, 'phase');
          const aimed = aimedPress;
          // W183 R12（.036 實機）：user＝等使用者自己按亮起來的那一顆（poll 每一下看一次；按了＝照常接手）。
          if (phase === 'poll' && aimed && aimed.token === t && aimed.user) {
            if (lastTrustedClick && lastTrustedAt >= aimed.at && pressHit(aimed.arm, lastTrustedClick)) {
              aimedPress = null;
              clearGesture();
              if (ownForms[t]) consume({ mark: t, rec: ownForms[t] }); else spentMarks[t] = 'used';
              diag['連接器'] = '使用者自己按了' + (aimed.arm.kind === 'reconnect' ? '重新連線' : '建立');
              return { status: 'pressed', native: true, byUser: true };
            }
            const alert = dialogAlert();
            if (alert) return { status: 'waiting_user', alert };
            if (!gestureDrawn && attached(aimed.arm.button)) drawGesture(aimed.arm.button);
            return { status: 'waiting_user' };
          }
          if (phase === 'poll') return { status: 'refused', reason: 'press_stale' };
          if (phase === 'confirm' && aimed && aimed.token === t) {
            aimedPress = null;
            // 那一下沒有落在那一顆上（沒有真的點擊、或點到別處）＝不用程式補按（程式按沒有真人手勢，ChatGPT 的授權視窗出不來）：not_landed，App 改請使用者按。
            if (!(lastTrustedClick && lastTrustedAt >= aimed.at && pressHit(aimed.arm, lastTrustedClick))) return { status: 'not_landed' };
            if (lastTrustedClick && lastTrustedAt >= aimed.at) {
              // 那一下落在哪一顆：往上找按鈕（重畫過的新節點也算——同樣的字）；落在別處＝不再用程式補按（避免按兩次），交回。
              const b = aimed.arm.button;
              let hit = lastTrustedClick === b || safeContains(b, lastTrustedClick);
              for (let p = lastTrustedClick, i = 0; !hit && p && i < 8; p = safeParent(p), i += 1) {
                if (safeTag(p) === 'BUTTON' || safeAttr(p, 'role') === 'button') {
                  hit = reTest(aimed.arm.kind === 'reconnect' ? RECONNECT : CREATE, labelOf(p));
                  break;
                }
              }
              if (!hit) return { status: 'refused', reason: 'press_missed' };
              if (ownForms[t]) consume({ mark: t, rec: ownForms[t] }); else spentMarks[t] = 'used';
              diag['連接器'] = aimed.arm.kind === 'reconnect' ? '已按重新連線（真的點擊）' : '已按建立（真的點擊）';
              return { status: 'pressed', native: true };
            }
          }
          const spent = t ? spentMarks[t] : '';
          if (spent) {
            noteStale('spent:' + spent, null, null);   // W183 R12：結構快照（App 用 connectorOutline 拿）
            return { status: 'refused', reason: spent === 'used' ? 'ack_replayed' : spent === 'detached' ? 'form_replaced' : 'press_stale' };
          }
          const rec = t ? ownForms[t] : null;
          if (!rec || !rec.armed || rec.void || rec.epoch !== connectorEpoch || rec.path !== sOf(location.pathname)) {
            noteStale(!rec ? 'no_record' : !rec.armed ? 'not_armed' : rec.void ? 'void' : rec.epoch !== connectorEpoch ? 'epoch' : 'path', rec, null);
            return { status: 'refused', reason: 'press_stale' };
          }
          const arm = rec.armed;
          // W183 R10 第三輪（GPT-6 發現 3）：按之前再核一次代勾綁住的同意內容；變了＝交回使用者（新的一輪），不按。
          if (rec.consent && consentPrint(rec.root) !== rec.consent) {
            rec.armed = null;
            const now = warningsIn(rec.root, null, rec);
            const back = handBack({ mark: t, rec }, 'risk_ack', now ? now.digest : '');
            back.consent = 'unknown';
            return back;
          }
          if (!arm.check()) { rec.armed = null; voidRecord(t, 'stale'); return { status: 'refused', reason: 'press_stale' }; }
          if (!live()) return ABORTED;
          if (phase === 'aim') {
            const m = await measureSettled(arm.button);
            if (!m.tick) {
              const back = { status: 'aim_failed', why: sOf(m.why) };
              if (m.rect) back.rect = m.rect;
              if (m.top) back.top = sOf(m.top);
              return back;
            }
            const a = bag();
            a.token = t; a.arm = arm; a.at = nowMs(); a.user = false;
            aimedPress = a;
            return { status: 'aimed', rect: m.tick };
          }
          // W183 R12（.036 實機：瞄不準時不准退回程式按）：把那一顆亮起來，等使用者自己按（poll 看）。
          if (phase === 'wait_user') {
            const a = bag();
            a.token = t; a.arm = arm; a.at = nowMs(); a.user = true;
            aimedPress = a;
            clearGesture();
            drawGesture(arm.button);
            return { status: 'waiting_user' };
          }
          rec.armed = null;
          consume({ mark: t, rec });
          kpress(arm.button);
          diag['連接器'] = arm.kind === 'reconnect' ? '已按重新連線' : '已按建立';
          if (phase === 'confirm') return { status: 'pressed', native: false };
          return arm.refound ? { status: 'pressed', refound: true } : { status: 'pressed' };
        },
        // W183 R10 第三輪（GPT-6 發現 3）：App 派送代勾的原生點擊之前問一次——這一張表單（記號）代勾那一刻綁住的同意內容還一樣嗎。
        // 只讀、不動網頁；表單換了、離開這一頁、記號用過、沒有綁住的內容＝changed。
        connectorConsent: async (cmd) => {
          if (!KIT_OK) return UNSAFE;
          const token = own(cmd, 'form');
          const t = typeof token === 'string' ? token : '';
          const rec = t && !spentMarks[t] ? ownForms[t] : null;
          if (!rec || rec.void || rec.epoch !== connectorEpoch || rec.path !== sOf(location.pathname) || !rec.consent || !attached(rec.root)) {
            return { status: 'changed' };
          }
          return { status: consentPrint(rec.root) === rec.consent ? 'ok' : 'changed' };
        },
        connectorHighlight: async (c) => {
          if (!KIT_OK) return { highlighted: false };
          const live = connectorStep();
          connectorURL(own(c, 'url'));
          if (!live()) return ABORTED;
          if (!createdSection()) await kroute(bag(), '/plugins', () => sIdx(location.pathname, '/plugins', 0) === 0);
          if (!live()) return ABORTED;
          removeHighlights();
          const name = own(c, 'name');
          if (typeof name === 'string') {
            if (connectorName(name) !== name) return { highlighted: false };
            const section = await openCreatedSection(live);
            const entries = section && createdLinks(section);
            if (!entries) return { highlighted: false };
            const matches = aFilter(entries, (entry) => entry.name === name);
            if (matches.length !== 1) return { highlighted: false };
            const links = aFilter(visibleOf(document, 'a[href]'), (link) => safeSquash(safeText(link)) === name
              && detailPathOf(safeAttr(link, 'href'), matches[0].id) === matches[0].detailPath);
            return { highlighted: links.length === 1 && drawHighlight(links[0]) };
          }
          // W183 R9：舊的「＋」；改版後標出「新增 ▾」（手動步驟從它開始）。只標、不按。
          await kwait(() => plusButtons().length > 0 || newButtons().length > 0, 3000);
          if (!live()) return ABORTED;
          const plus = plusButtons();
          const targets = plus.length ? plus : newButtons();
          if (targets.length !== 1) return { highlighted: false };
          return { highlighted: drawHighlight(targets[0]) };
        },
        // W183 R12（主導 2）：要真人點的那一步指給他看（只標、不按）。find＝找那一顆、捲到看得見、量位置（回一次性記號＋位置：App 先用
        // CEF 的節點驗證核同一個位置剛好一顆沒停用的按鈕）；show＝記號對、同一個操作世代、同一頁、位置沒變才畫亮框＋箭頭；clear＝拿掉。
        connectorGesture: async (c) => {
          if (!KIT_OK) return UNSAFE;
          const phase = own(c, 'phase');
          if (phase === 'clear') { clearGesture(); return { ok: true }; }
          // W183 R12（.037 實機）：App 用 CEF 真的點擊按了找到的那一顆（Continue to …）之後問：真的落在那一顆上嗎。
          if (phase === 'landed') {
            const b = gestureEl;
            const ok = !!b && !!lastTrustedClick && lastTrustedAt >= gestureFoundAt && (lastTrustedClick === b || safeContains(b, lastTrustedClick));
            if (ok) clearGesture();
            return { landed: ok };
          }
          // 還指著嗎（亮框還在、那一顆還在頁面上）：只讀、不重畫（App 每幾秒看一次，不會一閃一閃）。
          if (phase === 'alive') return { shown: gestureDrawn !== null && attached(gestureDrawn) };
          if (phase === 'show') {
            const m = own(c, 'mark');
            const at = gestureAt;
            const el = gestureEl;
            if (typeof m !== 'string' || !m || m !== gestureMark || !at || !attached(el) || gestureEpoch !== connectorEpoch
              || gesturePath !== sOf(location.pathname)) return { shown: false };
            gestureMark = '';   // 記號只用一次
            const now = tickPoint({ box: el });
            if (!now || !near(now.x, at.x) || !near(now.y, at.y) || !near(now.w, at.w) || !near(now.h, at.h)) return { shown: false };
            return { shown: drawGesture(el) };
          }
          const live = connectorStep();
          const url = connectorURL(own(c, 'url'));
          const rawName = own(c, 'name');
          const name = typeof rawName === 'string' && rawName.length >= 2 && rawName.length <= 80 ? safeSquash(rawName) : '';
          clearGesture();
          const cont = continueButton(name);
          const el = cont || gestureButton(url, name);
          if (!el) {
            // W183 R12（.036 實機：程式按了 Create 之後對話框出現「An app with this name already exists」＝ChatGPT 沒建成）：回 rejected＋那一句。
            const alert = dialogAlert();
            if (alert) return { status: 'rejected', alert };
            // W183 R12（.035 實機）：按了 Create 之後外掛對話框整張停在等待（Create 停用、那一格勾著）＝ChatGPT 在等它自己的授權視窗；
            // 那時候沒有 Connect 是正常的：回 waiting（不是找不到）。
            const dialogs = visibleOf(document, '[role="dialog"], dialog');
            for (let i = 0; i < dialogs.length; i += 1) {
              const creates = aFilter(visibleOf(dialogs[i], 'button, [role="button"]'), (b) => reTest(CREATE, labelOf(b)));
              const stuck = creates.length === 1 && (dDisabled(creates[0]) || safeAttr(creates[0], 'aria-disabled') === 'true');
              if (stuck && aSome(boxesIn(dialogs[i]), isChecked)) return { status: 'waiting' };
            }
            return { status: 'not_found' };
          }
          if (!live()) return ABORTED;
          let at = tickPoint({ box: el });
          if (!at) {
            // W183 R12：Continue 在畫面外（對話框底部被切掉）＝捲一下、看得到的那一條也行。
            const m = await measureSettled(el);
            at = m.tick || null;
          }
          if (!at) return { status: 'not_found', step: 'position', label: clip80(labelOf(el)), kind: cont ? 'continue' : 'connect' };
          gestureEl = el;
          gestureAt = at;
          gestureMark = newMark();
          gestureEpoch = connectorEpoch;
          gesturePath = sOf(location.pathname);
          gestureFoundAt = nowMs();
          const back = { status: 'found', mark: gestureMark, rect: at, label: clip80(labelOf(el)) };
          if (cont) back.kind = 'continue';
          return back;
        },
        // W183 R12（.033 實機）：結構快照（只讀、不動網頁；DOM 文字，不是截圖）。App 在對不上的時候（說明對不上、按鈕過期、找不到節點、
        // 表單讀回不對）要一份，寫進正式版的連線紀錄。stale＝上一次 press_stale 那一刻留的（拿了就清）。
        connectorOutline: async () => {
          if (!KIT_OK) return UNSAFE;
          const back = { outline: outlineOf(outlineRootOf(null)) };
          if (lastStale) { back.stale = lastStale; lastStale = null; }
          return back;
        },
        // W183 R12（.036 實機；主導裁決：撞名就自動換名字重建）：ChatGPT 明確說「這個名字的 App 已經有了」＝只換 Name（其他欄位照舊），
        // 把那一格勾選取消（名字換了＝這一輪重新同意：TATWO 之後照舊用真的點擊代勾），登記成 TATWO 自己的一張新表單。不按 Create。
        // 只收：畫面上剛好一張連接器表單、網址欄是這個網址、對話框裡的錯是撞名。
        connectorInspect: async (c) => {
          if (!KIT_OK) return UNSAFE;
          const live = connectorStep();
          const box = bag();
          await openKnownConnector(box, c, live);
          if (!box.root || !live()) return { authorization: 'unknown' };
          return { authorization: authorizationOf(box.root), connector: box.connector };
        },
        connectorDelete: async (c) => {
          if (!KIT_OK) return UNSAFE;
          const step = connectorStep(), epoch = authEpoch;
          const live = () => step() && authEpoch === epoch;
          const id = own(c, 'connectorID'), keep = own(c, 'keeping'), name = own(c, 'name');
          if (typeof keep !== 'string' || !keep || id === keep || typeof name !== 'string' || connectorName(name) !== name) return UNSAFE;
          const box = bag();
          await openKnownConnector(box, c, live, false);
          if (!box.root || box.connector.name !== name || !live()) return { deleted: false };
          const buttons = aFilter(visibleOf(box.root, 'button, [role="button"]'), (b) => reTest(/^(delete|delete app|delete connector|刪除|刪除應用程式|刪除連接器)$/i, labelOf(b)) && !dDisabled(b));
          if (buttons.length !== 1 || !live()) return { deleted: false };
          kpress(buttons[0]);
          await kwait(() => visibleOf(document, '[role="alertdialog"], [role="dialog"], dialog').length > 0 || !live(), 3000);
          const dialogs = aFilter(visibleOf(document, '[role="alertdialog"], [role="dialog"], dialog'),
            (root) => root !== box.root && hasURLToken(safeText(root), box.connector.serverURL)
              && aSome(leaves(root), (el) => safeSquash(safeText(el)) === name));
          if (dialogs.length !== 1 || !live()) return { deleted: false };
          const confirms = aFilter(visibleOf(dialogs[0], 'button, [role="button"]'), (b) => reTest(/^(delete|delete app|delete connector|刪除|刪除應用程式|刪除連接器)$/i, labelOf(b)) && !dDisabled(b));
          if (confirms.length !== 1 || !live()) return { deleted: false };
          kpress(confirms[0]);
          await kwait(() => !attached(dialogs[0]) || !shown(dialogs[0]) || !live(), 5000);
          if (!live() || (attached(dialogs[0]) && shown(dialogs[0]))) return { deleted: false };
          const routed = bag();
          await kroute(routed, '/plugins', () => sOf(location.pathname) === '/plugins');
          const remaining = routed.ok ? completeCreatedList(await openCreatedSection(live)) : null;
          return { deleted: live() && remaining !== null && !aSome(remaining, (entry) => entry.id === id) };
        },
        // W183 R12（.034 實機：CEF 的畫面快照整頁只有 1 個控制項＝節點驗證永遠過不了、永遠不代勾）：代勾改走 DOM 驗證。
        // aim＝按之前在同一份文件再驗一次（TATWO 自己讀回的這張表單、同意內容一字不差、剛好一格、字對得上核准的版本、看得見、沒停用、
        // 還沒勾），捲到看得見、量它的位置（App 用 CEF 真的滑鼠事件點中心）；after＝點完看勾上了沒、Create 能不能按。都不按任何東西。
        connectorTick: async (c) => {
          if (!KIT_OK) return UNSAFE;
          const token = own(c, 'form');
          const t = typeof token === 'string' ? token : '';
          const rec = t && !spentMarks[t] ? ownForms[t] : null;
          if (!rec || rec.void || rec.epoch !== connectorEpoch || rec.path !== sOf(location.pathname) || !attached(rec.root)) {
            return { status: 'gone' };
          }
          const root = rec.root;
          const boxes = boxesIn(root);
          if (boxes.length !== 1 || rec.zones.length !== 1 || rec.zones[0].box !== boxes[0]) return { status: 'changed', why: 'checkbox' };
          const box = boxes[0];
          if (own(c, 'phase') === 'after') {
            const creates = aFilter(visibleOf(root, 'button, [role="button"], input[type="submit"]'), (b) => reTest(CREATE, labelOf(b) || safeAttr(b, 'value')));
            const ready = creates.length === 1 && !(dDisabled(creates[0]) || safeAttr(creates[0], 'aria-disabled') === 'true');
            return { status: 'ok', checked: isChecked(box), create: ready };
          }
          if (!rec.consent || consentPrint(root) !== rec.consent) return { status: 'changed', why: 'consent' };
          if (isChecked(box) || dDisabled(box) || safeAttr(box, 'aria-disabled') === 'true' || !reTest(RISK_ACK, boxText(box))) {
            return { status: 'changed', why: 'box' };
          }
          const tick = tickPoint(rec.zones[0]);
          if (!tick) return { status: 'changed', why: 'position' };
          return { status: 'ok', tick };
        },
        connectorHome: async () => {
          if (!KIT_OK) return UNSAFE;
          const live = connectorStep();
          removeHighlights();
          if (!live()) return ABORTED;
          await kroute(bag(), '/', () => sOf(location.pathname) === '/');
          return { ok: true };
        },
        // W183 R9：原生外掛頁的「新增 ▾」（使用者在 TATWO 的 ChatGPT Space 自己按的）：到 /plugins、按「新增」、選那一項，
        // 只做到對話框打開為止——不填、不勾、不按 Create；表單由使用者在私訊框 Browser 的 ChatGPT Dev 分頁自己填。
        // item 只收 plugin／archive／mcp；只回結果代碼（不回頁面內容）。
        // W183 R9 審查（GPT-6 #8、#10）：
        // - 帶原生發的一次性操作序號 op（用過＝拒絕）；有世代（App 送 pluginNewMenuAbort＝舊的在下一個按之前停手）；已經開著對話框＝不在它下面按。
        // - 「上傳外掛程式封存檔」是選檔：網頁只在使用者真的按下時才開得出選檔視窗，所以只打開「新增」選單、標出那一項（menu_open），
        //   由使用者自己按（Pod 接了只給人用的檔案選擇器）。不回假的「按了」。
        // - 打開了＝記著這一次打開的對話框（或選單）；App 用 pluginNewMenuWatch 問它還開著嗎（關了就放掉 Pod 的操作租約）。
        pluginNewMenu: async (c) => {
          const key = sOf(own(c, 'item'));
          if (!listHas(MENU_KEYS, key)) throw new Error('unknown plugin menu item');
          const rawOp = own(c, 'op');
          const op = typeof rawOp === 'string' && reTest(/^[A-Za-z0-9-]{8,64}$/, rawOp) ? rawOp : '';
          if (!op) throw new Error('bad plugin menu operation');
          if (!KIT_OK) return UNSAFE;
          if (usedOps[op]) return { status: 'refused', reason: 'op_used' };
          usedOps[op] = true;
          const live = menuStep();
          currentOp = op;
          menuOps = bag();
          if (sIdx(location.pathname, '/plugins', 0) !== 0) {
            if (!live()) return ABORTED;
            const route = bag();
            await kroute(route, '/plugins', () => sIdx(location.pathname, '/plugins', 0) === 0);
            if (sIdx(location.pathname, '/plugins', 0) !== 0) return { status: 'not_found', step: 'plugins_page' };
          }
          if (!live()) return ABORTED;
          if (visibleOf(document, 'dialog, [role="dialog"]').length) return { status: 'busy', step: 'dialog_open' };
          await kwait(() => !live() || newButtons().length > 0, 6000);
          if (!live()) return ABORTED;
          const found = newButtons();
          if (!found.length) return { status: 'not_found', step: 'new_button' };
          if (found.length !== 1) return { status: 'ambiguous', step: 'new_button' };
          const before = visibleOf(document, 'dialog, [role="dialog"]');
          if (key === 'archive') {
            const shownItem = bag();
            await findNewItem(shownItem, found[0], key, 'menu_item', live);
            if (shownItem.stop) return shownItem.stop;
            if (!shownItem.item) return ABORTED;
            if (!live()) { closeMenu(); return ABORTED; }
            drawHighlight(shownItem.item);
            const rec = bag();
            rec.surface = shownItem.menu; rec.before = before; rec.archive = true;
            menuOps[op] = rec;
            return { status: 'menu_open' };
          }
          const pick = bag();
          await pickNewItem(pick, found[0], key, 'menu_item', live);
          if (pick.stop) return pick.stop;
          if (!pick.pressed) return ABORTED;
          const newDialog = () => aFind(visibleOf(document, 'dialog, [role="dialog"]'), (d) => !listHas(before, d));
          await kwait(() => !live() || !!newDialog(), 5000);
          if (!live()) return ABORTED;
          const dialog = newDialog();
          if (!dialog) return { status: 'not_found', step: 'dialog' };
          const rec = bag();
          rec.surface = dialog; rec.before = before; rec.archive = false;
          menuOps[op] = rec;
          return { status: 'opened' };
        },
        // 這一次打開的對話框（或選單）還開著嗎。「上傳外掛程式封存檔」：選單關了之後、使用者選檔帶出來的新對話框也算這一次的。
        pluginNewMenuWatch: async (c) => {
          const op = sOf(own(c, 'op'));
          const rec = menuOps[op];
          if (!KIT_OK || !rec || op !== currentOp) return { known: false, open: false };
          if (attached(rec.surface)) return { known: true, open: true };
          if (rec.archive) {
            const next = aFind(visibleOf(document, 'dialog, [role="dialog"]'), (d) => !listHas(rec.before, d));
            if (next) { rec.surface = next; rec.archive = false; return { known: true, open: true }; }
          }
          delete menuOps[op];
          return { known: true, open: false };
        },
        pluginNewMenuAbort: async (c) => {
          const op = sOf(own(c, 'op'));
          if (op && op === currentOp) {
            menuGen += 1;
            currentOp = '';
            menuOps = bag();
            removeHighlights();
          }
          return { ok: true };
        },
        // ==== SAFE-CHAIN END ====
        stop: async (command) => {
          const id = command.requestID;
          const stopButton = () => document.querySelector('[data-testid="stop-button"]');
          if (!id) {
            // 舊的全域停止（App 已改用指定代號）：照舊按網頁的停止鍵。
            const b = stopButton();
            if (b) b.click();
            return { stopped: !!b };
          }
          const work = preparing.get(id);
          if (!work && !turns[id] && !(pendingSend && pendingSend.id === id)) return { stopped: false };
          if (work) work.command.cancelled = true;
          if (turns[id]) {
            turns[id].cancelled = true;
            if (turns[id].personalizedProof === personalizedProof) revokePersonalizedProof('cancelled');
          } else if (work && work.command.personalizedProof === personalizedProof) revokePersonalizedProof('cancelled');
          // 準備最多等 2 秒；還沒結束就回報未知，Swift 關掉舊 Pod 後才釋放槽位。
          if (work) {
            let timer;
            const settled = await Promise.race([
              work.promise.then(() => true, () => true),
              new Promise(resolve => { timer = setTimeout(() => resolve(false), 2000); })
            ]);
            clearTimeout(timer);
            if (!settled) return { stopped: false, preparationPending: true };
          }
          const turn = turns[id];
          let stopped = false;
          // 先收回這則的送出請求：之後網頁發出的請求不再歸給它。
          const job = pendingSend && pendingSend.id === id ? pendingSend : null;
          if (job) {
            pendingSend = null;
            pendingModel = pendingEffort = pendingHint = pendingParent = pendingGizmo = null;
            pendingTemporary = false;
          }
          if (turn && turn.submitted && !turn.posted && job) {
            // 已按送出、網頁還在做自己的檢查、請求還沒發出（或點擊被網頁吞掉、永遠不會發出）：
            // 記下這則，晚到的請求在 fetch 擋掉（不轉發給 ChatGPT、不歸給下一則），這裡不必等、也不必收掉 Pod。
            cancelledSends.push({ text: job.text, conversationID: job.conversationID, until: Date.now() + 30000 });
            stopped = true;
          }
          if (turn && turn.submitted) {
            // 只按這一則按下送出後才出現的停止鍵（還在準備、沒按送出就沒有東西要停，不去停網頁上別的回答）。
            // 按了還在（網頁沒接到）隔一秒再按，直到它消失；已發出、停止鍵還沒出現時（剛發出、還沒收到回應）等它出現再按；
            // 收到回應了停止鍵還是不在＝伺服器上在想（網頁藏起停止鍵），跟以前一樣放行。
            let pressedAt = 0;
            await waitFor(() => {
              if (turn.finished) return true;
              const b = stopButton();
              if (b) {
                if (!pressedAt || Date.now() - pressedAt > 1000) { b.click(); pressedAt = Date.now(); stopped = true; }
                return false;
              }
              return !turn.posted || pressedAt > 0 || turn.accepted || Date.now() - turn.posted > 1500;
            }, 6000);
          }
          if (turns[id]) finishTurn(turns[id]);
          return { stopped, submitted: !!(turn && turn.submitted) };
        },
      };
      Object.defineProperty(window, '__tatwoPod', {
        configurable: false, enumerable: false, writable: false,
        value: Object.freeze({
          command(command) {
            if (!command || typeof command !== 'object') return;
            // W183 R9 審查（GPT-6 #3）：每一個指令都要帶 App 的鑰匙（=== 比對；佔位字沒換掉時長度不對＝一律不收）。
            // 網頁自己的程式叫的＝安靜丟掉（不回任何結果、不做任何事）；鑰匙比對完就拿掉，不往下傳。
            if (!(POD_KEY.length === 64 && typeof command.key === 'string' && command.key === POD_KEY)) return;
            try { delete command.key; } catch (e) { return; }
            // 送出流程中途出錯也要回報（09-25 實機：專案頁出錯時什麼都沒回，App 一直顯示「思考中」）。
            const failStream = (e) => {
              if (turns[command.id]) finishTurn(turns[command.id], String((e && e.message) || e).slice(0, 200));
              else postTerminal({ type: 'stream', id: command.id, kind: 'failed', message: String((e && e.message) || e).slice(0, 200) });
            };
            if (command.cmd === 'send' || command.cmd === 'regenerate') {
              const work = { command, promise: null };
              preparing.set(command.id, work);
              work.promise = (command.cmd === 'send' ? send(command).catch(failStream) : regenerate(command).catch(failStream))
                .finally(() => preparing.delete(command.id));
              return;
            }
            // W183 R9c（GPT-6 C1）：只認 handlers 自己的屬性；結果用抓好的 then 接（網頁改 Promise.prototype.then 換不掉回給 App 的結果）；
            // 連接器與「新增」的結果用自己寫的 JSON 回報（不經網頁改得到的 toJSON）。
            const cmd = typeof command.cmd === 'string' ? command.cmd : '';
            const handler = cmd && R_apply(O_hasOwn, handlers, [cmd]) ? handlers[cmd] : null;
            if (typeof handler !== 'function') { post({ type: 'result', id: command.id, ok: false, message: 'unknown command' }); return; }
            const reply = listHas(SAFE_COMMANDS, cmd) ? postSafe : post;
            let pending = null;
            try { pending = handler(command); } catch (e) { reply({ type: 'result', id: command.id, ok: false, message: sOf((e && e.message) || e) }); return; }
            R_apply(P_then, pending, [
              (data) => reply({ type: 'result', id: command.id, ok: true, data }),
              (e) => reply({ type: 'result', id: command.id, ok: false, message: sOf((e && e.message) || e) })]);
          },
        }),
      });

      const hello = async () => {
        const state = await waitFor(() => {
          if (auth) return 'in';
          if (document.querySelector('[data-testid="login-button"]')) return 'out';
          return null;
        }, 20000);
        // 20 秒內看不到網頁自己的登入標頭，就當沒登入：讓使用者看到登入頁，而不是一直轉圈。
        post({ type: 'hello', loggedIn: state === 'in' });
      };
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', hello, { once: true });
      else hello();
      return true;
    })
    """#
}
