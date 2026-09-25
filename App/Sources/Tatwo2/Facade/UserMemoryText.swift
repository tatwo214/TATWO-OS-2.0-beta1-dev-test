import Foundation

/// W163：使用者記憶的純文字規則。不碰檔案、不依賴其他型別，
/// tests/w163-memory.test.mjs 單獨編譯驗證。正本是入口 user.md（憲法 v4.1 §0 ③）。
enum UserMemoryText {
    /// 核准的新條目先放這一節，使用者之後可以在畫布裡搬到合適的段落。
    static let inboxHeading = "## 最近記住"

    /// 聊天裡的「記住…」：回傳要記的內容；不是記憶指令回 nil。
    static func rememberRequest(in message: String) -> String? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["請記住", "幫我記住", "記住", "記得", "remember:", "Remember:"] where text.hasPrefix(prefix) {
            var rest = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            while let first = rest.first, "：:，,。 ".contains(first) { rest = String(rest.dropFirst()) }
            rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            return rest.isEmpty ? nil : String(rest.prefix(400))
        }
        return nil
    }

    /// 一條記憶的正規化形式，用來判斷重複（去空白、去句尾標點、忽略大小寫）。
    static func normalized(_ text: String) -> String {
        var t = text.lowercased().components(separatedBy: .whitespacesAndNewlines).joined()
        while let last = t.last, "。.！!；;".contains(last) { t.removeLast() }
        return t
    }

    /// user.md 已經有同一句（不管在哪一節、有沒有〔公開〕標記）就算重複。
    static func contains(_ text: String, in userMarkdown: String) -> Bool {
        let target = normalized(text)
        guard !target.isEmpty else { return true }
        return userMarkdown.components(separatedBy: "\n").contains { line in
            var body = line.trimmingCharacters(in: .whitespaces)
            guard body.hasPrefix("- ") else { return false }
            body = String(body.dropFirst(2)).replacingOccurrences(of: "〔公開〕", with: "")
            return normalized(body) == target
        }
    }

    /// 把一條核准的記憶加進 user.md 的「最近記住」一節（沒有就建在檔尾）。公開條目加〔公開〕。
    static func append(_ text: String, isPublic: Bool, to userMarkdown: String) -> String {
        let line = "- " + text.trimmingCharacters(in: .whitespacesAndNewlines) + (isPublic ? "〔公開〕" : "")
        var lines = userMarkdown.components(separatedBy: "\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        if let start = lines.firstIndex(of: inboxHeading) {
            var end = start + 1
            while end < lines.count, !lines[end].hasPrefix("## ") { end += 1 }
            var insert = end
            while insert > start + 1, lines[insert - 1].trimmingCharacters(in: .whitespaces).isEmpty { insert -= 1 }
            lines.insert(line, at: insert)
        } else {
            lines += ["", inboxHeading, line]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Claude 自動記憶檔（frontmatter 有 type: user 或 feedback）取出「description」當提案文字。
    static func claudeMemoryCandidate(_ file: String) -> String? {
        guard file.hasPrefix("---\n"), let end = file.range(of: "\n---", range: file.index(file.startIndex, offsetBy: 4)..<file.endIndex) else { return nil }
        let front = file[file.index(file.startIndex, offsetBy: 4)..<end.lowerBound]
        var type = "", description = ""
        for raw in front.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("type:") { type = line.dropFirst(5).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("description:") { description = line.dropFirst(12).trimmingCharacters(in: .whitespaces) }
        }
        guard ["user", "feedback"].contains(type), !description.isEmpty else { return nil }
        return String(description.prefix(400))
    }
}
