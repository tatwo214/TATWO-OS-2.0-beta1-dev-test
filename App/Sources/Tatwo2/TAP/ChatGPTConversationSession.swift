import Combine
import Foundation

/// 私訊框自己的對話；只放記憶體，沒有儲存、日誌或對 ChatGPT Space 選取狀態的依賴。
@MainActor
final class ChatGPTConversationSession: ObservableObject {
    enum State: Equatable {
        case idle
        case needsLogin
        case queued
        case answering
        case failed(String)
    }

    /// W184 G3b 第二輪（審查 #3）：換到的那一則讀好了沒——新對話（沒有要讀的）、讀取中（不能送）、讀到了、讀不到（看得出來、可以重試）。
    enum LoadState: Equatable {
        case none
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var conversationID: String?
    @Published private(set) var messages: [TapMessage] = []
    @Published private(set) var state: State = .idle { didSet { if !writingTurnFailure { turnFailureRowID = nil } } }
    /// 回合失敗寫 state 時記下那一回合的失敗列；其他任何寫入都會清掉記號（不比對文字，同 Space 的 composerFailure）。
    private var turnFailureRowID: String?
    private var writingTurnFailure = false
    /// 私訊框上方那一行：只有寫它的那一回合的失敗列還在畫面上時才不重複；還沒連上、讀取中不能送、語音、還稿等照常顯示。
    var failureNotice: String? {
        guard case .failed(let reason) = state else { return nil }
        return ChatGPTFailureNotice.text(reason, rowID: turnFailureRowID, messages: messages)
    }
    @Published private(set) var loadState: LoadState = .none
    /// W184 G3b 第二輪（審查 #8）：這則是 ChatGPT「Work」模式開的（這裡只做 Chat：看得到、不能接著聊）。
    @Published private(set) var isWork = false
    /// W184 G3b 第二輪（審查 #4）：私訊框讀到的那一支最末端的節點（ChatGPT 上的代號；讀這則、別的地方送完重讀時記下）。
    /// 接著送出時交給 TAP 當上一層（同 ChatGPT Space 接在看著的那一支後面的做法）：別的地方（手機、另一台）後來又接著問過，
    /// 私訊框的這一則也接在它看到的內容後面（多一個版本），不會拿沒看過的上下文回答。自己送完一輪之後不知道確切的末端＝nil（照 ChatGPT 目前那一支）。
    private(set) var seenLeaf: String?
    /// 自己送的請求（TAP 通知「這則剛送完」時分得出是不是別人送的）。
    private var ownRequests: Set<String> = []
    /// W184 G3c（使用者：「右上隱私對話鈕無效 ui也跟原版不同」）：ChatGPT 的「臨時對話」（不存進紀錄）。新對話時可以開關；
    /// 開著送出＝跟 ChatGPT Space 的臨時聊天同一條路（TAP 在網頁自己的送出請求裡帶 history_and_training_disabled）；
    /// 送出後拿到的那一則記下來，接著在那一則送也照樣是臨時的。
    @Published var temporary = false
    /// 僅這則新對話的明確選擇；不寫入偏好，也不從外掛選擇推定。
    @Published var temporaryPersonalized = false
    @Published private(set) var temporaryConversationID: String?
    /// 現在這一則是臨時對話（新對話時看開關；已經有代號＝是不是臨時那一則）。
    var isTemporary: Bool { conversationID == nil ? temporary : conversationID == temporaryConversationID }
    private var updateWatch: AnyCancellable?
    /// W184 G3：私訊框的輸入框要看連線狀態（語音模式鈕），只讀。
    let tap: ChatGPTTap
    /// W184 G3：即時語音（跟 ChatGPT Space 同一套 ChatGPTVoiceMode）：在這則對話裡講；結束後把 ChatGPT 存下來的這則換上來。
    let voice: ChatGPTVoiceMode
    private var stopRequested = false
    @Published private(set) var stopNotice: String?
    @Published private var turnProgress = ChatGPTTurnProgress()
    private(set) var thinking: ChatGPTThinking? {
        get { turnProgress.thinking }
        set { turnProgress.thinking = newValue }
    }
    @Published private(set) var projectID: String?
    private var sentDraft = ""
    private var sentFiles: [TapAttachment] = []
    private var requestID: String?
    /// W184 G3（GPT-6 審查 6）：這則對話的版本——送出、開新對話、開始語音都加一；語音結束後讀回來的逐字稿版本對得上才換上
    /// （讀回來之前又送了一則、開了新對話或新的語音，舊的逐字稿就不蓋掉新的回答）。
    private(set) var revision = 0
    private var consumer: Task<Void, Never>?
    private var visibilityLease: UUID?
    private var connectionWatch: AnyCancellable?
    /// W184 G3 第三輪：誰拿著語音一變就重畫（另一邊拿著時私訊框要說一句、給「結束那邊的語音」）。
    private var voiceClaimWatch: AnyCancellable?
    /// 未送內容只放記憶體；接收方確認已放回輸入框前，不丟附件或移除使用者泡泡。
    struct ReturnedDraft: Identifiable {
        let id: String
        let conversationID: String?
        let text: String
        let attachments: [TapAttachment]
        let tool: String?
    }
    @Published private(set) var returnedDrafts: [ReturnedDraft] = []
    var returned: @MainActor (ReturnedDraft) -> Bool = { _ in false }
    var isSending: Bool { requestID != nil }

