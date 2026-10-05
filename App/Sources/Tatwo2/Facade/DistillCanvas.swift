import CryptoKit
import Foundation
import Darwin

/// W180 E4：/蒸餾＝一條 session 做完，把它整理成可重用的東西（預設技能 SKILL.md；也可選清單、SOP、GBrain 頁）。
/// AI 只起草進畫布（```tatwo-distill 圍欄），寫不寫、寫到哪由使用者在畫布按「預覽寫入」「確認寫入」決定；
/// 寫入一律在主設備做（DistillWriter），同名舊檔先封存、可還原。入口 skillet.md 不再是去處（W81 的整份覆蓋已拿掉）。
enum DistillCanvas {
    /// W81 舊畫布的固定五段（```tatwo-plan）；只給還沒選類型的舊畫布讀舊草稿用。
    static let headings = ["這段做了什麼", "架構現況", "決策與理由", "教訓", "下一步"]
    static let fence = "tatwo-distill"
    static let legacyFence = "tatwo-plan"
    static let maxBytes = 1024 * 1024

    /// 給人看的原因。橋接層把錯誤轉成字串時用 `String(describing:)`，所以 description 也要是原因本身（不是除錯字串）。
    struct Failure: LocalizedError, CustomStringConvertible {
        let reason: String
        var errorDescription: String? { reason }
        var description: String { reason }
    }

