import NaturalLanguage
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// 全域翻譯索引（W177，使用者 2026-09-25：ChatGPT「mcp商城全英文 我們這邊有辦法做到繁中？」）。
///
/// 做法參考 ClaudeTW 的「常駐索引」，再補上它做不到的動態內容：
/// - 常駐：英文 → 繁中的索引一開就整份載入記憶體，畫面只查表（不閃、不等網路）。
/// - 補齊：查不到的句子先顯示原文並排隊，交給 Apple 裝置端翻譯（內容不離開這台設備、不花額度），翻好寫回索引，下次直接查表。
/// - 固定用語：`glossary` 優先，同一個詞每次都一樣（外掛、技能、讀取工具…）；外掛名稱等品牌名不要丟進來。
/// - 只收公開的介面與目錄文字（例：外掛說明、工具說明）；對話內容、使用者資料一律不進索引。
/// - 品牌名與技術名詞不翻（送去翻前換成暫代字、翻完換回）；譯文寫回前換成台灣用語（09-25 實機：Apple 的繁中會把
///   「Desktop Commander」翻成「桌面指揮官」、Ping 翻成「砰」、Markdown 翻成「降價」，也常出現構建、訪問、計算機這類用詞）。
@MainActor
final class TranslationIndex: ObservableObject {
    static let shared = TranslationIndex()
    static let maxEntries = 6000
    static let maxLength = 4000
    /// 一次交給翻譯引擎的句數。
    static let batchSize = 40

    /// 固定用語（ChatGPT 外掛商店的類別、能力、介面詞）。
    static let glossary: [String: String] = [
        "Plugins": "外掛", "Plugin": "外掛", "Skills": "技能", "Read tools": "讀取工具", "Write tools": "寫入工具",
        "Interactive": "互動", "Write": "寫入", "Read": "讀取", "Search": "搜尋", "Sync": "同步",
        "Popular": "熱門", "Featured": "精選", "New & Noteworthy": "最新精選",
        "Productivity": "生產力", "Creativity": "創意", "Developer Tools": "開發工具", "Business & Operations": "商務與營運",
        "Data & Analytics": "資料與分析", "Communication": "溝通", "Education & Research": "教育與研究",
        "Scientific Research": "科學研究", "Security": "資安", "Finance": "金融", "Healthcare": "醫療保健",
        "Travel": "旅遊", "Entertainment": "娛樂", "Other": "其他", "Small Business": "小型企業", "Lifestyle": "生活",
        "Shopping": "購物", "Design": "設計", "Sales": "銷售", "Marketing": "行銷", "Education": "教育",
    ]

    /// 台灣用語：譯文寫回索引前換掉（只收在軟體與目錄文字裡意思不會變的詞）。
    static let taiwanTerms: [(String, String)] = [
        ("應用程序", "應用程式"), ("人工製品", "成品"), ("數據庫", "資料庫"), ("服務器", "伺服器"), ("聯結器", "連接器"),
        ("幻燈片", "簡報"), ("收件箱", "收件匣"), ("驅動器", "雲端硬碟"), ("計算機", "電腦"), ("構建", "建置"), ("訪問", "存取"),
        ("獲取", "取得"), ("配置", "設定"), ("影象", "影像"), ("視頻", "影片"), ("軟件", "軟體"), ("網絡", "網路"), ("默認", "預設"),
        ("文檔", "文件"), ("鏈接", "連結"), ("代碼", "程式碼"), ("郵箱", "信箱"), ("日曆", "行事曆"), ("搜索", "搜尋"), ("屏幕", "螢幕"),
        ("打印", "列印"), ("用戶", "使用者"), ("創建", "建立"), ("實時", "即時"), ("在線", "線上"), ("登錄", "登入"), ("界面", "介面"),
        ("硬盤", "硬碟"), ("內存", "記憶體"), ("緩存", "快取"), ("博客", "部落格"), ("短信", "簡訊"), ("質量", "品質"), ("賬", "帳"), ("令牌", "權杖"), ("身份", "身分"),
    ]
    /// 一律不翻的技術名詞（Apple 會把它們翻成別的意思）；各畫面另外可以帶品牌名（外掛名稱、開發者）。
    static let keepTerms = ["Markdown", "markdown", "whoami", "Ping", "ping", "repos", "repo", "Repo", "JSON", "URL", "PDF",
                            "CLI", "API", "MCP", "SDK", "OAuth", "Webhook", "webhook"]
    /// 索引格式版本：翻譯規則改了就加一，舊譯文重翻（索引只是快取，重翻不花額度）。
    static let schema = 2

