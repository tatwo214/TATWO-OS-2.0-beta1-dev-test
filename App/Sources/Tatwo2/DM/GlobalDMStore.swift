import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// 私訊框的對象。Coder 對話收本機討論串；W179 F：副設備連得到主設備時也收主設備上的（一樣用討論串 id）。
enum GlobalDMTarget: Hashable, Sendable {
    case assistant
    case thread(UUID)
    case chatGPT

    var storageValue: String {
        switch self {
        case .assistant: "assistant"
        case .chatGPT: "chatgpt"
        case .thread(let id): "thread:" + id.uuidString
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "assistant": self = .assistant
        case "chatgpt": self = .chatGPT
        default:
            guard storageValue.hasPrefix("thread:"),
                  let id = UUID(uuidString: String(storageValue.dropFirst("thread:".count))) else { return nil }
            self = .thread(id)
        }
    }
}

/// 對象清單裡的一條 session：「專案 › 標題」；別台上的前面標設備名，同名的後面補相對時間。
struct GlobalDMSessionCandidate: Identifiable, Equatable, Sendable {
    let id: UUID
    let projectName: String
    let title: String
    let activity: Date
    /// W179 F／W180 D2：別台（主設備或其他配對設備）上的對話標設備名；本機的是 nil。
    var deviceName: String? = nil
    /// W179 F：同一份清單裡有同名的，補相對時間（例「3 小時前」）好分辨。
    var disambiguator: String? = nil
    /// W180 D2：子討論串的父 session（清單裡掛在它下面）；最上層的是 nil。
    var parentID: UUID? = nil
    var parentTitle: String? = nil
    /// W182 R4：那台連不上，這條是離線副本裡的（灰、只能看；選到時可以「在這台接著聊」）。
    var isOffline = false
    /// 「專案 › 標題」；子討論串是「專案 › 父 session › 標題」。
    var label: String { parentTitle.map { "\(projectName) › \($0) › \(title)" } ?? "\(projectName) › \(title)" }
    private var baseLabel: String { deviceName.map { "\($0) · \(label)" } ?? label }
    /// W180 D2：子討論串在清單裡掛在父 session 下面時只寫自己的標題（同名的補時間）。
    var shortLabel: String { disambiguator.map { "\(title) · \($0)" } ?? title }
    /// 畫面上顯示的名字：「設備 · 專案 › 標題 · 3 小時前」。
    var displayLabel: String { disambiguator.map { "\(baseLabel) · \($0)" } ?? baseLabel }
    var isRemote: Bool { deviceName != nil }

    /// 同名（含設備名）的幾條各自補上時間；其他照舊。相對時間（「3 小時前」）分得開就用它，同一組裡有撞到的
    /// 整組改用日期時間（「9/25 14:03」），同一分鐘的再補序號，保證每一列的名字都不一樣。
    static func disambiguated(_ rows: [GlobalDMSessionCandidate], now: Date) -> [GlobalDMSessionCandidate] {
        var result = rows
        for indices in Dictionary(grouping: rows.indices, by: { rows[$0].baseLabel }).values where indices.count > 1 {
            var tags = indices.map { relativeTime(rows[$0].activity, now: now) }
            if Set(tags).count < tags.count { tags = indices.map { absoluteTime(rows[$0].activity) } }
            let repeats = Dictionary(tags.map { ($0, 1) }, uniquingKeysWith: +)
            var seen: [String: Int] = [:]
            for (offset, index) in indices.enumerated() {
                let tag = tags[offset]
                seen[tag, default: 0] += 1
                result[index].disambiguator = repeats[tag, default: 0] > 1 ? "\(tag) #\(seen[tag, default: 1])" : tag
            }
        }
        return result
    }

    static func absoluteTime(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: date)
        return String(format: "%d/%d %02d:%02d", parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }

    /// W180 A3：圖示上的專案縮寫：英文取前兩個字的字首（只有一個字就取前兩個字母），中文等取第一個字；沒有名字是「C」。
    static func abbreviation(_ projectName: String) -> String {
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = name.first else { return "C" }
        func plain(_ character: Character) -> Bool { character.isASCII && (character.isLetter || character.isNumber) }
        guard plain(first) else { return String(first) }
        let words = name.split { !plain($0) }
        if words.count >= 2 { return words.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }.joined() }
        let letters = name.filter(plain)
        return String(letters.prefix(1)).uppercased() + String(letters.dropFirst().prefix(1))
    }

    static func relativeTime(_ date: Date, now: Date) -> String {
        if abs(now.timeIntervalSince(date)) < 60 { return "剛剛" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// W180 D2：私訊框看得到的一台配對設備。連得到時帶遠端引擎；連不上或還在連時只有名字與狀態。
struct GlobalDMRemoteDevice {
    let device: AssistantPrimaryDevice
    let engine: (any AssistantRemoteEngine)?
    let connecting: Bool
    let isPrimary: Bool

    /// 畫面上的說法：主設備「名字」／「名字」。
    var place: String { isPrimary ? "主設備「\(device.displayName)」" : "「\(device.displayName)」" }
}

/// W180 D2：對象清單的一列 session；depth＞0 是子討論串（掛在上一層下面）。
struct GlobalDMSessionRow: Identifiable, Equatable {
    let session: GlobalDMSessionCandidate
    let depth: Int
    var id: UUID { session.id }
}

enum GlobalDMSessionTree {
    /// 最上層照給的順序；每條底下掛它的子討論串（依活動、新的在前，最多三層）。父 session 也在清單裡的子討論串
    /// 不單獨列，等父 session 那一列再掛；父 session 不在清單裡的（例如搜尋只搜到子討論串）照原位置單獨一列。
    static func rows(_ roots: [GlobalDMSessionCandidate], all: [GlobalDMSessionCandidate]) -> [GlobalDMSessionRow] {
        let children = Dictionary(grouping: all.filter { $0.parentID != nil }, by: { $0.parentID ?? $0.id })
        let rootIDs = Set(roots.map(\.id))
        var result: [GlobalDMSessionRow] = []
        var added = Set<UUID>()
        func add(_ session: GlobalDMSessionCandidate, depth: Int) {
            guard added.insert(session.id).inserted else { return }
            result.append(GlobalDMSessionRow(session: session, depth: depth))
            guard depth < 3 else { return }
            for child in children[session.id] ?? [] { add(child, depth: depth + 1) }
        }
        for root in roots {
            if let parent = root.parentID, rootIDs.contains(parent) { continue }
            add(root, depth: 0)
        }
        return result
    }
}

/// W180 A3：框頂圖示列的一顆（順序見 `GlobalDMStore.iconItems`）。
struct GlobalDMIconItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case assistant, chatGPT, coder, session(UUID), later, directKeys
        /// W183 R8b：第三顆圓鈕 Browser（手機式瀏覽器；授權頁都開在這裡）。
        case browser
    }
    /// 頭像色（畫面照 GlobalDMPalette 上色）。W182 R4：offline＝連不上那台的對話（灰，點得到、只能看）。W183 R8b：browser。
    enum Tint: Equatable { case assistant, chatGPT, session, later, offline, browser }

    let kind: Kind
    let letter: String
    /// 無障礙名稱與對象全名。
    let title: String
    /// 滑過時的說明（含直達鍵）。
    var help: String
    var tint: Tint
    /// 別台上的對話：那台的名字（圖示右下角的小設備標記）。
    var device: String? = nil
    /// 「之後」與關掉的 ChatGPT 是灰色、不能點。
    var isEnabled = true

    var id: String {
        switch kind {
        case .assistant: "assistant"
        case .chatGPT: "chatgpt"
        case .coder: "coder"
        case .session(let id): "thread:" + id.uuidString
        case .later: "later:" + letter
        case .directKeys: "keys"
        case .browser: "browser"   // W183 R8b
        }
    }
}

