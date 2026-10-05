import Foundation

/// W180 E1：一條記憶檔（入口 memory/ 底下一個 Markdown）的開頭欄位。純邏輯，只用 Foundation（node 測試單獨編譯這支檔）。
/// 認得三種寫法（09-26 實查 217 檔）：`metadata:` 底下縮排寫 type（大多數）、最上層直接寫 `type:`、完全沒有開頭欄位。
/// 另讀 aliases（別名／主題）、scope（範圍，只存不顯示）、subject、level、source、conflict、created（記下的時間）；兩種位置都認，metadata 優先。
/// 寫回時只改有變的鍵，不認得的鍵與註解原樣保留；沒變的檔一個位元組都不動（呼叫端不寫就好）。
struct TatwoMemoryFile: Equatable, Sendable {
    /// 放在 metadata 底下的欄位（寫新檔時也放這裡）。
    static let managedKeys = ["type", "aliases", "scope", "subject", "level", "source", "conflict", "created"]

    var name: String?
    var description: String?
    var type: String?
    var aliases: [String] = []
    var scope: String?
    var subject: String?
    var level: String?
    var source: String?
    var conflict: String?
    /// 記下的時間（ISO 8601；memory_save 寫；「最近 7 天記下的」看這個）。
    var created: String?
    /// 開頭欄位之後的全部文字（原樣，含開頭欄位下面那行空行）。
    var body: String
    /// 原本兩條 `---` 之間的行（不含 `---`）；nil＝原本沒有開頭欄位。
    let frontmatterLines: [String]?
    /// 解析當下的值：寫回時跟現在比，沒變的鍵不動。
    private var parsed: Fields?

    private struct Fields: Equatable, Sendable {
        var name: String?
        var description: String?
        var managed: [String: Value]
    }

    enum Value: Equatable, Sendable {
        case scalar(String)
        case list([String])
    }

    // MARK: - 建新檔

    init(name: String?, description: String?, type: String?, aliases: [String] = [], scope: String? = nil,
         subject: String? = nil, level: String? = nil, source: String? = nil, conflict: String? = nil, created: String? = nil,
         content: String) {
        self.name = name
        self.description = description
        self.type = type
        self.aliases = aliases
        self.scope = scope
        self.subject = subject
        self.level = level
        self.source = source
        self.conflict = conflict
        self.created = created
        self.body = "\n" + content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        self.frontmatterLines = nil
        self.parsed = nil
    }

    private init(frontmatter: [String]?, body: String, top: [String: Value], meta: [String: Value]) {
        func scalar(_ value: Value?) -> String? {
            switch value {
            case .scalar(let text)?: return text
            case .list(let items)?: return items.joined(separator: ", ")
            case nil: return nil
            }
        }
        func pick(_ key: String) -> Value? { meta[key] ?? top[key] }
        self.frontmatterLines = frontmatter
        self.body = body
        self.name = scalar(top["name"])
        self.description = scalar(top["description"])
        self.type = scalar(pick("type"))
        switch pick("aliases") {
        case .list(let items)?: self.aliases = items
        case .scalar(let text)?: self.aliases = Self.parseList(text)
        case nil: self.aliases = []
        }
        self.scope = scalar(pick("scope"))
        self.subject = scalar(pick("subject"))
        self.level = scalar(pick("level"))
        self.source = scalar(pick("source"))
        self.conflict = scalar(pick("conflict"))
        self.created = scalar(pick("created"))
        self.parsed = nil
        self.parsed = fields
    }

    private var fields: Fields {
        var managed: [String: Value] = [:]
        for key in Self.managedKeys {
            if let value = managedValue(key) { managed[key] = value }
        }
        return Fields(name: name.flatMap(Self.nonEmpty), description: description.flatMap(Self.nonEmpty), managed: managed)
    }