    /// 已翻好的句子（原文 → 繁中）。
    @Published private(set) var entries: [String: String] = [:]
    /// `.translationTask` 靠這個值的變動啟動；型別放 Any 是因為 Translation 只在 macOS 15 以上有（跟 Browser 翻譯同一套）。
    @Published var configurationBox: Any?
    @Published private(set) var translating = false
    /// 翻不了的原因（系統沒有翻譯、語言包沒裝且使用者不下載…）；有值時就只顯示原文，不再排隊。
    @Published private(set) var unavailable: String?

    private var queue: [String] = []
    private var queued: Set<String> = []
    /// 每句要保護的品牌名（外掛名稱、開發者）。
    private var keeping: [String: [String]] = [:]
    /// 這次開 App 翻不好的句子（譯文是空的、暫代字被翻壞）：先顯示原文，不再排隊（不然畫面每次重畫都會再送一次）。
    private var rejected: Set<String> = []
    private var saveTask: Task<Void, Never>?
    private let fileURL: URL?

    init(fileURL: URL? = TranslationIndex.defaultFileURL) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["schema"] as? Int == Self.schema,
           let map = object["entries"] as? [String: String] {
            entries = map
        }
    }

    nonisolated static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TATWO OS/Translation/zh-Hant.json")
    }

    /// 畫面用：有譯文就回譯文；沒有就先回原文、排進翻譯（翻好畫面自己會更新）。
    /// keeping：這句裡不要翻的品牌名（例：外掛名稱、開發者）。
    func text(_ source: String, keeping terms: [String] = []) -> String {
        let key = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return source }
        if let fixed = Self.glossary[key] { return fixed }
        if let hit = entries[key] { return hit }
        enqueue(key, keeping: terms)
        return source
    }

    /// 只翻英文（中文、日文…原樣）；太長或沒有字母的不翻。短句（一兩個字）語言辨識不準：全是 ASCII 又有英文字母就當英文。
    static func needsTranslation(_ text: String) -> Bool {
        guard text.count <= maxLength, text.rangeOfCharacter(from: .letters) != nil else { return false }
        if text.unicodeScalars.allSatisfy(\.isASCII) {
            return text.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")) != nil
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage == .english
    }

    /// 送去翻之前：不翻的詞換成暫代字（Apple 不認得的字會原樣留下）。回傳送去翻的句子與暫代字對照。
    static func protect(_ text: String, keeping extra: [String]) -> (String, [(token: String, term: String)]) {
        var out = text
        var map: [(token: String, term: String)] = []
        let terms = (extra.filter { $0.count >= 2 } + keepTerms).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        for term in terms.sorted(by: { $0.count > $1.count }) {
            let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: term) + "(?![A-Za-z0-9])"
            guard out.range(of: pattern, options: .regularExpression) != nil else { continue }
            let token = "Zq\(map.count)Xv"
            out = out.replacingOccurrences(of: pattern, with: token, options: .regularExpression)
            map.append((token, term))
        }
        return (out, map)
    }

    /// 翻完之後：暫代字換回原詞、換成台灣用語；暫代字被翻壞（不見了）就不收這句（先顯示原文，下次再試）。
    static func restore(_ translated: String, _ map: [(token: String, term: String)]) -> String? {
        var out = translated
        for (token, term) in map {
            guard out.contains(token) else { return nil }
            out = out.replacingOccurrences(of: token, with: term)
        }
        return localize(out)
    }

    static func localize(_ text: String) -> String {
        taiwanTerms.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    private func enqueue(_ key: String, keeping terms: [String]) {
        guard unavailable == nil else { return }
        // 上次畫面關掉時沒翻完的還在佇列：再叫一次翻譯就好。
        if queued.contains(key) { Task { @MainActor [weak self] in self?.kick() }; return }
        guard !rejected.contains(key), Self.needsTranslation(key) else { return }
        queued.insert(key)
        queue.append(key)
        if !terms.isEmpty { keeping[key] = terms }
        // 畫面正在算版面時不能改 @Published：排到下一輪再啟動翻譯。
        Task { @MainActor [weak self] in self?.kick() }
    }

    private func kick() {
        guard !translating, !queue.isEmpty, unavailable == nil else { return }
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            translating = true
            if var config = configurationBox as? TranslationSession.Configuration {
                config.invalidate()
                configurationBox = config
            } else {
                configurationBox = TranslationSession.Configuration(source: Locale.Language(identifier: "en"),
                                                                    target: BrowserPageTranslator.targetLanguage)
            }
            return
        }
        #endif
        unavailable = "這個 macOS 版本沒有內建翻譯"
    }

    #if canImport(Translation)
    /// 由 `.translationTask` 呼叫：一批一批翻，翻好寫回索引；翻的時候又排進來的也一起翻完。
    @available(macOS 15.0, *)
    func run(_ session: TranslationSession) async {
        defer { translating = false }
        do {
            try await session.prepareTranslation()   // 語言包沒裝時，系統會自己問要不要下載
            while !queue.isEmpty {
                let batch = Array(queue.prefix(Self.batchSize))
                let protected = batch.map { Self.protect($0, keeping: keeping[$0] ?? []) }
                let requests = protected.enumerated().map { TranslationSession.Request(sourceText: $0.element.0, clientIdentifier: String($0.offset)) }
                let responses = try await session.translations(from: requests)
                for response in responses {
                    guard let index = response.clientIdentifier.flatMap(Int.init), batch.indices.contains(index) else { continue }
                    let target = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !target.isEmpty, let done = Self.restore(target, protected[index].1) {
                        entries[batch[index]] = done
                    } else {
                        rejected.insert(batch[index])
                    }
                }
                queue.removeFirst(min(batch.count, queue.count))
                batch.forEach { queued.remove($0); keeping[$0] = nil }
                scheduleSave()
            }
        } catch is CancellationError {
            // 畫面關掉了：還沒翻的留在佇列，下次打開再翻。
        } catch {
            unavailable = "翻譯暫時不能用：\(error.localizedDescription)"
            queue.removeAll()
            queued.removeAll()
            keeping.removeAll()
        }
    }
    #endif

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// 索引整份寫回一個 JSON（原子寫入）；超過上限（很少發生）時只留 maxEntries 句。
    private func save() {
        guard let fileURL else { return }
        var map = entries
        if map.count > Self.maxEntries {
            map = Dictionary(uniqueKeysWithValues: map.sorted { $0.key < $1.key }.suffix(Self.maxEntries).map { ($0.key, $0.value) })
            entries = map
        }
        let object: [String: Any] = ["schema": Self.schema, "target": "zh-Hant",
                                     "note": "TATWO OS 全域翻譯索引：只有公開的介面與目錄文字，沒有對話內容",
                                     "entries": map]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// 掛在要翻譯的畫面上：跑 `.translationTask`（Translation 要有畫面才拿得到翻譯引擎）。
struct TranslationIndexHost: ViewModifier {
    @ObservedObject var index = TranslationIndex.shared

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            content.translationTask(index.configurationBox as? TranslationSession.Configuration) { session in
                await index.run(session)
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
