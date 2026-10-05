import Foundation

/// W180 E1b：入口 memory/ 主副自動同步的合併規則（純邏輯，只用 Foundation，node 測試單獨編譯這支檔）。
/// 一律用「主設備版／副設備版」描述，不用 ours／theirs：副設備合併主設備的、主設備收副設備的，兩邊算出來的樹一樣。
/// - 同一檔兩邊都改：主設備版留原名，副設備版另存 `<名>--<設備>-<日期>.<副檔名>`，Markdown 在開頭欄位標 `conflict`。
/// - 一邊刪、一邊改：留改過的那版（不因為同步少掉內容）。
/// - 索引與說明（MEMORY.md、MEMORY-*.md、README.md、.gitignore）是清單：兩邊的行都留，以主設備的順序為主。
/// - 另一邊送來的樹只准一般檔：連結檔、子模組、memory/ 以外的路徑（`..`、`.git`）一律拒收。
/// - macOS 檔名不分大小寫：只差大小寫的同一個檔兩版都留；資料夾只差大小寫、檔和資料夾同名就停下來說清楚（W180 E1b 審查）。
/// - 一次要從這台拿掉很多檔（像整個資料夾被清空）先不套用，等使用者確認；拿掉的檔先封存（W180 E1b 審查）。
enum TatwoMemorySyncMerge {
    struct Entry: Equatable, Sendable {
        var mode: String
        var id: String
    }

    enum Resolution: Equatable, Sendable {
        /// 用這一版；nil＝合起來是刪掉（只在另一邊沒改、這邊刪的時候）。
        case take(Entry?)
        /// 清單類檔：兩邊的行都留。
        case union
        /// 主設備版留原名，副設備版另存一份並標 conflict。
        case both
    }

    struct TreeEntry: Equatable, Sendable {
        var mode: String
        var type: String
        var id: String
        var size: Int?
        var path: String
    }

    static let maxFileBytes = 8 << 20
    static let maxEntries = 20_000

    // MARK: 刪除太多先不套用

    /// 一次合併要從這台拿掉的檔：超過 10 個，或 3 個以上而且超過原本的兩成，就先不套用、等使用者在狀態列確認。
    static func massRemoval(removed: Int, total: Int) -> Bool {
        removed > 10 || (removed >= 3 && removed * 5 > total)
    }

    /// before 有、after 沒有的路徑（macOS 只差大小寫的算同一個檔，不算拿掉）。
    static func removed(from before: [String], to after: [String]) -> [String] {
        let kept = Set(after.map(pathKey))
        return before.filter { !kept.contains(pathKey($0)) }.sorted()
    }

    // MARK: macOS 的檔名（不分大小寫）

    /// macOS 當成同一個名字的比較用：不分大小寫、忽略看不見的字、組合字一律 NFC。
    static func pathKey(_ path: String) -> String {
        folded(path.precomposedStringWithCanonicalMapping)
    }

    /// 只差大小寫（macOS 會當成同一個檔）的幾組路徑；每組照字典序。
    static func caseGroups(_ paths: [String]) -> [[String]] {
        Dictionary(grouping: paths, by: pathKey).values.filter { $0.count > 1 }.map { $0.sorted() }
            .sorted { $0[0] < $1[0] }
    }

    /// 放進 macOS 工作樹會出事的排法（git 會默默丟掉一邊）：資料夾只差大小寫、同名的檔和資料夾。回一句原因，nil＝可以。
    static func layoutProblem(_ paths: [String]) -> String? {
        var folders: [String: String] = [:]
        for path in paths.sorted() {
            var prefix = ""
            for part in path.split(separator: "/", omittingEmptySubsequences: false).dropLast() {
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + String(part)
                let key = pathKey(prefix)
                if let seen = folders[key], seen != prefix {
                    return "有只差大小寫的資料夾：\(display(seen))／\(display(prefix))"
                }
                folders[key] = prefix
            }
        }
        for path in paths.sorted() where folders[pathKey(path)] != nil {
            return "有同名的檔和資料夾：\(display(path))"
        }
        return nil
    }