    private func managedValue(_ key: String) -> Value? {
        switch key {
        case "aliases":
            let items = aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return items.isEmpty ? nil : .list(items)
        case "type": return type.flatMap(Self.nonEmpty).map(Value.scalar)
        case "scope": return scope.flatMap(Self.nonEmpty).map(Value.scalar)
        case "subject": return subject.flatMap(Self.nonEmpty).map(Value.scalar)
        case "level": return level.flatMap(Self.nonEmpty).map(Value.scalar)
        case "source": return source.flatMap(Self.nonEmpty).map(Value.scalar)
        case "conflict": return conflict.flatMap(Self.nonEmpty).map(Value.scalar)
        case "created": return created.flatMap(Self.nonEmpty).map(Value.scalar)
        default: return nil
        }
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 讀

    /// 內文（去掉頭尾空白）。
    var content: String { body.trimmingCharacters(in: .whitespacesAndNewlines) }

    mutating func setContent(_ text: String) {
        body = "\n" + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// E1b 的衝突副本（同一條兩邊都改，副設備那版另存並標 conflict）。
    var isConflictCopy: Bool {
        guard let value = conflict?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else { return false }
        return !["false", "no", "0", "none"].contains(value)
    }

    /// 給人看的標題：name 是人話就用 name；是 Claude 那種英文代號（全小寫、連字號）就用 description；都沒有用檔名。
    func displayTitle(fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        let name = self.name.flatMap(Self.nonEmpty)
        if let name, !Self.looksLikeSlug(name) { return String(name.prefix(80)) }
        if let description = description.flatMap(Self.nonEmpty) { return String(description.prefix(80)) }
        return name ?? stem
    }

    static func looksLikeSlug(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "_" || scalar == "."
        }
    }

    /// created 的寫法：`2026-09-27T04:29:47Z`（memory_save 寫的）或 `2026-09-27`。
    static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let date = full.date(from: trimmed) { return date }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return day.date(from: trimmed)
    }

    static func parse(_ text: String) -> TatwoMemoryFile {
        let lines = text.components(separatedBy: "\n")
        func plain() -> TatwoMemoryFile { TatwoMemoryFile(frontmatter: nil, body: text, top: [:], meta: [:]) }
        guard let first = lines.first, strip(first).trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.indices.dropFirst().first(where: { strip(lines[$0]).trimmingCharacters(in: .whitespaces) == "---" })
        else { return plain() }
        let frontmatter = lines[1..<close].map(strip)
        let body = lines[(close + 1)...].joined(separator: "\n")
        var top: [String: Value] = [:]
        var meta: [String: Value] = [:]
        var index = 0
        while index < frontmatter.count {
            let line = frontmatter[index]
            guard !isIndented(line), let (key, value) = keyValue(line) else { index += 1; continue }
            let block = continuation(frontmatter, after: index)
            if key == "metadata", value.isEmpty {
                meta = nested(Array(frontmatter[block]))
            } else if top[key] == nil {
                top[key] = Self.value(value, children: Array(frontmatter[block]))
            }
            index = block.upperBound
        }
        return TatwoMemoryFile(frontmatter: frontmatter, body: body, top: top, meta: meta)
    }

    // MARK: - 寫

    /// 整份檔案的文字。原本有開頭欄位的：只改有變的鍵，其他行原樣；原本沒有的：補一份。
    func rendered() -> String {
        let now = fields
        guard var lines = frontmatterLines, let before = parsed else {
            // 原本沒有開頭欄位：補一份，內文前面空一行。
            return "---\n" + freshFrontmatter(now).joined(separator: "\n") + "\n---\n" + (body.hasPrefix("\n") ? body : "\n" + body)
        }
        if before.name != now.name { lines = Self.setTop(lines, key: "name", line: now.name.map { "name: " + Self.encodeScalar($0) }) }
        if before.description != now.description {
            lines = Self.setTop(lines, key: "description", line: now.description.map { "description: " + Self.encodeScalar($0) })
        }
        for key in Self.managedKeys where before.managed[key] != now.managed[key] {
            lines = Self.setManaged(lines, key: key, value: now.managed[key].map(Self.encode))
        }
        return "---\n" + lines.joined(separator: "\n") + "\n---\n" + body
    }

