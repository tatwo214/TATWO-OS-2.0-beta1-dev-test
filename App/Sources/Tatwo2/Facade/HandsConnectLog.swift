import Foundation

// W183 R12（.033 實機 09-30 13:45–13:52：連線又失敗、使用者「按半天根本不知道在幹嘛」；正式版查不到任何紀錄——HandsConnectFlow.log 只在 DEBUG）：
// 正式版的連線紀錄。
// - 每一步一行：時間、這次嘗試的代號（attempt 的前 8 碼）、步驟、動作、結果或錯誤碼（流程的卡片、進度、Pod 指令的結果、第幾次按）。
// - 對不上的時候（說明對不上、按鈕過期 press_stale、找不到節點、表單讀回不對）多一段 Pod 頁的結構快照（DOM 文字，不是截圖；16 KB 內）。
// - 存在 Hands 的 app 資料夾（connect-log.txt，0600）；超過 maxBytes 就只留最後 keepBytes（整行為單位）。
// - 不寫：帳號原文（信箱）、token、配對碼、網址的查詢字串與片段——寫進去之前一律過 scrub（呼叫的地方本來就不傳這些；scrub 是第二道）。
// - App 內讀最後 200 行：tail(200)（hands_setup_status 的 connect_log；主導也可以直接讀檔）。
final class HandsConnectLog: @unchecked Sendable {
    static let shared = HandsConnectLog(url: HandsPaths.default.appDir.appendingPathComponent("connect-log.txt"))

    let url: URL
    let maxBytes: Int
    let keepBytes: Int
    /// 結構快照一段最多多長（腳本已經截在 16 KB；這裡再守一次）。
    static let maxStructure = 16 * 1024
    /// 一般的一行最多多長。
    static let maxLine = 2048
    private let lock = NSLock()
    private var attempt = "-"
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    init(url: URL, maxBytes: Int = 512 * 1024, keepBytes: Int = 256 * 1024) {
        self.url = url
        self.maxBytes = maxBytes
        self.keepBytes = keepBytes
    }

    /// 這次嘗試的代號（流程開始、換一次嘗試時設；nil＝沒有進行中的嘗試）。
    func begin(attempt id: UUID?) {
        lock.lock(); attempt = id.map { String($0.uuidString.prefix(8)).lowercased() } ?? "-"; lock.unlock()
    }

    var attemptCode: String { lock.lock(); defer { lock.unlock() }; return attempt }

    /// 寫一行：步驟（短代號）＋內容（白話或代碼）。
    func write(_ step: String, _ detail: String) {
        let clean = Self.oneLine(Self.scrub(detail), limit: Self.maxLine)
        append("\(stamp())\t\(attemptCode)\t\(Self.oneLine(step, limit: 40))\t\(clean)")
    }

    /// 結構快照（多行的樹：換行寫成 ⏎，整段一行；16 KB 內）。
    func structure(_ step: String, _ label: String, _ outline: String) {
        let clean = Self.oneLine(Self.scrub(String(outline.prefix(Self.maxStructure))), limit: Self.maxStructure + 64)
        append("\(stamp())\t\(attemptCode)\t\(Self.oneLine(step, limit: 40))\t\(Self.oneLine(label, limit: 200)) ⟦\(clean)⟧")
    }

    /// 最後 count 行（舊到新）；maxTotal＝總長上限（超過就從舊的那一頭少拿幾行）。
    func tail(_ count: Int = 200, maxTotal: Int = .max) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(max(0, count)).map(String.init))
        var total = lines.reduce(0) { $0 + $1.utf8.count }
        while total > maxTotal, !lines.isEmpty { total -= lines.removeFirst().utf8.count }
        return lines
    }

    // MARK: - 內部

    private func stamp() -> String { formatter.string(from: Date()) }

    private func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: folder.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard let bytes = (line + "\n").data(using: .utf8) else { return }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        // 捷徑、不是一般檔案＝不寫（不跟著捷徑寫到別處）。
        if let type = try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType, type != .typeRegular { return }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: bytes)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > maxBytes {
            rotate()
        }
    }

    /// 只留最後 keepBytes（從一行的開頭算）。
    private func rotate() {
        guard let data = try? Data(contentsOf: url), data.count > keepBytes else { return }
        var tail = data.suffix(keepBytes)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) { tail = tail[tail.index(after: newline)...] }
        try? HandsFiles.writeAtomically(Data(tail), to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 一行：換行、tab 寫成可見的記號；太長截掉。
    static func oneLine(_ text: String, limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\r\n", with: "⏎").replacingOccurrences(of: "\n", with: "⏎")
            .replacingOccurrences(of: "\r", with: "⏎").replacingOccurrences(of: "\t", with: " ")
        let clipped = flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
        return String(clipped.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
    }

    /// 第二道：帳號區與名稱、信箱、Bearer／長 token、網址的查詢字串與片段、看起來像 8 碼配對碼的字，一律遮掉。
    static func scrub(_ text: String) -> String {
        var out = text
        let rules: [(String, String)] = [
            (#"(?im)^([ ]*)(?:section|div)[^\n]*\n\1 +[^\n]*"(?:connected accounts|accounts|已連線帳號|已連接帳號|連線帳號|帳號)"[^\n]*(?:\n\1 +[^\n]*)*"#, "$1(account)"),
            (#"(?im)^[^\n]*(?:account(?:[_ -]?name)?|帳號(?:名稱)?)\s*[:=][^\n]*"#, "(account)"),
            (#"(?im)^[^\n]*['’]s [^\n]* account[^\n]*"#, "(account)"),
            (#"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer <token>"),
            (#"(https?://[^\s?#⟦⟧"']+)[?#][^\s⟦⟧"']*"#, "$1?<…>"),
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
            (#"[A-Za-z0-9_\-]{32,}"#, "<token>"),
            (#"\b[A-HJ-NP-Z2-9]{4}[ -]?[A-HJ-NP-Z2-9]{4}\b"#, "<code>"),
        ]
        for (pattern, template) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }
}
