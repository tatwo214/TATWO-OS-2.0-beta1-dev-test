import AppKit
import SwiftUI

/// W180 E1：回答下面那一列「用了 N 條記憶」。收合時一行；展開第一行小字說明「這輪帶給 AI 參考的記憶」，
/// 接著每條一列標題，各有「不相關」「打開」（玻璃 chip）。Coder、TATWO、私訊框三處都經 ChatSystemNoteRow 畫這一列。
struct TatwoMemoryUsageRow: View {
    let note: TatwoMemoryUsageNote
    let rowWidth: CGFloat?
    var revealsMemory = false
    @State private var expanded = false
    /// 按過「不相關」的：id → 那一行小字（主設備「已記下不相關」；副設備「同步到主設備後生效」）。
    @State private var marked: [String: String] = [:]
    @State private var failed: String?
    /// W184 C：字級跟著說明列（Coder、TATWO 照舊 12／10.5；私訊框 13／11）。
    @Environment(\.chatNoteTypography) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if revealsMemory {
                Text(note.headline).font(.system(size: typography.label)).foregroundStyle(.secondary)
                    .help(TatwoMemoryUsageNote.detailCaption)
            } else {
            Button {
                withAnimation(.easeInOut(duration: 0.14)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "brain")
                        .font(.system(size: typography.mark, weight: .semibold))
                    Text(note.headline)
                        .font(.system(size: typography.text))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .black))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(note.headline)
            .accessibilityHint(expanded ? "收起" : "展開看是哪幾條")
            .accessibilityIdentifier("tatwo-memory-usage")
            }
            if expanded || revealsMemory {
                VStack(alignment: .leading, spacing: 5) {
                    Text(TatwoMemoryUsageNote.detailCaption)
                        .font(.system(size: typography.label))
                        .foregroundStyle(.tertiary)
                    ForEach(note.items) { item in row(item) }
                    if let failed {
                        Text(failed).font(.system(size: typography.label)).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, revealsMemory ? 0 : 18)
                .transition(.opacity)
            }
        }
        .padding(.leading, revealsMemory ? 0 : 6)
        .frame(width: rowWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(revealsMemory ? "coder-turn-memory" : "tatwo-memory-details")
    }

    private func row(_ item: TatwoMemoryUsageNote.Item) -> some View {
        HStack(spacing: 6) {
            Text(item.title)
                .font(.system(size: typography.text))
                .foregroundStyle(marked[item.id] != nil ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let done = marked[item.id] {
                Text(done).font(.system(size: typography.label)).foregroundStyle(.tertiary)
            } else {
                OSChipButton(title: "不相關") { markIrrelevant(item) }
                    .accessibilityIdentifier("tatwo-memory-irrelevant-\(item.id)")
            }
            OSChipButton(title: "打開") { TatwoMemoryNavigator.open(item.id) }
                .accessibilityIdentifier("tatwo-memory-open-\(item.id)")
        }
    }

    nonisolated static let markedHere = "已記下不相關"
    /// 副設備：候選是主設備挑的，這台記下的「不相關」要同步到主設備才會生效。
    nonisolated static let markedAfterSync = "已記下，同步到主設備後生效"

    private func markIrrelevant(_ item: TatwoMemoryUsageNote.Item) {
        marked[item.id] = "記下中…"
        failed = nil
        let query = note.query
        Task.detached(priority: .utility) {
            do {
                let appliesHere = try TatwoMemoryStore.shared.markIrrelevant(id: item.id, query: query)
                await MainActor.run { marked[item.id] = appliesHere ? Self.markedHere : Self.markedAfterSync }
            } catch {
                let text = (error as? LocalizedError)?.errorDescription ?? "沒記下來"
                await MainActor.run {
                    marked[item.id] = nil
                    failed = text
                }
            }
        }
    }
}

/// W180 E1：從「用了 N 條記憶」的「打開」到 TATWO › 記憶，捲到那一條。
@MainActor
enum TatwoMemoryNavigator {
    static func open(_ id: String) {
        AssistantSpaceTabStore.shared.openMemory(focus: id)
        NotificationCenter.default.post(name: .tatwoOpenWorkOSWindow, object: TatwoPage.chat.rawValue)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .tatwoChatSelectMode, object: ChatRunMode.tatwo.rawValue)
    }
}