    private func freshFrontmatter(_ now: Fields) -> [String] {
        var lines: [String] = []
        if let name = now.name { lines.append("name: " + Self.encodeScalar(name)) }
        if let description = now.description { lines.append("description: " + Self.encodeScalar(description)) }
        let managed = Self.managedKeys.compactMap { key in now.managed[key].map { "  \(key): " + Self.encode($0) } }
        if !managed.isEmpty { lines.append("metadata:"); lines += managed }
        return lines
    }

    private static func encode(_ value: Value) -> String {
        switch value {
        case .scalar(let text): return encodeScalar(text)
        case .list(let items): return encodeList(items)
        }
    }

    // MARK: - 開頭欄位的小工具

    static func strip(_ line: String) -> String { line.hasSuffix("\r") ? String(line.dropLast()) : line }

    static func isIndented(_ line: String) -> Bool { line.hasPrefix(" ") || line.hasPrefix("\t") }

    static func keyValue(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("- "), trimmed != "-",
              let colon = trimmed.firstIndex(of: ":") else { return nil }
        let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(" ") else { return nil }
        let rest = trimmed[trimmed.index(after: colon)...]
        // `key:value`（沒有空白）不是 YAML 的鍵值；只認冒號後面是空白或行尾。
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        return (key, rest.trimmingCharacters(in: .whitespaces))
    }

    /// 一個鍵底下接著的縮排行（到下一個不縮排的行或空行為止）。
    static func continuation(_ lines: [String], after index: Int) -> Range<Int> {
        var end = index + 1
        while end < lines.count, isIndented(lines[end]), !lines[end].trimmingCharacters(in: .whitespaces).isEmpty { end += 1 }
        return (index + 1)..<end
    }

    private static func indentWidth(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    /// metadata 底下某個鍵佔到哪一行為止：縮排更深的行，加上同一層、緊接著的 `- x` 清單項。
    private static func childEnd(_ lines: [String], key index: Int, limit: Int) -> Int {
        let width = indentWidth(lines[index])
        var end = index + 1
        while end < limit {
            let line = lines[end]
            let deeper = indentWidth(line) > width
            let sameLevelItem = indentWidth(line) == width && line.trimmingCharacters(in: .whitespaces).hasPrefix("- ")
            guard deeper || sameLevelItem else { break }
            end += 1
        }
        return end
    }

    /// metadata 底下那一段：`  key: value`，清單項 `    - x` 算前一個鍵的。
    private static func nested(_ lines: [String]) -> [String: Value] {
        var result: [String: Value] = [:]
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard let (key, value) = keyValue(line) else { index += 1; continue }
            let end = childEnd(lines, key: index, limit: lines.count)
            if result[key] == nil { result[key] = self.value(value, children: Array(lines[(index + 1)..<end])) }
            index = end
        }
        return result
    }

