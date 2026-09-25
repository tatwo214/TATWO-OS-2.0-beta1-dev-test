import Foundation

// TAP — TATWO App Protocol（W177，使用者 2026-09-24「用方案 A TAP」）。
// 外部 App 經 Tap（一個 App 一座，例：ChatGPT Tap）接進 OS；Tap 底下的 Pod 是跑那個 App 真用戶端的容器。
// OS 核心與畫面只認這裡的型別，不知道任何外部 App 的細節。
// v0 只有「對話」——ChatGPT Space 真正用得到的部分；不為還沒要接的 App 預留欄位（憲法 §1）。

/// 一座 Tap 目前能不能用。
enum TapConnection: Equatable {
    /// 使用者在設定 › Plugin › TAP 關掉了。
    case off
    case starting
    /// Pod 開起來了，但這個 App 還沒登入。
    case needsLogin
    case ready
    /// 閒置收起來省記憶體；用到時再開。
    case sleeping
    case failed(String)
}

struct TapConversation: Identifiable, Equatable, Hashable {
    let id: String
    var title: String
    var updatedAt: Date
}

enum TapRole: String, Equatable {
    case user
    case assistant
}

struct TapMessage: Identifiable, Equatable {
    let id: String
    let role: TapRole
    var text: String
    /// 給這則回答的模型（App 回報得出來才有）。
    var model: String? = nil
    /// 訊息裡的圖片（生圖結果、使用者附的圖）；要顯示時再用 imageData 取。
    var images: [TapImage] = []
    /// 使用者附的檔案名稱（非圖片）。
    var files: [String] = []
    /// 回答引用的網頁（網頁版回答下方的「Sources」）。
    var sources: [TapSource] = []
    /// 使用者訊息的上一層節點（編輯＝從這裡送出新版本）。
    var parentID: String? = nil
    /// 這則（或這一輪回答）有好幾個版本時（網頁的 ‹ 1/2 ›）。
    var variant: TapVariant? = nil
}

/// 同一個位置的幾個版本（重新產生或編輯出來的）：目前第幾個、共幾個、各版本的節點。
struct TapVariant: Equatable, Hashable {
    let index: Int
    let count: Int
    let nodes: [String]
}

/// 一則對話的一支（預設是 App 目前那一支；切換版本時是別支）。
struct TapThread {
    let messages: [TapMessage]
    /// 這一支最末端的節點。
    let leaf: String?
    /// 是不是 App 目前那一支（不是的話，接著送出要指定接在 leaf 後面）。
    let isCurrent: Bool
}

/// 回答引用的來源網頁。
struct TapSource: Identifiable, Equatable, Hashable {
    let url: URL
    let title: String
    var id: String { url.absoluteString }
    var host: String { url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "" }
}

/// App 自己的工具（ChatGPT：生圖、網路搜尋、深入研究…），送出時帶上。
struct TapTool: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let detail: String
    /// 放在「＋」第一層（常用）；否則收在「更多」。
    var primary = true
    /// App 自己的排序（ChatGPT 網頁「＋」第一層的名次：生圖、搜尋、深入研究、Sketch）；nil＝沒有名次。
    var rank: Double? = nil
    /// 連接的 App（Gmail、Notion…），不是 ChatGPT 自己的工具。
    var isApp = false
    /// 沒有最近用過的 App 時，網頁版優先列的 App。
    var headApp = false
    /// 網頁版的「＋」不列（只在選了之後才出現）。
    var hidden = false
    /// App 自家出的 App（ChatGPT：connector_openai_…，例如 Documents、PDF）：網頁不放在第一層。
    var firstPartyApp = false
}

/// 資料庫（ChatGPT 網頁的 Library）裡的一個檔案。
struct TapLibraryItem: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let mime: String
    /// App 自己的分類（image、pdf、text…）。
    let category: String
    let date: Date?
    let size: Int?
    var isImage: Bool { category == "image" || mime.hasPrefix("image/") }
}

/// 資料庫的分頁（跟網頁版一樣）。
enum TapLibraryTab: String, CaseIterable, Identifiable {
    case suggested
    case images
    case all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .suggested: "建議"
        case .images: "圖片"
        case .all: "全部"
        }
    }
}