    convenience init() { self.init(tap: .shared) }

    init(tap: ChatGPTTap) {
        self.tap = tap
        self.voice = ChatGPTVoiceMode(tap: tap, holderNotice: "私訊框另一欄的語音模式還開著")
        if tap.connection == .needsLogin { state = .needsLogin }
        connectionWatch = tap.$connection.removeDuplicates().sink { [weak self] connection in
            guard let self else { return }
            if connection == .needsLogin {
                self.state = .needsLogin
            } else if connection == .ready, self.state == .needsLogin {
                self.state = .idle
            }
        }
        voice.conversation = { [weak self] in self?.conversationID }
        voice.finished = { [weak self] conversationID in self?.voiceEnded(in: conversationID) }
        voiceClaimWatch = tap.voiceClaims.removeDuplicates().sink { [weak self] _ in self?.objectWillChange.send() }
        // W184 G3b 第二輪（審查 #4）：同一則在別的地方（ChatGPT Space、私訊框另一欄）送完一輪＝重讀正本（自己沒在送時）。
        updateWatch = tap.$conversationUpdate.compactMap { $0 }.sink { [weak self] update in
            guard let self, update.conversationID == self.conversationID, !self.ownRequests.contains(update.requestID),
                  self.requestID == nil, !self.voice.voiceActive else { return }
            self.reload()
        }
    }

    /// 讀取中、讀不到、Work 模式的對話不能送：送不出的那一句（能送＝nil）。
    var sendBlocker: String? {
        if isWork { return Self.workNotice }
        switch loadState {
        case .loading: return "這則還在讀取，讀完再送"
        case .failed: return "這則沒讀到，先按「重試」讀一次再送"
        case .none, .loaded: return nil
        }
    }

    static let workNotice = "這則是 ChatGPT「Work」模式的對話（跟 Codex 共用額度）；這裡只做 Chat，不能接著聊"

    /// W184 G3 第三輪（修正核對 #1）：語音在另一邊手上（ChatGPT Space、或私訊框另一欄）時的那一句；自己拿著或沒人拿著＝nil。
    var voiceElsewhere: String? {
        guard tap.voiceClaim != nil, !voice.holdsVoice else { return nil }
        return tap.voiceHolderNotice ?? "另一邊的語音模式還開著"
    }

    /// 「結束那邊的語音」：請拿著語音的那一邊走它自己的確認結束。
    @discardableResult
    func endVoiceElsewhere() -> Bool {
        guard voiceElsewhere != nil else { return false }
        return tap.requestVoiceEnd()
    }

    /// 呼叫方在畫面開／關時成對使用；關閉畫面不停止正在送出的請求。
    func appear() {
        if visibilityLease == nil { visibilityLease = tap.acquireLease() }
        // 已知需要登入時不開登入頁；由 B 房帶去 ChatGPT Space。
        if tap.connection != .needsLogin { tap.start() }
    }