    private static func value(_ raw: String, children: [String]) -> Value {
        let items = children.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if raw.isEmpty, !items.isEmpty, items.allSatisfy({ $0.hasPrefix("- ") || $0 == "-" }) {
            return .list(items.map { decodeScalar(String($0.dropFirst()).trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty })
        }
        if raw == "|" || raw == ">" || raw == "|-" || raw == ">-" {
            return .scalar(items.joined(separator: raw.hasPrefix("|") ? "\n" : " "))
        }
        if raw.hasPrefix("["), raw.hasSuffix("]") { return .list(parseList(raw)) }
        return .scalar(decodeScalar(raw))
    }

    static func decodeScalar(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { return text }
        if text.hasPrefix("\""), text.hasSuffix("\"") {
            var out = ""
            var escaped = false
            for character in text.dropFirst().dropLast() {
                if escaped {
                    switch character {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(character)
                    }
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else {
                    out.append(character)
                }
            }
            return out
        }
        if text.hasPrefix("'"), text.hasSuffix("'") {
            return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return text
    }

    static func encodeScalar(_ value: String) -> String {
        let text = value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        guard let first = text.first else { return "\"\"" }
        let reserved = ["true", "false", "null", "yes", "no", "on", "off", "~"]
        let needsQuotes = "[]{}&*!|>'\"%@`#,?:-".contains(first)
            || text.contains(": ") || text.contains(" #") || text.hasSuffix(":")
            || text != text.trimmingCharacters(in: .whitespaces)
            || reserved.contains(text.lowercased()) || Double(text) != nil
        guard needsQuotes else { return text }
        return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `[a, b]`、`a、b、c`、`a，b` 都認。
    static func parseList(_ raw: String) -> [String] {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("["), text.hasSuffix("]") {
            var items: [String] = []
            var current = ""
            var quote: Character?
            for character in text.dropFirst().dropLast() {
                if let open = quote {
                    current.append(character)
                    if character == open { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                    current.append(character)
                } else if character == "," {
                    items.append(current)
                    current = ""
                } else {
                    current.append(character)
                }
            }
            items.append(current)
            return items.map { decodeScalar($0) }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return text.components(separatedBy: CharacterSet(charactersIn: ",、，；;"))
            .map { decodeScalar($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func encodeList(_ items: [String]) -> String {
        "[" + items.map { item -> String in
            let text = item.replacingOccurrences(of: "\n", with: " ")
            let plain = !text.isEmpty && text == text.trimmingCharacters(in: .whitespaces)
                && !text.contains(where: { ",[]{}\"':#&*!|>%@`".contains($0) })
                && !["-", "?"].contains(String(text.first!))
            return plain ? text : "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }.joined(separator: ", ") + "]"
    }

    // MARK: - 改行

    private static func topRange(_ lines: [String], key: String) -> Range<Int>? {
        for index in lines.indices where !isIndented(lines[index]) {
            if let (found, _) = keyValue(lines[index]), found == key {
                return index..<continuation(lines, after: index).upperBound
            }
        }
        return nil
    }

    private static func setTop(_ lines: [String], key: String, line: String?) -> [String] {
        var lines = lines
        if let range = topRange(lines, key: key) {
            lines.replaceSubrange(range, with: line.map { [$0] } ?? [])
            return lines
        }
        guard let line else { return lines }
        // 新加的 name 放最前面；description 放在 name 後面。
        let at = key == "description" ? (topRange(lines, key: "name")?.upperBound ?? 0) : 0
        lines.insert(line, at: at)
        return lines
    }

    private static func setManaged(_ lines: [String], key: String, value: String?) -> [String] {
        var lines = lines
        if let meta = topRange(lines, key: "metadata") {
            let children = (meta.lowerBound + 1)..<meta.upperBound
            for index in children {
                guard let (found, _) = keyValue(lines[index]), found == key else { continue }
                let width = indentWidth(lines[index])
                let end = childEnd(lines, key: index, limit: meta.upperBound)
                let indent = String(lines[index].prefix(width))
                lines.replaceSubrange(index..<end, with: value.map { [indent + key + ": " + $0] } ?? [])
                return lines
            }
        }
        if let range = topRange(lines, key: key) {
            lines.replaceSubrange(range, with: value.map { [key + ": " + $0] } ?? [])
            return lines
        }
        guard let value else { return lines }
        if let meta = topRange(lines, key: "metadata") {
            let indent = meta.count > 1 ? String(lines[meta.lowerBound + 1].prefix(indentWidth(lines[meta.lowerBound + 1]))) : "  "
            lines.insert(indent + key + ": " + value, at: meta.upperBound)
        } else {
            lines += ["metadata:", "  " + key + ": " + value]
        }
        return lines
    }
}
