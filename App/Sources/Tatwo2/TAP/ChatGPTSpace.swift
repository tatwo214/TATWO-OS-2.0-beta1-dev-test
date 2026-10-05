import AppKit
import Combine
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

/// W177 ChatGPT Space：原生畫面。版面照 ChatGPT 網頁版（使用者 2026-09-24「整個ui要盡可能接近chatgpt頁面 並且功能要對齊」）：
/// 側欄＝新對話、搜尋、釘選、專案、依日期的對話；主畫面＝標題、對話、輸入框（模型／推理強度選單在輸入框裡）。
/// 只透過 TAP 的 ConversationTap 跟 ChatGPT 說話；Markdown、輸入框沿用 Coder 的元件，看起來跟 OS 其他地方一致。
@MainActor
final class ChatGPTSpaceModel: ObservableObject {
    static let shared = ChatGPTSpaceModel()
    static let modelKey = "tatwo.tap.chatgpt.model"
    static let effortKey = "tatwo.tap.chatgpt.effort"
    static let pageModelKey = "tatwo.tap.chatgpt.pageModel"
    static let pageEffortKey = "tatwo.tap.chatgpt.pageEffort"

    let tap: ChatGPTTap
    @Published private(set) var conversations: [TapConversation] = []
    @Published private(set) var total = 0
    @Published private(set) var pinned: [TapFolder] = []
    @Published private(set) var projects: [TapFolder] = []
    @Published private(set) var projectsLoadState: ChatGPTListLoadState = .idle
    private var projectsLoad: Task<Void, Never>?
    @Published var showsProjectCreation = false
    @Published var projectName = ""
    @Published private(set) var creatingProject = false
    @Published private(set) var projectCreationFailure: String?
    var canCreateProject: Bool { !creatingProject && !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func beginProjectCreation() {
        guard !creatingProject else { return }
        projectName = ""; projectCreationFailure = nil; showsProjectCreation = true
    }

    func createProject() {
        guard showsProjectCreation, canCreateProject else { return }
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        creatingProject = true; projectCreationFailure = nil
        Task { @MainActor in
            let lease = tap.acquireLease(backgroundWork: true)
            defer { creatingProject = false; tap.releaseLease(lease) }
            do {
                if tap.connection == .needsLogin { throw TapError.remote("請先登入 ChatGPT，再建立專案") }
                try await readyForDirectory()
                let folder = try await tap.createProject(name: name, description: "")
                projectsLoad?.cancel(); projectsLoad = nil
                projects.removeAll { $0.id == folder.id }; projects.insert(folder, at: 0)
                projectsLoadState = .loaded
                projectConversations[folder.id] = []; projectLoadStates[folder.id] = .loaded
                if showsProjectCreation {
                    expandedProjects.insert(folder.id); newChat(with: folder)
                    showsProjectCreation = false
                }
            } catch { projectCreationFailure = "建立失敗：" + error.localizedDescription }
        }
    }
    @Published private(set) var projectConversations: [String: [TapConversation]] = [:]
    @Published private(set) var expandedProjects: Set<String> = []
    @Published private(set) var projectLoadStates: [String: ChatGPTListLoadState] = [:]
    @Published private(set) var listFailure: String?
    @Published private(set) var searchLoadState: ChatGPTListLoadState = .idle
    private var projectLoads: [String: Task<Void, Never>] = [:]
    private var listTicket: UUID?
    private var directoryGeneration = 0
    @Published private(set) var selectedID: String?
    @Published private(set) var messages: [TapMessage] = []
    @Published private(set) var models: [TapModel] = []
    @Published private(set) var defaultModelID: String?
    /// ChatGPT 伺服器記的「上次使用」檔位（網頁、桌面版、手機共用）；Space 沒特別選時就用它。
    @Published private(set) var defaultEffortID: String?
    /// 網頁自己實際在用的模型與強度（記住，下次打開就對）；使用者沒特別選時，選單照這個顯示。
    @Published private(set) var pageModelID: String?
    @Published private(set) var pageEffortID: String?
    private var selectionWatch: AnyCancellable?
    /// 使用者自己選的模型；nil＝用 ChatGPT 的預設。
    @Published var selectedModelID: String? {
        didSet {
            UserDefaults.standard.set(selectedModelID, forKey: Self.modelKey)
            // 換模型時，新模型沒有的推理強度就改回預設。
            if let effort = selectedEffortID, !(currentModel?.efforts.contains { $0.id == effort } ?? false) {
                selectedEffortID = nil
            }
        }
    }
    /// 使用者自己選的推理強度；nil＝用 ChatGPT 的預設。
    @Published var selectedEffortID: String? {
        didSet { UserDefaults.standard.set(selectedEffortID, forKey: Self.effortKey) }
    }
    @Published var draft = ""
    /// 未送出的完整草稿只留記憶體；換頁或新草稿衝突時，不能只留附件檔名。
    struct UnsentDraft {
        let text: String
        let files: [TapAttachment]
        let tool: TapTool?
        let conversationID: String?
        let gpt: TapFolder?
        let temporary: Bool
        var temporaryPersonalized = false
        let branchLeaf: String?
    }
    @Published private(set) var unsentDrafts: [UnsentDraft] = []
    var canRestoreUnsentDraft: Bool {
        !isSending && draft.isEmpty
            && attachments.isEmpty && selectedTool == nil
    }
    func restoreUnsentDraft() {
        guard canRestoreUnsentDraft, let saved = unsentDrafts.first else { return }
        if let id = saved.conversationID { select(id) }
        else { newChat(with: saved.gpt); temporaryChat = saved.temporary }
        temporaryPersonalized = saved.temporaryPersonalized
        branchLeaf = saved.branchLeaf
        draft = saved.text
        attachments = saved.files
        selectedTool = saved.tool
        unsentDrafts.removeFirst()
        failure = "未送出的內容已放回輸入框，尚未重新送出"
    }
    /// 側欄搜尋：打字 0.35 秒後問 ChatGPT 伺服器（搜得到還沒載入的舊對話）；失敗就只搜已載入的標題。
    @Published var search = "" { didSet { scheduleSearch() } }
    @Published private(set) var searchResults: [TapConversation]?
    private var searchTask: Task<Void, Never>?
    private var searchResultQuery = ""
    /// 對話選項（跟網頁版一樣）：重新命名、封存、刪除（刪除要再確認一次）。
    /// 「＋」裡的 ChatGPT 工具（生圖、網路搜尋…）；選了會在輸入框出現小卡，送出時帶上。
    /// W184 G3b 第二輪：「＋」與「/」的清單一律是 TAP 從 ChatGPT 網頁讀到的這一份；這次開 App 還沒讀到時先用上次讀到的（toolsCacheKey，
    /// 只有名稱、說明與分層旗標），從沒讀過＝空的（畫面寫一行說明，不自己編預設清單）。
    @Published private(set) var tools: [TapTool] = []
    /// Space 與私訊框沿用同一份 $tools；刷新只經這個入口，舊連線回應不能寫回目錄或快取。
    private lazy var toolCatalog = ChatGPTToolCatalog<[TapTool]>(
        load: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.tap.tools()
        },
        publish: { [weak self] loaded in
            guard let self else { return }
            self.tools = loaded
            Self.cacheTools(loaded, in: .standard)
        }
    )
    @Published var selectedTool: TapTool?
    /// 新對話頁：ChatGPT 自己的問候語與建議。
    @Published private(set) var greeting: String?
    @Published private(set) var suggestions: [TapSuggestion] = []
    /// GPTs：點一下就跟那個 GPT 開新對話。
    @Published private(set) var gpts: [TapFolder] = []
    @Published private(set) var activeGPT: TapFolder?
    /// 暫時對話（網頁版右上角的開關）：這則新對話不存進紀錄；送出一次後就是那則對話的狀態。
    @Published var temporaryChat = false
    /// 只屬於這一則；必須從臨時聊天選單明確選擇，不沿用全域偏好。
    @Published var temporaryPersonalized = false
    /// 目前這則是暫時對話（有編號但不在紀錄裡）：標題顯示「暫時對話」、不列進側欄、沒有對話選項。
    @Published private(set) var temporaryConversationID: String?
    /// 正在看的不是 ChatGPT 目前那一支（切換過版本）時，這一支最末端的節點；接著送出就接在它後面。
    @Published private(set) var branchLeaf: String?
    /// 側欄的頁面（跟網頁一樣：圖庫、排程、外掛、網站；帳號選單裡的個人化）；nil＝對話。
    @Published private(set) var page: ChatGPTPage?
    var dotsPresented: Bool { tap.dotsState != .closed }
    private var dotsTask: Task<Void, Never>?
#if DEBUG
    /// 無 Chromium 的隔離自測只替換網頁表面；導覽、租約與原生按鈕仍走正式碼。
    var dotsPageForSelfTest: AnyView?
    var dotsBrowserOpenForSelfTest: ((URL) -> Void)?
    var dotsControlFramesForSelfTest: [String: CGRect] = [:]
    var failureNoticeForSelfTest: ((String) -> Void)?
#endif
    var showingLibrary: Bool { page == .library }
    // 排程、外掛、網站、個人化、帳號（使用者 09-25「2全要」）。
    @Published private(set) var automations: [TapAutomation] = []
    @Published private(set) var installedPlugins: [TapPlugin] = []
    @Published private(set) var pluginSections: [TapPluginSection] = []
    @Published private(set) var sites: [TapSite] = []
    @Published private(set) var memories: [TapMemory] = []
    @Published private(set) var memoryUsage: Int?
    @Published var instructions = TapInstructions()
    @Published private(set) var instructionsLoaded = false
    @Published private(set) var account: TapAccount?
    @Published private(set) var pageLoading = false
    @Published var pageFailure: String?
    @Published var pageNotice: String?
    @Published var removeAutomationTarget: TapAutomation?
    @Published var uninstallPluginTarget: TapPlugin?
    /// 外掛詳細頁（點外掛列或已安裝的圖示打開；使用者 09-25「mcp的部分無法點擊進去」）。
    @Published private(set) var pluginDetailTarget: TapPlugin?
    @Published private(set) var pluginDetail: TapPluginDetail?
    @Published private(set) var pluginDetailFailure: String?
    @Published var deleteMemoryTarget: TapMemory?
    @Published var clearMemoriesRequested = false
    @Published var deleteLibraryTarget: TapLibraryItem?
    /// 分享（對話或單一提問）：先說明會建立公開連結，按了才建立。
    struct ShareRequest: Identifiable {
        let id = UUID()
        let conversationID: String
        let messageID: String?
        let title: String
    }
    @Published var shareRequest: ShareRequest?
    @Published private(set) var shareURL: URL?
    @Published private(set) var shareStopped = false
    @Published private(set) var sharing = false
    @Published private(set) var shareFailure: String?
    /// 在 Space 裡打開網頁版的某一頁（設定、外掛登入…）。
    /// 即時語音（網頁的語音模式在 Pod 裡跑，這裡蓋原生畫面）。W184 G3：開始、看狀態、結束抽成 ChatGPTVoiceMode（私訊框同一套）；
    /// Space 照舊看自己的 voiceActive／voiceLive／voiceStatus（變動轉發出去，畫面照常更新）。
    let voice: ChatGPTVoiceMode
    private var voiceForward: AnyCancellable?
    var voiceActive: Bool { voice.voiceActive }
    var voiceLive: Bool { voice.voiceLive }
    var voiceStatus: String { voice.voiceStatus }
    var voiceStopping: Bool { voice.voiceStopping }
    @Published var libraryTab: TapLibraryTab = .suggested {
        didSet { if libraryTab != oldValue { reloadLibrary() } }
    }
    @Published var libraryQuery = "" { didSet { scheduleLibrarySearch() } }
    @Published private(set) var libraryItems: [TapLibraryItem] = []
    @Published private(set) var libraryLoading = false
    @Published private(set) var libraryFailure: String?
    @Published var libraryNotice: String?
    private var libraryCursor: String?
    private var libraryTask: Task<Void, Never>?
    /// 最近在「＋」選過的 App（跟網頁版一樣排在前面）。
    static let recentAppsKey = "tatwo.tap.chatgpt.recentApps"
    /// W184 G3b 第二輪：最後一次從 ChatGPT 讀到的工具與 App（讀不到時用；只有代號、名稱、一行說明與分層旗標，沒有對話內容）。
    static let toolsCacheKey = "tatwo.tap.chatgpt.toolsCache"
    /// 對話清單在 TAP 上更新了（私訊框在新對話送完、別的地方在這則送完）：抽屜與側欄的清單跟著更新。
    private var conversationUpdateWatch: AnyCancellable?
    private var mappedConversationLoad: Task<Void, Never>?
    /// 要附上的檔案（只在記憶體；送出時交給 ChatGPT 網頁自己上傳）。合計上限 20 MB。
    @Published private(set) var attachments: [TapAttachment] = []
    nonisolated static let attachmentLimit = 20 * 1024 * 1024
    /// W184 G3 第三輪（修正核對 #5）：圖片最多讀 200 MB（讀進來照舊由 admit 轉成 ChatGPT 看得懂的 JPEG，合計 20 MB 的規矩不變）；
    /// 其他檔案最多 20 MB。以前轉 JPEG 後收得下的大張 HEIC／TIFF／RAW 照樣收得下。
    nonisolated static let imageReadLimit = 200 * 1024 * 1024
    /// 圖片只放記憶體（對話內容不落地）。
    private let imageCache = NSCache<NSString, NSImage>()
    /// 點圖片放大看。
    @Published var zoomedImage: NSImage?
    /// 放大的圖從哪來：下載時照來源取原檔；同一則訊息有好幾張圖時可以左右切換（跟 Coder 的圖片預覽一樣）。
    enum ZoomSource {
        case library(TapLibraryItem)
        case conversation(pointer: String, gallery: [String])
    }
    @Published private(set) var zoomSource: ZoomSource?
    @Published var renameTarget: TapConversation?
    @Published var renameText = ""
    @Published var deleteTarget: TapConversation?
    @Published private(set) var isSending = false
    @Published private(set) var isLoadingList = false
    @Published private(set) var isLoadingMessages = false
    /// 開過（或預載過）的對話留在記憶體，再開立刻顯示、同時拿最新的換上（使用者 09-25「chatgpt的載入速度需要加快」）。
    /// 只在記憶體、最多 cacheLimit 則；對話內容不落地。
    private var messageCache: [String: [TapMessage]] = [:]
    private var conversationFailures: [String: TapMessage] = [:]
    private var messageCacheOrder: [String] = []
    private var messageLoads: [String: Task<[TapMessage]?, Never>] = [:]
    static let cacheLimit = 30
    /// 通知開關的代號（跟 Space 設定裡的分頁代號一樣）。
    static let noticeSpace = "chatgpt"
    /// ChatGPT Space 正在畫面上（背景預熱時不要排休眠給正在看的人）。
    private var visible = false
    /// 每次換對話／開新對話加一：送出中切走之後，舊的送出不能再把畫面拉回它那則。
    /// W180 A2：對話區也用它當識別——換則／開新對話就重建捲動區，不沿用上一則長對話的捲動位置
    /// （09-27 實機：看過長對話再開新對話，新畫面與送出後的提問、錯誤訊息都落在看不到的位置）。
    @Published private(set) var viewEpoch = 0
    @Published private(set) var stopNotice: String?
    @Published private var turnProgress = ChatGPTTurnProgress()
    private(set) var thinking: ChatGPTThinking? {
        get { turnProgress.thinking }
        set { turnProgress.thinking = newValue }
    }
    @Published var failure: String? { didSet { if !writingTurnFailure { turnFailureRowID = nil } } }
    /// 送出流程寫 failure 時記下那一回合的失敗列；其他任何寫入都會清掉記號（不比對文字）。
    private var turnFailureRowID: String?
    private var writingTurnFailure = false
    private func showTurnFailure(_ text: String, rowID: String) {
        writingTurnFailure = true; failure = text; writingTurnFailure = false
        turnFailureRowID = rowID
    }
    /// 輸入框上方那一行：只有寫它的那一回合的失敗列還在畫面上時才不重複；其他操作的錯誤、或那一列已被換掉時照常顯示。
    var composerFailure: String? {
        ChatGPTFailureNotice.text(failure, rowID: turnFailureRowID, messages: messages)
    }
    private var loadedOnce = false
    private var connectionWatch: AnyCancellable?
    private var foregroundWatch: AnyCancellable?
    private var handsConnectionWatch: AnyCancellable?
    private var visibilityLease: UUID?
    private var requestID: String?
    private var stopRequested = false
    /// 離開 ChatGPT Space 多久沒回來就讓 Pod 休眠（8 GB 機器上隱藏網頁約佔 150–300 MB）。
    static let idleSleepDelay: Duration = .seconds(15 * 60)

    private init() {
        tap = .shared
        voice = ChatGPTVoiceMode(tap: tap, holderNotice: "ChatGPT Space 的語音模式還開著")
        tools = Self.cachedTools(in: .standard)
        selectedModelID = UserDefaults.standard.string(forKey: Self.modelKey)
        selectedEffortID = UserDefaults.standard.string(forKey: Self.effortKey)
        pageModelID = UserDefaults.standard.string(forKey: Self.pageModelKey)
        pageEffortID = UserDefaults.standard.string(forKey: Self.pageEffortKey)
        observeDirectoryConnection()
        observeForeground()
        selectionWatch = tap.$pageSelection.sink { [weak self] selection in
            guard let self, let selection else { return }
            self.pageModelID = selection.model
            self.pageEffortID = selection.effort
            UserDefaults.standard.set(selection.model, forKey: Self.pageModelKey)
            UserDefaults.standard.set(selection.effort, forKey: Self.pageEffortKey)
        }
        // W184 G3：語音在正在看的那則；結束後照舊重讀清單、換上那則（voiceFinished）。
        voice.conversation = { [weak self] in self?.selectedID }
        voice.finished = { [weak self] conversationID in self?.voiceFinished(conversationID: conversationID) }
        voiceForward = voice.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // W184 G3b 第二輪（審查 #5）：私訊框建的新對話（或清單裡還沒有的那則）送完了，清單重讀第一頁，抽屜才找得到它。
        conversationUpdateWatch = tap.$conversationUpdate.compactMap { $0 }.sink { [weak self] update in
            guard let self, !self.conversations.contains(where: { $0.id == update.conversationID }) else { return }
            Task { @MainActor in await self.reloadConversationList() }
        }
        // 等本單例初始化完成才取得配對流程；testTap init 不訂閱正式流程，也不碰 shared Pod。
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.observeHandsConnection(HandsConnectFlow.shared.$phase.eraseToAnyPublisher())
        }
    }

#if DEBUG
    /// 不接 shared Pod、不讀寫偏好、不訂閱背景刷新，僅供隔離測試。
    init(testTap: ChatGPTTap) {
        tap = testTap
        voice = ChatGPTVoiceMode(tap: testTap, holderNotice: "fixture")
        observeDirectoryConnection(skipInitial: true)
        observeForeground()
    }

