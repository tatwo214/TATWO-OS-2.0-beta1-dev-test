import SwiftUI

/// OS 自己講的話（權限已允許、監工提醒、支線摘要…）不用氣泡：一行小字、前面一個小圖示。
/// 只接 status 是 `done|…` 或 `info|…` 的系統訊息；錯誤走 ChatErrorCard，其餘照舊。
struct ChatSystemNotePresentation: Equatable {
    let symbol: String
    let tag: String
    let text: String

    static func isAutomaticDeviceStatus(_ message: ChatMessage) -> Bool {
        guard message.role == .system, message.id.hasPrefix("offline:") else { return false }
        let parts = message.id.split(separator: ":")
        guard parts.count == 3, UUID(uuidString: String(parts[1])) != nil else { return false }
        switch (parts[2], message.status) {
        case ("head", "info|離線補回"), ("legacy", "info|離線補回"), ("merged", "done|已補回"): return true
        default: return false
        }
    }

    static func resolve(_ message: ChatMessage) -> ChatSystemNotePresentation? {
        guard !isAutomaticDeviceStatus(message) else { return nil }
        guard message.role == .system,
              let status = message.status?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let parts = status.split(separator: "|", maxSplits: 1).map(String.init)
        guard let kind = parts.first?.lowercased(), kind == "done" || kind == "info" else { return nil }
        let tag = parts.count > 1 ? parts[1] : ""
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let symbol: String
        switch tag {
        case "權限": symbol = text.hasPrefix("拒絕") ? "hand.raised" : "checkmark.shield"
        case "監工": symbol = "eye"
        case "支線摘要": symbol = "arrow.triangle.branch"
        case "記憶": symbol = "brain"   // W180 E1
        default: symbol = kind == "done" ? "checkmark.circle" : "info.circle"
        }
        return ChatSystemNotePresentation(symbol: symbol, tag: tag, text: text)
    }
}

/// W184 C：說明列（含「用了 N 條記憶」）的字級。Coder、TATWO 不設＝照舊（字 12、小標 10.5、圖示與小鈕 11）；
/// 私訊框照手機 token 設成 13／11／11（GlobalDMChatLayout.noteTypography）。只換字級，樣子與行為不變。
struct ChatNoteTypography: Equatable, Sendable {
    var text: CGFloat = 12
    var label: CGFloat = 10.5
    var mark: CGFloat = 11

    static let standard = ChatNoteTypography()
}

private struct ChatNoteTypographyKey: EnvironmentKey {
    static let defaultValue = ChatNoteTypography.standard
}

extension EnvironmentValues {
    var chatNoteTypography: ChatNoteTypography {
        get { self[ChatNoteTypographyKey.self] }
        set { self[ChatNoteTypographyKey.self] = newValue }
    }
}

struct ChatSystemNoteRow: View {
    let presentation: ChatSystemNotePresentation
    let rowWidth: CGFloat?
    var revealsMemory = false
    @State private var expanded = false
    @Environment(\.chatNoteTypography) private var typography   // W184 C

    private var isLong: Bool { presentation.text.count > 120 || presentation.text.contains("\n") }

    var body: some View {
        // W180 E1：「用了 N 條記憶」畫成可展開的一列（三處逐字稿都經這裡）。
        if presentation.tag == TatwoMemoryUsageNote.tag, let note = TatwoMemoryUsageNote.decode(presentation.text) {
            TatwoMemoryUsageRow(note: note, rowWidth: rowWidth, revealsMemory: revealsMemory)
        } else {
            noteBody
        }
    }

    private var noteBody: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: presentation.symbol)
                .font(.system(size: typography.mark, weight: .semibold))
                .foregroundStyle(.secondary)
            if !presentation.tag.isEmpty {
                Text(presentation.tag)
                    .font(.system(size: typography.label, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 17)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            Text(presentation.text)
                .font(.system(size: typography.text))
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if isLong {
                Button(expanded ? "收起" : "展開") {
                    withAnimation(.easeInOut(duration: 0.14)) { expanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: typography.mark, weight: .medium))
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, revealsMemory ? 0 : 6)
        .frame(width: rowWidth, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(presentation.tag) \(presentation.text)")
    }
}
