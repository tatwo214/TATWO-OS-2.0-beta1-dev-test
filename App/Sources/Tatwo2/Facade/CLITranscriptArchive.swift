import Foundation

/// W110：各家 CLI 已經把每段對話寫在自己的家目錄；這裡只讀，不複製、不建索引、不落任何內容。
struct CLITranscriptSession: Identifiable, Equatable, Sendable {
    enum Engine: String, Sendable, CaseIterable { case claude, codex
        var label: String { self == .claude ? "Claude" : "Codex" }
    }
    /// native＝使用者平常在終端機用的 CLI；osEngine＝OS 內建引擎（隔離家目錄）。
    enum Origin: String, Sendable { case native, osEngine }
    var id: String { url.path }
    let url: URL
    let engine: Engine
    let origin: Origin
    let sessionID: String
    let title: String
    let cwd: String
    let modifiedAt: Date
    let bytes: Int64
    /// 非互動（房間、腳本、SDK）：Codex 看 source=exec，Claude 看 entrypoint 不是 cli。
    let isBatch: Bool
}

struct CLITranscriptItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case user, assistant, toolCall, toolResult, summary }
    let id: Int
    let kind: Kind
    let text: String
    let toolName: String?
    let timestamp: Date?
    /// 顯示用上限截掉了多少字；原文仍在檔案裡。
    let clipped: Int
}

enum CLITranscriptArchive {
    struct Source: Sendable { let root: URL; let engine: CLITranscriptSession.Engine; let origin: CLITranscriptSession.Origin }
    static let sampleBytes = 256 * 1024
    static let textLimit = 60_000
    static let toolLimit = 8_000
    /// 還在寫入的檔可能正在別處進行；這段時間內不給接續。
    static let liveWindow: TimeInterval = 300

    static func defaultSources(home: URL = FileManager.default.homeDirectoryForCurrentUser, enginesRoot: URL?) -> [Source] {
        var list = [Source(root: home.appendingPathComponent(".claude/projects"), engine: .claude, origin: .native),
                    Source(root: home.appendingPathComponent(".codex/sessions"), engine: .codex, origin: .native)]
        if let enginesRoot {
            list.append(.init(root: enginesRoot.appendingPathComponent("claude/projects"), engine: .claude, origin: .osEngine))
            list.append(.init(root: enginesRoot.appendingPathComponent("codex/sessions"), engine: .codex, origin: .osEngine))
        }
        return list
    }

    // MARK: 清單（每個檔只讀頭尾各一段）

