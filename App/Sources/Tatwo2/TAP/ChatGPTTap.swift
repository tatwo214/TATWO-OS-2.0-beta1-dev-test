import Combine
import Foundation

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
    @Published private(set) var connection: TapConnection = .off
    /// 最近一次送出的串流格式（只有事件名稱與欄位名稱，沒有內容）；設定 › Plugin › TAP 顯示，給診斷用。
    @Published private(set) var lastStreamShape: String?
    /// 最近一次送出時，串流本身解析得到文字（false＝靠網頁畫面備援）。
    @Published private(set) var lastStreamParsed = false
    /// 網頁自己實際會用的模型與強度選項（看到網頁送出請求時回報）；選單沒特別選時照這個顯示。
    @Published private(set) var pageSelection: (model: String, effort: String?)?
    let pod: TapWebPod
    private var results: [String: CheckedContinuation<Any, Error>] = [:]
    private var streams: [String: AsyncStream<TapStreamEvent>.Continuation] = [:]
    /// 網頁回過「收到了」的送出（沒回的 60 秒後判定失敗）。
    private var acceptedStreams: Set<String> = []

    private init() {
        pod = TapWebPod(podID: "chatgpt", profileID: Self.profileID, homeURL: Self.homeURL, script: Self.podScript)
        pod.onEvent = { [weak self] json in self?.receive(json) }
        connection = Self.isEnabled ? .sleeping : .off
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
        guard Self.isEnabled else { connection = .off; return }
        guard !pod.isRunning else { return }
        connection = .starting
        // 對話內容不落地：每次開 App 第一次啟動前清掉上次留下的瀏覽器快取（登入不動）。
        TapPodStorage.purgeHTTPCacheOnce(profileID: Self.profileID)
        do {
            try pod.start()
        } catch {
            connection = .failed(error.localizedDescription)
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            if self?.connection == .starting { self?.connection = .failed("ChatGPT 網頁沒有回應") }
        }
    }

    /// 收起 Pod 省記憶體；登入資料留著，下次開不用重登。
    func sleep() {
        failPending("已休眠")
        pod.stop()
        connection = Self.isEnabled ? .sleeping : .off
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
        let data = try await request("list", ["offset": offset, "limit": limit]) as? [String: Any] ?? [:]
        let items = (data["items"] as? [[String: Any]] ?? []).compactMap { item -> TapConversation? in
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
        return TapThread(messages: messages, leaf: data["leaf"] as? String, isCurrent: (data["current"] as? Bool) ?? true)
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
        let data = try await request("tools") as? [String: Any] ?? [:]
        return (data["items"] as? [[String: Any]] ?? []).compactMap { item -> TapTool? in
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
        let data = try await request("projects") as? [String: Any] ?? [:]
        return Self.folders(data["items"])
    }

    func conversations(inProject projectID: String) async throws -> [TapConversation] {
        let data = try await request("projectConversations", ["projectID": projectID]) as? [String: Any] ?? [:]
        return (data["items"] as? [[String: Any]] ?? []).compactMap { item -> TapConversation? in
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
    func voice(start conversationID: String?) async throws -> (live: Bool, conversationID: String?) {
        var payload: [String: Any] = [:]
        if let conversationID { payload["conversationID"] = conversationID }
        let data = try await request("voice", payload, timeout: .seconds(40)) as? [String: Any] ?? [:]
        return ((data["live"] as? Bool) ?? false, data["conversationID"] as? String)
    }

    func voiceStop() async throws {
        _ = try await request("voice", ["stop": true])
    }

    func voiceState() async throws -> (live: Bool, conversationID: String?) {
        let data = try await request("voiceState") as? [String: Any] ?? [:]
        return ((data["live"] as? Bool) ?? false, data["conversationID"] as? String)
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
        let data = try await request("search", ["query": query]) as? [String: Any] ?? [:]
        return (data["items"] as? [[String: Any]] ?? []).compactMap { item -> TapConversation? in
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
            return TapFolder(id: id, title: title, kind: TapFolder.Kind(rawValue: (item["kind"] as? String) ?? "") ?? .other)
        }
    }

    func send(text: String, conversationID: String?, model: String?, effort: String?,
              attachments: [TapAttachment], tool: String?, gizmoID: String?, temporary: Bool,
              parentID: String?) -> AsyncStream<TapStreamEvent> {
        var payload: [String: Any] = ["cmd": "send", "text": text]
        if let parentID { payload["parentID"] = parentID }
        if let tool { payload["hint"] = tool }
        if temporary { payload["temporary"] = true }
        if let gizmoID { payload["gizmoID"] = gizmoID }
        if !attachments.isEmpty {
            payload["files"] = attachments.map { ["name": $0.name, "mime": $0.mime, "base64": $0.data.base64EncodedString()] }
        }
        if let conversationID { payload["conversationID"] = conversationID }
        if let model { payload["model"] = model }
        if let effort { payload["effort"] = effort }
        return startStream(payload)
    }

    /// 重新產生；給模型／檔位＝換那個重答（網頁的 Switch model），沒給就是 Try again。
    func regenerate(conversationID: String, model: String?, effort: String?, temporary: Bool) -> AsyncStream<TapStreamEvent> {
        var payload: [String: Any] = ["cmd": "regenerate", "conversationID": conversationID]
        if temporary { payload["temporary"] = true }
        if let model { payload["model"] = model }
        if let effort { payload["effort"] = effort }
        return startStream(payload)
    }

    private func startStream(_ base: [String: Any]) -> AsyncStream<TapStreamEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: TapStreamEvent.self)
        guard connection == .ready else {
            continuation.yield(.failed(TapError.notReady.localizedDescription))
            continuation.finish()
            return stream
        }
        let id = UUID().uuidString
        var payload = base
        payload["id"] = id
        guard let script = try? Self.commandScript(payload) else {
            continuation.yield(.failed("送出內容無法編碼"))
            continuation.finish()
            return stream
        }
        streams[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.streams[id] = nil; self?.acceptedStreams.remove(id) }
        }
        pod.run(script)
        // 網頁一段時間什麼都沒回：判定沒送出，不讓畫面一直「思考中」（09-25 實機）。有附件時網頁要先上傳，等久一點。
        let silence: Duration = (base["files"] as? [Any])?.isEmpty == false ? .seconds(150) : .seconds(60)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: silence)
            guard let self, let pending = self.streams[id], !self.acceptedStreams.contains(id) else { return }
            pending.yield(.failed("ChatGPT 網頁沒有回應，這則可能沒有送出"))
            pending.finish()
            self.streams[id] = nil
        }
        return stream
    }

    func stop() {
        guard let script = try? Self.commandScript(["cmd": "stop", "id": UUID().uuidString]) else { return }
        pod.run(script)
    }

    // MARK: - Pod 通訊

    private func request(_ command: String, _ arguments: [String: Any] = [:], timeout: Duration = .seconds(20)) async throws -> Any {
        guard connection == .ready else { throw TapError.notReady }
        let id = UUID().uuidString
        var payload = arguments
        payload["cmd"] = command
        payload["id"] = id
        let script = try Self.commandScript(payload)
        return try await withCheckedThrowingContinuation { continuation in
            results[id] = continuation
            pod.run(script)
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
        switch type {
        case "hello":
            if let loggedIn = object["loggedIn"] as? Bool { connection = loggedIn ? .ready : .needsLogin }
            if connection == .ready { UserDefaults.standard.set(true, forKey: Self.readyOnceKey) }
        case "auth":
            connection = .ready
            UserDefaults.standard.set(true, forKey: Self.readyOnceKey)
        case "selection":
            if let model = object["model"] as? String, !model.isEmpty {
                pageSelection = (model, object["effort"] as? String)
            }
        case "result":
            guard let id = object["id"] as? String, let continuation = results.removeValue(forKey: id) else { return }
            if (object["ok"] as? Bool) == true {
                continuation.resume(returning: object["data"] ?? NSNull())
            } else {
                continuation.resume(throwing: TapError.remote((object["message"] as? String) ?? "ChatGPT 回報錯誤"))
            }
        case "stream":
            guard let id = object["id"] as? String, let continuation = streams[id],
                  let kind = object["kind"] as? String else { return }
            acceptedStreams.insert(id)   // 回了任何事件都算有回應
            switch kind {
            case "accepted":
                continuation.yield(.accepted)
            case "conversation":
                if let conversationID = object["conversationID"] as? String { continuation.yield(.conversation(id: conversationID)) }
            case "text":
                continuation.yield(.text(messageID: (object["messageID"] as? String) ?? "", full: (object["full"] as? String) ?? ""))
            case "title":
                if let conversationID = object["conversationID"] as? String, let title = object["title"] as? String {
                    continuation.yield(.title(conversationID: conversationID, title: title))
                }
            case "finished":
                lastStreamShape = object["shape"] as? String
                lastStreamParsed = (object["parsed"] as? Bool) ?? false
                continuation.yield(.finished)
                continuation.finish()
                streams[id] = nil
            case "failed":
                continuation.yield(.failed((object["message"] as? String) ?? "送出失敗"))
                continuation.finish()
                streams[id] = nil
            default:
                break
            }
        default:
            break
        }
    }

    private func failPending(_ message: String) {
        for continuation in results.values { continuation.resume(throwing: TapError.remote(message)) }
        results.removeAll()
        for continuation in streams.values {
            continuation.yield(.failed(message))
            continuation.finish()
        }
        streams.removeAll()
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
      // 先把要用的內建函式拿在手上：網頁之後改掉全域的 JSON 也不影響回報。
      const stringify = JSON.stringify;
      const post = (o) => { try { report(stringify(o)); } catch (e) {} };
      const originalFetch = window.fetch.bind(window);
      const KEEP = /^(authorization|chatgpt-account-id|oai-device-id|oai-client-version|oai-client-build-number|oai-language)$/i;
      let auth = null;
      const authWaiters = [];
      let pendingSend = null;
      // 使用者選的模型／推理強度：送出前網頁會先 POST f/conversation/prepare（拿 x-conduit-token），兩個請求都要一致。
      let pendingModel = null;
      let pendingEffort = null;
      let pendingHint = null;
      let pendingTemporary = false;
      // 接在哪一支後面（切換過版本、或編輯訊息）：改寫網頁送出的上一層節點。
      let pendingParent = null;
      // 在專案／GPT 裡開新對話：送出內容要帶 conversation_mode（gizmo_interaction＋gizmo_id）。
      let pendingGizmo = null;
      // 語音結束後的保險（見 voice）。
      let voiceGuard = null;
      let voiceStopAt = 0;
      // 診斷（只有欄位名稱與像代號的短值，沒有內容），設定 › Plugin › TAP 顯示。
      const diag = {};
      const EFFORT_KEY = /^(thinking_effort|reasoning_effort|effort)$/;
      const withModel = (init, model, effort, label) => {
        if (!init || typeof init.body !== 'string') return init;
        try {
          const body = JSON.parse(init.body);
          if (!body || typeof body !== 'object') return init;
          if (label) {
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
          if (pendingGizmo) {
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
            const k = Object.keys(body).find((x) => EFFORT_KEY.test(x));
            diag[label + '改寫後'] = 'model=' + (typeof body.model === 'string' ? body.model.slice(0, 40) : '-') + '，強度=' + (k ? String(body[k]).slice(0, 12) : '無');
          }
          return changed ? Object.assign({}, init, { body: stringify(body) }) : init;
        } catch (e) { return init; }
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
      const shapeText = (s) => {
        const list = (bag) => Object.keys(bag).map((k) => k + '×' + bag[k]).join(', ') || '-';
        return '事件 ' + s.events + '（JSON ' + s.json + '、其他 ' + s.other + '）；event: ' + list(s.names) + '；type: ' + list(s.types)
          + '；o: ' + list(s.ops) + '；p: ' + list(s.paths) + '；欄位: ' + list(s.keys) + (s.headers ? '；' + s.headers : '')
          + '；交棒: ' + list(s.handoff) + '；連線: ' + list(s.net) + '；WS: ' + list(s.ws) + '；已開 WS: ' + (sockets.join(', ') || '-');
      };
      const setConversation = (turn, conversationID) => {
        if (!conversationID || typeof conversationID !== 'string' || turn.conversationPosted) return;
        turn.conversationID = conversationID;
        turn.conversationPosted = true;
        post({ type: 'stream', id: turn.id, kind: 'conversation', conversationID });
      };
      function finishTurn(turn, failure) {
        if (turn.finished) return;
        turn.finished = true;
        clearInterval(turn.timer);
        delete turns[turn.id];
        if (!failure) setConversation(turn, turn.conversationID || conversationFromURL());
        if (failure) { post({ type: 'stream', id: turn.id, kind: 'failed', message: failure }); return; }
        post({ type: 'stream', id: turn.id, kind: 'finished', conversationID: turn.conversationID,
          parsed: turn.sseText, shape: shapeText(turn.shape) });
      }
      function tick(turn) {
        if (turn.finished) return;
        const stopping = stopVisible();
        if (stopping) turn.sawStop = true;
        if (!turn.sseText) {
          const nodes = assistantNodes();
          if (nodes.length > turn.before) {
            const text = String(nodes[nodes.length - 1].innerText || '').trim();
            if (text && text !== turn.domText) {
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
          else if (turn.project) { if (!turn.lookingUp) findProjectConversation(turn); return; }
          else if (turn.sseEnded && Date.now() - (turn.sseEndedAt || 0) < 1500) return;
        }
        // 轉線的回答（stream_handoff）：續傳串流把答案送完（有文字、串流結束）就算完成；沒有續傳就交給 pollTurn 讀對話判斷。
        // 串流還開著但一直沒有文字也照樣讀對話（伺服器說完成才算完成）。
        const done = !stopping && (turn.handoff ? (turn.sseText && turn.sseEnded)
          : (turn.sseEnded || (turn.sawStop && Date.now() - turn.started > 1500)));
        if (turn.handoff && !turn.polling && (turn.sseEnded || !turn.sseText)) pollTurn(turn);
        if (done || Date.now() - turn.started > (turn.handoff ? 30 : 10) * 60 * 1000) finishTurn(turn);
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
            if (!items) { finishTurn(turn); return; }   // 讀到的不是清單：沒得找，照原本的方式收尾
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
        turn.polling = true;
        let wait = 1200, failingSince = 0;
        while (!turn.finished && Date.now() - turn.started < 30 * 60 * 1000) {
          await sleep(wait);
          wait = Math.min(wait + 1000, 8000);
          const id = turn.conversationID || conversationFromURL();
          if (!id || turn.finished) continue;
          setConversation(turn, id);
          let convo = null;
          try { convo = await api(conversationPath(id)); failingSince = 0; } catch (e) {
            bump(turn.shape.types, 'poll-error');
            // 連續兩分鐘讀不到這則對話：照原本的方式收尾（畫面上已有的字就是答案），不要掛 30 分鐘。
            if (!failingSince) failingSince = Date.now();
            if (Date.now() - failingSince > 120000) { finishTurn(turn); return; }
            continue;
          }
          if (turn.finished) return;
          bump(turn.shape.types, 'poll');
          // 讀到的不是一則對話：沒得等，照原本的方式收尾。
          if (!convo || typeof convo.mapping !== 'object' || !convo.mapping) { finishTurn(turn); return; }
          const head = convo.mapping[convo.current_node];
          const m = head && head.message;
          // 只認這一輪之後產生的回答：伺服器可能還回上一輪的節點（審查 #10）。
          const fresh = !!m && (!m.create_time || m.create_time * 1000 >= turn.started - 5000);
          const role0 = m && m.author && m.author.role;
          // 診斷只記代號：讀到的最新節點是誰、什麼狀態、有沒有 async 狀態（不記內容）。
          const code = (v) => (v == null ? '-' : /^[a-z0-9_.-]{1,24}$/i.test(String(v)) ? String(v) : typeof v);
          bump(turn.shape.handoff, 'poll=' + code(role0) + '/' + code(m && m.status) + (fresh ? '' : '/old')
            + (convo.async_status != null ? '/async:' + code(convo.async_status) : ''));
          // 兩分鐘了還看不到這一輪的回答、也看不出在產生（沒有 async 狀態、沒有停止鍵、網頁上這一輪也還沒有回答泡泡）：
          // 收工，不要掛 30 分鐘。網頁上已經有這一輪的泡泡（例如「Pro thinking」）就等伺服器，最多 30 分鐘。
          const pageBubble = assistantNodes().length > turn.before;
          if ((role0 !== 'assistant' || !fresh) && !convo.async_status && !stopVisible() && !pageBubble
            && Date.now() - turn.started > 120000) { finishTurn(turn); return; }
          if (!fresh) continue;
          const msgs = thread(convo).messages;
          const last = msgs.length && msgs[msgs.length - 1].role === 'assistant' ? msgs[msgs.length - 1] : null;
          if (last && last.text && last.text !== turn.polledText && !turn.sseText) {
            turn.polledText = last.text;
            post({ type: 'stream', id: turn.id, kind: 'text', messageID: last.id || 'poll', full: last.text });
          }
          const ended = !!m && m.author && m.author.role === 'assistant' && m.status === 'finished_successfully'
            && (m.end_turn === true || !!(m.metadata && m.metadata.finish_details));
          if (ended && !stopVisible()) { finishTurn(turn); return; }
        }
      }
      function startTurn(id) {
        const turn = { id, started: Date.now(), conversationID: null, conversationPosted: false, sseText: false,
          sseEnded: false, domText: '', before: assistantNodes().length, sawStop: false, finished: false,
          shape: newShape(), timer: null };
        turns[id] = turn;
        turn.timer = setInterval(() => tick(turn), 150);
        return turn;
      }

      async function readStream(turn, body) {
        turn.sseEnded = false;   // 每條串流（含轉線後的續傳）各自算結束
        const id = turn.id;
        const shape = turn.shape;
        const reader = body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';
        const messages = {};
        let current = null, lastPath = null, lastOp = null, lastSent = 0, dirty = false;
        const isText = (m) => m && m.role === 'assistant' && (m.type === 'text' || m.type === 'multimodal_text');
        const emitText = (force) => {
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
          const entry = { id: m.id, role: m.author && m.author.role, type: m.content && m.content.content_type,
            text: typeof parts[0] === 'string' ? parts[0] : '' };
          messages[c != null ? c : m.id] = entry;
          current = entry;
          emitText(true);
        };
        const applyOne = (op) => {
          if (!op || typeof op !== 'object') return;
          let p = op.p, o = op.o;
          const v = op.v;
          if (p === undefined) p = lastPath;
          if (o === undefined) o = lastOp;
          // 第一個事件可能省略 p/o：v 裡直接是一則訊息就當新增。
          if ((o == null) && v && typeof v === 'object' && v.message) o = 'add';
          if (typeof op.c === 'number' && messages[op.c]) current = messages[op.c];
          lastPath = p; lastOp = o;
          bump(shape.ops, o); bump(shape.paths, p);
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
        const handleData = (data) => {
          if (data === '[DONE]') return;
          if (turn.finished) return;
          let obj;
          try { obj = JSON.parse(data); } catch (e) { shape.other += 1; return; }
          shape.json += 1;
          if (!obj || typeof obj !== 'object') return;
          bump(shape.keys, Object.keys(obj).sort().join('+'));
          if (typeof obj.conversation_id === 'string') setConversation(turn, obj.conversation_id);
          if (obj.v && typeof obj.v === 'object' && typeof obj.v.conversation_id === 'string') setConversation(turn, obj.v.conversation_id);
          if (obj.type) bump(shape.types, obj.type);
          if (obj.type === 'stream_handoff') { turn.handoff = true; turn.sseText = false; }
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
            buffer += decoder.decode(value, { stream: true }).replace(/\r\n/g, '\n');
            let index;
            while ((index = buffer.indexOf('\n\n')) >= 0) {
              const block = buffer.slice(0, index);
              buffer = buffer.slice(index + 2);
              shape.events += 1;
              const name = block.split('\n').find((l) => l.startsWith('event:'));
              if (name) bump(shape.names, name.slice(6).trim());
              const data = block.split('\n').filter((l) => l.startsWith('data:')).map((l) => l.slice(5).replace(/^ /, '')).join('\n');
              if (data) handleData(data);
            }
          }
          if (dirty) emitText(true);
        } catch (e) {
          bump(shape.types, 'read-error');
        }
        turn.sseEnded = true;
        turn.sseEndedAt = Date.now();
      }

      window.fetch = async function (input, init) {
        const url = typeof input === 'string' ? input : (input && input.url) || String(input);
        if (url.indexOf('/backend-api/') >= 0) captureAuth(input, init);
        const method = ((init && init.method) || (input && input.method) || 'GET').toUpperCase();
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
        // 網頁送訊息有兩條路：一般是 /f/conversation，旗標沒開時走舊的 /conversation（09-25 實機：專案裡送出走這條，
        // 以前只攔 /f/ 那條，模型、暫時對話、專案都沒套上，也沒解析到回答）。兩條都攔。
        if (method === 'POST' && (pendingModel || pendingEffort || pendingHint || pendingParent || pendingGizmo) && /\/backend-api\/(f\/)?conversation\/prepare(\?|$)/.test(url)) {
          init = withModel(init, pendingModel, pendingEffort, '準備請求');
        }
        if (method === 'POST' && /\/backend-api\/(f\/)?conversation(\?|$)/.test(url) && pendingSend) {
          job = pendingSend;
          pendingSend = null;
          pendingModel = null;
          pendingEffort = null;
          diag['送出路徑'] = /\/backend-api\/f\/conversation/.test(url) ? '/f/conversation' : '/conversation';
          pendingHint = job.hint || null;
          pendingTemporary = !!job.temporary;
          pendingParent = job.parentID || null;
          pendingGizmo = job.gizmo || null;
          init = withModel(init, job.model, job.effort, '送出請求');
          pendingHint = null;
          pendingTemporary = false;
          pendingParent = null;
          pendingGizmo = null;
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
          response = await originalFetch(input, init);
        } catch (e) {
          if (job && turns[job.id]) finishTurn(turns[job.id], String((e && e.message) || e));
          throw e;
        }
        if (!job) {
          // 交棒後回答可能從另一條串流過來：送出期間任何事件串流都一起解析（看得懂就用）。
          try {
            if (during && !during.finished && response.body
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
          finishTurn(turn, 'HTTP ' + response.status);
          return response;
        }
        post({ type: 'stream', id: job.id, kind: 'accepted' });
        try {
          const h = response.headers;
          const names = [];
          h.forEach((_, k) => { if (/compress|encoding/i.test(k)) names.push(k); });
          turn.shape.headers = 'ct=' + String(h.get('content-type') || '').split(';')[0]
            + (h.get('content-encoding') ? ' ce=' + h.get('content-encoding') : '') + (names.length ? ' h=' + names.join('+') : '');
        } catch (e) {}
        // 讀複製品，網頁拿回原本那個回應（網址、型別等屬性都不變）。
        readStream(turn, response.clone().body);
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
              if (!turn || typeof event.data !== 'string') return;
              let obj;
              try { obj = JSON.parse(event.data); } catch (e) { bump(turn.shape.ws, 'text'); return; }
              if (!obj || typeof obj !== 'object') return;
              bump(turn.shape.ws, Object.keys(obj).sort().join('+') + (typeof obj.type === 'string' ? ':' + obj.type : ''));
              if (turn.feed && (obj.message || 'o' in obj || 'p' in obj || 'v' in obj)) turn.feed(event.data);
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
          if (hidden) continue;
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

      const composer = () => document.querySelector('#prompt-textarea');
      async function openConversation(conversationID) {
        const target = conversationID ? '/c/' + conversationID : '/';
        if (location.pathname !== target) {
          history.pushState({}, '', target);
          window.dispatchEvent(new PopStateEvent('popstate', { state: {} }));
        }
        // 專案裡的對話網址是 /g/<專案>/c/<id>，網頁可能自己改成那樣：結尾對得上就算。
        const ready = await waitFor(() => (conversationID ? location.pathname.endsWith(target) : location.pathname === '/') && composer()
          && (!conversationID || document.querySelector('[data-message-author-role]')), 8000);
        if (!ready) return false;
        await sleep(conversationID ? 700 : 250);
        return true;
      }
      // 跟某個 GPT 開新對話：網頁的網址是 /g/<GPT 代號>（後面可能接名稱）；專案（g-p-…）是 /g/<專案>/project，在那裡送出就開在專案裡。
      async function openGizmo(gizmoID) {
        const target = '/g/' + gizmoID;
        if (!location.pathname.startsWith(target) || (/^g-p-/.test(gizmoID) && !/\/project$/.test(location.pathname))) {
          history.pushState({}, '', target + (/^g-p-/.test(gizmoID) ? '/project' : ''));
          window.dispatchEvent(new PopStateEvent('popstate', { state: {} }));
        }
        const ready = await waitFor(() => location.pathname.startsWith(target) && composer(), 8000);
        diag['GPT 對話'] = ready ? '已開到 GPT 頁' : '沒有開到 GPT 頁';
        if (!ready) return false;
        await sleep(400);
        return true;
      }
      // 網頁的選單元件多半在「按下」（pointerdown）時才打開，光送 click 不會開：送完整的按壓順序。
      const press = (el) => {
        const opts = { bubbles: true, cancelable: true, view: window, button: 0, buttons: 1, pointerId: 1, pointerType: 'mouse', isPrimary: true };
        for (const [Type, name] of [['PointerEvent', 'pointerdown'], ['MouseEvent', 'mousedown'], ['PointerEvent', 'pointerup'], ['MouseEvent', 'mouseup']]) {
          try { const E = window[Type]; if (typeof E === 'function') el.dispatchEvent(new E(name, opts)); } catch (e) {}
        }
        try { el.click(); } catch (e) {}
      };
      // Space 只做 Chat（使用者 09-24 裁決）：Work 跟 Codex 共用額度。新對話頁頂端的「Chat／Work」切到 Chat。
      const modeButton = (names) => [...document.querySelectorAll('button, [role="tab"], [role="radio"]')]
        .find((b) => names.includes(String(b.textContent || '').trim()));
      // 回傳 'chat'／'work'（確定還在 Work）／'unknown'（沒有切換鈕或看不出來，例如專案頁、沒有 Work 的帳號）。
      async function ensureChatMode() {
        const chat = modeButton(['Chat', '聊天', '對話']);
        if (!chat) { diag['Chat 切換'] = '找不到切換鈕'; return 'unknown'; }
        const work = modeButton(['Work', '工作']);
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
        const fail = (message) => post({ type: 'stream', id: command.id, kind: 'failed', message });
        if (!(await openConversation(command.conversationID))) { fail('ChatGPT 網頁沒有開到這則對話'); return; }
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
        pendingSend = { id: command.id, model, effort, temporary: command.temporary === true };
        const turn = startTurn(command.id);
        turn.before = Math.max(0, turn.before - 1);
        press(button);
        // ↻ 會先跳一個選單（換模型重答／Try again）：按「Try again」。
        const item = await waitFor(() => [...document.querySelectorAll('[role="menuitem"], [role="menu"] button, [role="option"]')]
          .find((x) => REGEN.test(String(x.textContent || '')) || REGEN.test(String(x.getAttribute('aria-label') || ''))), viaMenu ? 2000 : 400);
        if (item) {
          diag['重新產生'] += '（經選單）';
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
        const fail = (message) => post({ type: 'stream', id: command.id, kind: 'failed', message });
        const opened = !command.conversationID && typeof command.gizmoID === 'string' && command.gizmoID
          ? await openGizmo(command.gizmoID) : await openConversation(command.conversationID);
        if (!opened) { fail('ChatGPT 網頁沒有開到這則對話'); return; }
        // Space 只做 Chat：確定還停在 Work（跟 Codex 共用額度）就不送（審查 #6）。
        if (!command.conversationID && (await ensureChatMode()) === 'work') { fail('ChatGPT 停在 Work 模式（跟 Codex 共用額度），這則沒有送出'); return; }
        const files = Array.isArray(command.files) ? command.files : [];
        if (files.length && !(await attachFiles(files))) { fail('找不到 ChatGPT 的上傳欄位'); return; }
        const box = composer();
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
        if (!box) { pendingModel = null; pendingEffort = null; pendingParent = null; pendingGizmo = null; fail('找不到 ChatGPT 的輸入框'); return; }
        // 只選輸入框裡的字（網頁可能把上次沒送出的字當草稿恢復；對整頁全選蓋不掉它；09-25 實機）。
        const selectComposer = () => {
          box.focus();
          try {
            if (typeof box.select === 'function') { box.select(); return; }
            const range = document.createRange();
            range.selectNodeContents(box);
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
          } catch (e) { document.execCommand('selectAll', false); }
        };
        const composerText = () => String(box.value != null ? box.value : (box.innerText || '')).trim();
        selectComposer();
        document.execCommand('insertText', false, command.text);
        if (composerText() && composerText() !== String(command.text).trim()) {
          selectComposer();
          document.execCommand('insertText', false, command.text);
        }
        if (composerText() && composerText() !== String(command.text).trim()) {
          pendingModel = null; pendingEffort = null; pendingParent = null; pendingGizmo = null;
          fail('ChatGPT 的輸入框打不進這段字'); return;
        }
        // 有附件時網頁要先上傳完才讓送出：等久一點。
        const button = await waitFor(() => {
          const b = document.querySelector('[data-testid="send-button"]');
          return b && !b.disabled ? b : null;
        }, files.length ? 90000 : 5000);
        if (!button) { pendingModel = null; pendingEffort = null; pendingParent = null; pendingGizmo = null; fail('找不到送出鍵'); return; }
        // 暫時對話的每一則（不只第一則）都要帶暫時旗標，否則伺服器找不到那則對話（09-24 實機：第二則 HTTP 404）。
        pendingSend = { id: command.id, model: command.model || null, effort: command.effort || null, hint: pendingHint,
          temporary: command.temporary === true, parentID: pendingParent, gizmo: pendingGizmo };
        const turn = startTurn(command.id);
        turn.project = pendingGizmo && /^g-p-/.test(pendingGizmo) ? pendingGizmo : null;
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
          if (!turn.finished && !turn.domText && !turn.sawStop) finishTurn(turn, 'ChatGPT 沒有送出這則訊息');
        }, 20000);
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
        return id && title ? { id, title, kind: 'project' } : null;
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

      const handlers = {
        list: async (c) => {
          const j = await api('/backend-api/conversations?offset=' + (c.offset || 0) + '&limit=' + (c.limit || 50) + '&order=updated');
          return { total: j.total, items: (j.items || []).map((i) => ({ id: i.id, title: i.title, update_time: i.update_time })) };
        },
        get: async (c) => {
          if (!Object.keys(modelTitles).length) { try { await handlers.models(); } catch (e) {} }
          const t = thread(await api('/backend-api/conversation/' + encodeURIComponent(c.conversationID)),
            typeof c.branch === 'string' ? c.branch : null);
          return { messages: t.messages, parents: t.parents, leaf: t.leaf, current: t.current };
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
          const j = await api('/backend-api/gizmos/snorlax/sidebar');
          const list = (j && j.items) || [];
          diag['專案欄位'] = keysOf(list) + '｜' + keysOf(list.map(gizmoOf));
          return { items: list.map(projectOf).filter(Boolean) };
        },
        projectConversations: async (c) => {
          const j = await api('/backend-api/gizmos/' + encodeURIComponent(c.projectID) + '/conversations?cursor=0');
          return { items: ((j && j.items) || []).map((i) => ({ id: i.id, title: i.title, update_time: i.update_time })) };
        },
        rename: async (c) => { await apiSend('PATCH', conversationPath(c.conversationID), { title: String(c.title || '').slice(0, 200) }); return { ok: true }; },
        archive: async (c) => { await apiSend('PATCH', conversationPath(c.conversationID), { is_archived: true }); return { ok: true }; },
        remove: async (c) => { await apiSend('PATCH', conversationPath(c.conversationID), { is_visible: false }); return { ok: true }; },
        search: async (c) => {
          const j = await api('/backend-api/conversations/search?query=' + encodeURIComponent(String(c.query || '').slice(0, 200)) + '&cursor=');
          const list = (j && j.items) || [];
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
          const list = (j && j.system_hints) || [];
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
          const endButton = () => [...document.querySelectorAll('button')].find((b) => /end voice mode/i.test(String(b.getAttribute('aria-label') || '')));
          if (c.stop) {
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
          if (voiceGuard) { clearInterval(voiceGuard); voiceGuard = null; }
          if (!(await openConversation(c.conversationID ? String(c.conversationID) : null))) throw new Error('沒有開到對話');
          if (!c.conversationID) await ensureChatMode();
          // 網頁輸入框有字時，語音鈕（composer-speech-button）會換成送出鍵（09-25 實機：找不到語音鈕）。先清空再找。
          const box = composer();
          const hadText = !!(box && String(box.innerText || box.value || '').trim());
          if (hadText) {
            box.focus();
            document.execCommand('selectAll', false);
            document.execCommand('delete', false);
          }
          const start = await waitFor(() => document.querySelector('[data-testid="composer-speech-button"]')
            || [...document.querySelectorAll('button')].find((b) => {
              const l = String(b.getAttribute('aria-label') || '');
              return /start voice|voice mode|語音/i.test(l) && !/end voice|結束/i.test(l);
            }), 8000);
          diag['語音輸入框'] = hadText ? '原本有字，已清空' : '原本是空的';
          diag['語音'] = start ? '找到：' + String(start.getAttribute('aria-label') || start.getAttribute('data-testid') || '').slice(0, 30) : '找不到語音鈕';
          if (!start) throw new Error('找不到 ChatGPT 的語音模式鈕');
          press(start);
          const live = await waitFor(() => !!endButton(), 20000);
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
        voiceState: async () => ({ live: [...document.querySelectorAll('button')].some((b) => /end voice mode/i.test(String(b.getAttribute('aria-label') || ''))),
          conversationID: conversationFromURL() }),
        diagnostics: async () => diag,
        stop: async () => {
          const b = document.querySelector('[data-testid="stop-button"]');
          if (b) b.click();
          return { stopped: !!b };
        },
      };
      Object.defineProperty(window, '__tatwoPod', {
        configurable: false, enumerable: false, writable: false,
        value: Object.freeze({
          command(command) {
            if (!command || typeof command !== 'object') return;
            // 送出流程中途出錯也要回報（09-25 實機：專案頁出錯時什麼都沒回，App 一直顯示「思考中」）。
            const failStream = (e) => post({ type: 'stream', id: command.id, kind: 'failed', message: String((e && e.message) || e).slice(0, 200) });
            if (command.cmd === 'send') { send(command).catch(failStream); return; }
            if (command.cmd === 'regenerate') { regenerate(command).catch(failStream); return; }
            const handler = handlers[command.cmd];
            if (!handler) { post({ type: 'result', id: command.id, ok: false, message: 'unknown command' }); return; }
            handler(command).then(
              (data) => post({ type: 'result', id: command.id, ok: true, data }),
              (e) => post({ type: 'result', id: command.id, ok: false, message: String((e && e.message) || e) }));
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