    static func byteEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    static func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func argument(in text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.split(whereSeparator: \.isWhitespace).first == "/蒸餾" else { return nil }
        return String(text.dropFirst("/蒸餾".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 新畫布：預設整理成技能；/蒸餾 後面的字當主題。
    static func newPlan(threadID: UUID, argument: String, output: DistillOutputKind = .skill) -> TatwoPlanArtifactV1 {
        var plan = TatwoPlanArtifactV1(threadID: threadID, objective: argument.isEmpty ? "把這條對話整理成可重用的東西" : argument,
                                       sections: [], kind: "distill")
        plan.distillOutput = output
        plan.distillText = template(for: output)
        return plan
    }

    /// 畫布實際的類型：舊畫布沒存類型時視為技能。
    static func output(of plan: TatwoPlanArtifactV1) -> DistillOutputKind { plan.distillOutput ?? .skill }

    // MARK: 範本（給 AI 的格式，也是新畫布的起始內容）

    static func template(for output: DistillOutputKind) -> String {
        switch output {
        case .skill:
            return """
            ---
            name: <技能資料夾名：小寫英文、數字和 -，64 字內>
            description: <一行：什麼時候該用這個技能（含「: 」就整句用引號包起來）>
            ---
            # <技能標題>
            ## 何時用
            ## 步驟
            ## 驗收
            ## 不要做
            """
        case .checklist:
            return """
            # <清單標題>
            - [ ] <第一項>
            - [ ] <第二項>
            """
        case .sop:
            return """
            # <SOP 標題>
            ## 目的
            ## 步驟
            ## 注意
            """
        case .gbrain:
            return """
            # <頁面標題>
            自由 Markdown：不要 Timeline／History 段落、不要單獨一行的 ---，首尾不要空白。
            """
        }
    }

    // MARK: 解析 AI 回覆

    /// 最後一個完整的 ```<fence> 圍欄內文（只拿掉圍欄那兩行，不修空白）；範例圍欄與沒收尾的不算。
    static func fencedBody(in reply: String, fence name: String) -> String? {
        var body: [String]?
        var nested: String?
        var outside: String?
        var result: String?
        for line in reply.components(separatedBy: "\n") {
            let token = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if body == nil {
                if let fence = outside {
                    if token == fence { outside = nil }
                } else if token == "```" + name {
                    body = []
                } else if token.hasPrefix("```") || token.hasPrefix("~~~") {
                    outside = String(token.prefix { $0 == "`" || $0 == "~" })
                }
            } else if let fence = nested {
                body?.append(line)
                if token == fence { nested = nil }
            } else if token == "```" {
                result = body!.joined(separator: "\n")
                body = nil
            } else {
                body?.append(line)
                if token.hasPrefix("```") || token.hasPrefix("~~~") {
                    nested = String(token.prefix { $0 == "`" || $0 == "~" })
                }
            }
        }
        return result
    }

    /// 畫布收下的草稿：```tatwo-distill 全文逐位元進畫布。還沒選類型的 W81 舊畫布也收舊的 ```tatwo-plan 五段草稿。
    static func draft(from reply: String, legacy: Bool = false) -> String? {
        if let text = fencedBody(in: reply, fence: fence), acceptable(text) { return text }
        if legacy, let text = fencedBody(in: reply, fence: legacyFence), complete(text) { return text }
        return nil
    }

    private static func acceptable(_ text: String) -> Bool {
        !text.contains("\0") && text.utf8.count <= maxBytes && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// W81 舊五段草稿是否五段都有內容。
    static func complete(_ text: String) -> Bool {
        // Validation may inspect a trimmed copy; storage and delivery use `text`.
        let inspected = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard acceptable(text),
              let sections = TatwoPlanArtifactV1.parseSections(fromReply: "```tatwo-plan\n\(inspected)\n```") else { return false }
        return headings.allSatisfy { title in
            let matches = sections.filter { $0.title == title }
            return matches.count == 1 && !matches[0].body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: 名稱與標題

    /// 標題：第一個 `# ` 標題；沒有就第一行非空、非標題的字。
    static func title(for text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        if let heading = lines.first(where: { $0.hasPrefix("# ") }) {
            let title = heading.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return String(title.prefix(80)) }
        }
        return String((lines.first {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#") && trimmed != "---"
        } ?? "工作蒸餾").prefix(80))
    }

    static func slug(for title: String, id: UUID) -> String {
        let latin = title.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? title
        let words = latin.lowercased().split { !$0.isASCII || (!$0.isLetter && !$0.isNumber) }
        let stem = String(words.joined(separator: "-").prefix(64))
        return "distill/\(stem.isEmpty ? "work" : stem)-\(id.uuidString.lowercased().prefix(8))"
    }

    /// 技能 SKILL.md 開頭的 name／description（--- 之間）。沒有完整開頭就是 nil。
    /// rawDescription 是引號還在的原字（用來判斷含「: 」的值有沒有用引號包起來）。
    static func skillFrontmatter(_ text: String) -> (name: String, description: String, body: String, rawDescription: String)? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first.map({ $0.trimmingCharacters(in: .whitespaces) }) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        var fields: [String: String] = [:]
        var raw: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if raw[key] == nil { raw[key] = value }
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            if fields[key] == nil { fields[key] = value }
        }
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (fields["name"] ?? "", fields["description"] ?? "", body, raw["description"] ?? "")
    }

    /// 技能名稱（也是資料夾名）照 Agent Skills 的 name 規範：小寫英文、數字和 -，64 字內，不以 - 開頭或結尾、不連用 --；
    /// 不能含保留字 anthropic、claude，也不能用 App 內建的名稱（tatwo-ultrawork、skillet）。
    static func skillNameProblem(_ name: String) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "技能名稱不能空白" }
        if name.count > 64 { return "技能名稱最多 64 個字" }
        guard name.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil else {
            return "技能名稱只能用小寫英文、數字和 -（不以 - 開頭或結尾、不連用 --）"
        }
        if DistillWriter.reservedSkillNames.contains(name) { return "「\(name)」是 App 內建的名稱，請換一個" }
        if name.contains("anthropic") || name.contains("claude") { return "技能名稱不能含保留字 anthropic 或 claude" }
        return nil
    }

    /// 技能的 description：一行、1024 字內、不能有 <標籤>；含「: 」或「 #」、或以 YAML 特殊符號開頭時要整句用引號包起來，
    /// 不然引擎解析 SKILL.md 開頭會失敗或截掉一半。
    static func skillDescriptionProblem(description: String, raw: String) -> String? {
        let trimmed = description.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || (trimmed.hasPrefix("<") && trimmed.hasSuffix(">")) {
            return "description 要寫一句話：什麼時候該用這個技能"
        }
        if description.count > 1024 { return "description 最多 1024 個字" }
        if description.range(of: #"<[A-Za-z!/?][^>]*>"#, options: .regularExpression) != nil { return "description 不能有 <標籤>" }
        let quoted = raw.count >= 2 && raw.first == raw.last && (raw.first == "\"" || raw.first == "'")
        if !quoted, description.contains(": ") || description.contains(" #") || description.hasSuffix(":")
            || description.first.map({ "[]{}&*!|>%@`,#?:-".contains($0) }) == true {
            return "description 含「: 」「 #」或以特殊符號開頭時，請整句用引號包起來"
        }
        return nil
    }

    /// 清單、SOP 的檔名（從標題來）：文字、數字、- 或 _，不以點開頭，64 字內。
    static func noteNameProblem(_ name: String) -> String? {
        if name.isEmpty { return "檔名不能空白" }
        if name.count > 64 { return "檔名最多 64 個字" }
        if name.hasPrefix(".") || name.contains("..") { return "檔名不能以點開頭或含 .." }
        if name.unicodeScalars.contains(where: { !(CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
                                                   || $0 == "-" || $0 == "_") }) {
            return "檔名只能用文字、數字、- 或 _"
        }
        return nil
    }

    /// 清單、SOP 的檔名：從標題來，不合法的字換成 -；空的話用畫布編號。
    static func noteName(for title: String, id: UUID) -> String {
        var result = ""
        for scalar in title.unicodeScalars {
            let keep = CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || scalar == "_" || scalar == "-"
            let next = keep ? String(scalar) : "-"
            if next == "-" && result.hasSuffix("-") { continue }
            result += next
        }
        let trimmed = String(result.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(64))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "蒸餾-\(id.uuidString.lowercased().prefix(8))" : trimmed
    }

    // MARK: 寫入前的檢查（主設備寫入時會再跑一次）

    /// 這份全文能不能照這個類型寫入；回傳給人看的問題（空＝可以）。疑似金鑰只說行號，不印內容。
    static func problems(_ text: String, output: DistillOutputKind) -> [String] {
        guard acceptable(text) else { return ["畫布是空的或太大"] }
        var found: [String] = []
        for finding in EngineRuleAudit.audit(text, kind: .skill) {
            found.append("第 \(finding.line) 行：\(finding.category)（\(finding.note)）")
        }
        let lines = text.components(separatedBy: "\n")
        let hasTitle = lines.contains { $0.hasPrefix("# ") && !$0.dropFirst(2).trimmingCharacters(in: .whitespaces).isEmpty }
        func hasPlaceholder(_ value: String) -> Bool { value.hasPrefix("<") && value.hasSuffix(">") }
        switch output {
        case .skill:
            guard let front = skillFrontmatter(text) else {
                found.append("技能開頭要有 --- name／description ---")
                break
            }
            if hasPlaceholder(front.name) { found.append("請把技能名稱換成真的名字") }
            else if let problem = skillNameProblem(front.name) { found.append(problem) }
            if let problem = skillDescriptionProblem(description: front.description, raw: front.rawDescription) { found.append(problem) }
            if front.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { found.append("技能內容是空的") }
        case .checklist:
            if !hasTitle { found.append("清單要有一行 # 標題") }
            if !lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).range(of: #"^- \[[ xX]\] \S"#, options: .regularExpression) != nil }) {
                found.append("清單至少要一項「- [ ] …」")
            }
        case .sop:
            if !hasTitle { found.append("SOP 要有一行 # 標題") }
            if !lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "## 步驟" }) { found.append("SOP 要有「## 步驟」") }
        case .gbrain:
            if let reason = gbrainBodyProblem(text) { found.append(reason) }
        }
        return found
    }

    /// Pinned W80b's parser trims boundary whitespace and extracts timeline
    /// markers. Reject unrepresentable bodies BEFORE writing; never silently edit.
    static func gbrainBodyProblem(_ text: String) -> String? {
        if text != text.trimmingCharacters(in: .whitespacesAndNewlines) || text.contains("\r") {
            return "GBrain 會正規化首尾空白或 CR 換行；請手動改成無首尾空白的 LF 正文，才可逐字寫入。"
        }
        if text.range(of: #"(?im)^\s*(?:<!--\s*timeline\s*-->|##\s+(?:timeline|history)\b|---\s*$)"#,
                      options: .regularExpression) != nil {
            return "GBrain 會解析 Timeline／History／分隔線；請先移除這些特殊標記，或改選技能、清單、SOP。"
        }
        return nil
    }
}