    static func list(sources: [Source]) -> [CLITranscriptSession] {
        var seen = Set<String>(), result: [CLITranscriptSession] = []
        for source in sources {
            let root = source.root.resolvingSymlinksInPath()
            guard let walker = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                if Task.isCancelled { return result }
                // Claude 把子代理放在 <session>/subagents/ 底下；那不是使用者的對話。
                if source.engine == .claude, walker.level != 2 { continue }
                guard seen.insert(url.path).inserted, let session = describe(url, source: source) else { continue }
                result.append(session)
            }
        }
        return result.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    static func describe(_ url: URL, source: Source) -> CLITranscriptSession? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize, size > 0,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: sampleBytes)) ?? Data()
        var tail = Data()
        if size > sampleBytes {
            try? handle.seek(toOffset: UInt64(size - min(size, sampleBytes)))
            tail = (try? handle.readToEnd()) ?? Data()
        }
        let headText = String(decoding: head, as: UTF8.self), tailText = String(decoding: tail, as: UTF8.self)
        let cwd = lastJSONString("cwd", in: headText, first: true) ?? ""
        var title: String?, sessionID: String, batch = false
        switch source.engine {
        case .claude:
            sessionID = url.deletingPathExtension().lastPathComponent
            title = lastJSONString("aiTitle", in: tailText.isEmpty ? headText : tailText) ?? lastJSONString("aiTitle", in: headText)
                ?? lastJSONString("lastPrompt", in: tailText.isEmpty ? headText : tailText)
            // 只有 entrypoint 是 cli 的才是人坐在終端機前的對話；`claude -p`、SDK（房間、腳本、OS 聊天背後那個）算非互動。
            if let entry = lastJSONString("entrypoint", in: headText, first: true) { batch = entry != "cli" }
        case .codex:
            sessionID = lastJSONString("id", in: String(headText.prefix(4096)), first: true) ?? ""
            // exec＝房間／腳本；sidecar＝OS 聊天背後那個（內容在 Chat 分頁本來就看得到）。
            let meta = headText.prefix(8192)
            batch = meta.contains("\"source\":\"exec\"") || meta.contains("\"originator\":\"codex_exec\"") || meta.contains("-sidecar\"")
        }
        if title == nil { title = firstUserLine(headText, engine: source.engine, partial: size > sampleBytes) }
        let clean = (title ?? "").split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return .init(url: url, engine: source.engine, origin: source.origin, sessionID: sessionID,
                     title: clean.isEmpty ? "（沒有標題）" : String(clean.prefix(120)), cwd: cwd,
                     modifiedAt: values.contentModificationDate ?? .distantPast, bytes: Int64(size), isBatch: batch)
    }

    /// 取樣可能切在一行中間，所以不逐行解 JSON，直接找 `"key":"…"`。
    static func lastJSONString(_ key: String, in text: String, first: Bool = false) -> String? {
        let needle = "\"\(key)\":\""
        guard let range = first ? text.range(of: needle) : text.range(of: needle, options: .backwards) else { return nil }
        var index = range.upperBound, escaped = false
        while index < text.endIndex {
            let ch = text[index]
            if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { break }
            index = text.index(after: index)
        }
        guard index < text.endIndex else { return nil }
        let literal = "\"" + text[range.upperBound..<index] + "\""
        return (try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: [.fragmentsAllowed])) as? String
    }

    private static func firstUserLine(_ head: String, engine: CLITranscriptSession.Engine, partial: Bool) -> String? {
        let lines = head.split(separator: "\n")
        for line in partial ? lines.dropLast() : lines[...] {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            for item in items(from: object, engine: engine, nextID: 0) where item.kind == .user { return item.text }
        }
        return nil
    }

    // MARK: 內容（逐行串流）

    /// progress：讀到百分之幾（0…100，整數變了才回報）；幾百 MB 的檔要讀幾十秒，畫面得有數字可看。
    static func read(_ session: CLITranscriptSession, progress: (@Sendable (Int) -> Void)? = nil) -> [CLITranscriptItem] {
        guard let handle = try? FileHandle(forReadingFrom: session.url) else { return [] }
        defer { try? handle.close() }
        var result: [CLITranscriptItem] = [], pending = Data()
        let marker = Data((session.engine == .claude ? "\"type\":\"user\"" : "\"type\":\"response_item\"").utf8)
        let markerAlt = Data("\"type\":\"assistant\"".utf8)
        func consume(_ line: Data) {
            // 先用位元組篩掉用不到的行（附件、計量、狀態），大檔省下大半解析時間。
            guard line.range(of: marker) != nil || (session.engine == .claude && line.range(of: markerAlt) != nil) else { return }
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
            result.append(contentsOf: items(from: object, engine: session.engine, nextID: result.count))
        }
        var consumed: Int64 = 0, lastPercent = -1
        while !Task.isCancelled, let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            pending.append(chunk)
            consumed += Int64(chunk.count)
            let percent = session.bytes > 0 ? Int(min(100, consumed * 100 / session.bytes)) : 100
            if percent != lastPercent { lastPercent = percent; progress?(percent) }
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 0x0A) {
                consume(pending[start..<newline])
                start = pending.index(after: newline)
            }
            pending = Data(pending[start...])
        }
        consume(pending)
        return result
    }

    static func items(from object: [String: Any], engine: CLITranscriptSession.Engine, nextID: Int) -> [CLITranscriptItem] {
        var out: [CLITranscriptItem] = []
        let time = (object["timestamp"] as? String).flatMap(parseDate)
        func add(_ kind: CLITranscriptItem.Kind, _ raw: String, tool: String? = nil) {
            let text = strip(raw)
            guard !text.isEmpty else { return }
            let limit = kind == .toolResult || kind == .toolCall ? toolLimit : textLimit
            out.append(.init(id: nextID + out.count, kind: kind, text: String(text.prefix(limit)), toolName: tool,
                             timestamp: time, clipped: max(0, text.count - limit)))
        }
        switch engine {
        case .claude:
            guard let type = object["type"] as? String, type == "user" || type == "assistant",
                  object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true,
                  let message = object["message"] as? [String: Any] else { return [] }
            let summary = object["isCompactSummary"] as? Bool == true
            if let text = message["content"] as? String { add(summary ? .summary : (type == "user" ? .user : .assistant), text) }
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text": add(summary ? .summary : (type == "user" ? .user : .assistant), block["text"] as? String ?? "")
                case "tool_use": add(.toolCall, compact(block["input"]), tool: block["name"] as? String)
                case "tool_result":
                    if let text = block["content"] as? String { add(.toolResult, text) }
                    else { add(.toolResult, (block["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")) }
                default: break
                }
            }
        case .codex:
            guard object["type"] as? String == "response_item", let payload = object["payload"] as? [String: Any] else { return [] }
            switch payload["type"] as? String {
            case "message":
                let role = payload["role"] as? String
                guard role == "user" || role == "assistant" else { return [] }
                let text = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                // Codex 把 AGENTS.md 與環境說明也記成 user 訊息；整則都是包裝的不算使用者說的話。
                let wrapped = role == "user" && (text.hasPrefix("# AGENTS.md instructions") || (strip(text).hasPrefix("<") && strip(text).hasSuffix(">")))
                if !wrapped { add(role == "user" ? .user : .assistant, text) }
            case "function_call", "custom_tool_call":
                add(.toolCall, payload["arguments"] as? String ?? payload["input"] as? String ?? "", tool: payload["name"] as? String)
            case "function_call_output", "custom_tool_call_output":
                add(.toolResult, payload["output"] as? String ?? compact(payload["output"]))
            default: break
            }
        }
        return out
    }

    /// 引擎自己塞給模型的包裝（系統提醒、環境說明）不是使用者說的話。
    private static func strip(_ text: String) -> String {
        var value = text
        for tag in ["system-reminder", "environment_context", "user_instructions", "local-command-caveat"] {
            while let open = value.range(of: "<\(tag)>"), let close = value.range(of: "</\(tag)>", range: open.upperBound..<value.endIndex) {
                value.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compact(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    // MARK: 接續（走引擎自己的 resume；OS 不另造授權）

    /// id 會進終端指令，只接受 UUID。還在寫入的檔不給接續。
    static func resumeArguments(_ session: CLITranscriptSession, now: Date = Date()) -> [String]? {
        guard UUID(uuidString: session.sessionID) != nil, now.timeIntervalSince(session.modifiedAt) > liveWindow else { return nil }
        return session.engine == .claude ? ["--resume", session.sessionID] : ["resume", session.sessionID]
    }

    static func resumeBlockedReason(_ session: CLITranscriptSession, now: Date = Date()) -> String? {
        if UUID(uuidString: session.sessionID) == nil { return "這個檔沒有可用的 session id" }
        if now.timeIntervalSince(session.modifiedAt) <= liveWindow { return "五分鐘內還在寫入，可能正在別處進行" }
        return nil
    }
}