    /// 合併會改到、這台卻有沒收進 git 的改動（改過沒 commit、新檔、被忽略的檔）的路徑：`git merge --ff-only` 會因為它們停下來。
    /// dirty 是 `git status --porcelain -z --ignored` 的路徑，資料夾以 `/` 結尾。
    static func blocking(changed: [String], dirty: [String]) -> [String] {
        let files = Set(dirty.filter { !$0.hasSuffix("/") }.map(pathKey))
        let folders = dirty.filter { $0.hasSuffix("/") }.map(pathKey)
        let dirtyKeys = dirty.map(pathKey)
        return changed.filter { path in
            let key = pathKey(path)
            return files.contains(key) || folders.contains { key.hasPrefix($0) }
                || dirtyKeys.contains { $0.hasPrefix(key + "/") }
        }
    }

    /// 給狀態列看的幾個檔名：`a.md、b.md 等 5 個`。
    static func names(_ paths: [String]) -> String {
        let shown = paths.prefix(2).map(display).joined(separator: "、")
        return paths.count > 2 ? shown + " 等 \(paths.count) 個" : shown
    }

    /// 封存時同名已經有了：`a/b-2.md`、`a/b-3.md`。
    static func numbered(_ path: String, _ n: Int) -> String {
        let slash = path.lastIndex(of: "/")
        let directory = slash.map { String(path[...$0]) } ?? ""
        let name = slash.map { String(path[path.index(after: $0)...]) } ?? path
        if let dot = name.lastIndex(of: "."), dot > name.startIndex {
            return directory + String(name[..<dot]) + "-\(n)" + String(name[dot...])
        }
        return directory + name + "-\(n)"
    }

    // MARK: git cat-file --batch 的輸出

    struct BatchObject: Equatable, Sendable {
        var id: String
        var type: String
        var size: Int
        var data: Data
    }

    /// `git cat-file --batch`（withContent＝true）或 `--batch-check` 的輸出。讀不懂或有物件不見就回 nil（當作不安全）。
    static func parseBatch(_ data: Data, withContent: Bool) -> [BatchObject]? {
        var objects: [BatchObject] = []
        var index = data.startIndex
        while index < data.endIndex {
            guard let newline = data[index...].firstIndex(of: 0x0A) else { return nil }
            let header = String(decoding: data[index..<newline], as: UTF8.self).split(separator: " ").map(String.init)
            index = data.index(after: newline)
            guard header.count == 3, let size = Int(header[2]), size >= 0 else { return nil }
            var content = Data()
            if withContent {
                guard data.distance(from: index, to: data.endIndex) >= size + 1 else { return nil }
                let end = data.index(index, offsetBy: size)
                guard data[end] == 0x0A else { return nil }
                content = Data(data[index..<end])
                index = data.index(after: end)
            }
            objects.append(BatchObject(id: header[0], type: header[1], size: size, data: content))
        }
        return objects
    }

    // MARK: 每個路徑怎麼合

    static func resolve(base: Entry?, primary: Entry?, secondary: Entry?, path: String) -> Resolution {
        if primary == secondary { return .take(primary) }
        if let primary, let secondary, primary.id == secondary.id { return .take(primary) }
        if base == primary { return .take(secondary) }
        if base == secondary { return .take(primary) }
        // 兩邊都改過而且不一樣。
        guard primary != nil else { return .take(secondary) }
        guard secondary != nil else { return .take(primary) }
        return isLineList(path) ? .union : .both
    }

    /// 索引、說明、忽略清單：一行一件事，兩邊加的行都留。
    static func isLineList(_ path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        if name == ".gitignore" { return true }
        guard !path.contains("/") else { return false }
        return name == "MEMORY.md" || name == "README.md" || (name.hasPrefix("MEMORY-") && name.hasSuffix(".md"))
    }

    // MARK: 清單類檔：兩邊的行都留