#endif

    private func observeForeground() {
        foregroundWatch = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in
            guard let self, self.visible else { return }
            self.retryProjects()
        }
    }

    /// hello 在 ready 時也可能是網頁重開；每次重新就緒都重讀已展開的專案。
    private func observeDirectoryConnection(skipInitial: Bool = false) {
        let states = tap.$connection.dropFirst(skipInitial ? 1 : 0)
        connectionWatch = states.sink { [weak self] connection in
            guard let self else { return }
            self.directoryGeneration += 1
            self.toolCatalog.connectionChanged(ready: connection == .ready, renewed: true)
            guard connection == .ready else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refresh()
                if !self.search.isEmpty { self.scheduleSearch() }
            }
        }
    }

    /// 清單讀取持有背景租約，休眠時沿用 W195 喚醒與 60 秒期限。
    private func readyForDirectory() async throws {
        if case .failed = tap.connection { tap.start() }
        try await tap.readyForSend()
    }

    private func directoryRead<T>(_ read: () async throws -> T) async throws -> T? {
        let lease = tap.acquireLease(backgroundWork: true)
        defer { tap.releaseLease(lease) }
        try await readyForDirectory()
        let generation = directoryGeneration
        do {
            let value = try await read()
            try Task.checkCancellation()
            return generation == directoryGeneration ? value : nil
        } catch {
            guard generation == directoryGeneration, !Task.isCancelled else { return nil }
            throw error
        }
    }

    func reloadConversationList() async {
        let ticket = UUID()
        listTicket = ticket
        isLoadingList = true
        listFailure = nil
        defer { if listTicket == ticket { isLoadingList = false } }
        do {
            guard let page = try await directoryRead({ try await tap.conversations(offset: 0, limit: max(50, conversations.count)) }),
                  listTicket == ticket else { return }
            if conversations != page.items { conversations = page.items }
            if total != page.total { total = page.total }
            loadedOnce = true
        } catch {
            if listTicket == ticket { listFailure = "讀不到對話清單" }
        }
    }

    /// 上次從 ChatGPT 讀到的工具與 App（沒有＝空的）。
    static func cachedTools(in defaults: UserDefaults) -> [TapTool] {
        (defaults.array(forKey: toolsCacheKey) as? [[String: Any]] ?? []).compactMap { item -> TapTool? in
            guard let id = item["id"] as? String, !id.isEmpty, let title = item["title"] as? String, !title.isEmpty else { return nil }
            var tool = TapTool(id: id, title: title, detail: item["detail"] as? String ?? "", primary: item["primary"] as? Bool ?? true)
            tool.rank = (item["rank"] as? NSNumber)?.doubleValue
            tool.isApp = item["app"] as? Bool ?? false
            tool.headApp = item["head"] as? Bool ?? false
            tool.hidden = item["hidden"] as? Bool ?? false
            tool.firstPartyApp = item["firstParty"] as? Bool ?? false
            return tool
        }
    }

    /// 記下這次從 ChatGPT 讀到的工具與 App（下次讀不到時用）。
    static func cacheTools(_ tools: [TapTool], in defaults: UserDefaults) {
        defaults.set(tools.map { tool -> [String: Any] in
            var item: [String: Any] = ["id": tool.id, "title": tool.title, "detail": tool.detail, "primary": tool.primary, "app": tool.isApp,
                                       "head": tool.headApp, "hidden": tool.hidden, "firstParty": tool.firstPartyApp]
            if let rank = tool.rank { item["rank"] = rank }
            return item
        }, forKey: toolsCacheKey)
    }

    /// 記住的代號在目前的選單裡找得到才算數（選單結構改版後，舊的記錄會對不上，09-24 實機）。
    private func existing(_ id: String?) -> String? { id.flatMap { id in models.contains { $0.id == id } ? id : nil } }
    var effectiveModelID: String? { existing(selectedModelID) ?? existing(pageModelID) ?? defaultModelID }
    var currentModel: TapModel? { models.first { $0.id == effectiveModelID } }
    /// 目前會用的強度選項：使用者選的；沒選且模型也沒換過，就是網頁自己的（都要在目前模型的檔位裡）。
    var effectiveEffortID: String? {
        let efforts = Set(currentModel?.efforts.map(\.id) ?? [])
        if let selectedEffortID, efforts.contains(selectedEffortID) { return selectedEffortID }
        // 沒特別選：先用 ChatGPT 伺服器的「上次使用」（跟網頁一樣），讀不到才用 Pod 上次實際送出的。
        if let defaultEffortID, efforts.contains(defaultEffortID) { return defaultEffortID }
        guard existing(selectedModelID) == nil || selectedModelID == pageModelID else { return nil }
        return pageEffortID.flatMap { efforts.contains($0) ? $0 : nil }
    }
    /// 輸入框膠囊與面板標題上的字，照網頁：「6 Pro」＝版本（黑字）＋檔位；最新版的一般檔位只有名字（High）；
    /// 最高檔（Pro）名字是紫色。
    struct PickerLabel: Equatable {
        var version: String?
        var level: String
        var isMax: Bool
    }
    var pickerLabel: PickerLabel {
        // W184 G3：規則抽成 PickerLabel.resolve（私訊框的膠囊同一條）。
        .resolve(effort: currentEffort, model: currentModel, fallback: "ChatGPT")
    }
    /// 使用者在 Space 選的跟 ChatGPT 的「上次使用」不一樣時，面板右上角才出現「↺ 重設」（跟網頁一樣）。
    var canResetSelection: Bool {
        (selectedEffortID != nil || selectedModelID != nil) && (effectiveEffortID != defaultEffortID || effectiveModelID != defaultModelID)
    }
    func resetSelection() {
        selectedModelID = nil
        selectedEffortID = nil
    }
    /// 輸入框裡選單上的字：跟網頁版一樣，有推理強度就顯示強度（換成中文），沒有就顯示模型名稱。
    var pickerTitle: String {
        if let effort = effectiveEffortID, let title = currentModel?.efforts.first(where: { $0.id == effort })?.title {
            return ChatGPTLabels.effort(title)
        }
        return currentModel?.title ?? "ChatGPT"
    }
    /// 思考強度面板上方的「6 Pro」：目前檔位的顯示版本＋顯示名稱。
    var currentEffort: TapEffort? {
        guard let efforts = currentModel?.efforts, !efforts.isEmpty else { return nil }
        return efforts.first { $0.id == effectiveEffortID }
    }
    var headerVersion: String {
        if let version = currentEffort?.version, !version.isEmpty { return version }
        return ChatGPTLabels.version(currentModel?.title ?? "")
    }
    var headerLevel: String {
        if let effort = currentEffort { return ChatGPTLabels.effort(effort.level.isEmpty ? effort.title : effort.level) }
        return currentEffort == nil && !(currentModel?.efforts.isEmpty ?? true) ? "預設" : (currentModel?.title ?? "ChatGPT")
    }
    var selectedTitle: String {
        guard let selectedID else { return activeGPT?.title ?? (temporaryChat ? "臨時聊天" : "新對話") }
        if selectedID == temporaryConversationID { return "臨時聊天" }
        let all = conversations + projectConversations.values.flatMap { $0 }
        return all.first { $0.id == selectedID }?.title ?? "新對話"
    }
    var filteredConversations: [TapConversation] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return conversations }
        if searchResultQuery == query, let searchResults { return searchResults }
        return conversations.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    func retrySearch() { scheduleSearch() }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { searchResults = nil; searchResultQuery = ""; searchLoadState = .idle; return }
        if searchResultQuery != query { searchResults = nil }
        searchLoadState = .loading
        searchTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            do {
                guard let found = try await self.directoryRead({ try await self.tap.search(query: query) }),
                      self.search.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                self.searchResults = found
                self.searchResultQuery = query
                self.searchLoadState = .loaded
            } catch {
                guard !Task.isCancelled, self.search.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                self.searchLoadState = .failed("讀不到搜尋結果")
            }
        }
    }

    func cachedImage(_ pointer: String) -> NSImage? { imageCache.object(forKey: pointer as NSString) }

    func loadImage(_ pointer: String) async -> NSImage? {
        if let cached = cachedImage(pointer) { return cached }
        // 暫時對話的圖也要讀得到：有編號就帶，沒有就不帶（09-24 實機）。
        guard let data = try? await tap.imageData(pointer: pointer, conversationID: selectedID),
              let image = NSImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: pointer as NSString)
        return image
    }

    func beginRename(_ item: TapConversation) {
        renameText = item.title
        renameTarget = item
    }

    func commitRename() {
        guard let target = renameTarget else { return }
        renameTarget = nil
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != target.title else { return }
        Task {
            do {
                try await tap.rename(conversationID: target.id, title: title)
                updateTitle(target.id, title)
            } catch {
                failure = "重新命名沒有完成：\(error.localizedDescription)"
            }
        }
    }

    func isPinned(_ id: String) -> Bool { pinned.contains { $0.id == id } }

    func togglePin(_ item: TapConversation) {
        let pin = !isPinned(item.id)
        Task {
            do {
                try await tap.setPinned(conversationID: item.id, pinned: pin)
                if let loaded = try? await tap.pinned() { pinned = loaded }
            } catch {
                failure = "\(pin ? "釘選" : "取消釘選")沒有完成：\(error.localizedDescription)"
            }
        }
    }

    /// 在新對話分支（網頁 More actions → Branch in new chat），開好就切過去。
    func branch() {
        guard !isSending, let conversationID = selectedID else { return }
        Task {
            do {
                if let newID = try await tap.branch(conversationID: conversationID) {
                    await refresh()
                    select(newID)
                }
            } catch {
                failure = "分支沒有完成：\(error.localizedDescription)"
            }
        }
    }

    func archive(_ item: TapConversation) {
        Task {
            do {
                try await tap.archive(conversationID: item.id)
                removeLocally(item.id)
            } catch {
                failure = "封存沒有完成：\(error.localizedDescription)"
            }
        }
    }

    func confirmDelete() {
        guard let target = deleteTarget else { return }
        deleteTarget = nil
        Task {
            do {
                try await tap.delete(conversationID: target.id)
                removeLocally(target.id)
            } catch {
                failure = "刪除沒有完成：\(error.localizedDescription)"
            }
        }
    }

    private func updateTitle(_ id: String, _ title: String) {
        if let index = conversations.firstIndex(where: { $0.id == id }) { conversations[index].title = title }
        if let index = searchResults?.firstIndex(where: { $0.id == id }) { searchResults?[index].title = title }
        for key in projectConversations.keys {
            if let index = projectConversations[key]?.firstIndex(where: { $0.id == id }) { projectConversations[key]?[index].title = title }
        }
    }

    private func removeLocally(_ id: String) {
        conversations.removeAll { $0.id == id }
        searchResults?.removeAll { $0.id == id }
        for key in projectConversations.keys { projectConversations[key]?.removeAll { $0.id == id } }
        if selectedID == id {
            selectedID = nil
            messages = []
        }
    }
    /// W180 A2：生圖這類非同步回答（串流結束時 ChatGPT 還在產生、正本還沒存好）：在等的那則對話。
    @Published private(set) var awaitingAsyncReplyID: String?
    var waitingForFirstWords: Bool {
        isSending && (messages.last.map { $0.role == .assistant && $0.text.isEmpty } ?? false)
    }
    var lastAssistantID: String? { messages.last { $0.role == .assistant }?.id }
    /// 設定頁「探查網頁選單」用：目前選的對話。
    var selectedIDForProbe: String? { selectedID }

    func appear() {
        visible = true
        tap.setSpaceVisible(true)
        if visibilityLease == nil { visibilityLease = tap.acquireLease() }
        tap.start()
        if tap.connection == .ready { Task { await refresh() } }
    }

    func disappear() {
        closeDots()
        visible = false
        tap.setSpaceVisible(false)
        // W184 G3 第三輪（修正核對 #1）：Space 主畫面不在了（切到 Coder 等其他模式、關 ChatGPT 分頁）＝結束 Space 的即時語音，
        // 跟私訊框同一條規則（語音畫面和停止鈕跟著看不到，不讓麥克風在背景開著、也不讓私訊框被沒人看得到的語音卡住）。
        voice.endVoice()
        if let visibilityLease { tap.releaseLease(visibilityLease) }
        visibilityLease = nil
        scheduleIdleSleep()
    }

    private func scheduleIdleSleep() {
        tap.scheduleIdleSleep(after: Self.idleSleepDelay)
    }

    func refresh() async {
        // 清單以外的（釘選、專案、模型、工具、GPTs、首頁建議）跟清單同時一起要、各自到了就顯示
        // （使用者 09-25「chatgpt的載入速度需要加快」：以前一個等一個，每個都是一次網路來回）。專案失敗保留清單並提供重試（W203）；同值不重寫（W202）。
        Task { if let loaded = try? await tap.pinned(), pinned != loaded { pinned = loaded } }
        retryProjects()
        for id in expandedProjects { retryProject(id) }
        if models.isEmpty {
            Task {
                guard models.isEmpty, let loaded = try? await tap.models() else { return }
                models = loaded.items
                defaultModelID = loaded.defaultID
                defaultEffortID = loaded.currentEffortID
            }
        }
        refreshToolCatalog()
        if gpts.isEmpty { Task { if let loaded = try? await tap.gpts() { gpts = loaded } } }
        if suggestions.isEmpty {
            Task {
                guard let loaded = try? await tap.home() else { return }
                greeting = loaded.greeting
                suggestions = Array(loaded.suggestions.prefix(4))
            }
        }
        await reloadConversationList()
    }

    func retryProjects() {
        projectsLoad?.cancel()
        if projects.isEmpty && projectsLoadState != .loaded { projectsLoadState = .loading }
        projectsLoad = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { projectsLoad = nil } }
            do {
                guard let loaded = try await directoryRead({ try await tap.projects() }) else { return }
                if projects != loaded { projects = loaded }   // W202：同值不重寫，避免多一輪重畫
                projectsLoadState = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                if projects.isEmpty && projectsLoadState != .loaded { projectsLoadState = .failed("讀不到專案清單") }
            }
        }
    }

    /// App 開好後在背景先把 ChatGPT 準備好（使用者 09-25「載入速度需要加快」）：點進分頁時不用再等網頁開機、清單已經讀好。
    /// 只在登入過（用過）才做；沒用到一樣 15 分鐘後休眠省記憶體；ChatGPT 在 設定 › Plugin › TAP 停用時不開。
    func prewarm() {
        guard ChatGPTTap.isEnabled, ChatGPTTap.hasBeenReady, !visible, !tap.pod.isRunning else { return }
        tap.start()
        scheduleIdleSleep()
    }

    func loadMore() async {
        guard !isLoadingList, conversations.count < total else { return }
        let ticket = UUID(); listTicket = ticket
        isLoadingList = true; listFailure = nil
        defer { if listTicket == ticket { isLoadingList = false } }
        do {
            guard let page = try await directoryRead({ try await tap.conversations(offset: conversations.count, limit: 50) }),
                  listTicket == ticket else { return }
            let known = Set(conversations.map(\.id))
            conversations += page.items.filter { !known.contains($0.id) }
            total = page.total
        } catch { if listTicket == ticket { listFailure = "讀不到更多對話" } }
    }

    func toggleProject(_ id: String) {
        if expandedProjects.contains(id) {
            expandedProjects.remove(id)
            projectLoads[id]?.cancel()
            projectLoads[id] = nil
            if projectLoadStates[id] == .loading { projectLoadStates[id] = .idle }
        } else {
            expandedProjects.insert(id)
            retryProject(id)
        }
    }

    /// 設定狀態在 Task 建立之前，展開的第一個畫面就看得到讀取中。
    func retryProject(_ id: String) {
        projectLoads[id]?.cancel()
        projectLoadStates[id] = .loading
        projectLoads[id] = Task { @MainActor [weak self] in
            await self?.loadProject(id)
        }
    }

    private func loadProject(_ id: String) async {
        defer { if !Task.isCancelled { projectLoads[id] = nil } }
        do {
            guard let items = try await directoryRead({ try await tap.conversations(inProject: id) }) else { return }
            if projectConversations[id] != items { projectConversations[id] = items }
            projectLoadStates[id] = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            projectLoadStates[id] = .failed("讀不到這個專案的對話")
        }
    }

    /// 送出中也能切到別則看（Pro 可能想好幾分鐘，跟網頁一樣邊等邊看別的）；只是不能再送第二則。
    func select(_ id: String) {
        closeDots()
        guard id != selectedID || page != nil else { return }
        mappedConversationLoad?.cancel()
        mappedConversationLoad = nil
        page = nil
        guard id != selectedID else { return }
        viewEpoch += 1
        branchLeaf = nil
        selectedID = id
        activeGPT = nil
        failure = nil
        // 開過的先顯示（不用等網路），再向 ChatGPT 拿最新的換上。
        let cached = messageCache[id]
        messages = cached ?? []
        isLoadingMessages = cached == nil
        loadSelected(id, reuseInFlight: cached == nil)
    }

    /// 從 Coder 跳來：select 會先喚醒再讀；已選同一則就強制重讀。
    func openMappedConversation(_ id: String) {
        let alreadySelected = selectedID == id
        select(id)
        guard alreadySelected else { return }
        isLoadingMessages = messages.isEmpty
        loadSelected(id, reuseInFlight: false)
    }

    /// 讀選到的那則：休眠時先喚醒（不會先閃「讀不到」再重讀）；畫面已有內容就不報錯。
    private func loadSelected(_ id: String, reuseInFlight: Bool) {
        mappedConversationLoad?.cancel()
        mappedConversationLoad = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled, selectedID == id { isLoadingMessages = false } }
            let lease = tap.acquireLease(backgroundWork: true)
            defer { tap.releaseLease(lease) }
            try? await readyForDirectory()
            guard !Task.isCancelled, selectedID == id else { return }
            let loaded = await loadMessages(id, reuseInFlight: reuseInFlight)
            guard !Task.isCancelled, selectedID == id else { return }
            if let loaded {
                if messages != loaded { messages = loaded }
                failure = nil
            } else if messages.isEmpty {
                failure = "讀不到這則對話"
            }
        }
    }

    /// 讀一則對話並放進快取；reuseInFlight＝同一則正在預載就等那一次（不重複要）。
    private var conversationProjects: [String: String] = [:]

    private func loadMessages(_ id: String, reuseInFlight: Bool) async -> [TapMessage]? {
        if reuseInFlight, let running = messageLoads[id] { return await running.value }
        let task = Task<[TapMessage]?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            guard let thread = try? await self.tap.thread(conversationID: id, branch: nil) else { return nil }
            if let projectID = thread.projectID { self.conversationProjects[id] = projectID }
            let loaded = self.includingFailure(id, in: thread.messages)
            self.remember(id, loaded)
            return loaded
        }
        messageLoads[id] = task
        let result = await task.value
        if messageLoads[id] == task { messageLoads[id] = nil }
        return result
    }

    private func remember(_ id: String, _ loaded: [TapMessage]) {
        messageCache[id] = loaded
        messageCacheOrder.removeAll { $0 == id }
        messageCacheOrder.append(id)
        while messageCacheOrder.count > Self.cacheLimit {
            let expired = messageCacheOrder.removeFirst()
            messageCache[expired] = nil
            conversationFailures[expired] = nil
        }
    }

    private func includingFailure(_ id: String, in loaded: [TapMessage]) -> [TapMessage] {
        guard let failed = conversationFailures[id] else { return loaded }
        var result = loaded.filter { $0.id != failed.id }
        result.append(failed)
        return result
    }

    /// 滑鼠停在側欄的對話上：先在背景讀好（跟網頁滑過連結就預載一樣），點下去幾乎立刻出來。
    func prefetch(_ id: String) {
        guard tap.connection == .ready, !isSending, id != selectedID, messageCache[id] == nil, messageLoads[id] == nil else { return }
        Task { _ = await loadMessages(id, reuseInFlight: true) }
    }

    func newChat(with gpt: TapFolder? = nil) {
        closeDots()
        mappedConversationLoad?.cancel()
        mappedConversationLoad = nil
        viewEpoch += 1
        page = nil
        branchLeaf = nil
        selectedID = nil
        messages = []
        thinking = nil
        failure = nil
        activeGPT = gpt
        temporaryChat = false
        temporaryPersonalized = false
    }

    var canSend: Bool {
        (tap.connection == .ready || tap.connection == .sleeping || tap.connection == .starting) && !isSending
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let files = attachments
        draft = ""
        attachments = []
        failure = nil
        let before = (messages: messages, branchLeaf: branchLeaf)
        messages.append(TapMessage(id: "local-user-\(UUID().uuidString)", role: .user, text: text, files: files.map(\.name)))
        // 畫面上膠囊顯示哪一檔就送哪一檔（沒特別選時是 ChatGPT 的「上次使用」），不讓網頁自己另外挑。
        let effort = effectiveEffortID
        let chosenTool = selectedTool
        let tool = chosenTool?.id
        selectedTool = nil
        // 新版選單的「版本」不是模型代號，不能直接送；檔位代號本身就帶模型（代號|強度）。
        let model = selectedModelID.flatMap { $0.hasPrefix("version:") ? nil : $0 }
        // 暫時對話的每一則都要帶暫時旗標（新對話看開關；接著問看這則是不是暫時對話）。
        let temporary = selectedID == nil ? temporaryChat : selectedID == temporaryConversationID
        // 切換過版本：接在正在看的那一支後面（跟網頁版一樣）。
        let parent = selectedID == nil ? nil : branchLeaf
        branchLeaf = nil
        consume(tap.send(text: text, conversationID: selectedID, model: model, effort: effort, attachments: files,
                         tool: tool, gizmoID: selectedID == nil ? activeGPT?.id : nil,
                         temporary: temporary, parentID: parent, temporaryPersonalized: temporary && temporaryPersonalized),
                startedIn: selectedID, failurePrefix: "送出沒有完成", temporary: temporary,
                project: selectedID == nil && activeGPT?.kind == .project ? activeGPT : nil,
                draft: (text, files, chosenTool), restore: before)
    }

    /// W180 A2：等非同步回答的正本（最後一則是 ChatGPT 的）存好；看著那則對話就換上畫面，沒在看也放進快取。
    private func waitForSavedReply(_ conversationID: String, timeout: TimeInterval) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            try? await Task.sleep(for: .seconds(4))
            guard let saved = try? await tap.messages(conversationID: conversationID),
                  saved.last?.role == .assistant else { continue }
            remember(conversationID, saved)
            if selectedID == conversationID, !isSending { messages = saved }
            return true
        }
        return false
    }

    /// W184 G3b：＋ 小卡的「照片」：只列圖片、從「圖片」資料夾開始。
    func pickPhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.directoryURL = URL.picturesDirectory
        panel.prompt = "附上"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in self?.addFiles(urls) }
        }
    }

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "附上"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in self?.addFiles(urls) }
        }
    }

    func addFiles(_ urls: [URL]) {
        Self.attachFiles(urls, into: attachmentSink)
    }

    /// W184 G3：收到的照片與檔案交給誰（ChatGPT Space 自己的附件、私訊框 ChatGPT 對象的附件）；收的規則在下面這幾個 static，兩邊同一套。
    struct AttachmentSink: Sendable {
        let add: @MainActor @Sendable (Data, String, String) -> Void
        let fail: @MainActor @Sendable (String) -> Void
    }

    private var attachmentSink: AttachmentSink {
        AttachmentSink(add: { [weak self] data, name, mime in self?.addData(data, name: name, mime: mime) },
                       fail: { [weak self] message in self?.failure = message })
    }

    /// 選的檔案：讀進記憶體（讀不到就說）；交給 sink 照 ChatGPT 的規矩收。
    /// W184 G3 第三輪（修正核對 #4）：跟檔案承諾同一個讀法——開檔不跟隨連結、只收一般檔案、先看大小（圖片 200 MB、其他 20 MB）再讀。
    static func attachFiles(_ urls: [URL], into sink: AttachmentSink) {
        for url in urls {
            guard let raw = readReceivedFile(url, in: url.deletingLastPathComponent(), limit: readLimit(for: url.lastPathComponent)) else {
                sink.fail(refusedMessage(url.lastPathComponent))
                continue
            }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            sink.add(raw, url.lastPathComponent, mime)
        }
    }

    /// 這個檔名最多讀多少：圖片 200 MB（之後轉 JPEG），其他 20 MB。
    nonisolated static func readLimit(for name: String) -> Int {
        UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .image) == true ? imageReadLimit : attachmentLimit
    }

    /// 沒收的那一句。
    nonisolated static func refusedMessage(_ name: String) -> String {
        "「\(name)」沒有加入：不是一般檔案、讀不到，或太大（圖片 200 MB、其他 20 MB）"
    }

    /// 收一個附件的規矩（W184 G3：私訊框的 ChatGPT 對象同一套）：ChatGPT 看不懂的圖片先轉 JPEG；加上它合計超過 20 MB 就不收。
    static func admit(_ data: Data, name: String, mime: String, currentBytes: Int) -> Result<TapAttachment, AdmitRefusal> {
        let file = webCompatible(data, name: name, mime: mime)
        let total = currentBytes + file.data.count
        guard total <= attachmentLimit else { return .failure(AdmitRefusal(message: "附件合計超過 20 MB，「\(name)」沒有加入")) }
        return .success(TapAttachment(name: file.name, mime: file.mime, data: file.data))
    }

    /// 沒收的原因（一句話，畫面直接顯示）。
    struct AdmitRefusal: Error, Equatable {
        let message: String
    }

    /// ChatGPT 看得懂的圖片格式；其他圖片（iPhone 照片的 HEIC、TIFF、BMP…）先轉成 JPEG 再交給網頁上傳
    /// （09-25 使用者「照片抓不進去」）。照片方向照原圖；長邊超過 4096 像素的縮到 4096。
    static let webImageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    static func webCompatible(_ data: Data, name: String, mime: String) -> (data: Data, name: String, mime: String) {
        let type = mime.lowercased()
        guard type.hasPrefix("image/"), !webImageTypes.contains(type), type != "image/svg+xml",
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return (data, name, mime) }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 4096]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return (data, name, mime) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return (data, name, mime)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return (data, name, mime) }
        let base = (name as NSString).deletingPathExtension
        return (output as Data, (base.isEmpty ? "照片" : base) + ".jpg", "image/jpeg")
    }

    func removeAttachment(_ id: UUID) { attachments.removeAll { $0.id == id } }

    /// 重新產生最後一個回答（走 ChatGPT 網頁自己的「重新產生」）；effort＝選單上的檔位（換那個模型／強度重答）。
    func regenerate(effort: String? = nil) {
        guard !isSending, tap.connection == .ready, let conversationID = selectedID, branchLeaf == nil else { return }
        failure = nil
        let before = (messages: messages, branchLeaf: branchLeaf)
        if let last = messages.lastIndex(where: { $0.role == .assistant }) { messages.remove(at: last) }
        let temporary = conversationID == temporaryConversationID
        consume(tap.regenerate(conversationID: conversationID, model: nil, effort: effort, temporary: temporary,
                               temporaryPersonalized: temporary && temporaryPersonalized),
                startedIn: conversationID, failurePrefix: "重新產生沒有完成", temporary: temporary, restore: before)
    }

    /// 版本切換（網頁的 ‹ 1/2 ›）：換到同一個位置的上一個／下一個版本，顯示那一支。
    func showVariant(_ message: TapMessage, offset: Int) {
        guard !isSending, let conversationID = selectedID, let variant = message.variant else { return }
        let target = variant.index + offset
        guard variant.nodes.indices.contains(target) else { return }
        Task {
            do {
                let thread = try await tap.thread(conversationID: conversationID, branch: variant.nodes[target])
                guard selectedID == conversationID else { return }
                messages = thread.messages
                branchLeaf = thread.isCurrent ? nil : thread.leaf
            } catch {
                failure = "切換版本沒有完成：\(error.localizedDescription)"
            }
        }
    }

    /// 編輯自己的訊息（網頁的 Edit message）：從同一個上一層送出新的版本，舊的留著可以切回去。
    func edit(_ message: TapMessage, to newText: String) {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, tap.connection == .ready, !text.isEmpty, let conversationID = selectedID,
              let parent = message.parentID, let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        failure = nil
        let before = (messages: messages, branchLeaf: branchLeaf)
        messages.removeSubrange(index...)
        messages.append(TapMessage(id: "local-user-\(UUID().uuidString)", role: .user, text: text))
        branchLeaf = nil
        // 畫面上膠囊顯示哪一檔就送哪一檔（沒特別選時是 ChatGPT 的「上次使用」），不讓網頁自己另外挑。
        let effort = effectiveEffortID
        let model = selectedModelID.flatMap { $0.hasPrefix("version:") ? nil : $0 }
        consume(tap.send(text: text, conversationID: conversationID, model: model, effort: effort, attachments: [],
                         tool: nil, gizmoID: nil, temporary: conversationID == temporaryConversationID, parentID: parent,
                         temporaryPersonalized: conversationID == temporaryConversationID && temporaryPersonalized),
                startedIn: conversationID, failurePrefix: "編輯沒有送出", temporary: conversationID == temporaryConversationID,
                restore: before)
    }

    /// 重答時可選的檔位：目前這一版的檔位（Instant、Medium、High、Extra High、Pro，跟網頁的 Switch model 一樣）。
    var regenerateOptions: [TapEffort] {
        (models.first { $0.id == effectiveModelID } ?? models.first { $0.id.hasPrefix("version:") })?.efforts ?? []
    }

    // MARK: 「＋」選單（照網頁版分層：前 4 個有名次的工具、最近用過的 App，其他收進「更多」）

    var plusTools: [TapTool] { Self.plusTools(tools) }

    var plusApps: [TapTool] { Self.plusApps(tools, recent: UserDefaults.standard.stringArray(forKey: Self.recentAppsKey) ?? []) }

    var moreTools: [TapTool] { Self.moreTools(tools, recent: UserDefaults.standard.stringArray(forKey: Self.recentAppsKey) ?? []) }

    func choose(_ tool: TapTool) {
        selectedTool = tool
        Self.rememberApp(tool, in: .standard)
    }

    // W184 G3：分層規則抽成 static（私訊框的「＋」同一套；最近用過的 App 記在同一個地方）。

    /// 有名次的前 4 個工具（網頁版「＋」第一層：生圖、網路搜尋、深入研究、Sketch）。
    static func plusTools(_ tools: [TapTool]) -> [TapTool] {
        Array(tools.filter { $0.rank != nil && !$0.hidden && !$0.isApp }
            .sorted { ($0.rank ?? 0) < ($1.rank ?? 0) }.prefix(4))
    }

    /// 最近用過的 App（最多 3 個；沒有最近的就用網頁優先列的；App 自家出的不放第一層）。
    static func plusApps(_ tools: [TapTool], recent: [String]) -> [TapTool] {
        let apps = tools.filter { $0.isApp && !$0.hidden && !$0.firstPartyApp }
        let recent = recent.compactMap { id in apps.first { $0.id == id } }
        let head = apps.filter(\.headApp)
        var seen = Set<String>()
        return Array((recent + head).filter { seen.insert($0.id).inserted }.prefix(3))
    }

    /// 其他收進「更多」。
    static func moreTools(_ tools: [TapTool], recent: [String]) -> [TapTool] {
        let shown = Set((plusTools(tools) + plusApps(tools, recent: recent)).map(\.id))
        return tools.filter { !$0.hidden && !shown.contains($0.id) }
    }

    /// 選了一個 App：排到最近用過的最前面（最多記 8 個；只有代號）。
    static func rememberApp(_ tool: TapTool, in defaults: UserDefaults) {
        guard tool.isApp else { return }
        var recent = defaults.stringArray(forKey: recentAppsKey) ?? []
        recent.removeAll { $0 == tool.id }
        recent.insert(tool.id, at: 0)
        defaults.set(Array(recent.prefix(8)), forKey: recentAppsKey)
    }

    /// 新對話頁的大標題：ChatGPT 網頁挑的那句（網頁是英文就換成對應的中文），沒有就用「我們該從哪裡開始？」。
    var headline: String {
        guard let greeting, !greeting.isEmpty else { return "我們該從哪裡開始？" }
        return Self.headlines[greeting] ?? greeting
    }

    static let headlines: [String: String] = [
        "What can I help with?": "有什麼可以幫忙的？",
        "Where should we start?": "我們該從哪裡開始？",
        "Where should we begin?": "我們該從哪裡開始？",
        "Ask ChatGPT anything": "問 ChatGPT 任何事",
        "Good to see you.": "很高興見到你。",
        "Ready to dive in?": "準備好開始了嗎？",
        "Ready when you are.": "你準備好就開始吧。",
        "What’s on your mind today?": "今天在想什麼？",
        "What's on your mind today?": "今天在想什麼？",
        "What’s on the agenda today?": "今天有什麼安排？",
        "What's on the agenda today?": "今天有什麼安排？",
        "How can I help?": "需要什麼幫忙？",
        "What can I do for you?": "我能為你做什麼？",
    ]

    /// 使用者重開選單／外掛頁時重讀；失敗保留上次清單，且不改使用者已選的工具。
    func refreshToolCatalog(invalidate: Bool = false) {
        toolCatalog.connectionChanged(ready: tap.connection == .ready)
        toolCatalog.refresh(invalidate: invalidate)
    }

    private func observeHandsConnection(_ phases: AnyPublisher<HandsConnectionPhase, Never>) {
        handsConnectionWatch = phases.removeDuplicates().sink { [weak self] phase in
            guard phase == .connected else { return }
            self?.refreshToolCatalog(invalidate: true)
            guard let self else { return }
            for id in self.expandedProjects { self.retryProject(id) }
            Task { await self.reloadConversationList() }
        }
    }

    // MARK: 資料庫

    func openLibrary() { open(.library) }

    /// 打開側欄的頁面；每次打開都重讀（排程、外掛等可能在網頁版改過）。
    func open(_ target: ChatGPTPage) {
        guard !isSending else { return }
        closeDots()
        page = target
        pageFailure = nil
        pageNotice = nil
        pluginDetailTarget = nil
        pluginDetail = nil
        switch target {
        case .library:
            if libraryItems.isEmpty { reloadLibrary() }
        case .scheduled, .plugins, .sites, .personalization:
            Task { await loadPage(target) }
        }
    }

    func loadPage(_ target: ChatGPTPage) async {
        // 即使外掛頁本身讀取失敗，工具目錄仍可獨立刷新；OAuth 完成回來整理也走這裡。
        if target == .plugins { refreshToolCatalog(invalidate: true) }
        pageLoading = true
        defer { pageLoading = false }
        do {
            switch target {
            case .library:
                break
            case .scheduled:
                automations = try await tap.automations()
            case .plugins:
                let loaded = try await tap.plugins()
                installedPlugins = loaded.installed
                pluginSections = loaded.sections
            case .sites:
                sites = try await tap.sites()
            case .personalization:
                async let loadedInstructions = tap.instructions()
                async let loadedMemories = tap.memories()
                instructions = try await loadedInstructions
                instructionsLoaded = true
                let memory = try await loadedMemories
                memories = memory.items
                memoryUsage = memory.usage
            }
        } catch {
            pageFailure = "讀不到\(target.title)：\(error.localizedDescription)"
        }
    }

    // MARK: 排程

    func setAutomation(_ item: TapAutomation, enabled: Bool) {
        guard let index = automations.firstIndex(where: { $0.id == item.id }) else { return }
        automations[index].enabled = enabled
        Task {
            do { try await tap.setAutomation(id: item.id, enabled: enabled) } catch {
                if let index = automations.firstIndex(where: { $0.id == item.id }) { automations[index].enabled = !enabled }
                pageFailure = "排程沒有\(enabled ? "開啟" : "暫停")：\(error.localizedDescription)"
            }
        }
    }

    func confirmRemoveAutomation() {
        guard let target = removeAutomationTarget else { return }
        removeAutomationTarget = nil
        Task {
            do {
                try await tap.removeAutomation(id: target.id)
                automations.removeAll { $0.id == target.id }
            } catch {
                pageFailure = "排程沒有刪除：\(error.localizedDescription)"
            }
        }
    }

    /// 新增排程：跟網頁一樣在對話裡用「排程」工具（Tasks）說要什麼時候做什麼。
    func newAutomation() {
        newChat()
        if let tasks = tools.first(where: { $0.id == "tasks" || $0.title.lowercased() == "tasks" }) { selectedTool = tasks }
        draft = "每天早上 9 點，"
    }

    // MARK: 設定（OS 這一側）

    /// 打開 設定 › Plugin › TAP（這座 Tap 的狀態、登入、休眠）；login＝直接跳出 ChatGPT 登入。Space 裡不放網頁（使用者 09-25）。
    func openTapSettings(login: Bool = false) {
        UserDefaults.standard.set("tap", forKey: "tatwo.plugins.selectedTab")
        if login { UserDefaults.standard.set(true, forKey: TapSettingsView.loginRequestKey) }
        NotificationCenter.default.post(name: .tatwoOpenSettingsSection, object: TatwoSettingsPage.Section.plugin.rawValue)
    }

    // MARK: 外掛

    func pluginAction(_ plugin: TapPlugin, action: String, enabled: Bool = true) {
        Task {
            do {
                if let authURL = try await tap.pluginAction(id: plugin.id, action: action, enabled: enabled) {
                    // 要登入那個 App 才能用：Space 裡不放網頁（使用者 09-25），交給預設瀏覽器完成授權。
                    NSWorkspace.shared.open(authURL)
                    pageNotice = "「\(plugin.name)」要先授權：已在瀏覽器打開，完成後回來重新整理這頁"
                }
                await loadPage(.plugins)
            } catch {
                pageFailure = "外掛沒有完成：\(error.localizedDescription)"
            }
        }
    }

    /// 打開外掛詳細頁：先用清單裡已有的名字、圖示、說明畫出來，詳細資料讀到再補上。
    func openPlugin(_ plugin: TapPlugin) {
        pluginDetailTarget = plugin
        pluginDetail = nil
        pluginDetailFailure = nil
        Task {
            do {
                let detail = try await tap.pluginDetail(id: plugin.id)
                if pluginDetailTarget?.id == plugin.id { pluginDetail = detail }
            } catch {
                if pluginDetailTarget?.id == plugin.id { pluginDetailFailure = "讀不到這個外掛的詳細資料：\(error.localizedDescription)" }
            }
        }
    }

    func closePlugin() {
        pluginDetailTarget = nil
        pluginDetail = nil
        pluginDetailFailure = nil
    }

    /// 外掛的範例提示：開新對話、放進輸入框（跟網頁點範例一樣，還沒送出）。
    func tryPluginPrompt(_ prompt: String) {
        newChat()
        draft = prompt
    }

    /// 詳細頁上外掛目前的狀態（安裝、啟用）照清單最新的為準。
    func pluginState(_ id: String) -> TapPlugin? {
        installedPlugins.first { $0.id == id } ?? pluginSections.lazy.flatMap(\.plugins).first { $0.id == id }
    }

    func confirmUninstallPlugin() {
        guard let target = uninstallPluginTarget else { return }
        uninstallPluginTarget = nil
        pluginAction(target, action: "uninstall")
    }

    // MARK: 網站

    func openSite(_ site: TapSite) {
        Task {
            let url: URL?
            if let known = site.url { url = known } else { url = try? await tap.siteURL(id: site.id) }
            guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
                pageFailure = "這個網站還沒有公開網址"
                return
            }
            NSWorkspace.shared.open(url)
        }
    }

    func copySiteURL(_ site: TapSite) {
        Task {
            let url: URL?
            if let known = site.url { url = known } else { url = try? await tap.siteURL(id: site.id) }
            guard let url else { pageFailure = "這個網站還沒有公開網址"; return }
            copy(url.absoluteString)
            pageNotice = "已拷貝網址"
        }
    }

    // MARK: 個人化（記憶與自訂指令）

    func saveInstructions() {
        let value = instructions
        Task {
            do {
                try await tap.saveInstructions(value)
                pageNotice = "自訂指令已儲存"
            } catch {
                pageFailure = "自訂指令沒有儲存：\(error.localizedDescription)"
            }
        }
    }

    func confirmDeleteMemory() {
        guard let target = deleteMemoryTarget else { return }
        deleteMemoryTarget = nil
        Task {
            do {
                try await tap.deleteMemory(id: target.id)
                memories.removeAll { $0.id == target.id }
            } catch {
                pageFailure = "記憶沒有刪除：\(error.localizedDescription)"
            }
        }
    }

    func confirmClearMemories() {
        clearMemoriesRequested = false
        Task {
            do {
                try await tap.clearMemories()
                memories = []
                memoryUsage = 0
            } catch {
                pageFailure = "記憶沒有清除：\(error.localizedDescription)"
            }
        }
    }

    // MARK: 帳號

    func loadAccount() async {
        if account == nil, let loaded = try? await tap.account() { account = loaded }
    }

    // MARK: 分享

    func requestShare(conversationID: String, messageID: String? = nil, title: String) {
        shareURL = nil
        shareFailure = nil
        shareStopped = false
        shareRequest = ShareRequest(conversationID: conversationID, messageID: messageID, title: title)
    }

    /// 停止分享：把剛建立的公開連結刪掉（拿到連結的人再也打不開）。
    func stopSharing() {
        guard let url = shareURL, !sharing else { return }
        sharing = true
        shareFailure = nil
        Task {
            defer { sharing = false }
            do {
                if try await tap.deleteShare(url: url) == false {
                    shareFailure = "已送出停止分享，但公開頁還打得開；過一下再按一次"
                    return
                }
                shareURL = nil
                shareStopped = true
            } catch {
                shareFailure = "沒有停止分享：\(error.localizedDescription)"
            }
        }
    }

    func createShareLink() {
        guard let request = shareRequest, !sharing else { return }
        sharing = true
        shareFailure = nil
        Task {
            defer { sharing = false }
            do {
                shareURL = try await tap.share(conversationID: request.conversationID, messageID: request.messageID)
            } catch {
                shareFailure = "沒有建立連結：\(error.localizedDescription)"
            }
        }
    }

    // MARK: 資料庫下載與刪除

    /// 下載：使用者自己選位置（使用者 09-25「2全要」：資料庫要能下載；TAP 只在這裡、存到使用者選的地方時寫檔）。
    func downloadLibraryItem(_ item: TapLibraryItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        panel.prompt = "下載"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try await tap.libraryData(itemID: item.id, full: true)
                try data.write(to: url, options: .atomic)
                libraryNotice = "已下載「\(item.name)」"
            } catch {
                libraryFailure = "「\(item.name)」沒有下載成功：\(error.localizedDescription)"
            }
        }
    }

    func confirmDeleteLibraryItem() {
        guard let target = deleteLibraryTarget else { return }
        deleteLibraryTarget = nil
        Task {
            do {
                try await tap.deleteLibraryItem(itemID: target.id)
                libraryItems.removeAll { $0.id == target.id }
            } catch {
                libraryFailure = "「\(target.name)」沒有刪除：\(error.localizedDescription)"
            }
        }
    }

    // MARK: 圖片放大

    /// 對話裡的圖：放大（記下同一則訊息的其他圖，給左右切換）。
    func zoom(_ image: NSImage, pointer: String, gallery: [String]) {
        zoomSource = .conversation(pointer: pointer, gallery: gallery.contains(pointer) ? gallery : [pointer])
        zoomedImage = image
    }

    func closeZoom() {
        zoomedImage = nil
        zoomSource = nil
    }

    var zoomTitle: String {
        if case .library(let item) = zoomSource { return item.name }
        return "ChatGPT 圖片"
    }

    /// 左右切換同一則訊息的圖（-1 上一張、+1 下一張）；沒有就回 nil。
    func zoomNeighbor(_ offset: Int) -> String? {
        guard case .conversation(let pointer, let gallery) = zoomSource, let index = gallery.firstIndex(of: pointer),
              gallery.indices.contains(index + offset) else { return nil }
        return gallery[index + offset]
    }

    func moveZoom(_ offset: Int) {
        guard let next = zoomNeighbor(offset), case .conversation(_, let gallery) = zoomSource else { return }
        Task {
            guard let image = await loadImage(next) else { return }
            zoomSource = .conversation(pointer: next, gallery: gallery)
            zoomedImage = image
        }
    }

    /// 下載放大中的圖：從圖庫打開的走圖庫下載；對話裡的圖取原檔（不重新編碼），
    /// 一樣只存到使用者自己在存檔視窗選的位置（使用者 09-25 #126：圖片預覽照 Coder 的，Coder 的預覽能下載）。
    func downloadZoomedImage() {
        switch zoomSource {
        case .library(let item):
            downloadLibraryItem(item)
        case .conversation(let pointer, _):
            Task {
                guard let data = try? await tap.imageData(pointer: pointer, conversationID: selectedID) else {
                    failure = "這張圖現在下載不了"
                    return
                }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "ChatGPT 圖片.\(Self.imageExtension(data))"
                panel.prompt = "下載"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    failure = "圖片沒有下載成功：\(error.localizedDescription)"
                }
            }
        case nil:
            break
        }
    }

    /// 照檔頭認圖片格式（下載時的副檔名）。
    static func imageExtension(_ data: Data) -> String {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if head.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if head.count >= 12, head[0...3] == [0x52, 0x49, 0x46, 0x46], head[8...11] == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        return "png"
    }

    // MARK: 即時語音

    func startVoice() {
        guard !voiceActive, !isSending, tap.connection == .ready else { return }
        voice.startVoice()
    }

    func stopVoice() {
        voice.stopVoice()
    }

    /// 語音結束了（ChatGPTVoiceMode 回報）：重讀清單；語音在正在看的那則就換上存好的內容，不在就切過去。
    /// W184 G3：網頁沒確認結束、關掉了語音那一頁時說一聲（麥克風停了）。
    private func voiceFinished(conversationID: String?) {
        if voice.voiceStatus.hasPrefix("語音沒開起來") { failure = voice.voiceStatus; return }
        if voice.lastEnd == .forced { failure = "語音那一頁沒有回應，已經關掉那一頁（麥克風停了）；等一下就能再用" }
        Task {
            await refresh()
            guard let conversationID else { return }
            if selectedID == conversationID {
                if let saved = try? await tap.messages(conversationID: conversationID) { messages = saved }
            } else {
                select(conversationID)
            }
        }
    }

    // MARK: 照片與檔案：貼上、拖進來

    /// 貼上或拖到輸入框：Finder 的檔案、圖片資料、「照片」App 的檔案（檔案承諾）都收（09-25 使用者「照片抓不進去」）。
    func attach(from pasteboard: NSPasteboard) -> Bool {
        Self.attach(from: pasteboard, into: attachmentSink)
    }

    /// 拖到對話區（不在輸入框上）：檔案網址或圖片。
    func attach(providers: [NSItemProvider]) -> Bool {
        Self.attach(providers: providers, into: attachmentSink)
    }

    // W184 G3：收照片與檔案的規則抽成 static（私訊框的 ChatGPT 對象同一套，交給它自己的 sink）。

    /// 貼上或拖到輸入框：Finder 的檔案、圖片資料、「照片」App 的檔案（檔案承諾）都收。
    static func attach(from pasteboard: NSPasteboard, into sink: AttachmentSink) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            Self.attachFiles(urls, into: sink)
            return true
        }
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            Self.receivePromises(receivers, into: sink)
            return true
        }
        // 剪貼簿裡有原始的 PNG／JPEG／HEIC 就直接用原檔（不重新編碼、畫質不變；HEIC 之後會轉 JPEG）；其他格式才經 NSImage 轉 PNG。
        let raw: [(String, String, String)] = [("public.png", "貼上的圖片.png", "image/png"), ("public.jpeg", "貼上的圖片.jpg", "image/jpeg"),
                                               ("public.heic", "貼上的照片.heic", "image/heic")]
        for (type, name, mime) in raw {
            if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type)), !data.isEmpty {
                sink.add(data, name, mime)
                return true
            }
        }
        if let image = NSImage(pasteboard: pasteboard), let png = Self.pngData(image) {
            sink.add(png, "貼上的圖片.png", "image/png")
            return true
        }
        return false
    }

    /// 拖到對話區（不在輸入框上）：檔案網址或圖片。
    static func attach(providers: [NSItemProvider], into sink: AttachmentSink) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in Self.attachFiles([url], into: sink) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                    // 系統給的暫存檔只在這個回呼裡有效：當場讀進記憶體。
                    guard let url else { return }
                    Self.receiveProvidedFile(url, fallbackMime: "image/png", into: sink)
                }
            }
        }
        return handled
    }

    /// W184 G3 第三輪（修正核對 #4）：拖到對話區、系統交來的檔案（loadFileRepresentation 的暫存檔）也走同一個安全讀法——
    /// 不跟隨連結、只收一般檔、確認就在交來的那個資料夾裡、先看大小（圖片 200 MB、其他 20 MB）再讀；讀不了就說一句。
    nonisolated static func receiveProvidedFile(_ url: URL, fallbackMime: String, into sink: AttachmentSink) {
        let name = url.lastPathComponent
        guard let data = readReceivedFile(url, in: url.deletingLastPathComponent(), limit: readLimit(for: name)) else {
            let message = refusedMessage(name)
            Task { @MainActor in sink.fail(message) }
            return
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? fallbackMime
        Task { @MainActor in sink.add(data, name, mime) }
    }

    private static func receivePromises(_ receivers: [NSFilePromiseReceiver], into sink: AttachmentSink) {
        guard let directory = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                            appropriateFor: FileManager.default.temporaryDirectory, create: true) else {
            sink.fail("沒辦法接收拖進來的照片")
            return
        }
        let queue = OperationQueue()
        let expected = receivers.reduce(0) { $0 + max(1, $1.fileNames.count) }
        var received: [URL] = []
        var completed = 0
        let lock = NSLock()
        // 保險：有照片一直沒回來也不能讓暫存留著（審查 #4）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { try? FileManager.default.removeItem(at: directory) }
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: queue) { url, error in
                lock.lock()
                // 成功或失敗都算完成一張（以前只數成功的，有一張失敗就永遠等不到收尾、暫存也不刪；審查 #4）。
                completed += 1
                if error == nil { received.append(url) }
                let done = completed >= expected
                let urls = received
                let failedCount = completed - received.count
                lock.unlock()
                // 讀進記憶體後就刪掉暫存（照片不留在磁碟上）。
                guard done else { return }
                if failedCount > 0 { Task { @MainActor in sink.fail("有 \(failedCount) 張照片沒有收到") } }
                // W184 G3（GPT-6 審查 3）：只收這次接收資料夾裡的一般檔案——符號連結、資料夾、裝置檔、資料夾外的路徑都不收，
                // 開檔不跟隨連結、最多讀 20 MB（檔案承諾是別的 App 給的，不能讓它指到你的私人檔案）。
                var files: [(Data, String, String)] = []
                var refused = 0
                for url in urls {
                    guard let data = Self.readReceivedFile(url, in: directory, limit: Self.readLimit(for: url.lastPathComponent),
                                                           singleLink: true) else { refused += 1; continue }
                    files.append((data, url.lastPathComponent,
                                  UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"))
                }
                try? FileManager.default.removeItem(at: directory)
                let admitted = files
                let rejected = refused
                Task { @MainActor in
                    for file in admitted { sink.add(file.0, file.1, file.2) }
                    if rejected > 0 { sink.fail("有 \(rejected) 個拖進來的項目沒有加入：不是一般檔案，或太大（圖片 200 MB、其他 20 MB）") }
                }
            }
        }
    }

    /// W184 G3（GPT-6 審查 3）：讀一個檔案承諾交來的檔案——只讀接收資料夾「直接裡面」的一般檔案：
    /// 所在資料夾（解開連結後）必須就是這次的接收資料夾；開檔不跟隨連結（O_NOFOLLOW，最後一層是連結就打不開）；
    /// 開了之後再確認是一般檔案（不是資料夾、裝置、管線）；超過 limit 不讀。都不對就回 nil。
    /// singleLink＝只收一個名字的檔案（檔案承諾：新寫進接收資料夾的檔案不會有別的硬連結；修正核對 #4(b)）。
    nonisolated static func readReceivedFile(_ url: URL, in directory: URL, limit: Int, singleLink: Bool = false) -> Data? {
        guard url.isFileURL else { return nil }
        let name = url.lastPathComponent
        let base = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        guard parent == base, !name.isEmpty, name != "..", name != ".", !name.contains("/") else { return nil }
        let path = base + "/" + name
        // POSIX 的 open／close／read 寫全名：ChatGPTSpaceModel 自己有 open(_:)（開側欄頁面），不寫全名會找到它。
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var info = Darwin.stat()
        guard Darwin.fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, Int(info.st_size) <= limit,
              !singleLink || info.st_nlink == 1 else { return nil }
        var data = Data(count: Int(info.st_size))
        var total = 0
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return info.st_size == 0 }
            while total < buffer.count {
                let n = Darwin.read(fd, base + total, buffer.count - total)
                if n < 0 { return false }
                if n == 0 { break }
                total += n
            }
            return true
        }
        guard ok else { return nil }
        return data.prefix(total)
    }

    func addData(_ data: Data, name: String, mime: String) {
        switch Self.admit(data, name: name, mime: mime, currentBytes: attachments.reduce(0) { $0 + $1.data.count }) {
        case .success(let file): attachments.append(file)
        case .failure(let refusal): failure = refusal.message
        }
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    func reloadLibrary() {
        libraryTask?.cancel()
        libraryCursor = nil
        libraryItems = []
        libraryFailure = nil
        libraryTask = Task { await loadLibraryPage() }
    }

    func loadMoreLibrary() {
        guard !libraryLoading, libraryCursor != nil else { return }
        libraryTask = Task { await loadLibraryPage() }
    }

    private func scheduleLibrarySearch() {
        libraryTask?.cancel()
        libraryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            self.libraryCursor = nil
            self.libraryItems = []
            self.libraryFailure = nil
            await self.loadLibraryPage()
        }
    }

    private func loadLibraryPage() async {
        let tab = libraryTab
        let query = libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let cursor = libraryCursor
        libraryLoading = true
        defer { libraryLoading = false }
        var reading = false
        do {
            guard let page = try await directoryRead({
                reading = true
                return try await tap.library(tab: tab, query: query, cursor: cursor)
            }) else { return }
            guard tab == libraryTab else { return }
            let known = Set(libraryItems.map(\.id))
            libraryItems += page.items.filter { !known.contains($0.id) }
            libraryCursor = page.cursor
        } catch {
            guard !Task.isCancelled else { return }
            if reading { libraryFailure = "讀不到資料庫：\(error.localizedDescription)"; return }
            let status = ChatGPTSpaceSidebarList.statusText(tap.connection)
            libraryFailure = status.isEmpty ? "ChatGPT 還沒準備好，稍後再試" : status
            return
        }
    }

    var libraryHasMore: Bool { libraryCursor != nil }

    /// 縮圖只放記憶體。
    func libraryThumbnail(_ item: TapLibraryItem) async -> NSImage? {
        let key = "library:\(item.id)"
        if let cached = cachedImage(key) { return cached }
        // 有的圖沒有縮圖（09-24 實機：格狀第一張空白）：退回用原圖（8 MB 以內）。
        var image = (try? await tap.libraryData(itemID: item.id, full: false)).flatMap(NSImage.init(data:))
        if image == nil, (item.size ?? 0) <= 8 * 1024 * 1024 {
            image = (try? await tap.libraryData(itemID: item.id, full: true)).flatMap(NSImage.init(data:))
        }
        guard let image else { return nil }
        imageCache.setObject(image, forKey: key as NSString)
        return image
    }

    /// 資料庫的預覽（只在記憶體）：PDF 與文字檔在 App 裡看；其他類型到網頁版開（TAP 不寫檔，所以不做下載）。
    struct LibraryPreview: Identifiable {
        enum Content {
            case text(String)
            /// Markdown 檔：用對話回答同一套排版顯示。
            case markdown(String)
            case pdf(Data)
            case unsupported
        }
        let id = UUID()
        let name: String
        let content: Content
        var item: TapLibraryItem? = nil
    }
    @Published var libraryPreview: LibraryPreview?

    static let textMimes: Set<String> = ["application/json", "application/xml", "application/x-yaml", "application/yaml",
                                         "application/javascript", "application/x-sh"]

    /// 點資料庫的檔案：圖片放大看；PDF、文字檔在 App 裡預覽（跟網頁版點檔案是打開預覽一樣）。
    func openLibraryItem(_ item: TapLibraryItem) {
        Task {
            if item.isImage {
                // 先用縮圖立刻放大（原圖要幾秒），原圖到了再換上。
                let thumbnail = cachedImage("library:\(item.id)")
                zoomSource = .library(item)
                if let thumbnail { zoomedImage = thumbnail }
                if let data = try? await tap.libraryData(itemID: item.id, full: true), let image = NSImage(data: data) {
                    if thumbnail == nil || zoomedImage === thumbnail { zoomedImage = image }
                } else if thumbnail == nil {
                    libraryFailure = "打不開「\(item.name)」"
                }
                return
            }
            let lower = item.name.lowercased()
            let textual = item.category == "text" || item.mime.hasPrefix("text/") || Self.textMimes.contains(item.mime)
                || [".md", ".txt", ".json", ".csv", ".yaml", ".yml", ".xml", ".log"].contains { lower.hasSuffix($0) }
            let pdf = item.category == "pdf" || item.mime == "application/pdf" || lower.hasSuffix(".pdf")
            guard textual || pdf else {
                libraryPreview = LibraryPreview(name: item.name, content: .unsupported, item: item)
                return
            }
            do {
                let data = try await tap.libraryData(itemID: item.id, full: true)
                let text = String(decoding: data.prefix(2_000_000), as: UTF8.self)
                let markdown = lower.hasSuffix(".md") || item.mime == "text/markdown"
                libraryPreview = LibraryPreview(name: item.name, content: pdf ? .pdf(data) : markdown ? .markdown(text) : .text(text),
                                                item: item)
            } catch {
                libraryFailure = "打不開「\(item.name)」：\(error.localizedDescription)"
            }
        }
    }

    func openSource(_ source: TapSource) {
        guard let scheme = source.url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return }
        NSWorkspace.shared.open(source.url)
    }

    /// 朗讀：用 macOS 內建語音在本機唸，不經過 ChatGPT。再按一次停。
    private let speaker = AVSpeechSynthesizer()
    @Published private(set) var speakingMessageID: String?

    func speak(_ message: TapMessage) {
        if speaker.isSpeaking {
            speaker.stopSpeaking(at: .immediate)
            if speakingMessageID == message.id { speakingMessageID = nil; return }
        }
        speakingMessageID = message.id
        let utterance = AVSpeechUtterance(string: message.text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-TW")
        speaker.speak(utterance)
    }

    /// 回饋（讚／倒讚）送回 ChatGPT；只對存在 ChatGPT 上的回答（本機暫存的不送）。
    @Published private(set) var ratedMessages: [String: Bool] = [:]

    func rate(_ message: TapMessage, good: Bool) {
        guard let conversationID = selectedID, !message.id.hasPrefix("local-") else { return }
        ratedMessages[message.id] = good
        Task {
            do { try await tap.feedback(conversationID: conversationID, messageID: message.id, good: good) }
            catch {
                ratedMessages[message.id] = nil
                failure = "回饋沒有送出：\(error.localizedDescription)"
            }
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// restore＝呼叫端改畫面之前的樣子（還在排隊就取消、又讀不到正本時換回去）。
    /// draft＝這一輪送出時從輸入框拿走的（W184 G3 第三輪：排在語音後面太久、沒送出就放回去）。
    private func consume(_ stream: AsyncStream<TapStreamEvent>, startedIn: String?, failurePrefix: String, temporary: Bool = false,
                         project: TapFolder? = nil, draft returnable: (text: String, files: [TapAttachment], tool: TapTool?)? = nil,
                         restore: (messages: [TapMessage], branchLeaf: String?)) {
        let startedAt = Date()
        let epoch = viewEpoch
        let startedGPT = activeGPT ?? projects.first { folder in
            projectConversations[folder.id]?.contains(where: { $0.id == startedIn }) == true
        } ?? startedIn.flatMap { conversationProjects[$0] }.map { TapFolder(id: $0, title: "專案", kind: .project) }
        let startedPersonalized = temporary && temporaryPersonalized
        isSending = true
        turnProgress = ChatGPTTurnProgress(thinking: ChatGPTThinking())
        requestID = nil
        stopRequested = false
        stopNotice = nil
        let placeholderID = "local-assistant-\(UUID().uuidString)"
        messages.append(TapMessage(id: placeholderID, role: .assistant, text: ""))
        let initialMessages = messages
        Task {
            // Keep this round independent of whichever conversation is on screen.
            var turnMessages = initialMessages
            var conversationID = startedIn
            // 這一輪自己的結果（不從目前畫面推算：送出中可能切到別則；審查 #11）。
            var receivedText = false
            // 這一輪有沒有真的交給網頁（還在排隊就被停掉的沒有）。
            var dispatched = false
            var turnFailure: String?
            var thoughtSeconds: Int?
            // W184 G3 第三輪：排在語音後面太久、TAP 沒送出就交回來（放回輸入框）。
            var returnedToDraft = false
            var failureNotified = false
            @MainActor func presentFailure(_ issue: ChatGPTTurnFailure) {
                if let index = turnMessages.firstIndex(where: { $0.id == placeholderID }) { turnMessages[index].turnFailure = issue }
                if let conversationID, let row = turnMessages.first(where: { $0.id == placeholderID }) {
                    conversationFailures[conversationID] = row
                    remember(conversationID, turnMessages)
                }
                if viewingTurn() { messages = turnMessages; thinking = nil; failure = nil }
                if !failureNotified && !(NSApp.isActive && visible && page == nil && viewingTurn()) {
                    failureNotified = true
                    let title = "ChatGPT 沒有完成：" + issue.displayText
                    IslandNotice.shared.info(title: title, detail: "")
                    #if DEBUG
                    failureNoticeForSelfTest?(title)
                    #endif
                }
            }
            // 還在看這一輪那則嗎（新對話：還沒換過畫面）。
            @MainActor func viewingTurn() -> Bool { conversationID != nil ? selectedID == conversationID : viewEpoch == epoch }
            for await event in stream {
                switch event {
                case .request(let id):
                    requestID = id
                    if stopRequested { tap.stop(requestID: id) }
                case .queued:
                    break // 保持 isSending；排隊不是失敗，仍可停止自己的這則。
                case .accepted:
                    dispatched = true
                case .finished:
                    if turnFailure == nil, let conversationID { conversationFailures[conversationID] = nil }
                    break
                case .conversation(let id):
                    conversationID = id
                    if temporary { temporaryConversationID = id }
                    if selectedID == nil, viewEpoch == epoch { selectedID = id }
                case .progress:
                    if viewingTurn(), thinking != nil {
                        var updated = turnProgress
                        updated.apply(event, startIfMissing: false)
                        if updated != turnProgress { turnProgress = updated }
                    }
                case .text(_, let full):
                    if !full.isEmpty, thinking != nil, let index = messages.firstIndex(where: { $0.id == placeholderID }) {
                        turnProgress.apply(event)
                        thoughtSeconds = turnProgress.thoughtSeconds
                        messages[index].thoughtSeconds = thoughtSeconds
                    }
                    if !full.isEmpty { receivedText = true }
                    if let index = turnMessages.firstIndex(where: { $0.id == placeholderID }) { turnMessages[index].text = full }
                    if let index = messages.firstIndex(where: { $0.id == placeholderID }) { messages[index].text = full }
                case .title(let id, let title):
                    if let index = conversations.firstIndex(where: { $0.id == id }) { conversations[index].title = title }
                case .notSubmitted(let message):
                    let userStopped = stopRequested
                    // .accepted 只代表 Tap 已交給 Pod；這個事件另證明網站尚未送出。
                    dispatched = false
                    returnedToDraft = returnable != nil
                    stopRequested = true
                    turnFailure = "\(failurePrefix)：\(message)"
                    if !userStopped {
                        presentFailure(ChatGPTTurnFailure(message: message, reason: "not_submitted", draft: returnable?.text ?? "",
                            projectID: startedGPT?.id, files: returnable?.files ?? []))
                    }
                    if viewingTurn() {
                        if userStopped { stopNotice = message; failure = nil }
                        else if let turnFailure { showTurnFailure(turnFailure, rowID: placeholderID) }
                    }
                case .failed(let message, let reason):
                    if message == ChatGPTTap.queueTimeoutReason, !dispatched, returnable != nil { returnedToDraft = true }
                    turnFailure = "\(failurePrefix)：\(message)"
                    presentFailure(ChatGPTTurnFailure(message: message, reason: reason,
                        draft: returnable?.text ?? restore.messages.last(where: { $0.role == .user })?.text ?? "",
                        projectID: startedGPT?.id, files: returnable?.files ?? []))
                }
            }
            isSending = false
            thinking = nil
            requestID = nil
            // 沒送出、交回來的那一則：放回輸入框（輸入框已經有新的字或附件就不蓋掉），畫面照「排隊中就停掉」換回去。
            if returnedToDraft, let returnable {
                let canReturn = viewingTurn()
                    && draft.isEmpty
                    && attachments.isEmpty && selectedTool == nil
                if canReturn {
                    draft = returnable.text
                    attachments = returnable.files
                    selectedTool = returnable.tool
                }
                if viewingTurn(), let turnFailure {
                    let note = turnFailure + (canReturn ? "；已放回輸入框" : "；未覆蓋目前草稿，原訊息已暫存")
                    if stopNotice != nil { stopNotice = note; failure = nil } else { showTurnFailure(note, rowID: placeholderID) }
                }
                // 保存完整內容，包括附件資料；舊對話已換走也不能丟稿。
                if !canReturn {
                    unsentDrafts.append(UnsentDraft(text: returnable.text, files: returnable.files,
                        tool: returnable.tool, conversationID: startedIn, gpt: startedGPT,
                        temporary: temporary, temporaryPersonalized: startedPersonalized, branchLeaf: restore.branchLeaf))
                    if viewingTurn() {
                        messages = restore.messages
                        branchLeaf = restore.branchLeaf
                    } else {
                        messages.removeAll { $0.id == placeholderID && $0.text.isEmpty }
                    }
                    return
                }
                stopRequested = true   // 沒交給網頁就交回來＝照「排隊中就停掉」把畫面換回去（下一輪開始時會歸零）
            }
            let streamedSomething = receivedText
            if stopRequested, dispatched, viewingTurn(),
               let index = messages.firstIndex(where: { $0.id == placeholderID }) {
                messages[index].stopNotice = "已停止"
            }
            messages.removeAll { $0.id == placeholderID && $0.text.isEmpty && $0.stopNotice == nil && $0.turnFailure == nil }
            if stopRequested, dispatched { return }
            // 還在排隊就取消（沒交給網頁，ChatGPT 上什麼都沒變）：不報「沒有收到回覆」、不發「回覆好了」通知；
            // 但送出前先改過的畫面（本機的提問泡泡、重新產生先拿掉的回答、編輯截掉的後文）要換回來：
            // 讀得到正本就用正本（排隊時私訊框可能在同一則加了新的一輪）；原本在看舊版本、或讀不到，就換回送出前的樣子。
            // 讀的期間又送出了新的一則就不動畫面（那一則收尾時自己會讀正本）。
            if stopRequested, !dispatched {
                if let conversationID {
                    guard selectedID == conversationID else { return }
                    var saved: [TapMessage]?
                    if restore.branchLeaf == nil { saved = await loadMessages(conversationID, reuseInFlight: false) }
                    guard selectedID == conversationID, !isSending else { return }
                    if let saved {
                        messages = saved
                    } else {
                        messages = restore.messages
                        branchLeaf = restore.branchLeaf
                    }
                } else if selectedID == nil, viewEpoch == epoch {
                    messages = restore.messages
                }
                return
            }
            if turnFailure != nil { return }
            // 專案裡的新對話：網頁沒換到 /c/<編號> 時，去專案清單找剛建立的那則（09-25 實機：送出成功但拿不到編號）。
            if conversationID == nil, let project,
               let items = try? await tap.conversations(inProject: project.id),
               let newest = items.max(by: { $0.updatedAt < $1.updatedAt }), newest.updatedAt > startedAt.addingTimeInterval(-15) {
                conversationID = newest.id
                projectConversations[project.id] = items
                if selectedID == nil, viewEpoch == epoch { selectedID = newest.id }
            }
            await refresh()
            // 暫時對話不進紀錄，也不列進側欄（跟網頁版一樣）。
            if let conversationID, !temporary, !conversations.contains(where: { $0.id == conversationID }),
               !projectConversations.values.contains(where: { $0.contains { $0.id == conversationID } }) {
                // 清單 API 有時慢一拍：新對話先放最上面，下次重新整理就換成正式標題。
                conversations.insert(TapConversation(id: conversationID, title: "新對話", updatedAt: Date()), at: 0)
            }
            // 串流畫面是即時版；結束後換成 ChatGPT 存下來的正本（含 Markdown 原文）。正本可能慢一拍才存好，最多等三次。
            var reloaded = false
            if let conversationID {
                for attempt in 0..<3 where selectedID == conversationID {
                    if var saved = try? await tap.messages(conversationID: conversationID), saved.last?.role == .assistant {
                        if let thoughtSeconds, !saved.isEmpty { saved[saved.count - 1].thoughtSeconds = thoughtSeconds }
                        // 等待期間可能切到別則：寫回畫面前再確認一次（審查 #11）。
                        if selectedID == conversationID { messages = saved }
                        reloaded = true
                        break
                    }
                    if attempt < 2 { try? await Task.sleep(for: .milliseconds(1500)) }
                }
            }
            // W180 A2（09-27 實機）：專案裡生圖＝非同步回答，串流結束時圖還在產生，上面三次讀不到；
            // 背景再等最多 3 分鐘（每 4 秒讀一次正本），好了就換上。這段期間不算失敗、也不擋下一則。
            if !streamedSomething, !reloaded, turnFailure == nil, let conversationID {
                awaitingAsyncReplyID = conversationID
                reloaded = await waitForSavedReply(conversationID, timeout: 180)
                if awaitingAsyncReplyID == conversationID { awaitingAsyncReplyID = nil }
            }
            if !streamedSomething, !reloaded, turnFailure == nil {
                turnFailure = "沒有收到 ChatGPT 的回覆；可以到 設定 › Plugin › TAP 看連線狀態"
                presentFailure(ChatGPTTurnFailure(message: "沒有收到 ChatGPT 的回覆", reason: nil,
                    draft: returnable?.text ?? "", projectID: startedGPT?.id, files: returnable?.files ?? []))
            }
            // 回覆好了：你不在這則對話上（App 不在前面、不在 ChatGPT 分頁、或正在看別則）就用 Island 通知；只放對話名稱。
            if turnFailure == nil, streamedSomething || reloaded,
               !(NSApp.isActive && visible && page == nil && selectedID == conversationID) {
                let title = temporary ? "臨時聊天"
                    : (conversations.first { $0.id == conversationID }?.title
                        ?? projectConversations.values.lazy.flatMap { $0 }.first { $0.id == conversationID }?.title ?? "新對話")
                SpaceNotice.post(space: Self.noticeSpace, title: "ChatGPT 回覆好了", detail: title)
            }
        }
    }

    func recover(_ failure: ChatGPTTurnFailure) {
        guard !isSending else { return }
        let recovered = ChatGPTDraftRecovery.merge(current: draft, returning: failure.draft)
        let files = failure.files + attachments
        if failure.isTooLong {
            let project = failure.projectID.flatMap { id in
                (projects + pinned).first { $0.id == id } ?? TapFolder(id: id, title: "專案", kind: .project)
            }
            newChat(with: project)
        }
        draft = recovered
        for file in files where !attachments.contains(where: { $0.name == file.name && $0.mime == file.mime && $0.data == file.data }) {
            addData(file.data, name: file.name, mime: file.mime)
        }
    }

    func stop() {
        guard isSending else { return }
        stopRequested = true
        stopNotice = "已停止"
        failure = nil
        if let requestID { tap.stop(requestID: requestID) }
    }

    struct ConversationGroup: Identifiable {
        let title: String
        var items: [TapConversation]
        var id: String { title }
    }

    /// 對話清單依日期分組（今天／昨天／前 7 天／前 30 天／更早）。
    var groupedConversations: [ConversationGroup] { Self.grouped(filteredConversations) }

    /// W184 G3b：依日期分組的規則抽成 static（私訊框的對話抽屜用同一份）。
    static func grouped(_ items: [TapConversation], now: Date = Date(), calendar: Calendar = .current) -> [ConversationGroup] {
        var groups: [ConversationGroup] = []
        func append(_ title: String, _ item: TapConversation) {
            if let index = groups.firstIndex(where: { $0.title == title }) {
                groups[index].items.append(item)
            } else {
                groups.append(ConversationGroup(title: title, items: [item]))
            }
        }
        for item in items {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: item.updatedAt), to: calendar.startOfDay(for: now)).day ?? 999
            switch days {
            case ..<1: append("今天", item)
            case 1: append("昨天", item)
            case 2..<7: append("前 7 天", item)
            case 7..<30: append("前 30 天", item)
            default: append("更早", item)
            }
        }
        return groups
    }
}