/// 新對話頁的建議（App 自己給的）。
struct TapSuggestion: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let prompt: String
}

/// 使用者要附上的檔案（只在記憶體，送出時交給 App 自己上傳）。
struct TapAttachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let mime: String
    let data: Data
}

struct TapImage: Identifiable, Equatable, Hashable {
    /// App 自己的圖片指標（例如 file-service://…）。
    let id: String
    let width: Int?
    let height: Int?
}

struct TapModel: Identifiable, Equatable, Hashable {
    /// 送出時交給 App 的代號。
    let id: String
    let title: String
    let detail: String
    /// 這個模型可選的推理強度（App 有提供才有；照 App 自己的順序）。
    var efforts: [TapEffort] = []
}

struct TapEffort: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    /// 說明（App 有給才有，例如「立即回答」）。
    var detail: String = ""
    /// 面板上方顯示的版本代號（ChatGPT：「6 Pro」的「6」）。
    var version: String = ""
    /// 面板上方顯示的檔位名稱（ChatGPT：「6 Pro」的「Pro」）。
    var level: String = ""
    /// 最高檔（ChatGPT：Pro）：網頁的滑桿變紫色、帶星點，名字也是紫色。
    var isMax: Bool = false
    /// 名字前面要不要帶版本號（ChatGPT：最新版的 High 不帶、6 Pro 帶、舊版 5.6 High 帶）。
    var showsVersion: Bool = false
}

/// 側欄裡的專案或釘選項目（ChatGPT 的 Projects／Pinned）。
struct TapFolder: Identifiable, Equatable, Hashable {
    enum Kind: String {
        /// 專案：底下有自己的對話。
        case project
        /// 釘選的單一對話。
        case conversation
        /// 其他釘選（例如 GPT），第一版只列出來。
        case other
    }
    let id: String
    let title: String
    let kind: Kind
}

/// 送出一則訊息之後，Tap 依序回報的事件。
enum TapStreamEvent: Equatable {
    /// App 收下了，開始等回答。
    case accepted
    /// 新對話建立時的代號。
    case conversation(id: String)
    /// 到目前為止的完整回答（不是增量；畫面直接換成這段）。
    case text(messageID: String, full: String)
    case title(conversationID: String, title: String)
    case finished
    case failed(String)
}

enum TapError: LocalizedError, Equatable {
    case notReady
    case timeout
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .notReady: "還沒連上"
        case .timeout: "等太久沒有回應"
        case .remote(let message): message
        }
    }
}

/// 排程（ChatGPT 的 Scheduled／Tasks）。
struct TapAutomation: Identifiable, Equatable, Hashable {
    let id: String
    var title: String
    var prompt: String
    /// App 給的排程描述（ChatGPT：iCalendar RRULE 或文字）。
    var schedule: String
    var enabled: Bool
    var nextRun: Date?
    var conversationID: String?
    /// App 自己給的一句說明（ChatGPT 的 display_schedule，例如 Monitoring）；空字串＝沒有。
    var display: String = ""
    /// 已經跑完、不會再執行（一次性的排程跑過了）。
    var completed: Bool = false
    /// 條件監控（有變化才通知），不是固定時間。
    var watching: Bool = false
}

/// 外掛（ChatGPT 的 Plugins：連接的 App）。
struct TapPlugin: Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    var detail: String
    var enabled: Bool
    var iconURL: URL?
    var installed: Bool
}

/// 外掛詳細頁（ChatGPT Plugins › 某個外掛）。
struct TapPluginDetail: Equatable {
    struct Skill: Equatable, Hashable {
        let name: String
        let detail: String
    }
    /// 外掛連接器的工具；read＝只讀（網頁的 Read tools），否則是會改東西的 Write tools。
    struct Tool: Equatable, Hashable {
        let name: String
        let detail: String
        let read: Bool
        let destructive: Bool
    }
    enum ToolsState: Equatable { case none, loaded, failed }
    let id: String
    var name: String
    var developer: String
    var category: String
    var summary: String
    var about: String
    var capabilities: [String]
    var prompts: [String]
    var website: URL?
    var privacy: URL?
    var terms: URL?
    var icon: URL?
    var screenshots: [URL]
    var skills: [Skill]
    var tools: [Tool]
    var toolsState: ToolsState
}

