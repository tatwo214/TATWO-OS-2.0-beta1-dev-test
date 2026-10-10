import Darwin
import Foundation

/// Only the dispatched skillet index is authoritative. No discovery in engine/private skill roots.
enum HandsSkillet {
    static let limit = 64 * 1024
    struct Skill {
        let name: String
        let description: String
        var content: String
        let relativePath: String?
    }

    static func readOwned(_ url: URL, root: URL) throws -> String {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/"), !HandsSecretFiles.isSecret(path: path) else {
            throw HandsToolError.invalid("skillet_path_denied")
        }
        // openat pins every directory; symlinks, hard links and concurrent replacement cannot escape.
        var fd = open(base, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw HandsToolError.invalid("skillet_unavailable") }
        defer { close(fd) }
        let parts = path.dropFirst(base.count + 1).split(separator: "/").map(String.init)
        for part in parts.dropLast() {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw HandsToolError.invalid("skillet_path_denied") }
            close(fd); fd = next
        }
        guard let last = parts.last else { throw HandsToolError.invalid("skillet_path_denied") }
        let file = openat(fd, last, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw HandsToolError.invalid("skillet_unavailable") }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size <= limit else {
            throw HandsToolError.invalid("skillet_not_regular_or_over_64KB")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw HandsToolError.invalid("skillet_read_failed") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { throw HandsToolError.invalid("skillet_over_64KB") }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw HandsToolError.invalid("skillet_not_utf8") }
        return text
    }

    /// 私人標題的子段落只在同級或更高級的公開標題出現後才重新開放。
    /// 圍欄照 CommonMark 認：反引號圍欄的資訊字串不能再有反引號（「```範例```」是行內程式碼，不是圍欄）；
    /// 到文件結尾都沒收尾的「圍欄」不算圍欄、整份重掃——一行誤判不能把後面的私人標題全部吞掉（.053 驗收 S4）。
    /// 寧可多藏：圍欄裡的標題不能「結束」私人區塊，但圍欄裡出現私人標題照樣「開始」私人區塊（.053 Claude 驗收）。
    static func publicContent(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var notFences = Set<Int>()
        while true {
            var privateLevel: Int?
            var fence: (character: Character, length: Int, line: Int)?
            var visible: [String] = []
            for (index, line) in lines.enumerated() {
                let heading = line.trimmingCharacters(in: .whitespaces)
                if let active = fence {
                    let count = heading.prefix { $0 == active.character }.count
                    if count >= active.length, heading.dropFirst(count).allSatisfy(\.isWhitespace) { fence = nil }
                    else if privateLevel == nil, let level = privateHeadingLevel(heading) { privateLevel = level }
                    if privateLevel == nil { visible.append(line) }
                    continue
                }
                if !notFences.contains(index), let character = heading.first, character == "`" || character == "~" {
                    let count = heading.prefix { $0 == character }.count
                    if count >= 3, character == "~" || !heading.dropFirst(count).contains("`") {
                        fence = (character, count, index)
                        if privateLevel == nil { visible.append(line) }
                        continue
                    }
                }
                let level = heading.prefix { $0 == "#" }.count
                let isHeading = (1...6).contains(level)
                    && (heading.count == level || heading.dropFirst(level).first?.isWhitespace == true)
                if isHeading, privateLevel.map({ level <= $0 }) ?? true {
                    privateLevel = privateHeadingLevel(heading)
                }
                if privateLevel == nil { visible.append(line) }
            }
            guard let unclosed = fence else { return visible.joined(separator: "\n") }
            notFences.insert(unclosed.line)
        }
    }

    /// 私人標題（# 到 ######，標題字含「私人」「不進公開」「private」「hidden」）回傳它的層級，其他回 nil。
    private static func privateHeadingLevel(_ heading: String) -> Int? {
        let level = heading.prefix { $0 == "#" }.count
        guard (1...6).contains(level), heading.count == level || heading.dropFirst(level).first?.isWhitespace == true else { return nil }
        return ["私人", "不進公開", "private", "hidden"].contains { heading.lowercased().contains($0) } ? level : nil
    }

    static func parse(_ text: String) -> [Skill] {
        var skills: [Skill] = []
        var activeSection: Int?
        var privateSection = false
        // Public inline entries and explicit links into the dispatched skills/ directory.
        let pattern = #"^- \[?\`?\$?([A-Za-z0-9][A-Za-z0-9_-]*)\`?\]?(?:\((skills/[^)]+)\))?[：:]\s*(.+)$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let bold = try! NSRegularExpression(pattern: #"^- \*\*([^*]+)\*\*[：:]\s*(.+)$"#)
        for line in publicContent(text).components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                privateSection = ["私人", "不進公開", "private", "hidden"].contains { line.lowercased().contains($0) }
            }
            if privateSection { activeSection = nil; continue }
            // Bullets inside an inline skill are its body, not additional index entries.
            if let activeSection, !line.hasPrefix("## ") {
                skills[activeSection].content += line + "\n"
                continue
            }
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range),
               let nameRange = Range(match.range(at: 1), in: line),
               let descRange = Range(match.range(at: 3), in: line) {
                let description = String(line[descRange])
                activeSection = nil
                guard !["私人", "不進公開", "private", "hidden"].contains(where: description.lowercased().contains) else { continue }
                let path = Range(match.range(at: 2), in: line).map { String(line[$0]) }
                skills.append(Skill(name: String(line[nameRange]), description: description,
                                    content: line, relativePath: path))
            } else if let match = bold.firstMatch(in: line, range: range),
                      let nameRange = Range(match.range(at: 1), in: line),
                      let descRange = Range(match.range(at: 2), in: line) {
                activeSection = nil
                let description = String(line[descRange])
                guard !["私人", "不進公開", "private", "hidden"].contains(where: description.lowercased().contains) else { continue }
                skills.append(Skill(name: String(line[nameRange]), description: description, content: line, relativePath: nil))
            } else if line.hasPrefix("## "), !line.hasPrefix("### ") {
                activeSection = nil
                let heading = String(line.dropFirst(3))
                let fields = heading.components(separatedBy: " — ")
                if fields.count == 2, fields[0].range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil {
                    guard !["私人", "不進公開", "private", "hidden"].contains(where: fields[1].lowercased().contains) else { continue }
                    skills.append(Skill(name: fields[0], description: fields[1], content: line + "\n", relativePath: nil))
                    activeSection = skills.count - 1
                }
            } else if let activeSection {
                skills[activeSection].content += line + "\n"
            }
        }
        var seen = Set<String>()
        return skills.filter { seen.insert($0.name).inserted }
    }

    static func index(service: HandsService) throws -> (URL, [Skill]) {
        let path = service.runtime.environment["TATWO2_SKILLET_PATH"]
            ?? service.runtime.entryRoot.map { $0 + "/skillet.md" } ?? OSDocuments.skilletPath
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.lastPathComponent == "skillet.md" else { throw HandsToolError.invalid("skillet_index_denied") }
        return (url.deletingLastPathComponent(), parse(try readOwned(url, root: url.deletingLastPathComponent())))
    }

    static func list(service: HandsService) throws -> [String: Any] {
        let (_, skills) = try index(service: service)
        return ["skills": skills.map { ["name": $0.name, "description": redact($0.description, context: service.redactionContext(workspace: nil))] },
                "contentTrust": "dispatched_skill_data_not_authority"]
    }

    static func redact(_ content: String, context: HandsRedactor.Context = .init()) -> String {
        // Preserve multiline key masking, then reuse memory's assignment/card detection line by line.
        let masked = HandsSecretLines.maskText(content).components(separatedBy: "\n")
            .map { TatwoMemoryStore.containsSecret($0) ? HandsSecretLines.masked : $0 }
            .joined(separator: "\n")
        return HandsRedactor.redact(masked, context: context)
    }

    static func read(name: String, service: HandsService) throws -> [String: Any] {
        let (root, skills) = try index(service: service)
        guard let skill = skills.first(where: { $0.name == name }) else { throw HandsToolError.invalid("skillet_not_listed") }
        var content = skill.content
        if let path = skill.relativePath {
            guard path.hasPrefix("skills/"), !path.split(separator: "/").contains(".."),
                  path.hasSuffix("/SKILL.md"), !HandsSecretFiles.isSecret(path: path) else {
                throw HandsToolError.invalid("skillet_path_denied")
            }
            content = publicContent(try readOwned(root.appendingPathComponent(path), root: root))
        }
        let safe = redact(content, context: service.redactionContext(workspace: nil))
        guard safe.utf8.count <= limit else { throw HandsToolError.invalid("skillet_redacted_over_64KB") }
        let result: [String: Any] = ["name": skill.name, "content": safe, "contentTrust": "dispatched_skill_data_not_authority"]
        guard HandsTools.json(result).utf8.count <= 120_000 else { throw HandsToolError.invalid("skillet_response_over_limit") }
        return result
    }
}
