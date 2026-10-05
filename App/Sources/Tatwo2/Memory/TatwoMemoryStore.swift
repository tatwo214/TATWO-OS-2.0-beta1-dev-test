import Foundation

/// 從記憶頁「忘記」的一條：檔案搬到入口 archive/memory-forgotten-<日期>/，索引那幾行記在 forgotten.json，可以原樣還原。
struct TatwoForgottenMemory: Codable, Identifiable, Equatable, Sendable {
    /// 原本的檔名（memory/ 最上層）。
    let file: String
    /// 相對於入口：archive/memory-forgotten-<日期>/<檔名>。
    let archivePath: String
    let title: String
    /// 從 MEMORY.md／MEMORY-*.md 拿掉的那幾行（還原時放回去）。
    let indexLines: [String]
    let forgottenAt: Date

    var id: String { archivePath }
}

/// W180 E1：寫入口 memory/ 的地方（記憶頁、三個記憶工具、「不相關」回饋）。
/// 每一次寫都：先擋金鑰 → 寫檔 → 更新 MEMORY.md（用 EngineMemoryLinks.entryLine 的格式）→ 用 EngineMemoryLinks.commit 提交
/// （作者固定 TATWO OS、看起來含金鑰的檔不進 git）→ 讓快取失效。刪除一律是封存（可還原），不直接刪。
/// 全部方法會碰檔案與 git：只在背景執行緒叫。
/// 寫檔與 commit 用 E1b 同步的那把 `TatwoMemoryLock`（withLock）。
final class TatwoMemoryStore: @unchecked Sendable {
    static let shared = TatwoMemoryStore()
    static let maxFeedbackPerDevice = 300
    static let forgottenPrefix = "memory-forgotten-"
    static let indexSectionTitle = "TATWO 記下的"
    static let types = ["user", "feedback", "project", "reference"]
    static let maxTitle = 80
    static let maxContent = 4000
    static let maxAliases = 12

    enum Failure: LocalizedError, CustomStringConvertible, Equatable {
        case folderMissing, invalidID, notFound, secret, emptyTitle, emptyContent, tooLong, nameTaken(String), invalid(String)

        var description: String {
            switch self {
            case .folderMissing: "memory_folder_missing"
            case .invalidID: "memory_invalid_id"
            case .notFound: "memory_not_found"
            case .secret: "memory_secret_rejected"
            case .emptyTitle: "memory_empty_title"
            case .emptyContent: "memory_empty_content"
            case .tooLong: "memory_too_long"
            case .nameTaken(let name): "memory_name_taken:" + name
            case .invalid(let reason): reason
            }
        }

        /// 記憶頁那一行白話。
        var errorDescription: String? {
            switch self {
            case .folderMissing: "記憶資料夾還沒接上：到 設定 › OS › 記憶 接上。"
            case .invalidID, .notFound: "找不到這條記憶（可能剛被改名或忘記了）。"
            case .secret: "內容看起來含金鑰、密碼或權杖，沒有存。"
            case .emptyTitle: "標題不能是空的。"
            case .emptyContent: "內容不能是空的。"
            case .tooLong: "太長了：標題 80 字、內容 4000 字、別名 12 個以內。"
            case .nameTaken(let name): "記憶資料夾裡已經有「\(name)」，沒有還原。"
            case .invalid(let reason): "沒有存：\(reason)"
            }
        }
    }

    struct SaveRequest: Sendable {
        var title: String
        var content: String
        var aliases: [String] = []
        var type: String = "user"
        var source: String
        var scope: String = "private"
    }

    enum SaveOutcome: Equatable, Sendable {
        case saved(String)
        /// 同一條（內容一樣）已經有了。
        case duplicate(String)
        /// 同一個標題已經有一條、內容不一樣：沒有覆蓋（改記憶要使用者同意），把舊的內容交回去。
        case exists(id: String, content: String)
    }

    private let overrideLock = NSLock()
    private var override: EngineMemoryPaths?