    func disappear() {
        if let visibilityLease { tap.releaseLease(visibilityLease) }
        visibilityLease = nil
    }

    /// W180：私訊框選的模型／思考強度與附件一起交給 TAP（nil／空＝照舊）；附件只在記憶體。
    /// W184 G3：「＋」選的工具（生圖、網路搜尋、App…）照 ChatGPT Space 的帶法交給 TAP（tool 代號＝網頁的 hint）。
    func send(_ text: String, model: String? = nil, effort: String? = nil, attachments: [TapAttachment] = [], tool: String? = nil) {
        let originalText = text
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty, requestID == nil else { return }
        // W184 G3（GPT-6 審查 7）：自己的語音模式開著時不送文字（送出會換頁、打字，切斷語音）；TAP 那邊另外排隊。
        guard !voice.voiceActive else { return }
        guard tap.connection != .needsLogin else { state = .needsLogin; return }
        guard tap.connection == .ready || tap.connection == .sleeping || tap.connection == .starting else {
            state = .failed("ChatGPT 還沒連上，請稍後再送")
            return
        }
        // W184 G3b 第二輪（審查 #3、#8）：讀取中、讀不到、Work 模式的對話不送（草稿留在輸入框）。
        if let blocker = sendBlocker {
            state = .failed(blocker)
            return
        }
        let id = UUID().uuidString
        let placeholder = "local-assistant-\(id)"
        requestID = id
        revision += 1
        stopRequested = false
        stopNotice = nil
        if ownRequests.count > 64 { ownRequests.removeAll() }
        ownRequests.insert(id)
        state = .queued
        turnProgress = ChatGPTTurnProgress(thinking: ChatGPTThinking())
        sentDraft = originalText
        sentFiles = attachments
        messages.append(TapMessage(id: "local-user-\(id)", role: .user, text: text, files: attachments.map(\.name)))
        messages.append(TapMessage(id: placeholder, role: .assistant, text: ""))
        // W184 G3b 第二輪（審查 #4）：接著舊對話送＝接在私訊框看到的那一支後面（上一層＝讀到的末端節點；不知道就照 ChatGPT 目前那一支）。
        let parent = conversationID == nil ? nil : seenLeaf
        seenLeaf = nil
        let stream = tap.send(requestID: id, text: text, conversationID: conversationID, model: model, effort: effort,
                              attachments: attachments, tool: tool, gizmoID: conversationID == nil ? projectID : nil, temporary: isTemporary, parentID: parent,
                              temporaryPersonalized: isTemporary && temporaryPersonalized)
        let unsent = ReturnedDraft(id: id, conversationID: conversationID, text: originalText, attachments: attachments, tool: tool)
        let returnDraft = returned
        consumer = Task { @MainActor [weak self] in
            var didReturn = false
            var hasResponse = false
            // 不跨 await 強持有 session；釋放畫面擁有者也能正常取消與還租約。
            for await event in stream {
                guard !Task.isCancelled, let self, self.requestID == id else { break }
                // TAP 的 accepted 也表示取得 Pod，不等於網站已送；網站 accepted 後的
                // submitted:false 由 TAP 降為一般 failed。這裡不把未知失敗猜成未送。
                let reason: String?
                switch event {
                case .notSubmitted(let message): reason = hasResponse ? nil : message
                case .failed(let message, _) where message == ChatGPTTap.queueTimeoutReason && self.state == .queued && !hasResponse:
                    reason = message
                default: reason = nil
                }
                if let reason, !didReturn {
                    didReturn = true
                    self.returnedDrafts.append(unsent)
                    self.seenLeaf = parent
                    self.state = self.stopRequested ? .idle : .failed(reason)
                    let restored = returnDraft(unsent)
                    if restored { self.confirmReturnedDraft(id) }
                    let note = reason + (restored ? "；已放回輸入框" : "；未送內容已保留，可手動恢復")
                    if self.stopRequested { self.stopNotice = note; self.state = .idle }
                    else { self.state = .failed(note) }
                    continue
                }
                if didReturn { continue }
                switch event {
                case .conversation, .text, .title, .finished: hasResponse = true
                default: break
                }
                self.consume(event, placeholder: placeholder)
            }
            guard let self, self.requestID == id else { return }
            self.requestID = nil
            self.sentFiles = []
            self.consumer = nil
            self.thinking = nil
            if self.stopRequested, !didReturn,
               let index = self.messages.firstIndex(where: { $0.id == placeholder }) {
                self.messages[index].stopNotice = "已停止"
            }
            self.messages.removeAll { $0.id == placeholder && $0.text.isEmpty && $0.stopNotice == nil && $0.turnFailure == nil }
            if self.state == .queued || self.state == .answering { self.state = .idle }
        }
    }