    /// 主設備的行為底；副設備刪掉的行（原本只出現一次）拿掉；副設備新加的行插在它前一行後面（找不到就接在最後）。
    /// 空白行不搬、重複的行不再加。只看 (base, 主設備, 副設備)，兩邊算出來一樣。
    static func unionLines(base: String?, primary: String, secondary: String) -> String {
        func lines(_ text: String) -> [String] {
            var parts = text.components(separatedBy: "\n")
            if parts.last == "" { parts.removeLast() }
            return parts
        }
        func blank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let baseLines = lines(base ?? ""), primaryLines = lines(primary), secondaryLines = lines(secondary)
        var baseCounts: [String: Int] = [:]
        for line in baseLines where !blank(line) { baseCounts[line, default: 0] += 1 }
        let secondarySet = Set(secondaryLines)
        let dropped = Set(baseCounts.filter { $0.value == 1 && !secondarySet.contains($0.key) }.keys)
        var result = primaryLines.filter { !dropped.contains($0) }
        var present = Set(result)
        var cursor = result.count
        for line in secondaryLines {
            if present.contains(line) {
                if !blank(line), let index = result.firstIndex(of: line) { cursor = index + 1 }
                continue
            }
            guard !blank(line), baseCounts[line] == nil else { continue }
            let at = min(cursor, result.count)
            result.insert(line, at: at)
            cursor = at + 1
            present.insert(line)
        }
        guard !result.isEmpty else { return "" }
        let trailing = primary.isEmpty ? secondary.hasSuffix("\n") : primary.hasSuffix("\n")
        return result.joined(separator: "\n") + (trailing ? "\n" : "")
    }

    // MARK: 衝突副本

    /// `<名>--<設備>-<日期>.<副檔名>`；同名（不分大小寫）已經有了就加 -2、-3。
    static func copyPath(for path: String, label: String, day: String, taken: Set<String>) -> String {
        let slash = path.lastIndex(of: "/")
        let directory = slash.map { String(path[...$0]) } ?? ""
        let name = slash.map { String(path[path.index(after: $0)...]) } ?? path
        var stem = name, ext = ""
        if let dot = name.lastIndex(of: "."), dot > name.startIndex {
            stem = String(name[..<dot])
            ext = String(name[dot...])
        }
        let safeLabel = label.isEmpty ? "device" : label
        let base = directory + stem + "--" + safeLabel + "-" + day
        let folded = Set(taken.map { $0.lowercased() })
        var candidate = base + ext
        var n = 2
        while folded.contains(candidate.lowercased()) {
            candidate = base + "-\(n)" + ext
            n += 1
        }
        return candidate
    }