    /// 自測用：固定用這個入口（nil＝跟著 TATWO_OS_ROOT）。
    var pathsOverride: EngineMemoryPaths? {
        get { overrideLock.lock(); defer { overrideLock.unlock() }; return override }
        set { overrideLock.lock(); override = newValue; overrideLock.unlock() }
    }

    var paths: EngineMemoryPaths { pathsOverride ?? EngineMemoryPaths() }
    var memory: URL { paths.memory }

    /// W180 E1a＋E1b 合併：寫檔與 commit 跟自動同步（TatwoMemorySync）、EngineMemoryLinks 共用同一把 TatwoMemoryLock。
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        try TatwoMemoryLock.run(body)
    }

    var folderExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: memory.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - 檢查

    /// 看起來含金鑰、密碼、權杖、卡號就不收：EngineMemoryLinks.secretPatterns（英文關鍵字、常見權杖格式）再加
    /// 中文寫法（「密碼：」「密碼是」「金鑰 =」…後面接一串英數）、英文「password is …」、長串大小寫英數混合、過得了檢查碼的卡號。
    static func containsSecret(_ text: String) -> Bool {
        EngineMemoryLinks.secretPatterns.contains { text.range(of: $0, options: .regularExpression) != nil }
            || extraSecretPatterns.contains { text.range(of: $0, options: .regularExpression) != nil }
            || containsCardNumber(text)
    }

    static let extraSecretPatterns = [
        // 中文：密碼／密鑰／金鑰／口令／私鑰／驗證碼／PIN（碼）後面接冒號、等號、是、為，再接四個以上英數符號。
        #"(?:密碼|密码|密鑰|密钥|金鑰|金钥|口令|私鑰|私钥|驗證碼|验证码|(?<![A-Za-z])[Pp][Ii][Nn](?:\s*碼)?)\s*(?:[:：=＝]|是|為|爲)\s*["'「『]?[A-Za-z0-9!@#$%^&*()_+\-=./~]{4,}"#,
        // 英文：password is／was …（值裡要有數字，免得「password is required」這種說明也被擋）。
        #"(?i)(?<![a-z])(?:password|passwd|passcode|api\s*key|secret\s*key|private\s*key|access\s*key)\s*(?:[:：=＝]|\bis\b|\bwas\b)\s*["']?(?=[^\s"']*[0-9])[^\s"']{4,}"#,
        // 32 個以上、大小寫與數字都有的一串（API 金鑰、JWT 常見長相；git 的 sha、UUID 是單一大小寫，不會中）。
        #"(?<![A-Za-z0-9])(?=[A-Za-z0-9_\-]*[A-Z])(?=[A-Za-z0-9_\-]*[a-z])(?=[A-Za-z0-9_\-]*[0-9])[A-Za-z0-9_\-]{32,}(?![A-Za-z0-9])"#,
    ]

    /// 13–19 位、過得了 Luhn 檢查碼的數字（中間可以有空白或連字號）＝看起來是卡號。
    static func containsCardNumber(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![0-9])(?:[0-9][ -]?){12,18}[0-9](?![0-9])"#) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).contains { match in
            guard let span = Range(match.range, in: text) else { return false }
            let digits = text[span].compactMap(\.wholeNumberValue)
            guard (13...19).contains(digits.count) else { return false }
            var sum = 0
            for (index, digit) in digits.reversed().enumerated() {
                let value = index % 2 == 1 ? digit * 2 : digit
                sum += value > 9 ? value - 9 : value
            }
            return sum % 10 == 0
        }
    }

    /// 只收 memory/ 最上層的一般 .md（不收路徑、隱藏檔、索引檔）。
    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 200 && id.hasSuffix(".md") && !id.hasPrefix(".") && !id.contains("/")
            && !id.contains("\\") && !id.contains("\0") && !id.contains(where: \.isNewline)
            && !EngineMemoryLinks.isIndexFile(id)
    }

    /// 一條記憶檔的網址；不是一般檔（連結、資料夾）或不在就丟錯。
    func existingFile(_ id: String) throws -> URL {
        guard Self.validID(id) else { throw Failure.invalidID }
        guard folderExists else { throw Failure.folderMissing }
        let url = memory.appendingPathComponent(id, isDirectory: false)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.notFound }
        return url
    }

    func read(_ id: String) throws -> TatwoMemoryEntry {
        let url = try existingFile(id)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard (values?.fileSize ?? 0) <= TatwoMemoryIndex.maxFileBytes, let data = try? Data(contentsOf: url) else {
            throw Failure.notFound
        }
        return TatwoMemoryEntry(id: id, file: TatwoMemoryFile.parse(String(decoding: data, as: UTF8.self)),
                                modifiedAt: values?.contentModificationDate ?? .distantPast, size: data.count)
    }

    /// 現在資料夾裡的每一條（背景直接讀，給工具與重複檢查用）。
    func entries() -> [TatwoMemoryEntry] {
        guard folderExists else { return [] }
        return EngineMemoryLinks.memoryItems(in: memory).compactMap { try? read($0) }
    }

    private static func cleanAliases(_ aliases: [String]) -> [String] {
        var seen = Set<String>()
        return aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ") }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private static func checkFields(title: String, content: String, aliases: [String]) throws {
        guard !title.isEmpty else { throw Failure.emptyTitle }
        guard !content.isEmpty else { throw Failure.emptyContent }
        guard title.count <= maxTitle, content.count <= maxContent, aliases.count <= maxAliases,
              aliases.allSatisfy({ $0.count <= 40 }) else { throw Failure.tooLong }
        guard !containsSecret(([title, content] + aliases).joined(separator: "\n")) else { throw Failure.secret }
    }

    private static func key(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    // MARK: - 記下一條（memory_save）

    func save(_ request: SaveRequest, now: Date = Date()) throws -> SaveOutcome {
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        let content = request.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliases = Self.cleanAliases(request.aliases)
        try Self.checkFields(title: title, content: content, aliases: aliases)
        guard Self.types.contains(request.type) else { throw Failure.invalid("memory_invalid_type") }
        return try withLock {
            guard folderExists else { throw Failure.folderMissing }
            let titleKey = Self.key(title), contentKey = Self.key(content)
            let existing = entries()
            // 內容一樣＝同一條（標題不同也算）。
            if !contentKey.isEmpty, let same = existing.first(where: { Self.key($0.file.content) == contentKey }) {
                return .duplicate(same.id)
            }
            // 標題一樣、內容不一樣：可能是更正（例：地址換了）。不覆蓋，把舊的交回去，讓 AI 跟使用者確認。
            if let same = existing.first(where: { Self.key($0.title) == titleKey || Self.key($0.file.name ?? "") == titleKey }) {
                return .exists(id: same.id, content: same.file.content)
            }
            let name = uniqueName(for: title)
            let firstLine = content.split(separator: "\n").first.map(String.init) ?? content
            let file = TatwoMemoryFile(name: title, description: String(firstLine.prefix(120)), type: request.type,
                                       aliases: aliases, scope: request.scope, level: "raw", source: request.source,
                                       created: TatwoMemoryFile.formatDate(now), content: content)
            let text = file.rendered()
            guard !Self.containsSecret(text) else { throw Failure.secret }
            let url = memory.appendingPathComponent(name, isDirectory: false)
            try Data(text.utf8).write(to: url, options: .atomic)
            try insertIndexLine(EngineMemoryLinks.entryLine(for: url, name: name), file: name)
            _ = EngineMemoryLinks.commit(memory, message: "TATWO OS：記下「\(title)」")
            TatwoMemoryIndex.shared.invalidate()
            return .saved(name)
        }
    }

    /// 標題變檔名：留字母、數字（含中文），其他換成 -；撞名補 -2、-3。
    func uniqueName(for title: String) -> String {
        var slug = ""
        for character in title {
            if character.isLetter || character.isNumber { slug.append(character) }
            else if slug.last != "-" { slug.append("-") }
        }
        slug = String(slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40))
        if slug.isEmpty || slug.uppercased().hasPrefix("MEMORY") || slug.uppercased() == "README" {
            slug = "memory-" + slug
        }
        let fm = FileManager.default
        var name = slug + ".md"
        var number = 2
        while fm.fileExists(atPath: memory.appendingPathComponent(name).path) {
            name = "\(slug)-\(number).md"
            number += 1
        }
        return name
    }

    // MARK: - 改一條（記憶頁）

    func update(id: String, title: String, aliases: [String], content: String) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliases = Self.cleanAliases(aliases)
        try Self.checkFields(title: title, content: content, aliases: aliases)
        try withLock {
            let url = try existingFile(id)
            let entry = try read(id)
            var file = entry.file
            let oldName = file.name
            // Claude 那種英文代號的 name 留著（它靠 name 認檔），標題改在 description。
            if let name = file.name, TatwoMemoryFile.looksLikeSlug(name) {
                if entry.title != title { file.description = title }
            } else if entry.title != title {
                file.name = title
            }
            file.aliases = aliases
            if file.content != content { file.setContent(content) }
            let text = file.rendered()
            guard !Self.containsSecret(text) else { throw Failure.secret }
            try Data(text.utf8).write(to: url, options: .atomic)
            // 索引只在標題改了才動：只換那一行 [ ] 裡的字（「 — 」後面手寫的摘要原樣留著）；只改別名、內文不碰索引。
            if entry.title != title {
                try retitleIndexLine(file: id, oldTitles: [entry.title, oldName ?? ""], newTitle: file.name ?? title,
                                     fallback: EngineMemoryLinks.entryLine(for: url, name: id))
            }
            _ = EngineMemoryLinks.commit(memory, message: "TATWO OS：改「\(title)」")
            TatwoMemoryIndex.shared.invalidate()
        }
    }

    // MARK: - 忘記與還原

    func forget(id: String, now: Date = Date()) throws -> TatwoForgottenMemory {
        try withLock {
            let url = try existingFile(id)
            let title = (try? read(id))?.title ?? id
            let fm = FileManager.default
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd"
            let folderName = Self.forgottenPrefix + formatter.string(from: now)
            let archive = paths.archiveRoot.appendingPathComponent(folderName, isDirectory: true)
            try fm.createDirectory(at: archive, withIntermediateDirectories: true)
            var archivedName = id
            var number = 2
            while fm.fileExists(atPath: archive.appendingPathComponent(archivedName).path) {
                archivedName = (id as NSString).deletingPathExtension + "-\(number).md"
                number += 1
            }
            try fm.moveItem(at: url, to: archive.appendingPathComponent(archivedName))
            let removed = removeIndexLines(file: id)
            let record = TatwoForgottenMemory(file: id, archivePath: "archive/\(folderName)/\(archivedName)", title: title,
                                              indexLines: removed, forgottenAt: now)
            var manifest = Self.readManifest(archive)
            manifest.append(record)
            try Self.writeManifest(manifest, to: archive)
            try writeRestoreNote(archive)
            _ = EngineMemoryLinks.commit(memory, message: "TATWO OS：忘記「\(title)」（封存在 \(record.archivePath)）")
            TatwoMemoryIndex.shared.invalidate()
            return record
        }
    }

    /// 最近忘記的（新的在前）；封存檔已經不在的不列。
    func forgotten() -> [TatwoForgottenMemory] {
        let fm = FileManager.default
        let root = paths.archiveRoot
        let folders = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix(Self.forgottenPrefix) }
        var result: [TatwoForgottenMemory] = []
        for folder in folders {
            let archive = root.appendingPathComponent(folder, isDirectory: true)
            for record in Self.readManifest(archive)
            where fm.fileExists(atPath: paths.entryRoot.appendingPathComponent(record.archivePath).path) {
                result.append(record)
            }
        }
        return result.sorted { $0.forgottenAt != $1.forgottenAt ? $0.forgottenAt > $1.forgottenAt : $0.archivePath > $1.archivePath }
    }

    /// 原樣搬回來（位元組不變）、索引那幾行放回去。同名的已經在了就不動。
    func restore(_ record: TatwoForgottenMemory) throws {
        try withLock {
            guard folderExists else { throw Failure.folderMissing }
            guard Self.validID(record.file), record.archivePath.hasPrefix("archive/" + Self.forgottenPrefix),
                  !record.archivePath.contains("..") else { throw Failure.invalidID }
            let source = paths.entryRoot.appendingPathComponent(record.archivePath)
            let archive = source.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: source.path) else { throw Failure.notFound }
            let target = memory.appendingPathComponent(record.file, isDirectory: false)
            guard !FileManager.default.fileExists(atPath: target.path) else { throw Failure.nameTaken(record.file) }
            try FileManager.default.moveItem(at: source, to: target)
            let lines = record.indexLines.isEmpty ? [EngineMemoryLinks.entryLine(for: target, name: record.file)] : record.indexLines
            for line in lines { try insertIndexLine(line, file: record.file, replaceExisting: false) }
            var manifest = Self.readManifest(archive)
            manifest.removeAll { $0.archivePath == record.archivePath }
            try Self.writeManifest(manifest, to: archive)
            _ = EngineMemoryLinks.commit(memory, message: "TATWO OS：還原「\(record.title)」")
            TatwoMemoryIndex.shared.invalidate()
        }
    }

    private static func readManifest(_ archive: URL) -> [TatwoForgottenMemory] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: archive.appendingPathComponent("forgotten.json")))
            .flatMap { try? decoder.decode([TatwoForgottenMemory].self, from: $0) } ?? []
    }

    private static func writeManifest(_ rows: [TatwoForgottenMemory], to archive: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: archive.appendingPathComponent("forgotten.json"), options: .atomic)
    }

    private func writeRestoreNote(_ archive: URL) throws {
        let url = archive.appendingPathComponent("還原.md")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let text = """
        # 從記憶頁「忘記」的記憶

        - 這裡的檔是在 TATWO › 記憶 按「忘記」時搬過來的，內容一個字都沒改。
        - 還原：到 TATWO › 記憶 › 最近忘記的，按「還原」。
        - 手動還原：把檔搬回入口的 `memory/`，再把 `forgotten.json` 裡那條的 `indexLines` 貼回 `memory/MEMORY.md`。

        """
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    // MARK: - 「這條不相關」

    /// 記進 memory/.tatwo/feedback-<這台>.json（每台一檔，不互相蓋，跟著記憶同步）；之後同一句再問，那條排名往下掉。
    /// 回傳：這台挑候選時馬上用得到（主設備、或沒有配對身分的單機）。副設備回 false：候選是主設備挑的，同步過去才生效。
    @discardableResult
    func markIrrelevant(id: String, query: String, now: Date = Date()) throws -> Bool {
        guard Self.validID(id) else { throw Failure.invalidID }
        return try withLock {
            guard folderExists else { throw Failure.folderMissing }
            let directory = memory.appendingPathComponent(".tatwo", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("feedback-\(deviceTag()).json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var rows = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([TatwoMemoryFeedback].self, from: $0) } ?? []
            rows.append(TatwoMemoryFeedback(id: id, words: Array(TatwoMemoryRecall.words(query).prefix(30)), at: now))
            rows = Array(rows.suffix(Self.maxFeedbackPerDevice))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: url, options: .atomic)
            _ = EngineMemoryLinks.commit(memory, message: "TATWO OS：記下一條「不相關」")
            TatwoMemoryIndex.shared.invalidate()
            return !isSecondaryDevice()
        }
    }

    /// 這台是副設備（有配對身分、角色是副設備）。
    func isSecondaryDevice() -> Bool {
        ((try? DeviceIdentityStore.readLocal(entry: EngineMemoryLinks.entry(paths))) ?? nil)?.role == .secondary
    }

    /// 這台的設備 id（只留英數與 -）；還沒有身分就是 local。
    func deviceTag() -> String {
        let id = ((try? DeviceIdentityStore.readLocal(entry: EngineMemoryLinks.entry(paths))) ?? nil)?.deviceID ?? "local"
        let clean = String(id.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(64))
        return clean.isEmpty ? "local" : clean
    }

    // MARK: - MEMORY.md

    private var indexFiles: [URL] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: memory.path)) ?? [])
            .filter { $0 == "MEMORY.md" || ($0.hasPrefix("MEMORY-") && $0.hasSuffix(".md")) }.sorted()
        return names.map { memory.appendingPathComponent($0) }
    }

    private static func lines(_ url: URL) -> [String]? {
        (try? String(contentsOf: url, encoding: .utf8)).map { $0.components(separatedBy: "\n").map(EngineMemoryLinks.stripCR) }
    }

    /// 已經有指到這個檔的那一行就換成新的（replaceExisting）；沒有就加在主索引「TATWO 記下的」那一段最後。
    /// 主索引放不下（200 行或 25 KB）就交給 mergeIndex 放到 MEMORY-tatwo.md。
    func insertIndexLine(_ line: String, file: String, replaceExisting: Bool = true) throws {
        for url in indexFiles {
            guard var lines = Self.lines(url),
                  let index = lines.firstIndex(where: { EngineMemoryLinks.linkTargets(in: $0).contains(file) }) else { continue }
            guard replaceExisting, lines[index] != line else { return }
            lines[index] = line
            try Data(lines.joined(separator: "\n").utf8).write(to: url, options: .atomic)
            return
        }
        let main = memory.appendingPathComponent("MEMORY.md")
        var lines = Self.lines(main) ?? EngineMemoryLinks.indexHeader
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        let header = "## " + Self.indexSectionTitle
        if let start = lines.firstIndex(of: header) {
            var end = start + 1
            while end < lines.count, !lines[end].hasPrefix("## ") { end += 1 }
            var at = end
            while at > start + 1, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
            lines.insert(line, at: at)
        } else {
            lines += ["", header, line]
        }
        if EngineMemoryLinks.fits(lines, reserve: 0) {
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: main, options: .atomic)
        } else {
            try EngineMemoryLinks.mergeIndex(memory: memory, sections: [
                EngineMemoryLinks.IndexSection(label: "tatwo", title: Self.indexSectionTitle, lines: [line]),
            ], pointers: [])
        }
    }

    /// 改了標題：指到這個檔的那一行只換 `[ ]` 裡的字（而且只在那個字本來就是舊標題時換；Claude 那種英文代號留著），
    /// 「 — 」後面的摘要、其他行一個字都不動。哪個索引檔都沒有這個檔就補一行（fallback）。
    func retitleIndexLine(file: String, oldTitles: Set<String>, newTitle: String, fallback: String) throws {
        let label = newTitle.replacingOccurrences(of: "[", with: "［").replacingOccurrences(of: "]", with: "］")
            .replacingOccurrences(of: "\n", with: " ")
        let targets = [file, "./" + file]
        for url in indexFiles {
            guard var lines = Self.lines(url),
                  let index = lines.firstIndex(where: { EngineMemoryLinks.linkTargets(in: $0).contains(file) }) else { continue }
            let line = lines[index]
            for target in targets {
                guard let close = line.range(of: "](" + target + ")"),
                      let open = line[..<close.lowerBound].range(of: "[", options: .backwards) else { continue }
                let current = String(line[open.upperBound..<close.lowerBound])
                guard oldTitles.contains(current), current != label else { return }
                lines[index] = String(line[..<open.upperBound]) + label + String(line[close.lowerBound...])
                try Data(lines.joined(separator: "\n").utf8).write(to: url, options: .atomic)
                return
            }
            return
        }
        try insertIndexLine(fallback, file: file, replaceExisting: false)
    }

    /// 拿掉每個索引檔裡指到這個檔的行，回傳拿掉的行。
    func removeIndexLines(file: String) -> [String] {
        var removed: [String] = []
        for url in indexFiles {
            guard let lines = Self.lines(url) else { continue }
            let kept = lines.filter { !EngineMemoryLinks.linkTargets(in: $0).contains(file) }
            guard kept.count != lines.count else { continue }
            removed += lines.filter { EngineMemoryLinks.linkTargets(in: $0).contains(file) }
            try? Data(kept.joined(separator: "\n").utf8).write(to: url, options: .atomic)
        }
        return removed
    }
}