/// A bounded, short-lived stdio client for the existing OS-owned MCP adapter.
enum DistillGBrainClient {
    /// 送出寫入之前就停下：GBrain 上什麼都沒改（改完可以重來）。之後的錯誤都算「結果未確認」。
    struct NotSent: LocalizedError, CustomStringConvertible {
        let reason: String
        var errorDescription: String? { reason }
        var description: String { reason }
    }

    /// 一次工具呼叫：GBrain 回的內容，或 GBrain 自己回的錯誤（例如頁面不存在）。連線、逾時、adapter 拒絕照樣丟錯。
    enum Reply {
        case ok([String: Any])
        case toolError(String)
    }
    typealias Call = (String, [String: Any]) throws -> Reply

    /// 寫一頁：先讀同 slug 的舊頁（整份：正文、標題、frontmatter、tags、GBrain 給的完整原文）交給 archiveExisting 封存
    /// （沒有舊頁給 nil），再寫入、逐字讀回。舊頁讀不到（連線中斷、逾時、adapter 拒絕、回傳形狀不對）就不寫，丟 NotSent。
    static func put(slug: String, title: String, body: String, definition: [String: Any],
                    archiveExisting: ([String: Any]?) throws -> Void) throws {
        var sent = false
        do {
            let quotedTitle = try jsonText(title)
            try session(definition) { (call: Call) throws -> Void in
                let existing = try existingPage(slug, call)
                try archiveExisting(existing)
                // Metadata is a separate envelope; the body is never re-rendered or trimmed.
                let content = "---\ntitle: \(quotedTitle)\ntype: note\n---\n" + body
                sent = true
                guard case .ok = try call("put_page", ["slug": slug, "content": content]) else {
                    throw DistillCanvas.Failure(reason: "GBrain 拒絕寫入 \(slug)；請先查頁面，勿直接重送。")
                }
                try verify(slug, call, body: body, title: nil)
            }
        } catch let error where !sent {
            throw NotSent(reason: reason(error))
        }
    }

