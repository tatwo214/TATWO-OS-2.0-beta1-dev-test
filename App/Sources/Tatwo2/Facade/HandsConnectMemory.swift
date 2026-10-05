import Foundation

// W183 R12（.032 實機驗收：主導 12:00–12:15 陪使用者在 MacBook 實測私訊框的［連線］）：連線流程要跨重開 App 記住的兩件小事，只在這台、0600。
// - 使用者同意過的同意內容（主導 3：「ChatGPT 改了說明文字…使用者按了就等於他看過、同意這個版本：TATWO 代勾，並把這個版本（文字雜湊）
//   記進本機『使用者同意過的版本』。下次同一個版本就自動代勾」）：只記 HandsConsentOffer.digest（SHA-256），不記全文。
// - 按過「建立」、還沒查清楚的連接器（主導 5：「重連不要多建連接器…找到同一個 TATWO 連接器就沿用、繼續授權；不要再建第二個」）：
//   重開 App 之後也記得「上次按過建立」——清單裡找不到它時停下來講清楚，不再按第二次建立。只記帳號身分＋網址的雜湊，不記帳號。

/// 一個小的「雜湊＋時間」清單檔（最多 maxEntries 筆，最舊的先丟；讀不到＝空；存不進去＝照記憶體裡的）。
final class HandsConnectDigestBook: @unchecked Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var digest: String
        var at: Date
    }

    let url: URL
    let maxEntries: Int
    /// 多久以前的不算（nil＝一直算）。
    let lifetime: TimeInterval?
    private let lock = NSLock()
    private var cache: [Entry]?

    init(url: URL, maxEntries: Int = 32, lifetime: TimeInterval? = nil) {
        self.url = url
        self.maxEntries = maxEntries
        self.lifetime = lifetime
    }

    func contains(_ digest: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return live(now: now).contains { $0.digest == digest }
    }

    func insert(_ digest: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var list = live(now: now).filter { $0.digest != digest }
        list.append(Entry(digest: digest, at: now))
        if list.count > maxEntries { list.removeFirst(list.count - maxEntries) }
        save(list)
    }

    func remove(_ digest: String) {
        lock.lock(); defer { lock.unlock() }
        let list = load().filter { $0.digest != digest }
        save(list)
    }

    var entries: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    private func live(now: Date) -> [Entry] {
        let list = load()
        guard let lifetime else { return list }
        return list.filter { now.timeIntervalSince($0.at) < lifetime }
    }

    private func load() -> [Entry] {
        if let cache { return cache }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let list = HandsFiles.readSecure(url, limit: 64 * 1024).flatMap { try? decoder.decode([Entry].self, from: $0) } ?? []
        let kept = Array(list.filter { $0.digest.count <= 128 }.suffix(maxEntries))
        cache = kept
        return kept
    }

    private func save(_ list: [Entry]) {
        cache = list
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(list) { try? HandsFiles.writeAtomically(data, to: url) }
    }
}

/// W183 R12（主導 3）：使用者在 TATWO 卡片上看過、按了［同意並繼續］的同意內容（HandsConsentOffer.digest）。
enum HandsConsentApprovals {
    static let shared = HandsConnectDigestBook(url: HandsPaths.default.appDir.appendingPathComponent("connect-consent-approvals.json"), maxEntries: 16)
}

/// W183 R12（主導 5）：按過「建立」、還沒在清單裡找到的（帳號身分＋網址的雜湊）。7 天後不算（那時 ChatGPT 的清單早該看得到）。
enum HandsPendingCreates {
    static let shared = HandsConnectDigestBook(url: HandsPaths.default.appDir.appendingPathComponent("connect-pending-creates.json"),
                                               maxEntries: 16, lifetime: 7 * 24 * 3600)

    /// 流程的「帳號身分｜網址」→ 雜湊（不存帳號）。
    static func digest(_ createKey: String) -> String {
        HandsAuth.sha256Hex(Data(("tatwo-connect-pending|" + createKey).utf8))
    }
}