/// W180 E1：呼叫記憶工具的是哪一條（哪一種對話、哪家引擎、哪台、哪一條）；由 App 在主執行緒查好交給工具。
struct TatwoMemoryOrigin: Sendable {
    var who: String
    var engine: String?
    var threadID: UUID?
    /// Bot 串：三個記憶工具一律不給（對外的 Bot 不能讀使用者的私人記憶，也不能寫進去）。
    var isBot = false
    /// 唯讀副審：可以讀，不能記下。
    var readOnly = false
}

/// W180 E1：內建引擎的三個記憶工具（tatwo2_os MCP 的 memory_search／memory_get／memory_save）。
/// 只給 App 自己與 OS 裡的引擎呼叫（不在三份信任清單裡）；讀到的條目記進這輪的「用了 N 條記憶」。
enum TatwoMemoryTools {
    static let methods: Set<String> = ["memory_search", "memory_get", "memory_save"]

    /// 行為偏好、要 AI 以後怎麼做的話（就算 type 沒寫 feedback）：改走 user_remember 待核准，不直接寫成記憶。
    /// 每一輪都會把記憶當候選附給 AI，不能讓一句「以後都…」不經使用者核准就變成長期指示。
    static let instructionPatterns = [
        #"以後|之後都|往後|今後|從現在起|從今以後|下次起|每次都|每一次都|不要再|別再|請你|希望你|記得要|你要|你應該|你不要|你別|你必須|一律|務必|回答時|回覆時|回答要|回覆要|回答先|回覆先"#,
        #"(?i)\b(?:always|never|from now on|going forward|in the future|every time|each time|next time|make sure to|please|you should|you must|don't|do not)\b"#,
    ]