/// W180 D2：私訊框的一個附件。本機對象記檔案路徑（送出時交給引擎，同 Coder 輸入框）；ChatGPT 的只放記憶體（OS 不記錄）。
struct GlobalDMAttachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let mime: String
    let fileURL: URL?
    let data: Data?

    var isImage: Bool { mime.lowercased().hasPrefix("image/") }
}

/// 全域私訊框的狀態：開關、對象、各對象草稿、最近的 session。
/// 對話內容只在記憶體（ChatGPT 那條也是）；UserDefaults 只記總開關與上次的對象 id。
@MainActor
final class GlobalDMStore: ObservableObject {
    static let shared: GlobalDMStore = {
        let store = GlobalDMStore(refreshChatGPTToolCatalog: {
            ChatGPTSpaceModel.shared.refreshToolCatalog()
        })
        // W181：圖示列只有助理與 ChatGPT 時，上次停在某條 session 會變成沒有圖示可點；開 App 時改回助理。
        if !showsOtherTargets, case .thread = store.target { store.select(.assistant) }
        return store
    }()
    static let enabledKey = "tatwo2.globalDM.enabled"
    static let lastTargetKey = "tatwo2.globalDM.lastTarget"
    static let recentLimit = 5
    /// W180 A3：圖示列放幾條最近的 session。
    static let iconSessionLimit = 3