    /// 還原一頁：現頁的正文要還是這次寫的那一版（sha 對得上）才動；先把現頁整份交給 keepCurrent 存進封存，
    /// 再放回舊頁（標題、frontmatter、tags 一起），讀回比對正文與標題。現頁被改過、讀不到就不動，丟 NotSent。
    static func restore(slug: String, archived old: [String: Any], writtenSHA: String, definition: [String: Any],
                        keepCurrent: ([String: Any]) throws -> Void) throws {
        var sent = false
        do {
            guard let oldBody = old["compiled_truth"] as? String, let content = restoreContent(old) else {
                throw DistillCanvas.Failure(reason: "封存的舊頁讀不出正文；沒有還原。")
            }
            try session(definition) { (call: Call) throws -> Void in
                guard let current = try existingPage(slug, call) else {
                    throw DistillCanvas.Failure(reason: "GBrain 上已經沒有 \(slug)；沒有還原。")
                }
                guard let text = current["compiled_truth"] as? String, DistillCanvas.sha256(text) == writtenSHA else {
                    throw DistillCanvas.Failure(reason: "寫入後 GBrain 的 \(slug) 又被改過；為了不蓋掉新改的內容，沒有還原。")
                }
                try keepCurrent(current)
                sent = true
                guard case .ok = try call("put_page", ["slug": slug, "content": content]) else {
                    throw DistillCanvas.Failure(reason: "GBrain 拒絕放回 \(slug) 的舊頁；請先查頁面，勿直接重送。")
                }
                try verify(slug, call, body: oldBody, title: old["title"] as? String)
            }
        } catch let error where !sent {
            throw NotSent(reason: reason(error))
        }
    }

    /// 放回舊頁要送的全文：GBrain 給過完整原文（content：frontmatter＋正文＋timeline）就整份放回；
    /// 舊版 GBrain 沒給就用舊標題、類型、tags（設備標記由 adapter 重蓋）和正文組回。
    static func restoreContent(_ page: [String: Any]) -> String? {
        if let content = page["content"] as? String, !content.isEmpty { return content }
        guard let body = page["compiled_truth"] as? String,
              let title = try? jsonText(page["title"] as? String ?? ""),
              let type = try? jsonText(page["type"] as? String ?? "note") else { return nil }
        var header = ["title: \(title)", "type: \(type)"]
        let tags = (page["tags"] as? [String] ?? []).filter { $0 != "device" && !$0.hasPrefix("device:") }
        if !tags.isEmpty, let list = try? jsonText(tags) { header.append("tags: \(list)") }
        return "---\n" + header.joined(separator: "\n") + "\n---\n" + body
    }