    static func looksLikeInstruction(_ text: String) -> Bool {
        instructionPatterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// 在背景佇列上跑（os.sock 的處理本來就在背景）。
    static func perform(method: String, params: [String: Any], caller: UUID?, origin: TatwoMemoryOrigin?,
                        store: TatwoMemoryStore = .shared, now: Date = Date()) throws -> [String: Any] {
        guard methods.contains(method) else { throw TatwoMemoryStore.Failure.invalid("unsupported_method") }
        // Bot 串不給記憶工具（設計：對外的 Bot 只能拿公開的；範圍控管做好之前一律不給）；也不記進「用了 N 條記憶」。
        if origin?.isBot == true { throw TatwoMemoryStore.Failure.invalid("memory_not_available_for_bot") }
        if method == "memory_save", origin?.readOnly == true { throw TatwoMemoryStore.Failure.invalid("memory_read_only_thread") }
        switch method {
        case "memory_search":
            guard Set(params.keys).isSubset(of: ["query", "limit", "callerThreadID"]),
                  let query = params["query"] as? String, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  query.count <= 200 else { throw TatwoMemoryStore.Failure.invalid("invalid_params") }
            let limit = min(20, max(1, (params["limit"] as? Int) ?? 10))
            guard store.folderExists else { return ["results": [], "note": "記憶資料夾沒接上"] }
            let entries = store.entries()
            let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let context = TatwoMemoryRecallContext(feedback: TatwoMemoryIndex.readFeedback(store.memory), now: now)
            let ranked = TatwoMemoryRecall.rank(query: query, items: entries.map(\.candidate), context: context,
                                                minimumScore: 0.4, limit: limit)
            let results: [[String: Any]] = ranked.compactMap { row in
                guard let entry = byID[row.candidate.id] else { return nil }
                return ["id": entry.id, "title": entry.title, "summary": entry.summary, "type": entry.file.type ?? "",
                        "aliases": entry.file.aliases, "snippet": TatwoMemoryRecall.oneLine(entry.file.content, limit: 160)]
            }
            if let caller {
                TatwoMemoryTurnLedger.shared.read(thread: caller, items: ranked.map { .init(id: $0.candidate.id, title: $0.candidate.title) })
            }
            return ["results": results]
        case "memory_get":
            guard Set(params.keys).isSubset(of: ["id", "callerThreadID"]),
                  let id = params["id"] as? String else { throw TatwoMemoryStore.Failure.invalid("invalid_params") }
            let entry = try store.read(id)
            if let caller { TatwoMemoryTurnLedger.shared.read(thread: caller, items: [.init(id: entry.id, title: entry.title)]) }
            let formatter = ISO8601DateFormatter()
            return ["id": entry.id, "title": entry.title, "description": entry.file.description ?? "",
                    "type": entry.file.type ?? "", "aliases": entry.file.aliases, "source": entry.file.source ?? "",
                    "content": String(entry.file.content.prefix(8000)), "modifiedAt": formatter.string(from: entry.modifiedAt)]
        case "memory_save":
            guard Set(params.keys).isSubset(of: ["title", "content", "aliases", "type", "callerThreadID"]),
                  let title = params["title"] as? String, let content = params["content"] as? String,
                  params["aliases"] == nil || params["aliases"] is [String],
                  params["type"] == nil || params["type"] is String else { throw TatwoMemoryStore.Failure.invalid("invalid_params") }
            let type = (params["type"] as? String) ?? "user"
            let aliases = params["aliases"] as? [String] ?? []
            guard !TatwoMemoryStore.containsSecret(([title, content] + aliases).joined(separator: "\n")) else {
                throw TatwoMemoryStore.Failure.secret
            }
            if type == "feedback" || looksLikeInstruction(title + "\n" + content) {
                // 行為偏好（希望 AI 以後怎麼做）照舊走 user_remember：變成待核准，使用者核准才寫進 user.md。
                // type 沒寫 feedback、但內容是在叫 AI 以後怎麼做，也走這裡（不讓指示繞過核准變成每輪候選）。
                let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = content.trimmingCharacters(in: .whitespacesAndNewlines)
                let sentence = detail.isEmpty || detail == text ? text : text + "：" + detail
                let outcome = try UserMemoryStore.shared.propose(text: String(sentence.prefix(400)), source: "AI 記憶")
                return ["status": outcome.rawValue, "hint": "行為偏好已成為提案；使用者核准後才會寫進 user.md"]
            }
            let request = TatwoMemoryStore.SaveRequest(title: title, content: content, aliases: aliases, type: type,
                                                       source: source(origin: origin, store: store, now: now))
            switch try store.save(request, now: now) {
            case .saved(let id): return ["status": "saved", "id": id]
            case .duplicate(let id): return ["status": "duplicate", "id": id, "hint": "已經有同一條，沒有再存"]
            case .exists(let id, let old):
                return ["status": "exists", "id": id, "content": String(old.prefix(2000)),
                        "hint": "已經有同標題、內容不同的一條，沒有覆蓋。先跟使用者確認：要改請使用者到 TATWO › 記憶 改這一條，或換一個標題另存"]
            }
        default:
            throw TatwoMemoryStore.Failure.invalid("unsupported_method")
        }
    }

    /// 出處：哪一種對話・哪家引擎・哪台・日期・哪一條（前 8 碼）。
    static func source(origin: TatwoMemoryOrigin?, store: TatwoMemoryStore, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let device = ((try? DeviceIdentityStore.readLocal(entry: EngineMemoryLinks.entry(store.paths))) ?? nil)?.name
        let parts: [String?] = [origin?.who ?? "OS 裡的 AI", origin?.engine, device, formatter.string(from: now),
                                origin?.threadID.map { "對話 " + $0.uuidString.prefix(8) }]
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "・")
    }
}