// MARK: - W184 G3b：私訊框的對話抽屜讀 ChatGPT Space 那一份清單（專案、依日期的對話；動作是私訊框自己的）

extension ChatGPTSpaceModel: ChatGPTConversationDirectory {
    var directoryConversations: [TapConversation] { conversations }
    var directoryProjects: [TapFolder] { projects }
    var directoryProjectsLoadState: ChatGPTListLoadState { projectsLoadState }
    func directoryRetryProjects() { retryProjects() }
    var directoryPinned: [TapFolder] { pinned }
    var directorySuggestions: [TapSuggestion] { suggestions }
    func directoryOpen(_ page: ChatGPTPage) { open(page) }
    func directoryOpenSettings() { openTapSettings() }
    var directoryExpandedProjects: Set<String> { expandedProjects }
    func directoryConversations(inProject id: String) -> [TapConversation]? { projectConversations[id] }
    func directoryToggleProject(_ id: String) { toggleProject(id) }
    func directoryProjectLoadState(_ id: String) -> ChatGPTListLoadState { projectLoadStates[id] ?? .idle }
    func directoryRetryProject(_ id: String) { retryProject(id) }
    var directoryListLoadState: ChatGPTListLoadState {
        if isLoadingList { return .loading }
        if let listFailure { return .failed(listFailure) }
        return loadedOnce ? .loaded : .idle
    }
    func directoryRetryList() { Task { await reloadConversationList() } }
    /// 抽屜打開時：還沒讀過清單就讀一次（連上了才讀；Space 沒打開過也拿得到）。
    func directoryPrepare() {
        retryProjects()
        if !loadedOnce { Task { await refresh() } }
    }
    /// W184 G3b 第二輪（審查 #5）：還有沒載入的舊對話；載入下一頁（同側欄）；搜尋問 ChatGPT 伺服器（查不了＝nil）。
    var directoryHasMore: Bool { conversations.count < total }
    func directoryLoadMore() async { await loadMore() }
    func directorySearch(_ query: String) async -> [TapConversation]? {
        do { return try await directoryRead { try await tap.search(query: query) } }
        catch { return nil }
    }
}

