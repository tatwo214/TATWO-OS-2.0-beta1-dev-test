import Foundation
import SwiftUI

enum ChatGPTLocalText {
    struct PrivacyRule: Decodable {
        let category: String
        let pattern: String
        let replacement: String
    }
    // One portable rule set is used by the native UI and the embedded Pod script.
    static let privacyRulesJSON = #"""
    [
      {
        "category": "url",
        "pattern": "https?://[^\\s]+",
        "replacement": "[網址]"
      },
      {
        "category": "parameter",
        "pattern": "[?&][A-Za-z0-9_%.-]+=[^\\s&#]+",
        "replacement": "[參數]"
      },
      {
        "category": "key",
        "pattern": "(?:Bearer\\s+|(?:password|passwd|pwd|密碼|密码|access[_-]?token|token|api[_-]?key|authorization|secret)[\"']?\\s*[:=]\\s*(?:(?:Bearer|Basic)\\s+)?)(?:\"[^\"]*(?:\"|$)|'[^']*(?:'|$)|[^\\s,;\"']+)",
        "replacement": "[已隱去]"
      },
      {
        "category": "path",
        "pattern": "(?<![A-Za-z0-9_./-])(?:file://)?/(?:Users|Volumes|home|private|var|tmp)/[^\\r\\n,;\"'<>]+",
        "replacement": "[本機路徑]"
      },
      {
        "category": "contact",
        "pattern": "[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+",
        "replacement": "[聯絡資料]"
      },
      {
        "category": "contact",
        "pattern": "(?<![A-Za-z0-9_-])(?:\\+[0-9][0-9 .()-]{7,}[0-9]|0[0-9]{1,3}[ .-]?[0-9]{3,4}[ .-]?[0-9]{3,4}|\\([0-9]{2,4}\\)[ .-]?[0-9]{3,4}[ .-]?[0-9]{4}|[0-9]{3}[ .-][0-9]{3}[ .-][0-9]{4})(?![A-Za-z0-9_-])",
        "replacement": "[聯絡資料]"
      },
      {
        "category": "contact",
        "pattern": "(?<![A-Za-z0-9_-])[0-9]{11,15}(?![A-Za-z0-9_-])|(?<![A-Za-z])(?:phone|telephone|mobile|電話|手机|手機)[\"']?(?:\\s*[:=：]\\s*[\"']?[+0-9][0-9 .()-]{5,}[0-9]|\\s+[\"']?[+]?[0-9]{7,15}(?![A-Za-z0-9_-]))",
        "replacement": "[聯絡資料]"
      },
      {
        "category": "contact",
        "pattern": "(?<![A-Za-z0-9_])[A-Z][12][0-9]{8}(?![A-Za-z0-9_])",
        "replacement": "[聯絡資料]"
      },
      {
        "category": "opaque",
        "pattern": "\\b(?:sk-[A-Za-z0-9_-]+|eyJ[A-Za-z0-9_.-]+|[A-Za-z0-9_-]{32,})\\b",
        "replacement": "[已隱去]"
      },
      {
        "category": "control",
        "pattern": "[\\x00-\\x1f\\x7f]",
        "replacement": " "
      },
      {
        "category": "space",
        "pattern": "\\s+",
        "replacement": " "
      }
    ]
    """#
    static let privacyRules: [PrivacyRule] = {
        guard let data = privacyRulesJSON.data(using: .utf8),
              let rules = try? JSONDecoder().decode([PrivacyRule].self, from: data) else {
            preconditionFailure("Invalid local privacy rules")
        }
        return rules
    }()
    private static let compiled = privacyRules.map { rule in
        (try! NSRegularExpression(pattern: rule.pattern, options: .caseInsensitive), rule.replacement)
    }
    static func clean(_ text: String, limit: Int) -> String {
        let safe = compiled.reduce(text) { value, rule in
            rule.0.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: rule.1)
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(safe.prefix(max(0, limit)))
    }

}

enum ChatGPTFailureNotice {
    static func text(_ reason: String?, rowID: String?, messages: [TapMessage]) -> String? {
        guard let rowID else { return reason }
        return messages.contains { $0.id == rowID && $0.turnFailure != nil } ? nil : reason
    }
}

enum ChatGPTDraftRecovery {
    static func merge(current: String, returning: String) -> String {
        if returning.isEmpty || current.contains(returning) { return current }
        if current.isEmpty { return returning }
        return current + "\n\n" + returning
    }
}

/// Transient UI data; never encoded in diagnostics, memory or conversation storage.
struct ChatGPTTurnFailure: Equatable {
    let message: String
    let reason: String?
    let draft: String
    var projectID: String? = nil
    var files: [TapAttachment]
    var paths: [String]
    var names: [String: String] = [:]
    init(message: String, reason: String?, draft: String, projectID: String? = nil,
         files: [TapAttachment] = [], paths: [String] = []) {
        self.message = message
        self.reason = reason
        self.draft = draft
        self.projectID = projectID
        self.files = files; self.paths = paths
    }
    var isTooLong: Bool { reason == "conversation_too_long" }
    var displayText: String { isTooLong ? "這則對話太長，ChatGPT 無法繼續。" : message }
    var actionTitle: String { isTooLong ? "開新對話接著聊" : "放回輸入框" }
    var category: String { isTooLong ? "對話太長" : reason == "not_submitted" ? "沒有送出" : reason == "timeout" || reason == "no_progress" ? "未完成" : "ChatGPT 回報錯誤" }
    var storedStatus: String { "error|" + category }

    /// Only fixed categories are decoded, never provider text from a stored status.
    static func restored(status: String?, draft: String) -> Self? {
        switch status {
        case "error|對話太長": return Self(message: "對話太長", reason: "conversation_too_long", draft: draft)
        case "error|ChatGPT 回報錯誤": return Self(message: "ChatGPT 回報錯誤", reason: nil, draft: draft)
        case "error|沒有送出": return Self(message: "沒有送出", reason: "not_submitted", draft: draft)
        case "error|未完成": return Self(message: "ChatGPT 回答未完成", reason: "timeout", draft: draft)
        default: return nil
        }
    }
}

struct ChatGPTThinking: Equatable {
    var started = Date()
    var title = ""
    var server = false
    static func doneText(_ seconds: Int?) -> String? {
        seconds.flatMap { $0 > 0 ? "已思考 \($0) 秒" : nil }
    }
    func seconds(at now: Date = Date()) -> Int { max(0, Int(now.timeIntervalSince(started))) }
    func label(at now: Date) -> String {
        let elapsed = seconds(at: now)
        let time = elapsed < 60 ? "\(elapsed) 秒" : "\(elapsed / 60) 分"
        return server ? "ChatGPT 在伺服器上思考中・\(time)" : "思考中・\(elapsed) 秒"
    }
}

/// Shared transient clock; callers retain their established send/accepted start policy.
struct ChatGPTTurnProgress: Equatable {
    var thinking: ChatGPTThinking?
    var thoughtSeconds: Int?
    mutating func apply(_ event: TapStreamEvent, startIfMissing: Bool = true) {
        switch event {
        case .accepted:
            if startIfMissing && thinking == nil && thoughtSeconds == nil { thinking = ChatGPTThinking() }
        case .progress(let title, let server):
            guard thoughtSeconds == nil else { return }
            if thinking == nil && startIfMissing { thinking = ChatGPTThinking() }
            thinking?.title = title; thinking?.server = server
        case .text(_, let full):
            if !full.isEmpty, let current = thinking { thoughtSeconds = current.seconds(); thinking = nil }
        case .finished, .failed, .notSubmitted: thinking = nil
        default: break
        }
    }
}

struct ChatGPTThinkingRow: View {
    @Environment(\.tatwoWorkspaceVisible) private var workspaceVisible
    let thinking: ChatGPTThinking
    var body: some View {
        TimelineView(VisibleTimelineSchedule(base: PeriodicTimelineSchedule(from: thinking.started, by: 1), isVisible: workspaceVisible)) { context in
            #if DEBUG
            let _ = ChatRenderProbe.record("ChatGPTThinkingRow.tick")
            #endif
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text(thinking.label(at: context.date))
                    if !thinking.title.isEmpty { Text(thinking.title).lineLimit(2) }
                }
                .font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("chatgpt.thinkingProgress")
    }
}

struct ChatGPTTurnFailureRow: View {
    let failure: ChatGPTTurnFailure
    /// 草稿已經自動放回輸入框：只留說明，不再給「放回輸入框」。
    var draftInComposer = false
    let recover: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(failure.displayText).font(.system(size: 13)).foregroundStyle(.red).textSelection(.enabled)
            // 使用者裁決：按鈕一律玻璃 chip（不要看起來像一般文字）。
            if failure.isTooLong || !draftInComposer {
                Button(action: recover) {
                    Text(failure.actionTitle).font(.system(size: 13)).padding(.horizontal, 10).frame(height: 28)
                }
                .buttonStyle(.plain)
                .chatGlassChip(readable: true)
            }
        }
        .accessibilityIdentifier("chatgpt.turnFailure")
    }
}
