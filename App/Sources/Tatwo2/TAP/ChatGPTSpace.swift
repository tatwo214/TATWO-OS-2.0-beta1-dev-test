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

    let tap = ChatGPTTap.shared
    @Published private(set) var conversations: [TapConversation] = []
    @Published private(set) var total = 0
    @Published private(set) var pinned: [TapFolder] = []
    @Published private(set) var projects: [TapFolder] = []
    @Published private(set) var projectConversations: [String: [TapConversation]] = [:]
    @Published private(set) var expandedProjects: Set<String> = []
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
    /// 側欄搜尋：打字 0.35 秒後問 ChatGPT 伺服器（搜得到還沒載入的舊對話）；失敗就只搜已載入的標題。
    @Published var search = "" { didSet { scheduleSearch() } }
    @Published private(set) var searchResults: [TapConversation]?
    private var searchTask: Task<Void, Never>?
    /// 對話選項（跟網頁版一樣）：重新命名、封存、刪除（刪除要再確認一次）。
    /// 「＋」裡的 ChatGPT 工具（生圖、網路搜尋…）；選了會在輸入框出現小卡，送出時帶上。
    @Published private(set) var tools: [TapTool] = []
    @Published var selectedTool: TapTool?
    /// 新對話頁：ChatGPT 自己的問候語與建議。
    @Published private(set) var greeting: String?
    @Published private(set) var suggestions: [TapSuggestion] = []
    /// GPTs：點一下就跟那個 GPT 開新對話。
    @Published private(set) var gpts: [TapFolder] = []
    @Published private(set) var activeGPT: TapFolder?
    /// 暫時對話（網頁版右上角的開關）：這則新對話不存進紀錄；送出一次後就是那則對話的狀態。
    @Published var temporaryChat = false
    /// 目前這則是暫時對話（有編號但不在紀錄裡）：標題顯示「暫時對話」、不列進側欄、沒有對話選項。
    @Published private(set) var temporaryConversationID: String?
    /// 正在看的不是 ChatGPT 目前那一支（切換過版本）時，這一支最末端的節點；接著送出就接在它後面。
    @Published private(set) var branchLeaf: String?
    /// 側欄的頁面（跟網頁一樣：圖庫、排程、外掛、網站；帳號選單裡的個人化）；nil＝對話。
    @Published private(set) var page: ChatGPTPage?
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
    /// 即時語音（網頁的語音模式在 Pod 裡跑，這裡蓋原生畫面）。
    @Published private(set) var voiceActive = false
    @Published private(set) var voiceLive = false
    @Published private(set) var voiceStatus = ""
    private var voiceWatch: Task<Void, Never>?
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
    /// 要附上的檔案（只在記憶體；送出時交給 ChatGPT 網頁自己上傳）。合計上限 20 MB。
    @Published private(set) var attachments: [TapAttachment] = []
    static let attachmentLimit = 20 * 1024 * 1024
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
    private var messageCacheOrder: [String] = []
    private var messageLoads: [String: Task<[TapMessage]?, Never>] = [:]
    static let cacheLimit = 30
    /// 通知開關的代號（跟 Space 設定裡的分頁代號一樣）。
    static let noticeSpace = "chatgpt"
    /// ChatGPT Space 正在畫面上（背景預熱時不要排休眠給正在看的人）。
    private var visible = false
    /// 每次換對話／開新對話加一：送出中切走之後，舊的送出不能再把畫面拉回它那則。
    private var viewEpoch = 0
    /// 語音：每次開始／結束加一；結束之後才回來的「開始」結果作廢。
    private var voiceSession = 0
    @Published var failure: String?
    private var loadedOnce = false
    private var connectionWatch: AnyCancellable?
    private var idleSleep: Task<Void, Never>?
    /// 離開 ChatGPT Space 多久沒回來就讓 Pod 休眠（8 GB 機器上隱藏網頁約佔 150–300 MB）。
    static let idleSleepDelay: Duration = .seconds(15 * 60)

    private init() {
        selectedModelID = UserDefaults.standard.string(forKey: Self.modelKey)
        selectedEffortID = UserDefaults.standard.string(forKey: Self.effortKey)
        pageModelID = UserDefaults.standard.string(forKey: Self.pageModelKey)
        pageEffortID = UserDefaults.standard.string(forKey: Self.pageEffortKey)
        connectionWatch = tap.$connection.removeDuplicates().sink { [weak self] connection in
            guard connection == .ready else { return }
            Task { @MainActor in await self?.refresh() }
        }
        selectionWatch = tap.$pageSelection.sink { [weak self] selection in
            guard let self, let selection else { return }
            self.pageModelID = selection.model
            self.pageEffortID = selection.effort
            UserDefaults.standard.set(selection.model, forKey: Self.pageModelKey)
            UserDefaults.standard.set(selection.effort, forKey: Self.pageEffortKey)
        }
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
        if let effort = currentEffort {
            let level = ChatGPTLabels.effort(effort.level.isEmpty ? effort.title : effort.level)
            return PickerLabel(version: effort.showsVersion && !effort.version.isEmpty ? effort.version : nil, level: level, isMax: effort.isMax)
        }
        return PickerLabel(version: nil, level: currentModel?.title ?? "ChatGPT", isMax: false)
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
        if let searchResults { return searchResults }
        return conversations.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { searchResults = nil; return }
        searchResults = nil
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            let found = try? await self.tap.search(query: query)
            guard !Task.isCancelled, self.search.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            self.searchResults = found
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
    var waitingForFirstWords: Bool {
        isSending && (messages.last.map { $0.role == .assistant && $0.text.isEmpty } ?? false)
    }
    var lastAssistantID: String? { messages.last { $0.role == .assistant }?.id }
    /// 設定頁「探查網頁選單」用：目前選的對話。
    var selectedIDForProbe: String? { selectedID }

    func appear() {
        visible = true
        idleSleep?.cancel()
        idleSleep = nil
        tap.start()
        if tap.connection == .ready, !loadedOnce { Task { await refresh() } }
    }

    func disappear() {
        visible = false
        scheduleIdleSleep()
    }

    private func scheduleIdleSleep() {
        idleSleep?.cancel()
        idleSleep = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.idleSleepDelay)
            guard let self, !Task.isCancelled, !self.isSending, !self.tap.pod.isHosted else { return }
            self.tap.sleep()
        }
    }

    func refresh() async {
        guard tap.connection == .ready else { return }
        // 清單以外的（釘選、專案、模型、工具、GPTs、首頁建議）跟清單同時一起要、各自到了就顯示
        // （使用者 09-25「chatgpt的載入速度需要加快」：以前一個等一個，每個都是一次網路來回）。讀不到不算錯：少一塊而已。
        Task { if let loaded = try? await tap.pinned() { pinned = loaded } }
        Task { if let loaded = try? await tap.projects() { projects = loaded } }
        for id in expandedProjects { Task { await loadProject(id) } }
        if models.isEmpty {
            Task {
                guard models.isEmpty, let loaded = try? await tap.models() else { return }
                models = loaded.items
                defaultModelID = loaded.defaultID
                defaultEffortID = loaded.currentEffortID
            }
        }
        if tools.isEmpty { Task { if let loaded = try? await tap.tools() { tools = loaded } } }
        if gpts.isEmpty { Task { if let loaded = try? await tap.gpts() { gpts = loaded } } }
        if suggestions.isEmpty {
            Task {
                guard let loaded = try? await tap.home() else { return }
                greeting = loaded.greeting
                suggestions = Array(loaded.suggestions.prefix(4))
            }
        }
        isLoadingList = true
        defer { isLoadingList = false }
        do {
            let page = try await tap.conversations(offset: 0, limit: 50)
            conversations = page.items
            total = page.total
            loadedOnce = true
        } catch {
            failure = "讀不到對話清單：\(error.localizedDescription)"
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
        isLoadingList = true
        defer { isLoadingList = false }
        if let page = try? await tap.conversations(offset: conversations.count, limit: 50) {
            let known = Set(conversations.map(\.id))
            conversations += page.items.filter { !known.contains($0.id) }
            total = page.total
        }
    }

    func toggleProject(_ id: String) {
        if expandedProjects.contains(id) {
            expandedProjects.remove(id)
        } else {
            expandedProjects.insert(id)
            Task { await loadProject(id) }
        }
    }

    private func loadProject(_ id: String) async {
        if let items = try? await tap.conversations(inProject: id) { projectConversations[id] = items }
    }

    /// 送出中也能切到別則看（Pro 可能想好幾分鐘，跟網頁一樣邊等邊看別的）；只是不能再送第二則。
    func select(_ id: String) {
        guard id != selectedID || page != nil else { return }
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
        Task {
            defer { if self.selectedID == id { self.isLoadingMessages = false } }
            if let loaded = await loadMessages(id, reuseInFlight: cached == nil) {
                if selectedID == id, messages != loaded { messages = loaded }
            } else if selectedID == id, cached == nil {
                failure = "讀不到這則對話"
            }
        }
    }

    /// 讀一則對話並放進快取；reuseInFlight＝同一則正在預載就等那一次（不重複要）。
    private func loadMessages(_ id: String, reuseInFlight: Bool) async -> [TapMessage]? {
        if reuseInFlight, let running = messageLoads[id] { return await running.value }
        let task = Task<[TapMessage]?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            guard let loaded = try? await self.tap.messages(conversationID: id) else { return nil }
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
        while messageCacheOrder.count > Self.cacheLimit { messageCache[messageCacheOrder.removeFirst()] = nil }
    }

    /// 滑鼠停在側欄的對話上：先在背景讀好（跟網頁滑過連結就預載一樣），點下去幾乎立刻出來。
    func prefetch(_ id: String) {
        guard tap.connection == .ready, !isSending, id != selectedID, messageCache[id] == nil, messageLoads[id] == nil else { return }
        Task { _ = await loadMessages(id, reuseInFlight: true) }
    }

    func newChat(with gpt: TapFolder? = nil) {
        viewEpoch += 1
        page = nil
        branchLeaf = nil
        selectedID = nil
        messages = []
        failure = nil
        activeGPT = gpt
        temporaryChat = false
    }

    var canSend: Bool {
        tap.connection == .ready && !isSending
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let files = attachments
        draft = ""
        attachments = []
        failure = nil
        messages.append(TapMessage(id: "local-user-\(UUID().uuidString)", role: .user, text: text, files: files.map(\.name)))
        // 畫面上膠囊顯示哪一檔就送哪一檔（沒特別選時是 ChatGPT 的「上次使用」），不讓網頁自己另外挑。
        let effort = effectiveEffortID
        let tool = selectedTool?.id
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
                         temporary: temporary, parentID: parent),
                startedIn: selectedID, failurePrefix: "送出沒有完成", temporary: temporary,
                project: selectedID == nil && activeGPT?.kind == .project ? activeGPT : nil)
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
        for url in urls {
            guard let raw = try? Data(contentsOf: url) else { failure = "讀不到「\(url.lastPathComponent)」"; continue }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let file = Self.webCompatible(raw, name: url.lastPathComponent, mime: mime)
            let total = attachments.reduce(0) { $0 + $1.data.count } + file.data.count
            guard total <= Self.attachmentLimit else { failure = "附件合計超過 20 MB，「\(url.lastPathComponent)」沒有加入"; continue }
            attachments.append(TapAttachment(name: file.name, mime: file.mime, data: file.data))
        }
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
        if let last = messages.lastIndex(where: { $0.role == .assistant }) { messages.remove(at: last) }
        let temporary = conversationID == temporaryConversationID
        consume(tap.regenerate(conversationID: conversationID, model: nil, effort: effort, temporary: temporary),
                startedIn: conversationID, failurePrefix: "重新產生沒有完成", temporary: temporary)
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
        messages.removeSubrange(index...)
        messages.append(TapMessage(id: "local-user-\(UUID().uuidString)", role: .user, text: text))
        branchLeaf = nil
        // 畫面上膠囊顯示哪一檔就送哪一檔（沒特別選時是 ChatGPT 的「上次使用」），不讓網頁自己另外挑。
        let effort = effectiveEffortID
        let model = selectedModelID.flatMap { $0.hasPrefix("version:") ? nil : $0 }
        consume(tap.send(text: text, conversationID: conversationID, model: model, effort: effort, attachments: [],
                         tool: nil, gizmoID: nil, temporary: conversationID == temporaryConversationID, parentID: parent),
                startedIn: conversationID, failurePrefix: "編輯沒有送出", temporary: conversationID == temporaryConversationID)
    }

    /// 重答時可選的檔位：目前這一版的檔位（Instant、Medium、High、Extra High、Pro，跟網頁的 Switch model 一樣）。
    var regenerateOptions: [TapEffort] {
        (models.first { $0.id == effectiveModelID } ?? models.first { $0.id.hasPrefix("version:") })?.efforts ?? []
    }

    // MARK: 「＋」選單（照網頁版分層：前 4 個有名次的工具、最近用過的 App，其他收進「更多」）

    var plusTools: [TapTool] {
        Array(tools.filter { $0.rank != nil && !$0.hidden && !$0.isApp }
            .sorted { ($0.rank ?? 0) < ($1.rank ?? 0) }.prefix(4))
    }

    var plusApps: [TapTool] {
        let apps = tools.filter { $0.isApp && !$0.hidden && !$0.firstPartyApp }
        let recent = (UserDefaults.standard.stringArray(forKey: Self.recentAppsKey) ?? []).compactMap { id in apps.first { $0.id == id } }
        let head = apps.filter(\.headApp)
        var seen = Set<String>()
        return Array((recent + head).filter { seen.insert($0.id).inserted }.prefix(3))
    }

    var moreTools: [TapTool] {
        let shown = Set((plusTools + plusApps).map(\.id))
        return tools.filter { !$0.hidden && !shown.contains($0.id) }
    }

    func choose(_ tool: TapTool) {
        selectedTool = tool
        guard tool.isApp else { return }
        var recent = UserDefaults.standard.stringArray(forKey: Self.recentAppsKey) ?? []
        recent.removeAll { $0 == tool.id }
        recent.insert(tool.id, at: 0)
        UserDefaults.standard.set(Array(recent.prefix(8)), forKey: Self.recentAppsKey)
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

    // MARK: 資料庫

    func openLibrary() { open(.library) }

    /// 打開側欄的頁面；每次打開都重讀（排程、外掛等可能在網頁版改過）。
    func open(_ target: ChatGPTPage) {
        guard !isSending else { return }
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
                tools = (try? await tap.tools()) ?? tools
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
        voiceActive = true
        voiceLive = false
        voiceStatus = "連線中…（第一次會詢問麥克風權限）"
        let startedIn = selectedID
        voiceSession += 1
        let session = voiceSession
        Task {
            do {
                let state = try await tap.voice(start: startedIn)
                // 連線中就按了結束：網頁那邊可能才剛開始，再送一次結束（不讓麥克風在背景開著；09-25 實機）。
                guard session == voiceSession, voiceActive else {
                    // 已經開了新的語音就不要去關它（審查 #12）；沒有才補送結束。
                    if !voiceActive { try? await tap.voiceStop() }
                    return
                }
                voiceLive = state.live
                voiceStatus = state.live ? "正在聆聽，直接說話" : "還沒開始：請確認麥克風權限"
                watchVoice(startedIn: startedIn)
            } catch {
                guard session == voiceSession else { return }
                voiceStatus = "語音模式沒有開始：\(error.localizedDescription)"
            }
        }
    }

    private func watchVoice(startedIn: String?) {
        voiceWatch?.cancel()
        voiceWatch = Task { @MainActor [weak self] in
            var wasLive = false
            while let self, self.voiceActive, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let state = try? await self.tap.voiceState() else { continue }
                self.voiceLive = state.live
                if state.live { wasLive = true; self.voiceStatus = "正在聆聽，直接說話" }
                if wasLive && !state.live { self.finishVoice(conversationID: state.conversationID ?? startedIn); return }
            }
        }
    }

    func stopVoice() {
        guard voiceActive else { return }
        voiceSession += 1
        let startedIn = selectedID
        Task {
            try? await tap.voiceStop()
            let state = try? await tap.voiceState()
            finishVoice(conversationID: state?.conversationID ?? startedIn)
        }
    }

    private func finishVoice(conversationID: String?) {
        voiceWatch?.cancel()
        voiceActive = false
        voiceLive = false
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
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            addFiles(urls)
            return true
        }
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            receivePromises(receivers)
            return true
        }
        // 剪貼簿裡有原始的 PNG／JPEG／HEIC 就直接用原檔（不重新編碼、畫質不變；HEIC 之後會轉 JPEG）；其他格式才經 NSImage 轉 PNG。
        let raw: [(String, String, String)] = [("public.png", "貼上的圖片.png", "image/png"), ("public.jpeg", "貼上的圖片.jpg", "image/jpeg"),
                                               ("public.heic", "貼上的照片.heic", "image/heic")]
        for (type, name, mime) in raw {
            if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type)), !data.isEmpty {
                addData(data, name: name, mime: mime)
                return true
            }
        }
        if let image = NSImage(pasteboard: pasteboard), let png = Self.pngData(image) {
            addData(png, name: "貼上的圖片.png", mime: "image/png")
            return true
        }
        return false
    }

    /// 拖到對話區（不在輸入框上）：檔案網址或圖片。
    func attach(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                    guard let url else { return }
                    Task { @MainActor in self?.addFiles([url]) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] url, _ in
                    // 系統給的暫存檔只在這個回呼裡有效：當場讀進記憶體。
                    guard let url, let data = try? Data(contentsOf: url) else { return }
                    let name = url.lastPathComponent
                    let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
                    Task { @MainActor in self?.addData(data, name: name, mime: mime) }
                }
            }
        }
        return handled
    }

    private func receivePromises(_ receivers: [NSFilePromiseReceiver]) {
        guard let directory = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                            appropriateFor: FileManager.default.temporaryDirectory, create: true) else {
            failure = "沒辦法接收拖進來的照片"
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
            receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: queue) { [weak self] url, error in
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
                if failedCount > 0 { Task { @MainActor in self?.failure = "有 \(failedCount) 張照片沒有收到" } }
                let files = urls.compactMap { url -> (Data, String, String)? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return (data, url.lastPathComponent, UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
                }
                try? FileManager.default.removeItem(at: directory)
                Task { @MainActor in for file in files { self?.addData(file.0, name: file.1, mime: file.2) } }
            }
        }
    }

    func addData(_ data: Data, name: String, mime: String) {
        let file = Self.webCompatible(data, name: name, mime: mime)
        let total = attachments.reduce(0) { $0 + $1.data.count } + file.data.count
        guard total <= Self.attachmentLimit else { failure = "附件合計超過 20 MB，「\(name)」沒有加入"; return }
        attachments.append(TapAttachment(name: file.name, mime: file.mime, data: file.data))
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
        guard tap.connection == .ready else { libraryFailure = ChatGPTSpaceSidebarList.statusText(tap.connection); return }
        let tab = libraryTab
        let query = libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let cursor = libraryCursor
        libraryLoading = true
        defer { libraryLoading = false }
        do {
            let page = try await tap.library(tab: tab, query: query, cursor: cursor)
            guard !Task.isCancelled, tab == libraryTab else { return }
            let known = Set(libraryItems.map(\.id))
            libraryItems += page.items.filter { !known.contains($0.id) }
            libraryCursor = page.cursor
        } catch {
            guard !Task.isCancelled else { return }
            libraryFailure = "讀不到資料庫：\(error.localizedDescription)"
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

    private func consume(_ stream: AsyncStream<TapStreamEvent>, startedIn: String?, failurePrefix: String, temporary: Bool = false,
                         project: TapFolder? = nil) {
        let startedAt = Date()
        let epoch = viewEpoch
        isSending = true
        let placeholderID = "local-assistant-\(UUID().uuidString)"
        messages.append(TapMessage(id: placeholderID, role: .assistant, text: ""))
        Task {
            var conversationID = startedIn
            // 這一輪自己的結果（不從目前畫面推算：送出中可能切到別則；審查 #11）。
            var receivedText = false
            var turnFailure: String?
            // 還在看這一輪那則嗎（新對話：還沒換過畫面）。
            @MainActor func viewingTurn() -> Bool { conversationID != nil ? selectedID == conversationID : viewEpoch == epoch }
            for await event in stream {
                switch event {
                case .accepted, .finished:
                    break
                case .conversation(let id):
                    conversationID = id
                    if temporary { temporaryConversationID = id }
                    if selectedID == nil, viewEpoch == epoch { selectedID = id }
                case .text(_, let full):
                    if !full.isEmpty { receivedText = true }
                    if let index = messages.firstIndex(where: { $0.id == placeholderID }) { messages[index].text = full }
                case .title(let id, let title):
                    if let index = conversations.firstIndex(where: { $0.id == id }) { conversations[index].title = title }
                case .failed(let message):
                    turnFailure = "\(failurePrefix)：\(message)"
                    if viewingTurn() { failure = turnFailure }
                }
            }
            isSending = false
            let streamedSomething = receivedText
            messages.removeAll { $0.id == placeholderID && $0.text.isEmpty }
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
                    if let saved = try? await tap.messages(conversationID: conversationID), saved.last?.role == .assistant {
                        // 等待期間可能切到別則：寫回畫面前再確認一次（審查 #11）。
                        if selectedID == conversationID { messages = saved }
                        reloaded = true
                        break
                    }
                    if attempt < 2 { try? await Task.sleep(for: .milliseconds(1500)) }
                }
            }
            if !streamedSomething, !reloaded, turnFailure == nil {
                turnFailure = "沒有收到 ChatGPT 的回覆；可以到 設定 › Plugin › TAP 打開網頁版看"
                if viewingTurn() { failure = turnFailure }
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

    func stop() { tap.stop() }

    struct ConversationGroup: Identifiable {
        let title: String
        var items: [TapConversation]
        var id: String { title }
    }

    /// 對話清單依日期分組（今天／昨天／前 7 天／前 30 天／更早）。
    var groupedConversations: [ConversationGroup] {
        let calendar = Calendar.current
        let now = Date()
        var groups: [ConversationGroup] = []
        func append(_ title: String, _ item: TapConversation) {
            if let index = groups.firstIndex(where: { $0.title == title }) {
                groups[index].items.append(item)
            } else {
                groups.append(ConversationGroup(title: title, items: [item]))
            }
        }
        for item in filteredConversations {
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

// MARK: - 側欄：釘選、專案、對話

struct ChatGPTSpaceSidebarList: View {
    @ObservedObject var model: ChatGPTSpaceModel
    @ObservedObject var tap = ChatGPTTap.shared

    var body: some View {
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
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("搜尋對話", text: $model.search)
                    .font(ChatTypography.systemUI(12, weight: .regular))
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .chatGlassChip()
            .padding(.horizontal, 12)

            // 跟網頁版側欄一樣：圖庫、排程、外掛、網站（使用者 09-25「2全要」）。
            VStack(spacing: 0) {
                ForEach(ChatGPTPage.sidebar) { page in ChatGPTSidebarNavRow(model: model, page: page) }
            }
            .padding(.horizontal, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if tap.connection != .ready {
                        Text(Self.statusText(tap.connection))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.top, 6)
                    }
                    if model.search.isEmpty {
                        if !model.pinned.isEmpty {
                            sectionHeader("釘選")
                            ForEach(model.pinned) { folder in folderRows(folder, idPrefix: "pin") }
                        }
                        if !model.projects.isEmpty {
                            sectionHeader("專案")
                            ForEach(model.projects) { folder in folderRows(folder, idPrefix: "project") }
                        }
                        if !model.gpts.isEmpty {
                            sectionHeader("GPTs")
                            ForEach(model.gpts) { folder in folderRows(folder, idPrefix: "gpt").id("gpt-\(folder.id)") }
                        }
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
                if items.isEmpty {
                    Text("讀取中或還沒有對話")
                        .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                        .padding(.leading, 34).frame(height: 24)
                }
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
        case .starting: "正在連上 ChatGPT…"
        case .needsLogin: "還沒登入 ChatGPT"
        case .ready: ""
        case .sleeping: "ChatGPT 休眠中，打開這一頁就會連上"
        case .failed(let message): message
        }
    }
}

/// 側欄的一則對話：外觀不變；滑過時右邊出現「⋯」（跟網頁版一樣），右鍵也有同一份選單。
struct ChatGPTConversationRow: View {
    @ObservedObject var model: ChatGPTSpaceModel
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
    @ObservedObject var model: ChatGPTSpaceModel
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
    @ObservedObject var model: ChatGPTSpaceModel
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
    @ObservedObject var model: ChatGPTSpaceModel
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
    @ObservedObject var model: ChatGPTSpaceModel
    let sources: [TapSource]
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "link").font(.system(size: 10.5)).accessibilityHidden(true)
                Text("來源").font(.system(size: 12, weight: .medium))
                Text("\(sources.count)").font(.system(size: 11)).foregroundStyle(.secondary)
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
    @ObservedObject var model: ChatGPTSpaceModel
    @ObservedObject var tap = ChatGPTTap.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("圖庫")
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 18)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("搜尋圖庫", text: $model.libraryQuery)
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
    @ObservedObject var model: ChatGPTSpaceModel
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
    @ObservedObject var model: ChatGPTSpaceModel
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
    @ObservedObject var model: ChatGPTSpaceModel
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
    @ObservedObject var model: ChatGPTSpaceModel
    @ObservedObject var tap = ChatGPTTap.shared

    var body: some View {
        HStack(spacing: 6) {
            // 其他頁（圖庫、外掛…）與需要登入時不顯示。
            if model.page == nil, tap.connection != .needsLogin {
                if model.selectedID == nil, model.activeGPT == nil {
                    // 臨時聊天：照網頁放在右上角、用網頁那顆虛線對話泡泡（使用者 09-25：原本的位置與圖標很突兀）。
                    Button { model.temporaryChat.toggle() } label: {
                        ChatGPTTemporaryChatIcon(active: model.temporaryChat)
                            .frame(width: 20, height: 20)
                            .frame(width: 36, height: 36)
                            .background(model.temporaryChat ? ChatGPTPalette.pressed : Color.clear, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(ChatGPTHoverButtonStyle(cornerRadius: 18))
                    .help(model.temporaryChat ? "關閉臨時聊天" : "開啟臨時聊天：不會出現在紀錄裡")
                    .accessibilityLabel(model.temporaryChat ? "關閉臨時聊天" : "開啟臨時聊天")
                    .accessibilityIdentifier("chatgpt.temporary")
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
    }
}

struct ChatGPTSpaceMainPane: View {
    @ObservedObject var model: ChatGPTSpaceModel
    @ObservedObject var tap = ChatGPTTap.shared
    /// 視窗裡右上的鈕在紅綠燈那一列（ChatPage 畫）；只有小面板才在對話上方另放一列。
    var showsHeader = true
    @State private var composerHeight = TatwoChatTranscriptVisualMetrics.windowComposerTextMinimumHeight
    @State private var composerFocused = false
    @State private var dropTargeted = false
    @State private var showsModelPopover = false
    @State private var pickerHover = false
    @State private var escapeMonitor: Any?

    /// Space 裡不放任何 ChatGPT 網頁（使用者 09-25「我要就像os原生」）：需要登入時顯示原生卡片，登入在 設定 › Plugin › TAP 做。
    private var needsLogin: Bool { tap.connection == .needsLogin }

    /// ChatGPT 的字級（桌面版內文約 15pt、行高約 1.5 倍）；Coder 的回答維持原本 13pt。
    static let bodyPointSize: CGFloat = 15
    static let bodyLineSpacing: CGFloat = 5
    static let typography = ChatTranscriptTypography(scale: bodyPointSize / TatwoChatTranscriptVisualMetrics.transcriptPointSize,
                                                     lineSpacing: bodyLineSpacing, paragraphScale: 1.8)

    var body: some View {
        GeometryReader { proxy in
            Group {
                if needsLogin {
                    loginCard
                } else {
                    nativeContent
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            // Pod 的網頁永遠墊在畫面外（仍算看得見、不被節流），使用者看不到也點不到。
            .background(alignment: .topLeading) {
                TapPodHostView(pod: tap.pod)
                    .frame(width: 1100, height: 800)
                    .offset(x: -20_000)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
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

    /// 需要登入：原生卡片；按「前往登入」打開 設定 › Plugin › TAP 並直接跳出登入（登完自動關、回到這裡）。
    private var loginCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("需要登入 ChatGPT").font(.system(size: 17, weight: .semibold))
            Text("登入一次就好；登入只存在 ChatGPT 自己的獨立空間，不會碰到你其他瀏覽器的帳號。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button { model.openTapSettings(login: true) } label: {
                Text("前往登入").font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 16).frame(height: 30)
            }
            .buttonStyle(.plain)
            .chatGlassChip(isSelected: true)
            .accessibilityIdentifier("chatgpt.login")
        }
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
                conversation
                composer
            }
        }
        // 照片、檔案直接拖進對話（使用者 09-25「照片抓不進去」）：跟網頁版一樣整個對話區都收。
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $dropTargeted) { providers in
            guard model.page == nil else { return false }
            return model.attach(providers: providers)
        }
        .overlay {
            if dropTargeted, model.page == nil {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(LiquidGlassTokens.brandAccent.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    .background(LiquidGlassTokens.brandAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        Label("放開就加入照片或檔案", systemImage: "photo.on.rectangle.angled")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .padding(16)
                    .allowsHitTesting(false)
            }
        }
        .overlayPreferenceValue(ChatGPTPickerAnchorKey.self) { anchor in effortCard(anchor) }
        .onChange(of: showsModelPopover) { _, open in watchEscape(open) }
        .onChange(of: model.page) { _, page in if page != nil { showsModelPopover = false } }
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
                    if model.waitingForFirstWords {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("ChatGPT 思考中…").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    if let failure = model.failure {
                        Text(failure).font(.system(size: 12)).foregroundStyle(.red)
                    }
                    Color.clear.frame(height: 8).id("chatgpt.bottom")
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, showsHeader ? 8 : 16)
            }
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
            Text(tap.connection == .ready ? (model.activeGPT?.title ?? (model.temporaryChat ? "臨時聊天" : model.headline))
                 : ChatGPTSpaceSidebarList.statusText(tap.connection))
                .font(.system(size: 22, weight: .semibold))
            if tap.connection == .ready, model.temporaryChat, model.activeGPT == nil {
                // 跟網頁版臨時聊天的說明一樣。
                Text("臨時聊天不會出現在紀錄裡，不會使用或更新 ChatGPT 的記憶，也不會用來訓練模型。為了安全，副本最多可能保留 30 天。")
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
            if tap.connection == .starting { ProgressView().controlSize(.small) }
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
            if !message.text.isEmpty || !message.images.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
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
                    replyActions(message)
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
    private var composer: some View {
        VStack(spacing: 6) {
          VStack(alignment: .leading, spacing: 8) {
            if !model.attachments.isEmpty || model.selectedTool != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        if let tool = model.selectedTool {
                            HStack(spacing: 6) {
                                Image(systemName: "wand.and.stars").font(.system(size: 11))
                                    .foregroundStyle(LiquidGlassTokens.brandAccent).accessibilityHidden(true)
                                Text(tool.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Button { model.selectedTool = nil } label: {
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                                        .frame(width: 16, height: 16).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("取消 \(tool.title)")
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .chatGlassChip(isSelected: true)
                        }
                        // 附件照 ChatGPT：圖片是方形縮圖、檔案是檔案卡（使用者 09-25「#121 實際應該像 #122」）。
                        ForEach(model.attachments) { file in
                            ChatGPTAttachmentTile(file: file) { model.removeAttachment(file.id) }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                }
                .frame(height: attachmentRowHeight)
            }
            HStack(alignment: .bottom, spacing: 8) {
                // 跟網頁版的「＋」一樣：加入檔案，或選一個 ChatGPT 工具（生圖、搜尋…）。
                // 照網頁版分層（09-24 對照網頁）：加入檔案；有名次的前 4 個工具（生圖、網路搜尋、深入研究、Sketch）；
                // 最近用過的 App；其他收進「更多」。每項下面一行灰字說明，跟網頁版一樣。
                Menu {
                    Section {
                        // 圖示＋標題＋說明（Label 的標題塞兩行只會顯示第一行，09-24 實機）。
                        Button { model.pickFiles() } label: {
                            Image(systemName: "paperclip")
                            Text("加入照片和檔案")
                            Text("從電腦上傳")
                        }
                    }
                    if !model.plusTools.isEmpty || !model.plusApps.isEmpty {
                        Section {
                            ForEach(model.plusTools) { tool in toolButton(tool) }
                            ForEach(model.plusApps) { tool in toolButton(tool) }
                        }
                    }
                    if !model.moreTools.isEmpty {
                        Menu("更多") { ForEach(model.moreTools) { tool in toolButton(tool) } }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help("加入檔案或工具")
                .accessibilityLabel("加入檔案或工具")
                .accessibilityIdentifier("chatgpt.plus")

                // 提示字照 ChatGPT 繁中桌面版；貼上或拖進來的照片、檔案直接變附件（09-25「照片抓不進去」）。
                ChatComposerTextView(
                    text: $model.draft, contentHeight: $composerHeight, isFocused: composerFocused,
                    placeholder: "想問什麼都可以", isMonospaced: false,
                    minimumHeight: TatwoChatTranscriptVisualMetrics.windowComposerTextMinimumHeight,
                    maximumHeight: TatwoChatTranscriptVisualMetrics.windowComposerTextMaximumHeight,
                    onSubmit: { model.send() }, onFocusChange: { composerFocused = $0 },
                    onPasteImage: { model.attach(from: $0) },
                    accessibilityTextLabel: "ChatGPT 訊息",
                    pointSize: 15,
                    slashCommands: [],
                    acceptsPhotoDrags: true)
                    .frame(height: composerHeight)

                modelPicker
                    .frame(height: 32)

                // 語音輸入：用 macOS 內建聽寫把字打進輸入框（跟網頁版的麥克風一樣是「說話變文字」）。
                Button {
                    composerFocused = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
                    }
                } label: {
                    Image(systemName: "mic")
                        .font(.system(size: 13))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("語音輸入（macOS 聽寫）")
                .accessibilityLabel("語音輸入")

                if model.isSending {
                    Button { model.stop() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                            .frame(width: 28, height: 28).contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("停止")
                    .accessibilityLabel("停止回答")
                } else if model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.attachments.isEmpty {
                    // 跟網頁版一樣：還沒打字時，送出鍵的位置是語音模式（黑底圓鈕＋聲波）。
                    Button { model.startVoice() } label: {
                        Image(systemName: "waveform")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                            .frame(width: 30, height: 30)
                            .background(Color.primary, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(tap.connection != .ready)
                    .help("語音模式")
                    .accessibilityLabel("語音模式")
                    .accessibilityIdentifier("chatgpt.voice.start")
                } else {
                    ChatGPTSendButton(enabled: model.canSend) { model.send() }
                }
            }
          }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .liquidGlassPanelSurface(cornerRadius: LiquidGlassTokens.radiusPrimary)
            .frame(maxWidth: 760)
            Text("走你的 ChatGPT 訂閱（Chat），不耗 Codex 額度 · 記憶與自訂指令由 ChatGPT 帶過來")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private func toolButton(_ tool: TapTool) -> some View {
        Button { model.choose(tool) } label: {
            if tool.id == model.selectedTool?.id {
                Label {
                    Text(tool.title)
                    if !tool.detail.isEmpty { Text(tool.detail) }
                } icon: {
                    Image(systemName: "checkmark")
                }
            } else {
                Text(tool.title)
                if !tool.detail.isEmpty { Text(tool.detail) }
            }
        }
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

    /// 附件列的高度：有圖片＝縮圖高，只有檔案＝檔案卡高，只有工具小卡＝小卡高（上面多留 8pt 給右上角的 ×）。
    private var attachmentRowHeight: CGFloat {
        if model.attachments.contains(where: { $0.mime.lowercased().hasPrefix("image/") }) { return ChatGPTAttachmentTile.imageSize + 8 }
        if !model.attachments.isEmpty { return ChatGPTAttachmentTile.fileHeight + 8 }
        return 30 + 8
    }

    /// 照 ChatGPT 網頁版輸入框裡的膠囊（09-25 從網頁 CSS 對過）：平常只有字——一般檔位灰字（High）、帶版本時
    /// 版本黑字＋檔位灰字（6 Pro，最高檔紫色）；滑過淡灰底；打開時灰底膠囊、字換成「思考強度」。面板見 ChatGPTEffortCard。
    private var modelPicker: some View {
        let label = model.pickerLabel
        return Button { withAnimation(ChatGPTEffortCard.motion) { showsModelPopover.toggle() } } label: {
            HStack(spacing: 0) {
                if showsModelPopover {
                    Text("思考強度").foregroundStyle(ChatGPTPalette.tertiary)
                } else if let version = label.version {
                    Text(version).foregroundStyle(ChatGPTPalette.primary)
                    Text(" " + label.level).foregroundStyle(label.isMax ? ChatGPTPalette.purple : ChatGPTPalette.tertiary)
                } else {
                    Text(label.level).foregroundStyle(label.isMax ? ChatGPTPalette.purple : ChatGPTPalette.tertiary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ChatGPTPalette.tertiary)
                    .padding(.leading, 5)
                    .accessibilityHidden(true)
            }
            .font(.system(size: 15))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(showsModelPopover ? ChatGPTPalette.pressed : (pickerHover ? ChatGPTPalette.hover : Color.clear), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { pickerHover = $0 }
        .anchorPreference(key: ChatGPTPickerAnchorKey.self, value: .bounds) { $0 }
        .help("思考強度與模型")
        .accessibilityLabel("思考強度：\(label.version.map { $0 + " " } ?? "")\(label.level)")
        .accessibilityIdentifier("chatgpt.modelPicker")
    }

    /// 面板浮在膠囊正上方、置中對齊（網頁：寬 260，對齊膠囊中心，離膠囊 6pt）；點面板外面或按 Esc 就關。
    @ViewBuilder
    private func effortCard(_ anchor: Anchor<CGRect>?) -> some View {
        GeometryReader { proxy in
            if showsModelPopover, model.page == nil, let anchor {
                let rect = proxy[anchor]
                let width = ChatGPTEffortCard.width
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(ChatGPTEffortCard.motion) { showsModelPopover = false } }
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        ChatGPTEffortCard(model: model) { withAnimation(ChatGPTEffortCard.motion) { showsModelPopover = false } }
                    }
                    .frame(width: width, height: max(0, rect.minY - 6))
                    .offset(x: min(max(8, rect.midX - width / 2), max(8, proxy.size.width - width - 8)))
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
            }
        }
    }

    /// 面板開著時 Esc 只關面板（不讓它落到主視窗、把視窗關掉）。
    private func watchEscape(_ open: Bool) {
        if open, escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // 只攔主視窗、上面沒有表單或存檔視窗時的 Esc（審查 #14）。
                guard event.keyCode == 53, let window = event.window, window.isMainWindow, window.attachedSheet == nil else { return event }
                withAnimation(ChatGPTEffortCard.motion) { showsModelPopover = false }
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

    final class Coordinator {
        let pod: TapWebPod
        init(pod: TapWebPod) { self.pod = pod }
    }

    func makeCoordinator() -> Coordinator { Coordinator(pod: pod) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityElement(false)
        pod.claim(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.pod.release(nsView)
    }
}