enum ChatGPTListLoadState: Equatable {
    case idle, loading, loaded
    case failed(String)
}

/// Space 與私訊框抽屜共用一行狀態；讀取中仍保留先前的對話。
struct ChatGPTListStatusRow: View {
    let state: ChatGPTListLoadState
    let empty: Bool
    let emptyText: String
    let identifier: String
    let retry: () -> Void
    var body: some View {
        Group {
            switch state {
            case .idle:
                EmptyView()
            case .loading:
                Text("讀取中").foregroundStyle(.secondary)
            case .failed(let text):
                HStack(spacing: 6) {
                    Text(text).foregroundStyle(.secondary)
                    Button("重試", action: retry).buttonStyle(.plain)
                        .padding(.horizontal, 8).padding(.vertical, 4).chatGlassChip(readable: true)
                }
            case .loaded:
                if empty { Text(emptyText).foregroundStyle(.secondary) }
            }
        }
        .font(.system(size: 11.5))
        .padding(.vertical, 4)
        .accessibilityIdentifier(identifier + ".status")
    }
}

extension ChatGPTSpaceModel {
    func openDots() {
        guard !dotsPresented else { return }
        // Dots 的真網頁可見性由 presentsPage 宿主決定；返回原生對話後收回 hidden。
        // 送出、停止與返回載入仍由原本的工作租約喚醒，不靠看不到的宿主維持可見。
        tap.setSpaceVisible(false)
        // 原生對話、草稿、分支與頁面都留在原位；返回直接顯示原畫面。
        var target = URLComponents(url: ChatGPTTap.homeURL, resolvingAgainstBaseURL: false)!
        if let selectedID { target.path = "/c/" + selectedID }
        let returnURL = target.url ?? ChatGPTTap.homeURL
        dotsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await tap.openDots(returnURL: returnURL)
        }
    }

    func closeDots() {
        guard dotsPresented else { return }
        dotsTask?.cancel()
        dotsTask = nil
        tap.closeDots()
    }

    func openDotsInBrowser() {
#if DEBUG
        if let dotsBrowserOpenForSelfTest { dotsBrowserOpenForSelfTest(ChatGPTDotsState.url); return }
#endif
        NSWorkspace.shared.open(ChatGPTDotsState.url)
    }
}