    /// 主視窗子面板裡的框。
    @Published var isOpen = false { didSet { if isOpen != oldValue { presenceChanged() } } }
    /// 其他 App 在前景或主視窗看不到時，螢幕右下角那個獨立浮動框。
    @Published var isFloatingOpen = false { didSet { if isFloatingOpen != oldValue { presenceChanged() } } }
    /// 主視窗子面板現在真的在畫面上（控制器掛上／拿下時回寫）；主視窗縮到 Dock、隱藏或關掉時是 false，
    /// 框的開關狀態（isOpen）照留，回來時原樣出現。
    @Published var isDockedVisible = false { didSet { if isDockedVisible != oldValue { refreshChatGPTLease() } } }
    /// W183 R8b（使用者 09-28 晚：「私訊鈕授權在上方tatwoos跟chatgpt圓鈕新增一欄bowser」）：框裡現在是 Browser（第三顆圓鈕；
    /// 手機式瀏覽器，授權頁都開在這裡，分頁在 DMBrowser）。對象（target）不變：回到對話＝原本的對象。只在記憶體。
    @Published var isBrowsing = false {
        didSet { if isBrowsing != oldValue { refreshChatGPTLease() } }   // W184 G3：單欄換成 Browser＝ChatGPT 那一欄不在畫面上（語音要停）
    }
    /// W184 G3：倒放（整塊是影片子畫面，對話欄不在畫面上）；桌面控制器照形態回寫。
    var hidesColumns = false {
        didSet { if hidesColumns != oldValue { refreshChatGPTLease() } }
    }
    /// W184 G3 第三輪（修正核對 #3）：［連線］的 sheet 蓋在這個框上（遮罩吃掉點擊、語音畫面的停止鈕被蓋住）＝ChatGPT 那一欄不在畫面上，
    /// 語音要停。［連線］的呈現器出來／收起時回寫。
    var coveredBySheet = false {
        didSet { if coveredBySheet != oldValue { refreshChatGPTLease() } }
    }
    /// W184 AB：內橫兩欄（桌面控制器回寫）：Browser 開到右欄（isBrowsingBeside），左欄照常是對話（isBrowsing 不動：送出、Esc 照對話）。
    var browsesBeside = false
    /// W184 AB：內橫的右欄現在是 Browser（按了 Browser 圓鈕、或 DMBrowser 開了授權頁、配對頁）；選了對話對象就回到另一個對象。只在記憶體。
    @Published var isBrowsingBeside = false
    /// 送出被擋下或有話要說時，框裡的一行提示（例如斜線指令要到 Coder 用）；換對象、送出成功或關框就清掉。
    @Published private(set) var notice: String?
    /// W184 H4 修正第三輪：送出去（草稿已經清了）、引擎後來說沒送到的那一句，而那時輸入框已經有新的字（不蓋掉）：
    /// 框裡一行「上一句沒送到：…」＋「放回輸入框」（restoreUndelivered）。
    struct Undelivered: Equatable {
        let target: GlobalDMTarget
        let text: String
        let files: [GlobalDMAttachment]
    }
    @Published private(set) var undelivered: Undelivered?
    /// ChatGPT 的未送草稿獨立保存，不與本機引擎的單筆 undelivered 共用；不落盤。
    struct ChatGPTReturnedDraft: Identifiable {
        let id: String
        let origin: GlobalDMChatGPTOrigin
        let temporary: Bool
        let draft: GlobalDMChatGPTDraft
    }
    @Published private(set) var chatGPTReturnedDrafts: [ChatGPTReturnedDraft] = []
    @Published private(set) var target: GlobalDMTarget
    @Published private(set) var drafts: [GlobalDMTarget: String] = [:]
    @Published var isPickerOpen = false {
        didSet {
            if !isPickerOpen { isBrowsingAllSessions = false; sessionQuery = "" }
            if isPickerOpen { isModeCardOpen = false }   // W184 AB（H4 查核 #9）：開 session 清單＝模式卡收起
        }
    }
    /// W184 AB（H4 查核 #9：模式卡開著按 Esc 會把整個私訊框收掉——routeEscape 看不到卡）：輸入框「模式選擇」chip 開的模式卡開著沒有，
    /// 跟 GlobalDMComposer 的 modeOpen 兩邊同步。Esc 先收它（框照舊開著）；換對象、開 session 清單、收框都收。只在記憶體。
    @Published var isModeCardOpen = false
    @Published var isBrowsingAllSessions = false
    @Published var sessionQuery = ""
    /// 總開關（預設開）；設定頁之後由 E 房接。
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { isOpen = false; isFloatingOpen = false }
            refreshChatGPTLease()
        }
    }
    /// 只拿來讀本機討論串與送出；不寫 Coder 的選取或草稿。
    @Published private(set) var model: ChatPageModel?
    /// W179 E：直達鍵（對象 → ⌥⌘＋鍵）；預設只有 ⌥⌘G＝ChatGPT。存取在 `GlobalDMDirectKeyBook`，改了才寫。
    @Published private(set) var directKeys: [GlobalDMTarget: GlobalDMDirectKey]
    /// W179 E：框內「設定直達鍵…」那一頁開著。
    @Published var isEditingDirectKeys = false
    /// iPhone 打開的右半邊（第二個 store）不管直達鍵。
    let hasDirectKeys: Bool

    private let defaults: UserDefaults
    private let makeChatGPT: @MainActor () -> ChatGPTConversationSession
    private let chatGPTAllowed: @MainActor () -> Bool
    private var chatGPTSession: ChatGPTConversationSession?
    private var chatGPTLeased = false
    private var modelWatch: AnyCancellable?
    /// W179 F：每條 session 最後一次看到的樣子（名字、專案、設備；只在記憶體）；那台暫時連不上時框頂與圖示照舊顯示。
    private var knownSessions: [UUID: GlobalDMSessionCandidate] = [:]
    /// W180 D2：各對象的附件（只在記憶體；送到了才清）。
    @Published private(set) var attachmentsByTarget: [GlobalDMTarget: [GlobalDMAttachment]] = [:]
    /// W180 A4：私訊框對 ChatGPT 選的模型／思考強度（只在記憶體；不動 ChatGPT Space 的選擇）。
    @Published private(set) var chatGPTChoice = ChatGPTModelChoice()
    /// W180 A4：ChatGPT 的模型清單與預設（同一份資料，第一次用到 ChatGPT 對象才接上）。
    @Published private(set) var chatGPTCatalog = ChatGPTModelCatalog()
    private let chatGPTCatalogSource: @MainActor () -> AnyPublisher<ChatGPTModelCatalog, Never>
    /// 正式單例接共用目錄；普通 init 預設不做事，隔離測試不能因開選單碰到 shared Pod。
    let refreshChatGPTToolCatalog: @MainActor () -> Void
    private var chatGPTCatalogWatch: AnyCancellable?
    /// W184 G3（查證 #6、#14）：「最近用過的 App」跟 ChatGPT Space 同一份（UserDefaults.standard；內橫右欄也一樣）；自測換成私有的。
    private let recentAppsDefaults: UserDefaults
    /// W184 G3：ChatGPT 對象「＋」選的工具或 App（輸入框裡一張小卡，點 × 拿掉；送出時帶上、送到了才清）。只在記憶體。
    @Published var chatGPTTool: TapTool?
    /// W184 G3：ChatGPT 的思考強度面板開著（Esc、換對象、收框都會關）。
    @Published var isChatGPTModelCardOpen = false
    /// W184 G3b（使用者 09-29 17:35：「chatgpt沒有新對話、專案、過去對話、/指令」「＋號也跟chatgpt原版的快捷小視窗不一樣」）：
    /// ChatGPT 對象的快捷小視窗（＋、App）、「＋」換到「更多」那一頁、對話抽屜、「/」指令鍵盤指著的那一列、Esc 收起「/」時的草稿。
    /// Esc 先收這些（dismissChatGPTLayers）；換對象、收框都收。只在記憶體。
    @Published var isChatGPTPlusOpen = false
    @Published var chatGPTPlusShowingMore = false
    @Published var isChatGPTDrawerOpen = false
    /// 抽屜是釘住打開的（鍵盤 ⌘⇧S、VoiceOver；點外面、Esc 才收）；滑鼠指到左緣打開的＝滑鼠離開抽屜就收。
    @Published var chatGPTDrawerPinned = false
    /// W184 G3c（GPT-6 審查 #2）：抽屜是用鍵盤打開的（⌘⇧S）：抽屜把鍵盤焦點拿進去（搜尋欄）；收起時還給輸入框。
    @Published var chatGPTDrawerKeyboard = false
    @Published var chatGPTSlashIndex = 0
    @Published var chatGPTSlashDismissed: String?
    /// W184 G3b：換到別則（抽屜點的、✎ 新對話）時各則自己的草稿（字、附件、工具小卡；新對話的鍵是 ""）。只在記憶體。
    var chatGPTShelf: [String: GlobalDMChatGPTDraft] = [:]
    /// W184 G3b 第二輪（審查 #1）：換過幾次對話（附件開始收時記下來，晚到的才分得出該放哪一則）。
    var chatGPTDraftGeneration = 0

    /// `chatGPTAllowed`：目前 Space 有沒有開 ChatGPT 分頁（關掉時 W177 會把 Pod 收起來，私訊框不去叫醒它）。
    /// `chatGPTCatalog`：ChatGPT 的模型清單（W180：跟 ChatGPT Space 同一份；自測換成固定資料）。
    init(defaults: UserDefaults = .standard,
         chatGPT: @escaping @MainActor () -> ChatGPTConversationSession = { ChatGPTConversationSession() },
         chatGPTAllowed: @escaping @MainActor () -> Bool = { SpaceWorkspaceController.shared.allows(.chatgpt) },
         chatGPTCatalog: @escaping @MainActor () -> AnyPublisher<ChatGPTModelCatalog, Never> = {
             ChatGPTSpaceModel.shared.modelCatalogPublisher
         },
         refreshChatGPTToolCatalog: @escaping @MainActor () -> Void = {},
         directKeys: Bool = true,
         recentApps: UserDefaults = .standard) {
        self.defaults = defaults
        self.recentAppsDefaults = recentApps
        self.makeChatGPT = chatGPT
        self.chatGPTAllowed = chatGPTAllowed
        self.chatGPTCatalogSource = chatGPTCatalog
        self.refreshChatGPTToolCatalog = refreshChatGPTToolCatalog
        self.hasDirectKeys = directKeys
        self.directKeys = directKeys ? GlobalDMDirectKeyBook.load(from: defaults) : [:]
        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        self.target = defaults.string(forKey: Self.lastTargetKey).flatMap(GlobalDMTarget.init(storageValue:)) ?? .assistant
    }

    var isPresented: Bool { isOpen || isFloatingOpen }
    /// 框真的看得到：浮動框開著，或主視窗裡的框開著且子面板在畫面上。
    var isShowingBox: Bool { isFloatingOpen || (isOpen && isDockedVisible) }
    /// 目前 Space 的 ChatGPT 分頁開著，ChatGPT 對象才能用。
    var chatGPTAvailable: Bool { chatGPTAllowed() }

    /// 常駐的 ChatGPT 對話（私訊框自己的對話 id）；第一次用到才建立。
    var chatGPT: ChatGPTConversationSession {
        if let chatGPTSession { return chatGPTSession }
        let created = makeChatGPT()
        // W184 G3 第三輪：排在語音後面太久、沒送出的那一則放回這個框的輸入框。
        chatGPTSession = created
        return created
    }

    var chatGPTNeedsLogin: Bool { chatGPT.state == .needsLogin }

    func attach(_ model: ChatPageModel) {
        guard self.model !== model else { return }
        self.model = model
        // Space 設定（ChatGPT 分頁開關）變動時跟著 model 發佈；框開著時重新判斷要不要拿 ChatGPT 使用中租約。
        modelWatch = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshChatGPTLease() }
    }

    // MARK: - 對象與草稿

    func select(_ newTarget: GlobalDMTarget) {
        isPickerOpen = false
        isEditingDirectKeys = false
        isBrowsing = false   // W183 R8b：選了對話對象＝離開 Browser（分頁留著）
        isBrowsingBeside = false   // W184 AB：內橫的右欄回到另一個對象（還有分頁時照樣是 Browser）
        isChatGPTModelCardOpen = false   // W184 G3：ChatGPT 的思考強度面板
        closeChatGPTPopovers()   // W184 G3b：快捷小視窗、對話抽屜
        isModeCardOpen = false   // W184 AB（H4 查核 #9）：換對象＝模式卡收起
        guard newTarget != target else { return }
        notice = nil
        target = newTarget
        defaults.set(newTarget.storageValue, forKey: Self.lastTargetKey)
        refreshChatGPTLease()
    }

    func draft(for target: GlobalDMTarget) -> String { drafts[target] ?? "" }

    /// W184 H4 修正第三輪（同 Coder）：沒送到的那一句——那個對象的輸入框還空著就放回（字與附件）、說一聲；已經打了新的一句就不蓋掉，
    /// 改成一行「上一句沒送到：…」＋「放回輸入框」。
    func putBackUndelivered(target: GlobalDMTarget, text: String, files: [GlobalDMAttachment], message: String) {
        let empty = draft(for: target).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments(for: target).isEmpty
        if empty {
            setDraft(text, for: target)
            attachmentsByTarget[target] = files.isEmpty ? nil : files
            if undelivered?.target == target { undelivered = nil }
            if self.target == target { notice = message }
        } else {
            undelivered = Undelivered(target: target, text: text, files: files)
        }
    }

    /// 那一行（只在那個對象開著時）：「上一句沒送到：前 20 個字…」。
    var undeliveredNotice: String? {
        guard let undelivered, undelivered.target == target else { return nil }
        // 提示列的規則是一句話（句號只在最後）：預覽裡的句號、驚嘆號、問號換成空白。
        var preview = ChatPageModel.undeliveredPreview(undelivered.text)
        for mark in ["。", "！", "？", "!", "?"] { preview = preview.replacingOccurrences(of: mark, with: " ") }
        return "上一句沒送到：" + preview
    }

    /// 「放回輸入框」：把沒送到的那一句接在現在的草稿前面（附件排在前面），不送出。
    func restoreUndelivered() {
        guard let undelivered, undelivered.target == target else { return }
        let current = draft(for: target)
        setDraft(current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? undelivered.text : undelivered.text + "\n" + current,
                 for: target)
        let existing = attachments(for: target)
        let merged = undelivered.files.filter { file in !existing.contains { $0.id == file.id } } + existing
        attachmentsByTarget[target] = merged.isEmpty ? nil : merged
        self.undelivered = nil
    }

    func setDraft(_ text: String, for target: GlobalDMTarget) {
        if text.isEmpty { drafts[target] = nil } else { drafts[target] = text }
        // W184 G3b 第二輪（主導看 PNG：「/」清單沒畫出來）：Esc 收起「/」之後草稿改了＝那次收起作廢（改回「/」也會再出來）。
        if target == .chatGPT, let dismissed = chatGPTSlashDismissed, dismissed != text { chatGPTSlashDismissed = nil }
    }

    /// 上次的對象被封存或刪掉時退回助理。W179 F／W180 D2：別台上的對話在那台還在連、或暫時連不上時
    /// 先留著（App 剛開、剛睡醒都會這樣），等讀得到那台的清單、確定沒有這條才退回。
    func validateTarget() {
        guard case .thread(let id) = target, let model else { return }
        if !model.dmSessionCandidates().contains(where: { $0.id == id }), !model.dmSessionAwaitingRemote(id) {
            select(.assistant)
        }
    }

    /// 最近的 session（最上層的幾條；子討論串在清單裡掛在它們下面）。
    func recentSessions() -> [GlobalDMSessionCandidate] {
        Array((model?.dmSessionCandidates() ?? []).filter { $0.parentID == nil }.prefix(Self.recentLimit))
    }

    func searchSessions(_ query: String) -> [GlobalDMSessionCandidate] {
        searchSessions(query, in: model?.dmSessionCandidates() ?? [])
    }

    private func searchSessions(_ query: String, in all: [GlobalDMSessionCandidate]) -> [GlobalDMSessionCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.displayLabel.localizedCaseInsensitiveContains(trimmed) }
    }

    /// W180 D2：對象清單的 session 列：最近幾條（everything＝全部；有搜尋字時是搜尋結果），子討論串掛在父 session 下面。
    func sessionRows(query: String = "", everything: Bool = false) -> [GlobalDMSessionRow] {
        let all = model?.dmSessionCandidates() ?? []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let top = all.filter { $0.parentID == nil }
        let roots = !trimmed.isEmpty ? searchSessions(trimmed, in: all)
            : everything ? top : Array(top.prefix(Self.recentLimit))
        return GlobalDMSessionTree.rows(roots, all: all)
    }

    /// W180 D2：連不上的配對設備各一行說明（那台的對話暫時不列）。

    // MARK: - 圖示列（W180 A3）

    /// 圖示列的最近 session：最上層依活動的前幾條；目前的對象是 session 而不在裡面時換掉最後一條（連不上的那台上的也留著：
    /// 沿用最後一次看到的專案與設備名；沒看過就只標它可能在的那台，專案字母是「?」，不跟 Coder 的 C 撞在一起）。
    func iconSessions(_ all: [GlobalDMSessionCandidate]) -> [GlobalDMSessionCandidate] {
        for session in all { knownSessions[session.id] = session }
        var picked = Array(all.filter { $0.parentID == nil }.prefix(Self.iconSessionLimit))
        if case .thread(let id) = target, !picked.contains(where: { $0.id == id }) {
            let current = all.first { $0.id == id } ?? knownSessions[id]
                ?? GlobalDMSessionCandidate(id: id, projectName: "", title: title(for: target), activity: .distantPast,
                                            deviceName: model?.dmSessionAwaitedDeviceName(id))
            if picked.count >= Self.iconSessionLimit { picked.removeLast() }
            picked.append(current)
        }
        return picked
    }

    /// W181（使用者 09-27：「其他圓鈕先移除 我們優先把這兩個做好」）：圖示列先只放 TATWO 助理與 ChatGPT。
    /// 其他對象（Coder、最近的 session、之後、直達鍵）的程式留著，打開這個開關就回來。
    static let showsOtherTargets = false

    /// 圖示列，依序：TATWO 助理、ChatGPT、Coder（選 session）、最近的 session、之後（Bot 團隊、LINE）、設定直達鍵。
    func iconItems(showingOthers: Bool = GlobalDMStore.showsOtherTargets) -> [GlobalDMIconItem] {
        let all = model?.dmSessionCandidates() ?? []
        var items = [GlobalDMIconItem(kind: .assistant, letter: "T", title: "TATWO 助理",
                                      help: keyed("TATWO 助理", .assistant, fallback: "⌥⌘"), tint: .assistant)]
        if chatGPTAvailable {
            items.append(GlobalDMIconItem(kind: .chatGPT, letter: "G", title: "ChatGPT", help: keyed("ChatGPT", .chatGPT),
                                          tint: .chatGPT))
        } else {
            items.append(GlobalDMIconItem(kind: .chatGPT, letter: "G", title: "ChatGPT（Space 已關閉）",
                                          help: "目前 Space 把 ChatGPT 分頁關掉了，到設定打開才能選", tint: .chatGPT,
                                          isEnabled: false))
        }
        // W183 R8b：第三顆圓鈕 Browser（地球）；授權頁、ChatGPT 開發者設定與配對頁都開在它的分頁。
        items.append(GlobalDMIconItem(kind: .browser, letter: "B", title: "Browser",
                                      help: "Browser：Cloudflare 授權、ChatGPT 開發者設定與配對頁都開在這裡", tint: .browser))
        guard showingOthers else { return items }
        items.append(GlobalDMIconItem(kind: .coder, letter: "C", title: "Coder 對話",
                                      help: "Coder 對話：點開選一條（最近、其他專案、子討論串）", tint: .session))
        for session in iconSessions(all) {
            items.append(GlobalDMIconItem(kind: .session(session.id),
                                          letter: session.projectName.isEmpty ? "?"
                                              : GlobalDMSessionCandidate.abbreviation(session.projectName),
                                          title: session.projectName.isEmpty ? title(for: .thread(session.id)) : session.displayLabel,
                                          help: keyed(session.projectName.isEmpty ? title(for: .thread(session.id))
                                                          : session.displayLabel, .thread(session.id)),
                                          tint: .session, device: session.deviceName))
            if session.isOffline {   // W182 R4：連不上那台的對話照樣有圖示（灰），說明寫只能看
                items[items.count - 1].tint = .offline
                items[items.count - 1].help += "（離線，只能看）"
            }
        }
        items.append(GlobalDMIconItem(kind: .later, letter: "隊", title: "Bot 團隊（之後）",
                                      help: "Bot 團隊：之後才開放，現在不能選", tint: .later, isEnabled: false))
        items.append(GlobalDMIconItem(kind: .later, letter: "L", title: "LINE（之後）",
                                      help: "LINE：之後才開放，現在不能選", tint: .later, isEnabled: false))
        if hasDirectKeys {
            items.append(GlobalDMIconItem(kind: .directKeys, letter: "⌘", title: "設定直達鍵…",
                                          help: "設定直達鍵：在任何 App 按 ⌥⌘＋一個鍵直接切到那個對象", tint: .later))
        }
        return items
    }

    /// 說明後面補直達鍵（例「ChatGPT（⌥⌘G）」）；沒有設時助理照舊是 ⌥⌘。
    private func keyed(_ title: String, _ target: GlobalDMTarget, fallback: String? = nil) -> String {
        guard let key = directKeys[target]?.display ?? fallback else { return title }
        return "\(title)（\(key)）"
    }

    /// 這一顆是不是目前選著的（強調色外圈；同一時間只有一顆）：Coder 清單開著時是 C、直達鍵頁開著時是 ⌘，
    /// 其他時候是目前的對象。
    func isSelected(_ item: GlobalDMIconItem) -> Bool {
        switch item.kind {
        case .coder: return isPickerOpen
        case .directKeys: return isEditingDirectKeys
        default: return !isPickerOpen && !isEditingDirectKeys && isCurrentTarget(item)
        }
    }

    /// 這一顆是不是目前的對象（清單或直達鍵頁開著時只留玻璃圓的選中底、不畫外圈）。
    func isCurrentTarget(_ item: GlobalDMIconItem) -> Bool {
        if isBrowsing { return item.kind == .browser }   // W183 R8b：Browser 開著＝只有地球那顆是目前的
        switch item.kind {
        case .assistant: return target == .assistant
        case .chatGPT: return target == .chatGPT
        case .session(let id): return target == .thread(id)
        case .coder, .directKeys, .later, .browser: return false
        }
    }

    /// 點圖示：助理、ChatGPT、某條 session＝直接切過去；Coder＝在框內展開 session 選擇（再點收起）；⌘＝直達鍵頁。
    func activate(_ item: GlobalDMIconItem) {
        guard item.isEnabled else { return }
        switch item.kind {
        case .assistant: select(.assistant)
        case .chatGPT: select(.chatGPT)
        case .session(let id): select(.thread(id))
        case .coder:
            isEditingDirectKeys = false
            isPickerOpen.toggle()
            isBrowsing = false   // W183 R8b
        case .directKeys:
            isPickerOpen = false
            isEditingDirectKeys.toggle()
            isBrowsing = false   // W183 R8b
        case .browser:
            showBrowser()   // W183 R8b
        case .later:
            break
        }
    }

    /// W183 R8b：切到 Browser（第三顆圓鈕、或 DMBrowser 開了新分頁）；對象清單、直達鍵頁收起。
    func showBrowser() {
        isPickerOpen = false
        isEditingDirectKeys = false
        guard !browsesBeside else { isBrowsingBeside = true; return }   // W184 AB：內橫＝開到右欄，左欄的對話與提示不動
        notice = nil
        isBrowsing = true
    }

    func title(for target: GlobalDMTarget) -> String {
        switch target {
        case .assistant: return "TATWO 助理"
        case .chatGPT: return "ChatGPT"
        case .thread(let id):
            // W179 F：主設備暫時連不上時沿用最後一次看到的名字。
            if let session = model?.dmSessionCandidates().first(where: { $0.id == id }) {
                knownSessions[id] = session
                return session.displayLabel
            }
            return knownSessions[id]?.displayLabel ?? "Coder 對話"
        }
    }

    // MARK: - 直達鍵（W179 E）

    /// 先過擋鍵規則（系統已用的組合、別的對象用掉的鍵）；nil＝清掉。成功才寫。
    @discardableResult
    func setDirectKey(_ key: GlobalDMDirectKey?, for target: GlobalDMTarget) -> GlobalDMDirectKeyVerdict {
        guard hasDirectKeys else { return .unsupported }
        if let key {
            let verdict = GlobalDMDirectKeyRules.verdict(key, for: target, in: directKeys)
            guard verdict == .ok else { return verdict }
        }
        guard directKeys[target] != key else { return .ok }
        var next = directKeys
        next[target] = key
        directKeys = next
        GlobalDMDirectKeyBook.save(next, to: defaults)
        return .ok
    }

    // MARK: - 送出、停止、狀態

    var isRunning: Bool {
        switch target {
        case .assistant: return model?.assistantIsRunning ?? false
        case .thread(let id): return model?.dmSessionIsRunning(id) ?? false
        case .chatGPT: return chatGPT.isSending
        }
    }

    /// 對象在等核准（核准本身只在 Island）。
    var isAwaitingApproval: Bool {
        guard let engine = model?.localLiveForBridge else { return false }
        switch target {
        case .assistant: return model?.assistantThreadID.map { engine.pendingPermissionThreadIDs.contains($0) } ?? false
        case .thread(let id): return engine.pendingPermissionThreadIDs.contains(id)
        case .chatGPT: return false
        }
    }

    /// 送出鈕能不能按：有字或有附件。
    var hasContentToSend: Bool {
        !draft(for: target).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments(for: target).isEmpty
    }

    @discardableResult
    func send() -> Bool {
        guard !isBrowsing else { return false }   // W183 R5b 審查／R8b：Browser 開著時不送（Enter 是給網頁的）
        let eventSource = OSEventSources.begin(origin: "composer", actor: "你", surface: "dm"); defer { OSEventSources.send = eventSource }
        let target = self.target
        let text = draft(for: target)
        let files = attachments(for: target)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else { return false }
        notice = nil
        // W180 D2：附件帶不過去的對象（別台上的、接在主設備的助理）不假裝送出：說明一行、草稿與附件留著。
        if !files.isEmpty, let block = attachmentBlock(for: target) {
            notice = block
            return false
        }
        // 真的送到才清草稿與附件：本機的馬上清；W179 F：送到別台的等那台回覆收到才清，這段時間草稿被改過就不動，
        // 沒送到就留著（框裡有一行說明）。
        let delivered: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            if self.draft(for: target) == text { self.setDraft("", for: target) }
            if self.attachments(for: target).map(\.id) == files.map(\.id) { self.attachmentsByTarget[target] = nil }
            if case .thread = target, self.target == target, UserMemoryText.rememberRequest(in: text) != nil {
                self.notice = "已記成提案；到 設定 › OS › 文件 › 記憶提案 核准"
            }
        }
        // W184 H4 修正第三輪：已經清掉的那一句，引擎後來說沒送到／不確定：照 Coder 同一套放回（不自動重送）。
        let undeliveredBack: @MainActor (String) -> Void = { [weak self] message in
            self?.putBackUndelivered(target: target, text: text, files: files, message: message)
        }
        let paths = files.compactMap { $0.fileURL?.path }
        let accepted: Bool
        switch target {
        case .assistant:
            if let command = ChatPageModel.dmCoderOnlyCommand(in: text) {
                notice = "\(command) 要在 Coder 的輸入框用；TATWO 助理私訊目前不支援這個指令。"
                return false
            }
            accepted = model?.sendToAssistant(text: text, attachments: paths, onDelivered: delivered,
                                              onUndelivered: undeliveredBack) ?? false
        case .thread(let id):
            // Coder 輸入框自己處理的斜線指令（/goal、/plan、/pr…）不當一般訊息送給引擎；草稿留著好貼到 Coder。
            if let command = ChatPageModel.dmCoderOnlyCommand(in: text) {
                notice = "\(command) 要在 Coder 的輸入框用；私訊框只送一般訊息。"
                return false
            }
            accepted = model?.sendFromDM(threadID: id, text: text, attachments: paths, onDelivered: delivered,
                                         onUndelivered: undeliveredBack) ?? false
        case .chatGPT:
            guard chatGPTAvailable else { return false }
            let session = chatGPT
            guard !session.isSending else { return false }
            // W184 G3（GPT-6 審查 7）：語音模式開著不送文字（草稿留著）；session 與 TAP 另外也擋。
            if session.voice.voiceActive {
                notice = "語音模式開著；結束語音再送"
                return false
            }
            // W184 G3c（GPT-6 審查 #3）：抽屜蓋著輸入框時不送（被蓋住的輸入框收到的 Return 不算數；草稿留著）。
            if isChatGPTDrawerOpen { return false }
            // W180 A4：私訊框自己選的模型／思考強度（沒選就照 ChatGPT 的預設）；附件只在記憶體交給 TAP。
            let arguments = ChatGPTModelMenu.sendArguments(chatGPTCatalog, chatGPTChoice)
            // W184 G3：「＋」選的工具照 ChatGPT Space 的帶法交給 TAP；送到了才清小卡（同草稿）。
            let tool = chatGPTTool
            let origin = chatGPTOrigin
            let temporary = session.isTemporary
            let original = GlobalDMChatGPTDraft(text: text, files: files, tool: tool)
            // 每次送出捕捉完整工具與附件，不靠可能已變動的 catalog 重建，也不讀下一則草稿。
            session.returned = { [weak self] returned in
                self?.restoreChatGPTDraft(returned, original: original, origin: origin, temporary: temporary) ?? false
            }
            session.send(text, model: arguments.model, effort: arguments.effort,
                         attachments: files.compactMap { file in
                             file.data.map { TapAttachment(name: file.name, mime: file.mime, data: $0) }
                         }, tool: tool?.id)
            accepted = session.isSending
            if accepted {
                delivered()
                if chatGPTTool == tool { chatGPTTool = nil }
                isChatGPTModelCardOpen = false
            }
        }
        return accepted
    }

    // MARK: - 模型 chip（W180 A4：只改這個對象，不動 Coder 輸入框與其他對象）

    var modelChipTitle: String {
        switch target {
        case .assistant: return model?.assistantModelChipTitle ?? "模型"
        case .thread(let id): return model?.dmSessionModelChipTitle(id) ?? "模型"
        case .chatGPT: return ChatGPTModelMenu.chipTitle(chatGPTCatalog, chatGPTChoice)
        }
    }

    /// 回覆中不換模型；ChatGPT 分頁關著時不能選；別台上的對話那台連不上時不能選（選了也帶不過去）。
    var canChooseModel: Bool {
        guard let model, !isRunning else { return false }
        switch target {
        case .assistant: return true
        case .thread(let id): return model.dmSessionModelSelectable(id)
        case .chatGPT: return chatGPTAvailable
        }
    }

    /// 模型 chip 滑過的說明；不能選時寫為什麼。
    var modelChipHelp: String {
        if isRunning { return "回覆中不換模型" }
        switch target {
        case .assistant: return "助理的模型，不更動 Coder"
        case .thread(let id):
            return model?.dmSessionModelSelectable(id) == false ? "那台連上後才能換模型" : "這條對話的模型，只改這一條"
        case .chatGPT: return chatGPTAvailable ? "ChatGPT 的思考強度與模型，只改私訊框這邊" : "ChatGPT Space 已關閉"
        }
    }

    /// 助理與 Coder 對話的選單列（同 TATWO 助理的模型選單）。
    func modelOptions(for target: GlobalDMTarget) -> [AssistantModelOption] {
        switch target {
        case .assistant: return model?.assistantModelOptions ?? []
        case .thread(let id): return model?.dmSessionModelOptions(id) ?? []
        case .chatGPT: return []
        }
    }

    /// 選單第一行（不能點）：在哪一台跑。
    func modelHeadline(for target: GlobalDMTarget) -> String? {
        switch target {
        case .assistant: return model?.assistantPrimaryName.map { "在主設備「\($0)」上跑；沒選就照那邊的設定" }
        case .thread(let id): return model?.dmSessionModelHeadline(id)
        case .chatGPT: return nil
        }
    }

    func chooseModel(_ modelID: String, for target: GlobalDMTarget) {
        switch target {
        case .assistant: model?.setAssistantModel(modelID)
        case .thread(let id): model?.setDMSessionModel(id, modelID: modelID)
        case .chatGPT: break
        }
    }

    func chooseChatGPT(_ choice: ChatGPTModelChoice) {
        guard !chatGPT.isSending else { return }
        chatGPTChoice = choice
    }

    // MARK: - 附件（W180 D2）

    func attachments(for target: GlobalDMTarget) -> [GlobalDMAttachment] { attachmentsByTarget[target] ?? [] }

    /// 這個對象不能帶附件的原因（nil＝可以）：本機的助理、本機的 session、ChatGPT 可以；
    /// 別台上的對話與接在主設備的助理遠端送不了檔案。
    func attachmentBlock(for target: GlobalDMTarget) -> String? {
        guard let model else { return "私訊框還在準備" }
        switch target {
        case .assistant:
            if model.assistantAcceptsAttachments { return nil }
            return model.assistantPrimaryName != nil ? "主設備上的助理暫不支援附件" : "助理現在接不到，暫不能附加"
        case .thread(let id):
            return model.dmSessionAttachmentNote(id)
        case .chatGPT:
            return chatGPTAvailable ? nil : "ChatGPT Space 已關閉"
        }
    }

    /// 加檔案（選的、拖進來的、貼上的檔案）：ChatGPT 的讀進記憶體（同 ChatGPT Space：HEIC 等轉 JPEG、合計 20 MB）；
    /// 本機的記路徑（送出時交給引擎，同 Coder 輸入框）。不能帶附件的對象只說明、不加。
    func addAttachments(_ urls: [URL], origin: GlobalDMChatGPTOrigin? = nil) {
        let target = self.target
        if let block = attachmentBlock(for: target) {
            notice = block
            return
        }
        // W184 G3：ChatGPT 的檔案走 ChatGPT Space 同一套（讀進記憶體、ChatGPT 看不懂的圖片轉 JPEG、合計 20 MB），交給 chatGPTSink。
        if target == .chatGPT {
            let chatGPTSink = self.chatGPTSink(origin: origin)   // W184 G3b 第二輪（審查 #1）：放進開始收時那一則
            ChatGPTSpaceModel.attachFiles(urls, into: chatGPTSink)
            return
        }
        var list = attachments(for: target)
        for url in urls {
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            guard !list.contains(where: { $0.fileURL == url }) else { continue }
            list.append(GlobalDMAttachment(name: url.lastPathComponent, mime: mime, fileURL: url, data: nil))
        }
        attachmentsByTarget[target] = list.isEmpty ? nil : list
    }

    // MARK: W184 G3：ChatGPT 對象的附件＝ChatGPT Space 那一套（Finder 檔案、「照片」App 的檔案承諾、原始 PNG／JPEG／HEIC、拖進來的）

    /// 收到的照片與檔案一律放進 ChatGPT 對象（非同步收到時對象可能已經換了，也不會放錯地方）；只在記憶體。
    /// W184 G3b 第二輪（審查 #1）：開始收的時候是哪一則對話也記下來（origin，沒給＝現在這一則）：晚到的附件放回那一則，
    /// 不會掉進中途換過去的另一則（那一則的草稿收起來了＝放進它收起來的草稿；換回來時一起回來）。
    private var chatGPTSink: ChatGPTSpaceModel.AttachmentSink { chatGPTSink(origin: nil) }

    private func chatGPTSink(origin: GlobalDMChatGPTOrigin?) -> ChatGPTSpaceModel.AttachmentSink {
        let origin = origin ?? chatGPTOrigin
        return ChatGPTSpaceModel.AttachmentSink(add: { [weak self] data, name, mime in
                                                    self?.receiveChatGPTAttachment(data, name: name, mime: mime, origin: origin)
                                                },
                                                fail: { [weak self] message in self?.notice = message })
    }

    /// 現在這一則（對話代號、換過幾次對話）。
    var chatGPTOrigin: GlobalDMChatGPTOrigin {
        GlobalDMChatGPTOrigin(key: chatGPTSessionIfCreated?.conversationID ?? "", generation: chatGPTDraftGeneration)
    }

    /// 收下一個 ChatGPT 附件：開始收之後沒換過對話（新對話送出後拿到代號不算換）或又換回那一則＝放進輸入框；
    /// 中途換到別則＝放回開始那一則收起來的草稿（說一句）。
    func receiveChatGPTAttachment(_ data: Data, name: String, mime: String, origin: GlobalDMChatGPTOrigin) {
        guard attachmentBlock(for: .chatGPT) == nil else { return }
        let current = chatGPTOrigin
        let here = origin.generation == current.generation || origin.key == current.key
        var list = here ? attachments(for: .chatGPT) : (chatGPTShelf[origin.key]?.files ?? [])
        switch ChatGPTSpaceModel.admit(data, name: name, mime: mime, currentBytes: list.reduce(0) { $0 + ($1.data?.count ?? 0) }) {
        case .success(let file):
            list.append(GlobalDMAttachment(name: file.name, mime: file.mime, fileURL: nil, data: file.data))
            if here {
                attachmentsByTarget[.chatGPT] = list
            } else {
                var shelved = chatGPTShelf[origin.key] ?? GlobalDMChatGPTDraft(text: "", files: [], tool: nil)
                shelved.files = list
                chatGPTShelf[origin.key] = shelved
                notice = "「\(file.name)」收到時已經換了對話，放回原本那一則的草稿"
            }
        case .failure(let refusal):
            notice = refusal.message
        }
    }

    /// 拖到 ChatGPT 那一欄的對話區上（不在輸入框上）：同 ChatGPT Space 的對話區。
    @discardableResult
    func attachChatGPT(providers: [NSItemProvider]) -> Bool {
        guard target == .chatGPT else { return false }
        if let block = attachmentBlock(for: .chatGPT) {
            notice = block
            return false
        }
        return ChatGPTSpaceModel.attach(providers: providers, into: chatGPTSink)
    }

    /// 選了「＋」裡的工具或 App（nil＝拿掉小卡）；App 排進最近用過的（跟 ChatGPT Space 同一份，只有代號；內橫右欄也一樣）。
    func chooseChatGPTTool(_ tool: TapTool?) {
        chatGPTTool = tool
        if let tool { ChatGPTSpaceModel.rememberApp(tool, in: recentAppsDefaults) }
    }

    /// 最近用過的 App 代號（「＋」第二段的順序；跟 ChatGPT Space 同一份）。
    var chatGPTRecentApps: [String] { recentAppsDefaults.stringArray(forKey: ChatGPTSpaceModel.recentAppsKey) ?? [] }

    /// W184 G3b：已經建立的 ChatGPT 對話（沒建立＝nil；抽屜、新對話的判斷用，不為了問一下就建一個）。
    var chatGPTSessionIfCreated: ChatGPTConversationSession? { chatGPTSession }

    func restoreChatGPTFailure(_ failure: ChatGPTTurnFailure, session: ChatGPTConversationSession) {
        setDraft(session.recover(failure), for: .chatGPT)
        for file in failure.files where !attachments(for: .chatGPT).contains(where: { $0.name == file.name && $0.mime == file.mime && $0.data == file.data }) {
            receiveChatGPTAttachment(file.data, name: file.name, mime: file.mime, origin: chatGPTOrigin)
        }
    }

    /// W184 G3b：換對話時把那一則的附件放回來（或清空）。
    func replaceChatGPTAttachments(_ files: [GlobalDMAttachment]) {
        attachmentsByTarget[.chatGPT] = files.isEmpty ? nil : files
    }

    /// Esc：思考強度面板開著先關面板。有關掉才回 true。（語音在 endChatGPTVoiceForEscape，Browser 開著時也先停。）
    /// W184 G3b：先收「/」指令小視窗（草稿留著）、再收 ＋／App 的快捷小視窗、對話抽屜，最後才是思考強度面板；一次收一層。
    func dismissChatGPTLayers() -> Bool {
        if chatGPTSlashOpen {
            chatGPTSlashDismissed = draft(for: .chatGPT)
            return true
        }
        if isChatGPTPlusOpen { isChatGPTPlusOpen = false; chatGPTPlusShowingMore = false; return true }
        if isChatGPTDrawerOpen { isChatGPTDrawerOpen = false; chatGPTDrawerPinned = false; chatGPTDrawerKeyboard = false; return true }
        guard isChatGPTModelCardOpen else { return false }
        isChatGPTModelCardOpen = false
        return true
    }

    /// W184 G3：Esc 先停即時語音（Browser 開著也一樣）：開著就結束；結束中再按＝直接關掉語音那一頁。有做事才回 true。
    func endChatGPTVoiceForEscape() -> Bool {
        guard let session = chatGPTSession, session.voice.voiceActive else { return false }
        session.voice.stopVoice()
        return true
    }

    /// W184 G3（GPT-6 審查 1；查證 #2、#7）：ChatGPT 那一欄真的在畫面上——框看得到、對象是 ChatGPT、分頁開著、
    /// 單欄沒換成 Browser、不是倒放。即時語音只在這時開著；不是就結束（不只看租約）。
    var chatGPTColumnOnScreen: Bool {
        isEnabled && isShowingBox && target == .chatGPT && chatGPTAvailable && !isBrowsing && !hidesColumns && !coveredBySheet
    }

    private var chatGPTComposerIsEmpty: Bool {
        // 空白也是新草稿；新選的工具即使沒有文字也不可被還稿覆蓋。
        draft(for: .chatGPT).isEmpty && attachments(for: .chatGPT).isEmpty && chatGPTTool == nil
    }

    private func restoreChatGPTDraft(_ returned: ChatGPTConversationSession.ReturnedDraft,
                                     original: GlobalDMChatGPTDraft, origin: GlobalDMChatGPTOrigin,
                                     temporary: Bool) -> Bool {
        let reason: String
        if case .failed(let message) = chatGPTSessionIfCreated?.state { reason = message }
        else { reason = "這則沒有送出" }
        guard chatGPTOrigin == origin, chatGPTSessionIfCreated?.isTemporary == temporary, chatGPTComposerIsEmpty else {
            if !chatGPTReturnedDrafts.contains(where: { $0.id == returned.id }) {
                chatGPTReturnedDrafts.append(ChatGPTReturnedDraft(id: returned.id, origin: origin, temporary: temporary, draft: original))
            }
            notice = reason + "；未送內容已保留，可手動恢復"
            return false
        }
        applyChatGPTReturnedDraft(original)
        notice = reason + "；已放回輸入框"
        return true
    }

    private func applyChatGPTReturnedDraft(_ draft: GlobalDMChatGPTDraft) {
        setDraft(draft.text, for: .chatGPT)
        replaceChatGPTAttachments(draft.files)
        chatGPTTool = draft.tool
    }

    /// 只顯示目前這則可取回的第一筆，不會為了還稿偷偷切換對話或另一欄。
    var chatGPTReturnedDraft: ChatGPTReturnedDraft? {
        guard target == .chatGPT, let session = chatGPTSessionIfCreated else { return nil }
        return chatGPTReturnedDrafts.first {
            guard $0.origin.key == (session.conversationID ?? ""), $0.temporary == session.isTemporary else { return false }
            // 舊的「新對話」沒有網站代號；只允許回原來那則，或明確開的空白新對話。
            return !$0.origin.key.isEmpty || $0.origin.generation == chatGPTDraftGeneration || session.messages.isEmpty
        }
    }

    @discardableResult
    func restoreReturnedChatGPTDraft(_ id: String) -> Bool {
        guard let saved = chatGPTReturnedDraft, saved.id == id, let session = chatGPTSessionIfCreated,
              !session.isSending, !session.voice.voiceActive else { return false }
        guard chatGPTComposerIsEmpty else {
            notice = "請先移開目前草稿、附件與工具，再恢復未送內容"
            return false
        }
        applyChatGPTReturnedDraft(saved.draft)
        session.confirmReturnedDraft(saved.id)
        chatGPTReturnedDrafts.removeAll { $0.id == saved.id }
        notice = "未送內容已放回輸入框，尚未送出"
        return true
    }

    /// ⌘V 優先貼非空白文字；檔案網址、拖曳與「＋ › 貼上剪貼簿圖片」沿用附件路徑。
    /// 本機對象的圖片存成附件檔（同 Coder 輸入框貼圖）；ChatGPT 的圖片只放記憶體。
    /// W180 修正：帶不了附件的對象，⌘V 的剪貼簿同時有文字（Finder 拷貝的檔名、試算表或簡報帶圖片格式的內容）時照常貼文字，
    /// 不整個吃掉（有檔案時多一行說明檔案沒附上）；只有純圖片、純檔案，或拖進來的檔案才只說明、不貼。
    @discardableResult
    func pasteAttachment(from pasteboard: NSPasteboard) -> Bool {
        pasteAttachment(from: pasteboard, preferText: true)
    }

    @discardableResult
    func pasteAttachment(from pasteboard: NSPasteboard, preferText: Bool) -> Bool {
        let target = self.target
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if ComposerPastePolicy.prefersText(from: pasteboard, fileURLs: urls, preferText: preferText) { return false }
        if preferText, let block = attachmentBlock(for: target), pasteboard.name != .drag,
           pasteboard.string(forType: .string) != nil {
            if !urls.isEmpty { notice = block + "；只貼上文字" }
            return false
        }
        // W184 G3：ChatGPT 對象（收得了附件時）＝ChatGPT Space 那一套：「照片」App 的檔案承諾、原始 JPEG／HEIC 也收。
        if target == .chatGPT, attachmentBlock(for: target) == nil {
            return ChatGPTSpaceModel.attach(from: pasteboard, into: chatGPTSink)
        }
        if !urls.isEmpty {
            addAttachments(urls)
            return true
        }
        guard let png = pasteboard.data(forType: .png)
                ?? NSImage(pasteboard: pasteboard).flatMap({ ChatGPTSpaceModel.pngData($0) }) else { return false }
        if let block = attachmentBlock(for: target) {
            notice = block
            return true
        }
        let name = "剪貼簿.png"
        var list = attachments(for: target)
        guard let url = model?.dmSaveAttachment(data: png, suggestedName: name) else {
            notice = "圖片無法保存，請重試"
            return true
        }
        list.append(GlobalDMAttachment(name: name, mime: "image/png", fileURL: url, data: nil))
        attachmentsByTarget[target] = list
        return true
    }

    /// 框裡的一行提示（例如剪貼簿沒有圖片）；換對象、送出成功或關框就清掉。
    func showNotice(_ text: String) { notice = text }

    func removeAttachment(_ id: UUID) {
        let list = attachments(for: target).filter { $0.id != id }
        attachmentsByTarget[target] = list.isEmpty ? nil : list
    }

    /// 「＋ › 附加檔案…」：系統的選檔視窗（私訊框浮在別的 App 上時先把 TATWO 叫到前面，選檔視窗才看得到）。
    /// imagesOnly＝ChatGPT 的 ＋ 小卡「照片」：只列圖片、從「圖片」資料夾開始（W184 G3b）。
    func pickAttachments(imagesOnly: Bool = false) {
        let target = self.target
        if let block = attachmentBlock(for: target) {
            notice = block
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "附上"
        if imagesOnly {
            panel.allowedContentTypes = [.image]
            panel.directoryURL = URL.picturesDirectory
        }
        // W184 G3b 第二輪（審查 #1）：選檔視窗開著的時候可能換了對話：選好的檔案放回開視窗時那一則。
        let origin = target == .chatGPT ? chatGPTOrigin : nil
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                guard let self, self.target == target else { return }
                self.addAttachments(urls, origin: origin)
            }
        }
    }

    func stop() {
        switch target {
        case .assistant:
            model?.stopAssistant()
        case .thread(let id):
            model?.stopDMSession(id)
        case .chatGPT:
            chatGPT.stop()
        }
    }

    // MARK: - 開關

    func toggleDocked() {
        if isOpen { isOpen = false } else { openDocked() }
    }

    func openDocked() {
        validateTarget()
        isFloatingOpen = false
        isOpen = true
    }

    func openFloating() {
        validateTarget()
        isOpen = false
        isFloatingOpen = true
    }

    func close() {
        isPickerOpen = false
        isOpen = false
        isFloatingOpen = false
    }

    /// 等核准那一行的「到 Island 核准」：不在這裡核准。W180 D2：Island 上有「記著是這個對象的討論串」的請求，
    /// 就帶那一則的 id 開到它（正在顯示就把 Island 展開停住、還在排隊就排到下一則）；沒有就照 W179 叫 Island 展開。
    /// 別的對象、別的來源的請求一律不碰（不定位、不重排），免得對著別人的核准按允許。
    /// 工具核准是 App 層級的確認框（runModal）；它開著時 Island 點不到，所以同時把確認框帶到最前面。
    /// 回傳帶去的那一則 id（沒有是 nil）。
    @discardableResult
    func revealApprovalInIsland(in island: IslandNotice? = nil) -> UUID? {
        let island = island ?? IslandNotice.shared
        let revealed = approvalThreadID.flatMap { threadID in
            island.pendingRequestIDs(threadID: threadID).first { island.reveal(id: $0) }
        }
        if revealed == nil { IslandExceptionsNavigation.openWork() }
        bringModalForward()
        return revealed
    }

    /// 這個對象的核准會記在哪一條討論串（助理＝本機助理那條）；ChatGPT 沒有。
    private var approvalThreadID: UUID? {
        switch target {
        case .assistant: model?.assistantThreadID
        case .thread(let id): id
        case .chatGPT: nil
        }
    }

    private func bringModalForward() {
        if let modal = NSApp.modalWindow {
            NSApp.activate(ignoringOtherApps: true)
            modal.orderFrontRegardless()
            modal.makeKey()
        }
    }

    /// 沒登入 ChatGPT：把主視窗叫出來並切到 ChatGPT Space（Space 把 ChatGPT 分頁關掉時不切）。
    func openChatGPTSpace() {
        guard chatGPTAvailable else { return }
        isFloatingOpen = false
        NotificationCenter.default.post(name: .tatwoOpenWorkOSWindow, object: TatwoPage.chat.rawValue)
        NSApp.activate(ignoringOtherApps: true)
        model?.mode = .chatgpt
    }

    /// 框看得到且對象是 ChatGPT 時登記「使用中」；關掉、換對象、主視窗縮到 Dock／隱藏／關掉就還。
    private func presenceChanged() {
        if !isPresented {
            isPickerOpen = false; notice = nil; isEditingDirectKeys = false; isChatGPTModelCardOpen = false; closeChatGPTPopovers()
            isModeCardOpen = false   // W184 AB（H4 查核 #9）
        }
        refreshChatGPTLease()
    }

    private func refreshChatGPTLease() {
        let wants = isEnabled && isShowingBox && target == .chatGPT && chatGPTAvailable
        // W180 A4：第一次真的用到 ChatGPT 對象才接上模型清單（模型 chip 跟著重畫）。
        if wants, chatGPTCatalogWatch == nil {
            chatGPTCatalogWatch = chatGPTCatalogSource().sink { [weak self] catalog in self?.chatGPTCatalog = catalog }
        }
        if wants, !chatGPTLeased {
            chatGPTLeased = true
            chatGPT.appear()
        } else if !wants, chatGPTLeased {
            chatGPTLeased = false
            chatGPTSession?.disappear()
        }
        // W184 G3：ChatGPT 那一欄不在畫面上（收框、換對象、主視窗藏起來、單欄切到 Browser、倒放、分頁關掉）＝結束語音，
        // 不讓麥克風在背景開著；已經在結束就不重複。
        if !chatGPTColumnOnScreen, let session = chatGPTSession, session.voice.voiceActive { session.voice.endVoice() }
    }
}