/// 外掛目錄的一個分類（ChatGPT Plugins 首頁：精選、新上架、各類別）。
struct TapPluginSection: Identifiable, Equatable, Hashable {
    let id: String
    var title: String
    var plugins: [TapPlugin]
}

/// 網站（ChatGPT 的 Sites）。
struct TapSite: Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    var url: URL?
    var updatedAt: Date?
    var status: String
}

/// 記憶（ChatGPT 記住的一條）。
struct TapMemory: Identifiable, Equatable, Hashable {
    let id: String
    var text: String
    var updatedAt: Date?
}

/// 自訂指令（ChatGPT 的 Customize ChatGPT）。
struct TapInstructions: Equatable {
    var enabled = true
    /// ChatGPT 該怎麼稱呼你。
    var nickname = ""
    /// 你的職業。
    var occupation = ""
    /// ChatGPT 應有的特質。
    var traits = ""
    /// 關於你的其他事。
    var aboutYou = ""
}

/// 帳號（左下角）。
struct TapAccount: Equatable {
    var name: String
    var email: String
    var plan: String?
    var pictureURL: URL?
    /// 跟網頁一樣：兩個字以上取前兩個字的字首；一個字（例如帳號名）取前兩個字母。
    var initials: String {
        let words = name.split(separator: " ")
        if words.count >= 2 { return String(words.prefix(2).compactMap(\.first)).uppercased() }
        if let word = words.first { return String(word.prefix(2)).uppercased() }
        return String(email.prefix(2)).uppercased()
    }
}

/// TAP v0 的對話介面：畫面（ChatGPT Space、之後的全域私訊鈕）只透過它跟外部 App 說話。
@MainActor
protocol ConversationTap: AnyObject {
    var tapID: String { get }
    var displayName: String { get }
    var connection: TapConnection { get }
    func conversations(offset: Int, limit: Int) async throws -> (items: [TapConversation], total: Int)
    func messages(conversationID: String) async throws -> [TapMessage]
    func thread(conversationID: String, branch: String?) async throws -> TapThread
    /// currentEffortID：外部 App 記的「目前／上次使用」檔位（ChatGPT：伺服器的 last_used_model_config）；沒有就是 nil。
    func models() async throws -> (items: [TapModel], defaultID: String?, currentEffortID: String?)
    func pinned() async throws -> [TapFolder]
    func projects() async throws -> [TapFolder]
    func conversations(inProject projectID: String) async throws -> [TapConversation]
    /// parentID＝接在哪個節點後面（切換過版本或編輯訊息時）；nil＝App 目前那一支。
    func send(text: String, conversationID: String?, model: String?, effort: String?, attachments: [TapAttachment],
              tool: String?, gizmoID: String?, temporary: Bool, parentID: String?) -> AsyncStream<TapStreamEvent>
    func tools() async throws -> [TapTool]
    func home() async throws -> (greeting: String?, suggestions: [TapSuggestion])
    func gpts() async throws -> [TapFolder]
    /// 重新產生這則對話最後一個回答（走 App 自己的「重新產生」）；給模型＝換那個模型重答；temporary＝暫時對話。
    func regenerate(conversationID: String, model: String?, effort: String?, temporary: Bool) -> AsyncStream<TapStreamEvent>
    func rename(conversationID: String, title: String) async throws
    func feedback(conversationID: String, messageID: String, good: Bool) async throws
    func setPinned(conversationID: String, pinned: Bool) async throws
    func branch(conversationID: String) async throws -> String?
    func archive(conversationID: String) async throws
    func delete(conversationID: String) async throws
    func search(query: String) async throws -> [TapConversation]
    func imageData(pointer: String, conversationID: String?) async throws -> Data
    /// 資料庫：一頁檔案＋下一頁的游標。
    func library(tab: TapLibraryTab, query: String, cursor: String?) async throws -> (items: [TapLibraryItem], cursor: String?)
    /// 資料庫檔案的縮圖（full＝原檔）；只放記憶體。
    func libraryData(itemID: String, full: Bool) async throws -> Data
    func stop()
}