// MARK: - 側欄：釘選、專案、對話

struct ChatGPTSpaceSidebarList: View {
    @WorkspaceObservedObject var model: ChatGPTSpaceModel
    @WorkspaceObservedObject var tap: ChatGPTTap

    init(model: ChatGPTSpaceModel) {
        _model = WorkspaceObservedObject(wrappedValue: model)
        _tap = WorkspaceObservedObject(wrappedValue: model.tap)
    }

    var body: some View {
        #if DEBUG
        let _ = ChatRenderProbe.record("ChatGPTSpaceSidebarList.body")
        #endif
        VStack(alignment: .leading, spacing: 10) {
            Button { model.newChat() } label: {
                Label("新對話", systemImage: "square.and.pencil")
                    .font(ChatTypography.systemUI(12.5, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .chatGlassChip()
            .padding(.horizontal, 12)
            .accessibilityIdentifier("chatgpt.newChat")

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(ChatGlassChipModifier.chipForeground)
                ChatChipTextField(title: "搜尋對話", text: $model.search)
                    .font(ChatTypography.systemUI(12, weight: .regular))
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .chatGlassChip()
            .padding(.horizontal, 12)

            // 跟網頁版側欄一樣：圖庫、排程、外掛、網站（使用者 09-25「2全要」）。
            VStack(spacing: 0) {
                ChatGPTDotsSidebarRow(model: model)
                ForEach(ChatGPTPage.sidebar) { page in ChatGPTSidebarNavRow(model: model, page: page) }
            }
            .padding(.horizontal, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !Self.statusText(tap.connection).isEmpty {
                        Text(Self.statusText(tap.connection))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.top, 6)
                    }
                    if model.search.isEmpty {
                        if !model.pinned.isEmpty {
                            sectionHeader("釘選")
                            ForEach(model.pinned) { folder in folderRows(folder, idPrefix: "pin") }
                        }
                        sectionHeader("專案")
                        Button { model.beginProjectCreation() } label: {
                            Label("新增專案", systemImage: "folder.badge.plus")
                                .font(ChatTypography.systemUI(13, weight: .regular))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 30)
                        }
                        .buttonStyle(.plain).disabled(model.creatingProject)
                        .accessibilityIdentifier("chatgpt.project.new")
                        ChatGPTListStatusRow(state: model.projectsLoadState, empty: model.projects.isEmpty,
                                             emptyText: "還沒有專案", identifier: "chatgpt.projects") { model.retryProjects() }
                        ForEach(model.projects) { folder in folderRows(folder, idPrefix: "project") }
                        if !model.gpts.isEmpty {
                            sectionHeader("GPTs")
                            ForEach(model.gpts) { folder in folderRows(folder, idPrefix: "gpt").id("gpt-\(folder.id)") }
                        }
                    }
                    if model.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ChatGPTListStatusRow(state: model.directoryListLoadState, empty: model.conversations.isEmpty,
                                             emptyText: "還沒有對話", identifier: "chatgpt.list") { model.directoryRetryList() }
                    } else {
                        ChatGPTListStatusRow(state: model.searchLoadState, empty: model.filteredConversations.isEmpty,
                                             emptyText: "找不到符合的對話", identifier: "chatgpt.search") { model.retrySearch() }
                    }
                    ForEach(model.groupedConversations) { group in
                        sectionHeader(group.title)
                        ForEach(group.items) { item in ChatGPTConversationRow(model: model, item: item) }
                    }
                    if model.conversations.count < model.total, model.search.isEmpty {
                        Button("載入更多") { Task { await model.loadMore() } }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 12)
            }
            // 左下帳號（跟網頁、桌面版一樣）：個人化（記憶與自訂指令）、設定、說明。
            if tap.connection == .ready {
                ChatGPTAccountRow(model: model)
                    .padding(.horizontal, 12)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private func folderRows(_ folder: TapFolder, idPrefix: String) -> some View {
        switch folder.kind {
        case .conversation:
            ChatGPTConversationRow(model: model, item: TapConversation(id: folder.id, title: folder.title, updatedAt: .distantPast),
                                   icon: "pin")
                .id("\(idPrefix)-\(folder.id)")
        case .project:
            let expanded = model.expandedProjects.contains(folder.id)
            Button { model.toggleProject(folder.id) } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "folder.fill" : "folder")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text(folder.title)
                        .font(ChatTypography.systemUI(13, weight: .regular))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("專案 \(folder.title)")
            .accessibilityIdentifier("chatgpt.\(idPrefix)")
            if expanded {
                // 在這個專案開新對話（網頁的專案頁：輸入框送出就開在專案裡）。
                let active = model.activeGPT?.id == folder.id && model.selectedID == nil && !model.showingLibrary
                Button { model.newChat(with: folder) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(width: 16)
                            .accessibilityHidden(true)
                        Text("新對話").font(ChatTypography.systemUI(12.5, weight: active ? .medium : .regular))
                            .foregroundStyle(active ? Color.primary : Color.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 10)
                    .frame(height: 28)
                    .background(active ? LiquidGlassTokens.brandAccent.opacity(0.10) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("在「\(folder.title)」開新對話")
                .id("\(idPrefix)-\(folder.id)-new")
                let items = model.projectConversations[folder.id] ?? []
                ChatGPTListStatusRow(state: model.projectLoadStates[folder.id] ?? .idle, empty: items.isEmpty,
                                     emptyText: "還沒有對話", identifier: "chatgpt.project." + folder.id) { model.retryProject(folder.id) }
                    .padding(.leading, 34)
                // 專案裡的對話也會出現在下方日期清單：給獨立識別碼，否則同一清單重複 id 會讓畫面錯亂（09-24 實機）。
                ForEach(items) { item in
                    ChatGPTConversationRow(model: model, item: item)
                        .padding(.leading, 24).id("\(idPrefix)-\(folder.id)-\(item.id)")
                }
            }
        case .other:
            // GPT：點一下跟它開新對話（跟網頁版一樣）。
            let active = model.activeGPT?.id == folder.id && model.selectedID == nil
            Button { model.newChat(with: folder) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
                        .accessibilityHidden(true)
                    Text(folder.title).font(ChatTypography.systemUI(13, weight: active ? .medium : .regular)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(active ? LiquidGlassTokens.brandAccent.opacity(0.10) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("GPT \(folder.title)")
            .accessibilityIdentifier("chatgpt.\(idPrefix)")
        }
    }

    static func statusText(_ connection: TapConnection) -> String {
        switch connection {
        case .off: "ChatGPT 已在 設定 › Plugin › TAP 停用"
        case .starting: ""
        case .needsLogin: "還沒登入 ChatGPT"
        case .ready: ""
        case .sleeping: ""
        case .failed(let message): message
        }
    }
}

/// 側欄的一則對話：外觀不變；滑過時右邊出現「⋯」（跟網頁版一樣），右鍵也有同一份選單。
struct ChatGPTConversationRow: View {
    @WorkspaceObservedObject var model: ChatGPTSpaceModel
    let item: TapConversation
    var icon: String? = nil
    @State private var hovering = false
    @State private var prefetchTask: Task<Void, Never>?

    var body: some View {
        let selected = item.id == model.selectedID && !model.showingLibrary
        HStack(spacing: 0) {
            Button { model.select(item.id) } label: {
                HStack(spacing: 8) {
                    if let icon {
                        Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
                            .accessibilityHidden(true)
                    }
                    Text(item.title)
                        .font(ChatTypography.systemUI(13, weight: selected ? .medium : .regular))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chatgpt.conversation")
            if hovering {
                Menu { ChatGPTConversationActions(model: model, item: item) } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("對話選項：\(item.title)")
            }
        }
        .padding(.trailing, 4)
        .background(selected ? LiquidGlassTokens.brandAccent.opacity(0.10) : (hovering ? Color.primary.opacity(0.04) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { inside in
            hovering = inside
            // 停 0.15 秒才預載（滑過去不算），離開就取消。
            prefetchTask?.cancel()
            prefetchTask = inside ? Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                model.prefetch(item.id)
            } : nil
        }
        .contextMenu { ChatGPTConversationActions(model: model, item: item) }
    }
}

/// 對話裡的一張圖：第一次出現時才向 ChatGPT 取（只放記憶體），點一下放大。
struct ChatGPTImageView: View {
    @WorkspaceObservedObject var model: ChatGPTSpaceModel
    let image: TapImage
    let maxWidth: CGFloat
    /// 高度上限（使用者 09-25 #127「對話圖片太大張」：照網頁寬度，直式 2:3 的圖還是有 600 高）。
    var maxHeight: CGFloat = 400
    /// 同一則訊息裡所有圖的指標（放大後左右切換用）。
    var gallery: [String] = []
    @State private var loaded: NSImage?
    @State private var failed = false

    private var aspect: CGFloat {
        if let width = image.width, let height = image.height, width > 0, height > 0 { return CGFloat(width) / CGFloat(height) }
        if let size = loaded?.size, size.width > 0, size.height > 0 { return size.width / size.height }
        return 1
    }

    /// 顯示的框：寬度照網頁（imagegen-image：直式 max-w-[400px]、橫式與方形 max-w-[480px]），高度最多 maxHeight；
    /// 窄的時候整個等比縮小。點圖用 Coder 的預覽看原尺寸。
    private var box: CGSize {
        let widthCap = aspect < 1 ? min(maxWidth, 400) : maxWidth
        let height = min(widthCap / aspect, maxHeight)
        return CGSize(width: height * aspect, height: height)
    }

    var body: some View {
        Group {
            if let loaded {
                Button { model.zoom(loaded, pointer: image.id, gallery: gallery) } label: {
                    Image(nsImage: loaded)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: box.width, maxHeight: box.height)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("放大")
                .accessibilityLabel("圖片，點一下放大")
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxWidth: box.width, maxHeight: box.height)
                    .overlay {
                        if failed {
                            Label("圖片讀不到", systemImage: "photo").font(.system(size: 12)).foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .accessibilityLabel(failed ? "圖片讀不到" : "圖片讀取中")
            }
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .task(id: image.id) {
            if let cached = model.cachedImage(image.id) { loaded = cached; return }
            failed = false
            if let image = await model.loadImage(image.id) { loaded = image } else { failed = true }
        }
    }
}

/// 自己的訊息：泡泡在右邊；滑過時下方出現拷貝、編輯（跟網頁版一樣）；有好幾個版本時顯示 ‹ 1/2 ›。
struct ChatGPTUserMessageView: View {
    @WorkspaceObservedObject var model: ChatGPTSpaceModel
    let message: TapMessage
    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""

    private var canEdit: Bool {
        message.parentID != nil && !message.id.hasPrefix("local-") && !model.isSending && model.selectedID != nil
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            // 使用者附的圖與檔案放在泡泡上面（跟網頁版一樣）。
            ForEach(message.images) { image in
                ChatGPTImageView(model: model, image: image, maxWidth: 240, maxHeight: 240, gallery: message.images.map(\.id))
            }
            ForEach(message.files, id: \.self) { name in
                Label(name, systemImage: "doc")
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .chatGlassChip()
            }
            if editing {
                VStack(alignment: .trailing, spacing: 8) {
                    TextEditor(text: $draft)
                        .font(.system(size: 14.5))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 64, maxHeight: 240)
                        .padding(10)
                        .background(LiquidGlassTokens.brandAccent.opacity(0.07),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityLabel("編輯訊息")
                    HStack(spacing: 8) {
                        Button("取消") { editing = false }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 14).frame(height: 28).chatGlassChip()
                            .keyboardShortcut(.cancelAction)
                        Button("送出") {
                            editing = false
                            model.edit(message, to: draft)
                        }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14).frame(height: 28).chatGlassChip(isSelected: true)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .frame(maxWidth: 560)
            } else if !message.text.isEmpty {
                HStack {
                    Spacer(minLength: 80)
                    // ChatGPT 的泡泡：中性淺灰、15pt、跟回答同一套字級（09-25「細節文字排版」）。
                    Text(message.text)
                        .font(.system(size: ChatGPTSpaceMainPane.bodyPointSize))
                        .lineSpacing(ChatGPTSpaceMainPane.bodyLineSpacing)
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        // 拷貝／編輯平常藏起來（滑過才出現），輔助使用也要按得到。
                        .accessibilityAction(named: "拷貝訊息") { model.copy(message.text) }
                        .accessibilityAction(named: "編輯訊息") {
                            guard canEdit else { return }
                            draft = message.text
                            editing = true
                        }
                }
            }
            if !editing {
                HStack(spacing: 2) {
                    if let variant = message.variant {
                        ChatGPTVariantNav(model: model, message: message, variant: variant)
                    }
                    Group {
                        if !message.text.isEmpty {
                            iconButton("doc.on.doc", help: "拷貝訊息") { model.copy(message.text) }
                        }
                        if canEdit, !message.text.isEmpty {
                            iconButton("pencil", help: "編輯訊息") {
                                draft = message.text
                                editing = true
                            }
                        }
                        // 網頁版使用者訊息上的 Share prompt：只分享這一則提問。
                        if let conversationID = model.selectedID, conversationID != model.temporaryConversationID,
                           !message.id.hasPrefix("local-") {
                            iconButton("square.and.arrow.up", help: "分享這則提問") {
                                model.requestShare(conversationID: conversationID, messageID: message.id, title: message.text)
                            }
                        }
                    }
                    // 跟網頁版一樣滑過才出現（位置先留好，不會跳動）。
                    .opacity(hovering ? 1 : 0)
                }
                .frame(height: 26)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onHover { hovering = $0 }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 版本切換（網頁的 ‹ 1/2 ›）：重新產生或編輯之後，同一個位置有好幾個版本。
struct ChatGPTVariantNav: View {
    @WorkspaceObservedObject var model: ChatGPTSpaceModel
    let message: TapMessage
    let variant: TapVariant

    var body: some View {
        HStack(spacing: 0) {
            Button { model.showVariant(message, offset: -1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(variant.index == 0 || model.isSending)
            .help("上一個版本")
            .accessibilityLabel("上一個版本")
            Text("\(variant.index + 1)/\(variant.count)")
                .font(.system(size: 12).monospacedDigit())
                .accessibilityLabel("第 \(variant.index + 1) 個版本，共 \(variant.count) 個")
            Button { model.showVariant(message, offset: 1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(variant.index >= variant.count - 1 || model.isSending)
            .help("下一個版本")
            .accessibilityLabel("下一個版本")
        }
        .foregroundStyle(.secondary)
    }
}

/// 回答引用的網頁（網頁版回答下方的 Sources）：點開列出來源，點一個用預設瀏覽器打開。
struct ChatGPTSourcesButton: View {
    @WorkspaceObservedObject var model: ChatGPTSpaceModel
    let sources: [TapSource]
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "link").font(.system(size: 10.5)).accessibilityHidden(true)
                Text("來源").font(.system(size: 12, weight: .medium))
                Text("\(sources.count)").font(.system(size: 11)).foregroundStyle(ChatGlassChipModifier.chipForeground)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .chatGlassChip()
        .help("這個回答引用的網頁")
        .accessibilityLabel("來源 \(sources.count) 個")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text("來源").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 8).padding(.bottom, 6)
                    ForEach(sources) { source in
                        Button { model.openSource(source) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.host).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                Text(source.title).font(.system(size: 12.5)).lineLimit(2).multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(source.url.absoluteString)
                    }
                }
                .padding(12)
            }
            .frame(width: 340)
            .frame(maxHeight: 420)
        }
    }
}

/// 資料庫（ChatGPT 網頁的 Library）：標題、搜尋、分頁（建議／圖片／全部）。
/// 清單照網頁的「名稱｜最近活動」；圖片分頁用格狀（網頁的圖片分頁也只有格狀）。點圖片放大；PDF、文字檔在 App 裡預覽。
struct ChatGPTLibraryView: View {
    @WorkspaceObservedObject var model: ChatGPTSpaceModel
    @WorkspaceObservedObject var tap = ChatGPTTap.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("圖庫")
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 18)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(ChatGlassChipModifier.chipForeground).accessibilityHidden(true)
                ChatChipTextField(title: "搜尋圖庫", text: $model.libraryQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .chatGlassChip()
            HStack(spacing: 4) {
                ForEach(TapLibraryTab.allCases) { tab in
                    let active = model.libraryTab == tab
                    Button { model.libraryTab = tab } label: {
                        Text(tab.title)
                            .font(.system(size: 13, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? Color.primary : Color.secondary)
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                            .background(active ? Color.primary.opacity(0.07) : Color.clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
            content
        }
        .frame(maxWidth: 820, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatgpt.libraryView")
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if model.libraryTab == .images {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)], spacing: 12) {
                        ForEach(model.libraryItems) { item in
                            Button { model.openLibraryItem(item) } label: {
                                ChatGPTLibraryThumb(model: model, item: item, size: nil)
                                    .aspectRatio(1, contentMode: .fit)
                            }
                            .buttonStyle(.plain)
                            .help(item.name)
                            .accessibilityLabel(item.name)
                            .contextMenu { itemActions(item) }
                        }
                    }
                } else {
                    if !model.libraryItems.isEmpty {
                        HStack {
                            Text("名稱")
                            Spacer()
                            Text("最近活動").frame(width: 140, alignment: .leading)
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        Divider()
                    }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.libraryItems) { item in
                            Button { model.openLibraryItem(item) } label: {
                                HStack(spacing: 12) {
                                    ChatGPTLibraryThumb(model: model, item: item, size: 36)
                                    Text(item.name).font(.system(size: 13.5)).lineLimit(1)
                                    Spacer(minLength: 12)
                                    Text(Self.relative(item.date))
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 140, alignment: .leading)
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 56)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(item.isImage ? "放大" : "預覽")
                            .accessibilityLabel(item.name)
                            .contextMenu { itemActions(item) }
                            Divider()
                        }
                    }
                }
                footer
            }
            .padding(.bottom, 24)
        }
    }

    /// 右鍵：下載（使用者 09-25「2全要」）、刪除（移到圖庫垃圾桶）。
    @ViewBuilder
    private func itemActions(_ item: TapLibraryItem) -> some View {
        Button("下載…") { model.downloadLibraryItem(item) }
        Divider()
        Button("刪除", role: .destructive) { model.deleteLibraryTarget = item }
    }

    @ViewBuilder
    private var footer: some View {
        if let notice = model.libraryNotice {
            Text(notice).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 14)
        }
        if let failure = model.libraryFailure {
            Text(failure).font(.system(size: 12)).foregroundStyle(.red).padding(.top, 14)
        } else if model.libraryLoading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 18)
        } else if model.libraryHasMore {
            // 捲到底自動載入下一頁。
            Color.clear.frame(height: 24).onAppear { model.loadMoreLibrary() }
        } else if model.libraryItems.isEmpty, tap.connection == .ready {
            Text(model.libraryQuery.isEmpty ? "這裡還沒有檔案" : "找不到符合的檔案")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.top, 40)
        }
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// 資料庫檔案的預覽（只在記憶體）：文字檔可選取、拷貝；PDF 用系統的 PDF 檢視；其他類型請到網頁版。
struct ChatGPTLibraryPreviewView: View {
    @WorkspaceObservedObject var model: ChatGPTSpaceModel
    let preview: ChatGPTSpaceModel.LibraryPreview

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(preview.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                if let text = copyText {
                    Button("拷貝") { model.copy(text) }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14).frame(height: 28).chatGlassChip()
                }
                if let item = preview.item {
                    Button("下載…") { model.downloadLibraryItem(item) }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14).frame(height: 28).chatGlassChip()
                }
                Button("完成") { model.libraryPreview = nil }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14).frame(height: 28).chatGlassChip()
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Group {
                switch preview.content {
                case .text(let text):
                    ScrollView {
                        Text(text)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                case .markdown(let text):
                    ScrollView {
                        ChatAssistantTranscriptBlockView(
                            document: TatwoAssistantTranscriptPresentation.document(markdown: text),
                            copyAllText: text,
                            tracksAvailableWidth: true)
                            .environment(\.chatTranscriptTypography, ChatGPTSpaceMainPane.typography)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }
                case .pdf(let data):
                    ChatGPTPDFView(data: data)
                case .unsupported:
                    VStack(spacing: 8) {
                        Image(systemName: "doc").font(.system(size: 30)).foregroundStyle(.secondary)
                        Text("這種檔案沒辦法在這裡預覽；可以按「下載…」存到電腦再打開。")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, idealWidth: 860, minHeight: 480, idealHeight: 720)
    }

    private var copyText: String? {
        switch preview.content {
        case .text(let text), .markdown(let text): return text
        case .pdf, .unsupported: return nil
        }
    }
}

/// PDF 直接從記憶體顯示（不落地）。
struct ChatGPTPDFView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}
}

/// 資料庫的縮圖：圖片第一次出現時才取（只放記憶體）；其他檔案用類型圖示。size＝nil 時填滿格子（圖片分頁）。
struct ChatGPTLibraryThumb: View {
    @WorkspaceObservedObject var model: ChatGPTSpaceModel
    let item: TapLibraryItem
    let size: CGFloat?
    @State private var image: NSImage?

    var body: some View {
        let radius: CGFloat = size.map { $0 > 60 ? 12 : 8 } ?? 12
        // 縮圖疊在底框上（fill 超出的部分由外框裁掉，不撐大版面）。
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.primary.opacity(0.05))
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: (size ?? 100) > 60 ? 28 : 14))
                        .foregroundStyle(.secondary)
                }
            }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .task(id: item.id) {
            guard item.isImage, image == nil else { return }
            image = await model.libraryThumbnail(item)
        }
    }

    private var symbol: String {
        switch item.category {
        case "image": return "photo"
        case "pdf": return "doc.richtext"
        case "audio": return "waveform"
        case "video": return "film"
        case "text": return "doc.text"
        default:
            // 類型沒寫時看副檔名（09-24 實機：xlsx 顯示成一般文件）。
            let name = item.name.lowercased()
            if item.mime.contains("json") || name.hasSuffix(".json") { return "curlybraces" }
            if item.mime.contains("sheet") || item.mime.contains("csv") || [".xlsx", ".xls", ".csv", ".numbers"].contains { name.hasSuffix($0) } { return "tablecells" }
            if item.mime.contains("presentation") || [".pptx", ".ppt", ".key"].contains { name.hasSuffix($0) } { return "rectangle.on.rectangle" }
            if name.hasSuffix(".pdf") { return "doc.richtext" }
            if [".md", ".txt", ".docx", ".doc", ".rtf"].contains { name.hasSuffix($0) } { return "doc.text" }
            return "doc"
        }
    }
}

/// 對話選項（側欄「⋯」、右鍵、標題列「⋯」共用）。
struct ChatGPTConversationActions: View {
    @WorkspaceObservedObject var model: ChatGPTSpaceModel
    let item: TapConversation

    var body: some View {
        Button(model.isPinned(item.id) ? "取消釘選" : "釘選") { model.togglePin(item) }
        Button("重新命名") { model.beginRename(item) }
        Button("封存") { model.archive(item) }
        Divider()
        Button("刪除", role: .destructive) { model.deleteTarget = item }
    }
}

// MARK: - 主畫面：對話

/// ChatGPT Space 右上的鈕，跟 ChatGPT 桌面版一樣在標題那一列：新對話時是臨時聊天；對話裡是分享與對話選項（⋯）。
/// 模型與思考強度在輸入框裡；左上角不放標題（使用者 09-25「新對話在左上角也很突兀」）。
/// 視窗裡由 ChatPage 放在紅綠燈那一列的右上（使用者 09-25 #125）；小面板沒有那一列，放在對話上方。
struct ChatGPTTopBarControls: View {
    @WorkspaceObservedObject var model: ChatGPTSpaceModel
    @WorkspaceObservedObject var tap = ChatGPTTap.shared
    @State private var temporaryChoicePresented = false

    var body: some View {
        HStack(spacing: 6) {
            // W183 R3：ChatGPT build的狀態小鈕（圖示＋狀態點、全文在 help；開著才出現；點了開 TAP › ChatGPT）。放在下面的 if 外面：登入畫面、圖庫頁也看得到。
            ChatGPTHandsStatusButton { model.openTapSettings() }
            // 其他頁（圖庫、外掛…）與需要登入時不顯示。
            if model.page == nil, tap.connection != .needsLogin {
                if model.selectedID == nil, model.activeGPT == nil {
                    // 臨時聊天：照網頁放在右上角、用網頁那顆虛線對話泡泡（使用者 09-25：原本的位置與圖標很突兀）。
                    Button {
                        model.temporaryChat.toggle()
                        if !model.temporaryChat { model.temporaryPersonalized = false }
                        temporaryChoicePresented = model.temporaryChat
                    } label: {
                        ChatGPTTemporaryChatIcon(active: model.temporaryChat)
                            .frame(width: 20, height: 20)
                            .frame(width: 36, height: 36)
                            .background(model.temporaryChat ? ChatGPTPalette.pressed : Color.clear, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(ChatGPTHoverButtonStyle(cornerRadius: 18))
                    .help(ChatGPTTemporaryChatText.help(active: model.temporaryChat))
                    .accessibilityLabel(ChatGPTTemporaryChatText.label(active: model.temporaryChat))
                    .accessibilityIdentifier("chatgpt.temporary")
                    .popover(isPresented: $temporaryChoicePresented) {
                        ChatGPTTemporaryPersonalizationChoice {
                            guard !model.isSending, model.messages.isEmpty else { return }
                            model.temporaryChat = true
                            model.temporaryPersonalized = true
                            temporaryChoicePresented = false
                        } dismiss: {
                            temporaryChoicePresented = false
                        }
                    }
                }
                // 臨時聊天不在紀錄裡：沒有分享、釘選、重新命名、封存、刪除（跟網頁版一樣）。
                if let id = model.selectedID, id != model.temporaryConversationID {
                    Button { model.requestShare(conversationID: id, title: model.selectedTitle) } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("分享")
                    .accessibilityLabel("分享這則對話")
                    .accessibilityIdentifier("chatgpt.share")
                    Menu {
                        ChatGPTConversationActions(model: model, item: TapConversation(id: id, title: model.selectedTitle, updatedAt: Date()))
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("這則對話的選項")
                }
            }
        }
        .task { await ChatGPTHandsStatusButton.pollRemoteStatus() }   // W183 R3：副設備問主機的手腳狀態（掛在一定存在的列上；小鈕沒出現前也會問）
    }
}

struct ChatGPTProjectCreationView: View {
    @ObservedObject var model: ChatGPTSpaceModel
    @FocusState private var nameFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("建立專案").font(ChatTypography.systemUI(18, weight: .semibold))
                Spacer()
                Button { model.showsProjectCreation = false } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain).chatGlassChip()
                .accessibilityLabel("關閉").accessibilityIdentifier("chatgpt.project.cancel")
            }
            ChatChipTextField(title: "輸入專案名稱", text: $model.projectName)
                .padding(10).chatGlassChip().focused($nameFocused)
                .accessibilityIdentifier("chatgpt.project.name")
                .onSubmit { model.createProject() }
            if let failure = model.projectCreationFailure {
                Text(failure).font(ChatTypography.systemUI(12, weight: .regular)).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier("chatgpt.project.error")
            }
            Button(model.creatingProject ? "建立中…" : "建立專案") { model.createProject() }
                .buttonStyle(.plain).padding(.horizontal, 14).frame(height: 32).chatGlassChip(isSelected: true)
                .disabled(!model.canCreateProject).accessibilityIdentifier("chatgpt.project.create")
        }
        .padding(24).frame(width: 380).background(Color(nsColor: .windowBackgroundColor))
        .onAppear { nameFocused = true }
        .onExitCommand { model.showsProjectCreation = false }
    }
}

struct ChatGPTSpaceMainPane: View {
    @WorkspaceObservedObject var model: ChatGPTSpaceModel
    var osModel: ChatPageModel? = nil
    @WorkspaceObservedObject var tap: ChatGPTTap
    let connectionEntry: HandsConnectEntry