    /// 同 slug 現在的頁（整份）；不存在是 nil。GBrain 明確回「page_not_found」才算不存在，其他錯誤一律丟出（不當新建）。
    private static func existingPage(_ slug: String, _ call: Call) throws -> [String: Any]? {
        switch try call("get_page", ["slug": slug, "include_content": true]) {
        case .ok(let result):
            guard let page = pageObject(result), page["compiled_truth"] is String else {
                throw DistillCanvas.Failure(reason: "GBrain 已有 \(slug)，但讀不出它的內容；為了不蓋掉它，沒有寫入。")
            }
            return page
        case .toolError(let text):
            guard notFound(text) else {
                throw DistillCanvas.Failure(reason: "GBrain 讀不到 \(slug) 目前的內容；為了不蓋掉它，沒有寫入。")
            }
            return nil
        }
    }

    /// GBrain 的 get_page 對不存在的頁回 isError，內文是 {"error":"page_not_found",…}。
    static func notFound(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["error"] as? String == "page_not_found"
    }

    private static func verify(_ slug: String, _ call: Call, body: String, title: String?) throws {
        guard case .ok(let result) = try call("get_page", ["slug": slug]), let page = pageObject(result),
              let text = page["compiled_truth"] as? String, DistillCanvas.byteEqual(text, body),
              title == nil || page["title"] as? String == title else {
            throw DistillCanvas.Failure(reason: "GBrain 已寫入 \(slug)，但讀回不一致；請檢查，勿直接重送。")
        }
    }

    static func pageObject(_ result: [String: Any]) -> [String: Any]? {
        if let structured = result["structuredContent"] as? [String: Any] { return structured }
        for item in result["content"] as? [[String: Any]] ?? [] {
            if let text = item["text"] as? String, let data = text.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
        }
        return nil
    }

    private static func jsonText<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func reason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private static func session<T>(_ definition: [String: Any], _ body: (Call) throws -> T) throws -> T {
        guard let command = definition["command"] as? String, let args = definition["args"] as? [String] else {
            throw DistillCanvas.Failure(reason: "缺少 GBrain adapter。")
        }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: command); process.arguments = args
        process.standardInput = input; process.standardOutput = output
        // Do not collect potentially sensitive diagnostics in application logs.
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? output.fileHandleForReading.close()
        }
        var buffer = Data()
        func send(_ object: [String: Any]) throws {
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: object) + Data([10]))
        }
        func response(_ id: Int) throws -> Reply {
            let deadline = Date().addingTimeInterval(45)
            while Date() < deadline {
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                          object["id"] as? Int == id else { continue }
                    // adapter 自己拒絕（服務不可用、參數不合規）：不是「頁面不存在」，一律當錯誤。
                    guard object["error"] == nil, let result = object["result"] as? [String: Any] else {
                        throw DistillCanvas.Failure(reason: "GBrain 拒絕或無法連線。")
                    }
                    if result["isError"] as? Bool == true {
                        let text = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                        return .toolError(text)
                    }
                    return .ok(result)
                }
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 100)
                if ready < 0 && errno == EINTR { continue }
                if ready > 0 {
                    var bytes = [UInt8](repeating: 0, count: 8192)
                    let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
                    guard count > 0 else { throw DistillCanvas.Failure(reason: "GBrain 連線中斷。") }
                    buffer.append(contentsOf: bytes.prefix(count))
                    guard buffer.count <= 4 * 1024 * 1024 else {
                        throw DistillCanvas.Failure(reason: "GBrain 回覆過大。")
                    }
                }
            }
            throw DistillCanvas.Failure(reason: "GBrain 逾時。")
        }
        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2024-11-05", "capabilities": [:],
            "clientInfo": ["name": "tatwo-distill", "version": "1"]]])
        guard case .ok = try response(1) else { throw DistillCanvas.Failure(reason: "GBrain 拒絕連線。") }
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        var nextID = 2
        return try body { name, arguments in
            let id = nextID; nextID += 1
            try send(["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
            return try response(id)
        }
    }
}