    func send(text: String) { send(text) }

    /// 只在輸入框完整接回內容後呼叫；手動恢復不會送出，也不換對話。
    func confirmReturnedDraft(_ id: String) {
        guard returnedDrafts.contains(where: { $0.id == id }) else { return }
        returnedDrafts.removeAll { $0.id == id }
        messages.removeAll { $0.id == "local-user-\(id)" || $0.id == "local-assistant-\(id)" }
    }

    func stop() {
        guard let id = requestID, !stopRequested else { return }
        stopRequested = true
        stopNotice = "已停止"
        thinking = nil
        state = .idle
        // 保留消費者等網站的未送出證據；回執逾時只標停止，不猜測還稿。
        tap.stop(requestID: id)
    }

    /// W184 G3b：私訊框換到 ChatGPT 的另一則（抽屜點的）：換編號、讀那則的內容（只放記憶體）。回答中、語音開著時不換（呼叫端先擋）。
    /// W184 G3b 第二輪（審查 #3）：讀取中（不能送）、讀不到（說出來、可以重試）跟新對話分開；同一則讀不到時再點一次＝重讀。
    func open(conversationID id: String) {
        guard requestID == nil, !voice.voiceActive else { return }
        revision += 1
        conversationID = id
        messages = []
        thinking = nil
        projectID = nil
        seenLeaf = nil
        isWork = false
        temporary = false
        temporaryPersonalized = false
        state = tap.connection == .needsLogin ? .needsLogin : .idle
        load(id, keepingMessages: false)
    }

    /// 讀不到的那則再讀一次。
    func retryLoad() {
        guard let conversationID, requestID == nil, case .failed = loadState else { return }
        load(conversationID, keepingMessages: false)
    }

    /// 重讀這則的正本（送完一輪、別的地方送完一輪時）：畫面上的換成 ChatGPT 上的；讀不到就維持原樣。
    func reload() {
        guard let conversationID, requestID == nil else { return }
        load(conversationID, keepingMessages: true)
    }

    private func load(_ id: String, keepingMessages: Bool) {
        let expected = revision
        if !keepingMessages { loadState = .loading }
        Task { @MainActor [weak self] in
            do {
                guard let self else { return }
                let fresh = try await self.tap.thread(conversationID: id, branch: nil)
                guard self.revision == expected, self.conversationID == id, self.requestID == nil else { return }
                self.messages = fresh.messages
                self.seenLeaf = fresh.leaf ?? fresh.messages.last?.id
                self.isWork = fresh.isWork
                self.projectID = fresh.projectID
                self.loadState = .loaded
                // 讀取中、讀不到時按了送出留下的那一句（「還在讀取」「先重試」）讀好了就收掉。
                if case .failed = self.state { self.state = self.tap.connection == .needsLogin ? .needsLogin : .idle }
            } catch {
                guard let self, self.revision == expected, self.conversationID == id, !keepingMessages else { return }
                self.loadState = .failed("讀不到這則對話：\(error.localizedDescription)")
            }
        }
    }

    func newConversation() {
        stop()
        revision += 1
        requestID = nil
        consumer?.cancel()
        consumer = nil
        stopRequested = false
        stopNotice = nil
        conversationID = nil
        projectID = nil
        thinking = nil
        messages = []
        seenLeaf = nil
        isWork = false
        loadState = .none
        temporary = false
        temporaryPersonalized = false
        state = tap.connection == .needsLogin ? .needsLogin : .idle
    }