    init(model: ChatGPTSpaceModel, osModel: ChatPageModel? = nil, showsHeader: Bool = true, connectionEntry: HandsConnectEntry = .shared) {
        _model = WorkspaceObservedObject(wrappedValue: model)
        self.osModel = osModel
        _tap = WorkspaceObservedObject(wrappedValue: model.tap)
        self.showsHeader = showsHeader
        self.connectionEntry = connectionEntry
    }
    /// 視窗裡右上的鈕在紅綠燈那一列（ChatPage 畫）；只有小面板才在對話上方另放一列。
    var showsHeader = true
    @State private var composerHeight = TatwoChatTranscriptVisualMetrics.windowComposerTextMinimumHeight
    @State private var composerFocused = false
    @State private var dropTargeted = false
    @State private var showsModelPopover = false
    /// W184 G3b：「＋」的快捷小視窗（ChatGPT 原版那種，不是系統選單）開著、換到「更多」那一頁。
    @State private var showsPlusMenu = false
    @State private var plusShowingMore = false
    /// W184 G3b 第二輪（使用者：「快捷指令直接參照chatgpt那邊有什麼 這邊chatgpt space、duo就有什麼」）：「/」指令（私訊框同一份規則、
    /// 同一個清單元件、同一份資料 model.tools）：鍵盤指著的那一列、Esc 收起時的草稿。
    @State private var slashIndex = 0
    @State private var slashDismissed: String?
    @State private var escapeMonitor: Any?
    /// W184 G3：聽寫綁在 Space 的輸入框上（可取消；畫面消失就取消）。
    @StateObject private var dictation = ChatGPTDictation()