    /// 衝突副本的名字（給狀態列數「兩版並存」幾條）：`…--<設備>-<8 位日期>[-n][.副檔名]`。
    static func isConflictCopy(_ path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name.range(of: #"^.+--.+-[0-9]{8}(-[0-9]+)?(\.[^.]+)?$"#, options: .regularExpression) != nil
    }

    /// Markdown 在開頭欄位加一行 `conflict: "<原檔名>"`（沒有開頭欄位就補一段）；已經標過或不是 UTF-8 就原樣。
    /// 內容只跟原檔名與副設備那版有關（不帶日期、設備），同一版另存過就認得出來、不會再產生一份。
    static func markConflict(_ data: Data, path: String) -> Data {
        guard path.lowercased().hasSuffix(".md"), let text = String(data: data, encoding: .utf8) else { return data }
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let marker = "conflict: \"" + escaped + "\""
        var lines = text.components(separatedBy: "\n")
        let newline = lines.first?.hasSuffix("\r") == true ? "\r" : ""
        if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
            for line in lines.dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed == "---" { break }
                if line.hasPrefix("conflict:") { return data }
            }
            lines.insert(marker + newline, at: 1)
            return Data(lines.joined(separator: "\n").utf8)
        }
        return Data(("---" + newline + "\n" + marker + newline + "\n---" + newline + "\n\n" + text).utf8)
    }

    // MARK: 送來的樹只准一般檔

    /// `git ls-tree -r -z -l --full-tree <commit>` 的輸出。讀不懂就回 nil（當作不安全）。
    static func parseTree(_ data: Data) -> [TreeEntry]? {
        var entries: [TreeEntry] = []
        for record in data.split(separator: 0, omittingEmptySubsequences: true) {
            guard let tab = record.firstIndex(of: 0x09) else { return nil }
            let meta = String(decoding: record[record.startIndex..<tab], as: UTF8.self)
            guard let path = String(data: Data(record[record.index(after: tab)...]), encoding: .utf8) else { return nil }
            let fields = meta.split(whereSeparator: { $0 == " " }).map(String.init)
            guard fields.count == 4 else { return nil }
            entries.append(TreeEntry(mode: fields[0], type: fields[1], id: fields[2], size: Int(fields[3]), path: path))
        }
        return entries
    }

    static func entries(_ tree: [TreeEntry]) -> [String: Entry] {
        var map: [String: Entry] = [:]
        for item in tree { map[item.path] = Entry(mode: item.mode, id: item.id) }
        return map
    }

    /// 回傳一句不安全的原因（含路徑）；nil＝可以合併。reference 是這台自己的樹：
    /// `.gitattributes`、`.gitmodules` 這類 git 設定檔只准跟這台一模一樣（避免對方塞過濾器或子模組設定）。
    static func problem(in tree: [TreeEntry], reference: [String: Entry]) -> String? {
        guard tree.count <= maxEntries else { return "檔案太多（超過 \(maxEntries) 個）" }
        for item in tree {
            let shown = display(item.path)
            guard safePath(item.path) else { return "有記憶資料夾以外的路徑：\(shown)" }
            switch item.mode {
            case "120000": return "有連結檔：\(shown)"
            case "160000": return "有子模組：\(shown)"
            case "100644", "100755": break
            default: return "有不是一般檔的東西：\(shown)"
            }
            guard item.type == "blob" else { return "有不是一般檔的東西：\(shown)" }
            guard let size = item.size, size <= maxFileBytes else { return "檔太大：\(shown)" }
            let name = folded(item.path.split(separator: "/").last.map(String.init) ?? item.path)
            if name.hasPrefix(".git"), name != ".gitignore", reference[item.path] != Entry(mode: item.mode, id: item.id) {
                return "有 git 設定檔跟這台不同：\(shown)"
            }
        }
        // W180 E1b 審查：macOS 放不下的排法（只差大小寫的檔名、資料夾，同名的檔和資料夾）一樣不收，git 會默默丟掉一邊。
        let paths = tree.map(\.path)
        if let group = caseGroups(paths).first {
            return "有只差大小寫的檔名：" + group.prefix(2).map(display).joined(separator: "／")
        }
        return layoutProblem(paths)
    }

    /// 相對路徑、每一段都不是空的、`.`、`..`、`.git`（不分大小寫、忽略看不見的字），沒有控制字元。
    static func safePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), path.utf8.count <= 1024 else { return false }
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            let name = String(component)
            guard !name.isEmpty, name != ".", name != "..", !name.contains("\\") else { return false }
            guard !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return false }
            if folded(name) == ".git" { return false }
        }
        return true
    }

    /// macOS 檔名不分大小寫，也會忽略某些看不見的字（git 的 protectHFS 同一組）。
    static func folded(_ name: String) -> String {
        let ignorable: Set<UInt32> = [0x200C, 0x200D, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                                      0x206A, 0x206B, 0x206C, 0x206D, 0x206E, 0x206F, 0xFEFF]
        let kept = name.unicodeScalars.filter { !ignorable.contains($0.value) }
        return String(String.UnicodeScalarView(kept)).lowercased()
    }

    static func display(_ path: String) -> String {
        let cleaned = String(path.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? "?" : Character($0) })
        return cleaned.count > 80 ? String(cleaned.prefix(80)) + "…" : cleaned
    }
}