    // MARK: W184 G3：即時語音

    /// 能不能開始即時語音：這則沒在送、TAP 沒人拿著語音、沒有回答在跑或排隊（ChatGPT Space 的也算；ChatGPTVoiceMode.canStart）。
    /// W184 G3c：臨時聊天裡不開——語音模式在網頁開的是一般對話（會存進紀錄），開了就不是臨時的了。
    var canStartVoice: Bool { requestID == nil && voice.canStart && !isTemporary }

    @discardableResult
    func startVoice() -> Bool {
        guard canStartVoice else { return false }
        revision += 1
        return voice.startVoice()
    }

    /// 語音結束：這次語音自己的那一則（開始時的對話；開始時是新對話＝live 期間看到的那一則）換上 ChatGPT 存下來的內容；只放記憶體。
    /// 讀回來時版本不一樣（中間又送了一則、開了新對話或新的語音）就不蓋掉。沒確認結束、關掉了語音那一頁時說一聲。
    private func voiceEnded(in conversationID: String?) {
        if voice.voiceStatus.hasPrefix("語音沒開起來") { state = .failed(voice.voiceStatus); return }
        if voice.lastEnd == .forced { state = .failed("語音那一頁沒有回應，已經關掉那一頁（麥克風停了）；等一下就能再用") }
        guard let conversationID else { return }
        if let current = self.conversationID, current != conversationID { return }   // 不是這一則的語音：不收
        let expected = revision
        Task { @MainActor [weak self] in
            guard let self, let fresh = try? await self.tap.thread(conversationID: conversationID, branch: nil),
                  self.revision == expected, self.requestID == nil else { return }
            self.conversationID = conversationID
            self.messages = fresh.messages
            self.seenLeaf = fresh.leaf ?? fresh.messages.last?.id
            self.isWork = fresh.isWork
            self.loadState = .loaded
        }
    }

    private func consume(_ event: TapStreamEvent, placeholder: String) {
        switch event {
        case .request:
            break
        case .queued:
            state = .queued
        case .accepted:
            state = .answering
        case .conversation(let id):
            // W184 G3c：臨時對話送出後 ChatGPT 給的那一則（不在紀錄裡）記下來，接著送也照樣是臨時的。
            if conversationID == nil, temporary { temporaryConversationID = id }
            conversationID = id
        case .progress:
            guard let index = messages.firstIndex(where: { $0.id == placeholder }), messages[index].text.isEmpty else { return }
            var updated = ChatGPTTurnProgress(thinking: thinking)
            updated.apply(event)
            if updated != turnProgress { turnProgress = updated }
        case .text(_, let full):
            if !full.isEmpty, thinking != nil, let index = messages.firstIndex(where: { $0.id == placeholder }) {
                turnProgress.apply(event)
                messages[index].thoughtSeconds = turnProgress.thoughtSeconds
            }
            if let index = messages.firstIndex(where: { $0.id == placeholder }) { messages[index].text = full }
            state = .answering
        case .title:
            break
        case .finished:
            state = .idle
        case .notSubmitted(let reason):
            state = .failed(reason)
        case .failed(let reason, let code):
            thinking = nil
            if let index = messages.firstIndex(where: { $0.id == placeholder }) {
                messages[index].turnFailure = ChatGPTTurnFailure(message: reason, reason: code, draft: sentDraft, projectID: projectID, files: sentFiles)
            }
            if tap.connection == .needsLogin { state = .needsLogin } else {
                writingTurnFailure = true; state = .failed(reason); writingTurnFailure = false
                turnFailureRowID = placeholder
            }
        }
    }

    /// The caller fills its composer after this; no send is performed.
    func recover(_ failure: ChatGPTTurnFailure) -> String {
        if failure.isTooLong {
            let project = failure.projectID
            newConversation()
            projectID = project
        }
        return failure.draft
    }

    deinit {
        consumer?.cancel()
        let tap = tap
        let lease = visibilityLease
        let request = requestID
        Task { @MainActor in
            if let request { tap.stop(requestID: request) }
            if let lease { tap.releaseLease(lease) }
        }
    }
}