    /// 對話仍用原生畫面；W197 的 Dots 第一版使用同一個 Pod 的網頁。
    private var needsLogin: Bool { tap.connection == .needsLogin }

    /// ChatGPT 的字級（桌面版內文約 15pt、行高約 1.5 倍）；Coder 的回答維持原本 13pt。
    static let bodyPointSize: CGFloat = 15
    static let bodyLineSpacing: CGFloat = 5
    static let typography = ChatTranscriptTypography(scale: bodyPointSize / TatwoChatTranscriptVisualMetrics.transcriptPointSize,
                                                     lineSpacing: bodyLineSpacing, paragraphScale: 1.8)

    var body: some View {
        #if DEBUG
        let _ = ChatRenderProbe.record("ChatGPTSpaceMainPane.body")
        #endif
        GeometryReader { proxy in
            Group {
                if model.dotsPresented {
                    ChatGPTDotsPane(model: model)
                } else if needsLogin {
                    loginCard
                } else {
                    nativeContent
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            // 原生 Space 使用同一個 Pod；離開且沒有回合時另設 hidden，位移只負責不露出網頁。
            .background(alignment: .topLeading) {
                if !model.dotsPresented, tap.webPod != nil {
                    TapPodHostView(pod: tap.pod, presentsPage: false)
                        .frame(width: 1100, height: 800)
                        .offset(x: -20_000)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
        // 圖片放大照 Coder 的圖片預覽（使用者 09-25 #126）。視窗裡是整個視窗的燈箱（ChatPage 畫，#128「點空白處要可以退出」：
        // 表單外面那圈點了不會關）；小面板沒有那一層，維持表單。
        .sheet(isPresented: Binding(get: { showsHeader && model.zoomedImage != nil }, set: { if !$0 { model.closeZoom() } })) {
            if let image = model.zoomedImage {
                ChatGPTImagePreview(model: model, image: image, inSheet: true)
            }
        }
        .sheet(isPresented: $model.showsProjectCreation) {
            ChatGPTProjectCreationView(model: model)
        }
        .sheet(item: $model.libraryPreview) { preview in
            ChatGPTLibraryPreviewView(model: model, preview: preview)
        }
        .sheet(item: $model.shareRequest) { request in
            ChatGPTShareSheet(model: model, request: request)
        }
        .alert("刪除「\(model.deleteLibraryTarget?.name ?? "")」？", isPresented: Binding(get: { model.deleteLibraryTarget != nil },
                                                                          set: { if !$0 { model.deleteLibraryTarget = nil } })) {
            Button("刪除", role: .destructive) { model.confirmDeleteLibraryItem() }
            Button("取消", role: .cancel) { model.deleteLibraryTarget = nil }
        } message: {
            Text("跟 ChatGPT 一樣先移到圖庫的垃圾桶，之後還能在 ChatGPT 裡還原。")
        }
        .alert("重新命名對話", isPresented: Binding(get: { model.renameTarget != nil }, set: { if !$0 { model.renameTarget = nil } })) {
            TextField("標題", text: $model.renameText)
            Button("儲存") { model.commitRename() }
            Button("取消", role: .cancel) { model.renameTarget = nil }
        }
        .alert("刪除這則對話？", isPresented: Binding(get: { model.deleteTarget != nil }, set: { if !$0 { model.deleteTarget = nil } })) {
            Button("刪除", role: .destructive) { model.confirmDelete() }
            Button("取消", role: .cancel) { model.deleteTarget = nil }
        } message: {
            Text("「\(model.deleteTarget?.title ?? "")」會從 ChatGPT 一起刪除，無法復原。想留著但不顯示，請改用「封存」。")
        }
        // 先成為自己的容器再掛識別碼，才不會蓋掉裡面每個元件自己的識別碼（09-24 實機）。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatgpt.space")
    }

    /// 未登入時只顯示主題色登入按鈕。
    private var loginCard: some View {
        Button { model.openTapSettings(login: true) } label: {
            Text("ChatGPT 登入").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20).frame(height: 40)
                .background(LiquidGlassTokens.brandAccent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chatgpt.login")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var nativeContent: some View {
        VStack(spacing: 0) {
            if let page = model.page {
                switch page {
                case .library: ChatGPTLibraryView(model: model)
                case .scheduled: ChatGPTScheduledView(model: model)
                case .plugins: ChatGPTPluginsView(model: model)
                case .sites: ChatGPTSitesView(model: model)
                case .personalization: ChatGPTPersonalizationView(model: model)
                }
            } else {
                if showsHeader { header }
                if let osModel {
                    ChatGPTSessionMappingRow(pageModel: osModel, spaceModel: model, side: .chatGPT)
                }
                conversation
                // W180 A2：錯誤放在輸入框上方、捲動區外面，不管捲到哪都看得到。
                if let notice = tap.recoveryNotice ?? model.stopNotice {
                    Text(notice).font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.bottom, 6)
                        .accessibilityIdentifier("chatgpt.stopNotice")
                }
                if let failure = model.composerFailure {
                    Text(failure)
                        .font(.system(size: 12)).foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 6)
                        .accessibilityIdentifier("chatgpt.failure")
                }
                if !model.unsentDrafts.isEmpty {
                    Button("取回未送出的草稿（\(model.unsentDrafts.count)）") { model.restoreUnsentDraft() }
                        .disabled(!model.canRestoreUnsentDraft)
                        .help("先處理目前輸入框的內容；取回只還原草稿，不會送出。關閉 App 前請取回。")
                        .accessibilityIdentifier("chatgpt.restoreUnsentDraft")
                }
                // W199：只在需要使用者動手時顯示一行；健康與短暫核對不佔位。
                HandsConnectEntryButton(entry: connectionEntry, identifier: "chatgpt.handsConnect.entry", insets: EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0))
                composer
            }
        }
        // 照片、檔案直接拖進對話（使用者 09-25「照片抓不進去」）：跟網頁版一樣整個對話區都收。
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $dropTargeted) { providers in
            guard model.page == nil else { return false }
            return model.attach(providers: providers)
        }
        .overlay {
            // W184 G3：虛線框是共用元件（私訊框的 ChatGPT 那一欄同一個）；尺寸照舊。
            if dropTargeted, model.page == nil { ChatGPTDropHighlight(metrics: .space) }
        }
        .overlayPreferenceValue(ChatGPTPickerAnchorKey.self) { anchor in effortCard(anchor) }
        .overlayPreferenceValue(ChatGPTPopoverAnchorKey.self) { anchors in
            ZStack {
                plusCard(anchors[.plus])
                slashCard(anchors[.slash])
            }
        }
        .onChange(of: showsModelPopover) { _, open in watchEscape(open || showsPlusMenu || slashOpen) }
        .onChange(of: showsPlusMenu) { _, open in
            watchEscape(open || showsModelPopover || slashOpen)
            if open { model.refreshToolCatalog() }
        }
        .onChange(of: slashOpen) { _, open in watchEscape(open || showsModelPopover || showsPlusMenu) }
        // 即使舊目錄沒有匹配也要讀；僅在開始／重新開始指令輸入時刷新，不隨結果變動重入。
        .onChange(of: slashQuery != nil, initial: true) { _, active in
            if active { model.refreshToolCatalog() }
        }
        // 草稿改了：Esc 收起的那次作廢、鍵盤指著的那一列回到第一列。
        .onChange(of: model.draft) { _, text in
            if let dismissed = slashDismissed, dismissed != text { slashDismissed = nil }
            slashIndex = 0
        }
        .onChange(of: model.page) { _, page in if page != nil { showsModelPopover = false; showsPlusMenu = false } }
        .onDisappear { watchEscape(false) }
        .overlay {
            if model.voiceActive { ChatGPTVoiceOverlay(model: model) }
        }
    }

    /// 小面板沒有紅綠燈那一列：右上的鈕放在對話上方。視窗裡這排鈕在紅綠燈那一列的右上（ChatPage 的頂右 overlay），
    /// 不再多一條標題列把對話往下擠（使用者 09-25 #125「上方chatgpt的空間空太多 文字都被擠在下面」）。
    private var header: some View {
        HStack(spacing: 6) {
            Spacer()
            ChatGPTTopBarControls(model: model)
        }
        .padding(.horizontal, 24)
        .frame(height: 48)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if model.messages.isEmpty && !model.isLoadingMessages {
                        emptyState
                    }
                    if model.isLoadingMessages {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(model.messages) { message in
                        messageRow(message).id(message.id)
                    }
                    if let waiting = model.awaitingAsyncReplyID, waiting == model.selectedID, !model.isSending {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("ChatGPT 還在產生（例如圖片），好了會自動顯示").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("chatgpt.awaitingAsync")
                    }
                    if model.waitingForFirstWords, let thinking = model.thinking {
                        ChatGPTThinkingRow(thinking: thinking)
                    }
                    Color.clear.frame(height: 8).id("chatgpt.bottom")
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, showsHeader ? 8 : 16)
            }
            .id(model.viewEpoch)
            .onChange(of: model.messages.last?.text) { _, _ in
                proxy.scrollTo("chatgpt.bottom", anchor: .bottom)
            }
            .onChange(of: model.messages.count) { _, _ in
                proxy.scrollTo("chatgpt.bottom", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text(model.activeGPT?.title ?? (model.temporaryChat ? "臨時聊天" : model.headline))
                .font(.system(size: 22, weight: .semibold))
            if tap.connection == .ready, model.temporaryChat, model.activeGPT == nil {
                // 跟網頁版臨時聊天的說明一樣（W184 G3c：字跟私訊框共用 ChatGPTTemporaryChatText）。
                Text(model.temporaryPersonalized ? ChatGPTTemporaryChatText.personalizedNote : ChatGPTTemporaryChatText.note)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            if tap.connection == .ready, model.activeGPT == nil, !model.temporaryChat, !model.suggestions.isEmpty {
                // ChatGPT 自己給的建議：點一下填進輸入框（不直接送出）。
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.suggestions) { item in
                        Button { model.draft = item.prompt } label: {
                            Text(item.title)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: 520, alignment: .leading)
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 12)
            }
            if case .failed = tap.connection {
                Button("重新連上") { tap.restart() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).frame(height: 28).chatGlassChip()
            }
            if tap.connection == .off {
                Button("啟用 ChatGPT") { tap.setEnabled(true) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).frame(height: 28).chatGlassChip()
            }

        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    @ViewBuilder
    private func messageRow(_ message: TapMessage) -> some View {
        switch message.role {
        case .user:
            ChatGPTUserMessageView(model: model, message: message)
        case .assistant:
            if !message.text.isEmpty || !message.images.isEmpty || message.stopNotice != nil || message.turnFailure != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let note = ChatGPTThinking.doneText(message.thoughtSeconds) {
                        Text(note).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    if !message.text.isEmpty {
                        ChatAssistantTranscriptBlockView(
                            document: TatwoAssistantTranscriptPresentation.document(markdown: message.text),
                            copyAllText: message.text,
                            tracksAvailableWidth: true)
                            .environment(\.chatTranscriptTypography, ChatGPTSpaceMainPane.typography)
                    }
                    ForEach(message.images) { image in
                        ChatGPTImageView(model: model, image: image, maxWidth: 480, gallery: message.images.map(\.id))
                    }
                    if let failure = message.turnFailure {
                        ChatGPTTurnFailureRow(failure: failure, draftInComposer: !failure.draft.isEmpty && model.draft.contains(failure.draft)) { model.recover(failure) }
                    }
                    if let note = message.stopNotice {
                        Label(note, systemImage: "stop.circle").font(.caption).foregroundStyle(.secondary)
                    } else if !message.text.isEmpty || !message.images.isEmpty { replyActions(message) }
                }
            }
        }
    }

    /// 回答下方的動作，跟網頁版一樣：拷貝、重新產生（只在最後一個回答，滑過去顯示是哪個模型回答的）。
    private func replyActions(_ message: TapMessage) -> some View {
        HStack(spacing: 2) {
            if let variant = message.variant {
                ChatGPTVariantNav(model: model, message: message, variant: variant)
            }
            actionButton("doc.on.doc", help: "拷貝") { model.copy(message.text) }
            // 重新產生只在 ChatGPT 目前那一支（切到舊版本時先切回來，跟網頁一樣重答的是最新那一支）。
            if message.id == model.lastAssistantID, !model.isSending, model.selectedID != nil, model.branchLeaf == nil {
                let help = message.model.map { "由 \($0) 回答・重新產生" } ?? "重新產生"
                if model.regenerateOptions.isEmpty {
                    actionButton("arrow.clockwise", help: help) { model.regenerate() }
                } else {
                    // 跟網頁版的 Switch model 一樣：再試一次，或換一個檔位（模型／強度）重答。
                    Menu {
                        Button("再試一次") { model.regenerate() }
                        Section("換模型重答") {
                            ForEach(model.regenerateOptions) { option in
                                Button(option.title) { model.regenerate(effort: option.id) }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 26)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(help)
                    .accessibilityLabel(help)
                }
            }
            // 更多（跟網頁版的 More actions 一樣）：朗讀、回饋。
            Menu {
                Button { model.speak(message) } label: {
                    Label(model.speakingMessageID == message.id ? "停止朗讀" : "朗讀", systemImage: "speaker.wave.2")
                }
                if message.id == model.lastAssistantID, !message.id.hasPrefix("local-"), model.selectedID != nil, model.branchLeaf == nil {
                    Button { model.branch() } label: { Label("在新對話分支", systemImage: "arrow.triangle.branch") }
                }
                if !message.id.hasPrefix("local-"), model.selectedID != nil {
                    Divider()
                    Button { model.rate(message, good: true) } label: {
                        Label("好的回答", systemImage: model.ratedMessages[message.id] == true ? "hand.thumbsup.fill" : "hand.thumbsup")
                    }
                    Button { model.rate(message, good: false) } label: {
                        Label("不好的回答", systemImage: model.ratedMessages[message.id] == false ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("更多動作")
            if !message.sources.isEmpty {
                ChatGPTSourcesButton(model: model, sources: message.sources)
                    .padding(.leading, 6)
            }
        }
    }

    private func actionButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// 跟網頁版一樣的輸入框：左邊「＋」、中間輸入、右邊模型／推理強度選單與送出。
    /// W184 G3：＋ 選單、工具小卡與附件縮圖、思考強度膠囊、語音輸入、語音模式／送出／停止都是共用元件（ChatGPTComposerKit.swift），
    /// 私訊框對象是 ChatGPT 時用同一套（手機 token）；這裡照舊是 ChatGPT Space 的尺寸（.space）與排法（一排）。
    private var composer: some View {
        let files = model.attachments.map(\.composerItem)
        return VStack(spacing: 6) {
          VStack(alignment: .leading, spacing: 8) {
            if !model.attachments.isEmpty || model.selectedTool != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    // 附件照 ChatGPT：圖片是方形縮圖、檔案是檔案卡（使用者 09-25「#121 實際應該像 #122」）。
                    ChatGPTComposerChips(tool: model.selectedTool, files: files, metrics: .space,
                                         removeTool: { model.selectedTool = nil }, removeFile: { model.removeAttachment($0) })
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                }
                .frame(height: ChatGPTComposerChips.rowHeight(files: files, metrics: .space))
            }
            HStack(alignment: .bottom, spacing: 8) {
                // 跟網頁版的「＋」一樣：加入檔案，或選一個 ChatGPT 工具（生圖、搜尋…）；分層照網頁版。W184 G3b：按了開 ChatGPT 原版那種
                // 快捷小視窗（ChatGPTQuickMenu，畫在對話區那一層，見 plusCard），不是系統選單。
                ChatGPTPlusButton(isOpen: plusOpen, metrics: .space)

                // 提示字照 ChatGPT 繁中桌面版；貼上或拖進來的照片、檔案直接變附件（09-25「照片抓不進去」）。
                ChatComposerTextView(
                    text: $model.draft, contentHeight: $composerHeight, isFocused: composerFocused,
                    placeholder: "想問什麼都可以", isMonospaced: false,
                    minimumHeight: TatwoChatTranscriptVisualMetrics.windowComposerTextMinimumHeight,
                    maximumHeight: TatwoChatTranscriptVisualMetrics.windowComposerTextMaximumHeight,
                    onSubmit: { model.send() }, onFocusChange: { composerFocused = $0 },
                    // W184 G3b 第二輪：「/」清單開著時 ↑↓ 選、Enter 選定（組字中、有修飾鍵的方向鍵照常給輸入框）。
                    onSuggestionKey: { handleSlashKey($0) },
                    onPasteImage: { model.attach(from: $0) },
                    accessibilityTextLabel: "ChatGPT 訊息",
                    pointSize: ChatGPTComposerMetrics.space.inputText,   // 15（W184 G3b 追加：私訊框照這一個數字）
                    slashCommands: [],
                    acceptsPhotoDrags: true,
                    onTextView: { dictation.textView = $0 },
                    suggestionKeysVerticalOnly: true)
                    .frame(height: composerHeight)
                    .anchorPreference(key: ChatGPTPopoverAnchorKey.self, value: .bounds) { [.slash: $0] }

                modelPicker
                    .frame(height: 32)

                // 語音輸入：用 macOS 內建聽寫把字打進輸入框（跟網頁版的麥克風一樣是「說話變文字」）。
                ChatGPTDictationButton(metrics: .space, dictation: dictation)

                // 跟網頁版一樣：回答中是停止；還沒打字時送出鍵的位置是語音模式（黑底圓鈕＋聲波）；有字是送出。
                // W184 G3：語音模式鈕看 TAP 的語音擁有者——私訊框的語音開著、或有回答在跑時不能按（Pod 只有一個麥克風）。
                ChatGPTSendSlot(isSending: model.isSending,
                                isEmpty: model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.attachments.isEmpty,
                                canSend: model.canSend, voiceEnabled: tap.voiceStartBlocker == nil, metrics: .space,
                                stop: { model.stop() }, startVoice: { model.startVoice() }, send: { model.send() })
            }
          }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .liquidGlassPanelSurface(cornerRadius: LiquidGlassTokens.radiusPrimary)
            // W179 UI：只回報位置（不改畫面）——主視窗的停靠私訊框放在這個輸入框上方，不蓋送出鈕。
            .globalDMComposerFrame(.chatgpt, active: !showsHeader)
            .frame(maxWidth: 760)
            Text("走你的 ChatGPT 訂閱（Chat），不耗 Codex 額度 · 記憶與自訂指令由 ChatGPT 帶過來")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .onDisappear { dictation.cancel() }   // W184 G3：輸入框不在了＝取消還沒開始的聽寫
    }

    private func modelButton(_ item: TapModel) -> some View {
        Button {
            model.selectedModelID = item.id
        } label: {
            if item.id == model.effectiveModelID {
                Label(item.title, systemImage: "checkmark")
            } else {
                Text(item.title)
            }
        }
    }

    /// 照 ChatGPT 網頁版輸入框裡的膠囊（09-25 從網頁 CSS 對過）：平常只有字——一般檔位灰字（High）、帶版本時
    /// 版本黑字＋檔位灰字（6 Pro，最高檔紫色）；滑過淡灰底；打開時灰底膠囊、字換成「思考強度」。面板見 ChatGPTEffortCard。
    /// W184 G3：膠囊是共用元件（ChatGPTPickerCapsule；私訊框同一個）。
    private var modelPicker: some View {
        let label = model.pickerLabel
        return ChatGPTPickerCapsule(label: label, isOpen: showsModelPopover, metrics: .space) {
            withAnimation(ChatGPTEffortCardMetrics.motion) { showsModelPopover.toggle() }
        }
    }

    /// 面板浮在膠囊正上方、置中對齊（網頁：寬 260，對齊膠囊中心，離膠囊 6pt）；點面板外面或按 Esc 就關。
    /// W184 G3：浮起來的那一層是共用元件（ChatGPTFloatingCardLayer；私訊框同一個）。
    @ViewBuilder
    private func effortCard(_ anchor: Anchor<CGRect>?) -> some View {
        ChatGPTFloatingCardLayer(anchor: anchor, isOpen: showsModelPopover && model.page == nil, width: ChatGPTEffortCardMetrics.width,
                                 dismiss: { withAnimation(ChatGPTEffortCardMetrics.motion) { showsModelPopover = false } }) {
            ChatGPTEffortCard(model: model) { withAnimation(ChatGPTEffortCardMetrics.motion) { showsModelPopover = false } }
        }
    }

    /// W184 G3b：「＋」的快捷小視窗（ChatGPT 原版那種）：跟 ＋ 左邊對齊、浮在它上面；點外面或 Esc 就關。
    private var plusOpen: Binding<Bool> {
        Binding(get: { showsPlusMenu }, set: { open in
            showsPlusMenu = open
            if !open { plusShowingMore = false }
        })
    }

    @ViewBuilder
    private func plusCard(_ anchor: Anchor<CGRect>?) -> some View {
        ChatGPTFloatingCardLayer(anchor: anchor, isOpen: showsPlusMenu && model.page == nil, width: ChatGPTQuickMenu.width, leading: true,
                                 dismiss: { plusOpen.wrappedValue = false }) {
            ChatGPTQuickMenu(sections: ChatGPTQuickMenu.plusSections(
                                tools: model.tools, recentApps: UserDefaults.standard.stringArray(forKey: ChatGPTSpaceModel.recentAppsKey) ?? [],
                                selectedToolID: model.selectedTool?.id,
                                thinking: model.thinkingEffortID == nil ? nil : model.thinkingHard, showingPlugins: plusShowingMore,
                                tatwo: HandsConnectEntry.shared.menuRow),   // W183 R11：外掛程式那一頁最上面「連線」
                             metrics: .space, identifier: "chatgpt.plus.menu") { id in pickPlus(id) }
        }
    }

    private func pickPlus(_ id: String) {
        switch id {
        case "plugins": plusShowingMore = true
        case "back": plusShowingMore = false
        case HandsConnectEntry.menuRowID:   // W183 R11：外掛程式那一頁的「連線」（跟對話上方那一顆同一個動作）
            plusOpen.wrappedValue = false
            HandsConnectEntry.shared.tap()
        case "thinking": model.toggleThinkingHard()
        case "photos":
            plusOpen.wrappedValue = false
            model.pickPhotos()
        case "files":
            plusOpen.wrappedValue = false
            model.pickFiles()
        default:
            guard id.hasPrefix("tool:"), let tool = model.tools.first(where: { "tool:" + $0.id == id }) else { return }
            plusOpen.wrappedValue = false
            model.choose(tool)
        }
    }

    /// Esc：思考強度面板與「＋」小卡都收（W184 G3b：＋ 小卡也收）。W184 G3b 第二輪：「/」清單開著＝只收清單（草稿留著）。
    private func closePopovers() {
        if slashOpen {
            slashDismissed = model.draft
            return
        }
        withAnimation(ChatGPTEffortCardMetrics.motion) { showsModelPopover = false }
        plusOpen.wrappedValue = false
    }

    // MARK: W184 G3b 第二輪：「/」指令（私訊框同一份規則 ChatGPTSlash、同一個清單元件 ChatGPTQuickMenu、同一份資料 model.tools）

    private var slashQuery: String? { model.page == nil ? ChatGPTSlash.query(model.draft, dismissed: slashDismissed) : nil }
    private var slashMatches: [TapTool] { slashQuery.map { ChatGPTQuickMenu.slashTools(model.tools, query: $0) } ?? [] }
    private var slashOpen: Bool { ChatGPTSlash.isOpen(query: slashQuery, catalog: model.tools, matches: slashMatches) }
    private var slashHighlight: Int {
        let count = slashMatches.count
        return count == 0 ? 0 : min(max(slashIndex, 0), count - 1)
    }

    /// 輸入框交來的鍵（只有沒修飾鍵的 ↑↓ 與 Enter）：清單開著時 ↑↓ 選、Enter 選定；第一列再往上、沒開著就不吃。
    private func handleSlashKey(_ key: ChatComposerSuggestionKey) -> Bool {
        let tools = slashMatches
        guard slashQuery != nil else { return false }
        // 清單只有一行說明（ChatGPT 的清單還沒讀到過）：Enter 不把「/…」當訊息送出。
        if tools.isEmpty { return key == .commit && slashOpen }
        guard let index = ChatGPTSlash.moved(key, index: slashHighlight, count: tools.count) else { return false }
        if key == .commit { chooseSlash(tools[index]) } else { slashIndex = index }
        return true
    }

    /// 選定＝那個工具變成輸入框裡的小卡（同 ＋ 選的），草稿裡的「/…」拿掉。
    private func chooseSlash(_ tool: TapTool) {
        model.choose(tool)
        model.draft = ""
        slashIndex = 0
        slashDismissed = nil
    }

    /// 「/」清單：跟輸入框左邊對齊、浮在它上面；點外面＝收（跟 Esc 一樣，草稿留著）。
    @ViewBuilder
    private func slashCard(_ anchor: Anchor<CGRect>?) -> some View {
        let tools = slashMatches
        ChatGPTFloatingCardLayer(anchor: anchor, isOpen: slashOpen, width: ChatGPTQuickMenu.width, leading: true,
                                 dismiss: { slashDismissed = model.draft }) {
            ChatGPTQuickMenu(sections: ChatGPTSlash.sections(tools, catalogEmpty: model.tools.isEmpty, selectedID: model.selectedTool?.id),
                             highlighted: tools.indices.contains(slashHighlight) ? "tool:" + tools[slashHighlight].id : nil,
                             metrics: .space, identifier: "chatgpt.slash") { id in
                if let picked = tools.first(where: { "tool:" + $0.id == id }) { chooseSlash(picked) }
            }
        }
    }

    /// 面板開著時 Esc 只關面板（不讓它落到主視窗、把視窗關掉）。
    private func watchEscape(_ open: Bool) {
        if open, escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // 只攔主視窗、上面沒有表單或存檔視窗時的 Esc（審查 #14）。
                guard event.keyCode == 53, let window = event.window, window.isMainWindow, window.attachedSheet == nil else { return event }
                closePopovers()
                return nil
            }
        } else if !open, let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }
}

/// 膠囊的位置（面板要浮在它正上方）。
struct ChatGPTPickerAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// 把 Pod 的瀏覽器放進 SwiftUI；離開畫面時交回前一個畫面或停泊視窗（網頁不關、登入不掉）。
struct TapPodHostView: NSViewRepresentable {
    let pod: TapWebPod
    var presentsPage = true

    final class Coordinator {
        let pod: TapWebPod
        init(pod: TapWebPod) { self.pod = pod }
    }

    func makeCoordinator() -> Coordinator { Coordinator(pod: pod) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityElement(false)
        pod.claim(view, presentsPage: presentsPage)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.pod.release(nsView)
    }
}

// MARK: - W180 A4：私訊框的 ChatGPT 模型選單資料

/// ChatGPT 的模型清單與伺服器記的預設（「上次使用」）。私訊框拿同一份清單做自己的選單；ChatGPT Space 的選擇不帶過去。
/// W184 G3：也帶「＋」的工具與 App（私訊框的「＋」照 ChatGPT Space 的分層；選哪個只在私訊框）。
struct ChatGPTModelCatalog: Equatable {
    var models: [TapModel] = []
    var defaultModelID: String? = nil
    var defaultEffortID: String? = nil
    var tools: [TapTool] = []
}

extension ChatGPTSpaceModel {
    /// 只讀：模型清單＋ChatGPT 的預設＋工具（Space 自己選的模型、強度、工具不在裡面）。
    var modelCatalog: ChatGPTModelCatalog {
        ChatGPTModelCatalog(models: models, defaultModelID: defaultModelID, defaultEffortID: defaultEffortID, tools: tools)
    }

    /// 清單載入或換了就送一次（私訊框的膠囊與「＋」跟著重畫）。
    var modelCatalogPublisher: AnyPublisher<ChatGPTModelCatalog, Never> {
        Publishers.CombineLatest4($models, $defaultModelID, $defaultEffortID, $tools)
            .map { ChatGPTModelCatalog(models: $0, defaultModelID: $1, defaultEffortID: $2, tools: $3) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}

/// 私訊框對 ChatGPT 選的模型／思考強度；都是 nil＝照 ChatGPT 的預設。只放記憶體。
struct ChatGPTModelChoice: Equatable, Sendable {
    var modelID: String? = nil
    var effortID: String? = nil

    var isDefault: Bool { modelID == nil && effortID == nil }
}

/// 私訊框的 ChatGPT 模型選單（純計算）：規則同 ChatGPT Space 的輸入框選單——選的模型還在清單裡才算數，
/// 沒選就用 ChatGPT 伺服器記的「上次使用」；版本（version:）不是模型代號，送出時只帶檔位。
enum ChatGPTModelMenu {
    struct Item: Equatable {
        let title: String
        let choice: ChatGPTModelChoice
        let isSelected: Bool
    }

    struct Section: Equatable {
        let title: String
        let items: [Item]
    }

    static func effectiveModel(_ catalog: ChatGPTModelCatalog, _ choice: ChatGPTModelChoice) -> TapModel? {
        func find(_ id: String?) -> TapModel? { id.flatMap { id in catalog.models.first { $0.id == id } } }
        return find(choice.modelID) ?? find(catalog.defaultModelID) ?? catalog.models.first
    }

    static func effectiveEffort(_ catalog: ChatGPTModelCatalog, _ choice: ChatGPTModelChoice) -> TapEffort? {
        guard let efforts = effectiveModel(catalog, choice)?.efforts, !efforts.isEmpty else { return nil }
        if let id = choice.effortID, let effort = efforts.first(where: { $0.id == id }) { return effort }
        if let id = catalog.defaultEffortID, let effort = efforts.first(where: { $0.id == id }) { return effort }
        return nil
    }

    /// 送出時帶的模型與檔位：模型只在自己選過、而且不是版本時帶；檔位照目前會用的那一檔（跟 ChatGPT Space 一樣不讓網頁自己挑）。
    /// 清單還沒載入時都不帶（照網頁自己的）。
    static func sendArguments(_ catalog: ChatGPTModelCatalog, _ choice: ChatGPTModelChoice) -> (model: String?, effort: String?) {
        guard !catalog.models.isEmpty else { return (nil, nil) }
        let model = choice.modelID.flatMap { id in
            catalog.models.contains { $0.id == id } && !id.hasPrefix("version:") ? id : nil
        }
        return (model, effectiveEffort(catalog, choice)?.id)
    }

    /// chip 上的字：有檔位顯示檔位（帶版本的前面加版本），沒有就模型名；清單還沒載入是「預設」。
    static func chipTitle(_ catalog: ChatGPTModelCatalog, _ choice: ChatGPTModelChoice) -> String {
        if let effort = effectiveEffort(catalog, choice) {
            let level = ChatGPTLabels.effort(effort.level.isEmpty ? effort.title : effort.level)
            return effort.showsVersion && !effort.version.isEmpty ? "\(effort.version) \(level)" : level
        }
        return effectiveModel(catalog, choice).map { $0.id.hasPrefix("version:") ? ChatGPTLabels.version($0.title) : $0.title }
            ?? "預設"
    }

    /// 選單：目前模型的思考強度、版本、其他模型；選過東西才有「回到 ChatGPT 的預設」（放在最後一段）。
    static func sections(_ catalog: ChatGPTModelCatalog, _ choice: ChatGPTModelChoice) -> [Section] {
        let model = effectiveModel(catalog, choice)
        let effort = effectiveEffort(catalog, choice)
        var result: [Section] = []
        if let model, !model.efforts.isEmpty {
            result.append(Section(title: "思考強度", items: model.efforts.map { item in
                let level = ChatGPTLabels.effort(item.level.isEmpty ? item.title : item.level)
                let title = item.showsVersion && !item.version.isEmpty ? "\(item.version) \(level)" : level
                return Item(title: title, choice: ChatGPTModelChoice(modelID: choice.modelID, effortID: item.id),
                            isSelected: item.id == effort?.id)
            }))
        }
        let versions = catalog.models.filter { $0.id.hasPrefix("version:") }
        if !versions.isEmpty {
            result.append(Section(title: "版本", items: versions.map {
                Item(title: ChatGPTLabels.version($0.title), choice: ChatGPTModelChoice(modelID: $0.id),
                     isSelected: $0.id == model?.id)
            }))
        }
        let others = catalog.models.filter { !$0.id.hasPrefix("version:") }
        if !others.isEmpty {
            result.append(Section(title: "其他模型", items: others.map {
                Item(title: $0.title, choice: ChatGPTModelChoice(modelID: $0.id), isSelected: $0.id == model?.id)
            }))
        }
        if !choice.isDefault {
            result.append(Section(title: "", items: [Item(title: "回到 ChatGPT 的預設", choice: ChatGPTModelChoice(),
                                                         isSelected: false)]))
        }
        return result
    }
}
