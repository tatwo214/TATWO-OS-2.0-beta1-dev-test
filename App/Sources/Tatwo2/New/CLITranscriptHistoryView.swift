import AppKit
import SwiftUI

/// W110：CLI 分頁「過去的對話」。各家 CLI 本來就把對話寫在自己的家目錄，這裡只是一扇閱讀窗：
/// 不複製、不另存、不上傳；要接著做就用該引擎自己的 resume。
struct CLITranscriptHistoryView: View {
    let sources: [CLITranscriptArchive.Source]
    /// OS 專案的（名稱, 工作資料夾）；資料夾對得上就用專案名稱當分組標題。
    let projects: [(name: String, workdir: String)]
    let onResume: (CLITranscriptSession) -> Void
    let onClose: () -> Void

    @State private var sessions: [CLITranscriptSession]?
    @State private var selected: CLITranscriptSession?
    @State private var engine: CLITranscriptSession.Engine?
    @State private var showsBatch = false
    @State private var query = ""
    @State private var collapsed: Set<String> = []

    private struct Group: Identifiable { let id: String; let title: String; let sessions: [CLITranscriptSession] }

    private var groups: [Group] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = (sessions ?? []).filter {
            (engine == nil || $0.engine == engine) && (showsBatch || !$0.isBatch)
                && (needle.isEmpty || $0.title.lowercased().contains(needle) || $0.cwd.lowercased().contains(needle))
        }
        var order: [String] = [], buckets: [String: [CLITranscriptSession]] = [:]
        for session in visible {   // sessions 已按時間新到舊；分組順序跟著最新的那段對話
            if buckets[session.cwd] == nil { order.append(session.cwd) }
            buckets[session.cwd, default: []].append(session)
        }
        return order.map { Group(id: $0, title: groupTitle($0), sessions: buckets[$0] ?? []) }
    }

    private func groupTitle(_ cwd: String) -> String {
        if cwd.isEmpty { return "（沒有記錄資料夾）" }
        if cwd == NSHomeDirectory() { return "家目錄" }   // 「一般」專案的資料夾也是家目錄；在這裡講資料夾比較不會誤會
        if let project = projects.first(where: { $0.workdir == cwd }), !project.name.isEmpty { return project.name }
        return URL(fileURLWithPath: cwd).pathComponents.suffix(2).joined(separator: "/")
    }

    var body: some View {
        HStack(spacing: 0) {
            listColumn.frame(width: 310)
            Divider()
            if let selected {
                CLITranscriptReader(session: selected, onResume: onResume).id(selected.id)
            } else {
                placeholder("clock.arrow.circlepath", "選一段對話來讀",
                            "這裡列的是各家 CLI 自己留在這台設備上的紀錄；OS 只讀，不複製、不上傳。")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await reload() }
        .accessibilityIdentifier("cli-history")
    }

    private func reload() async {
        let sources = sources
        let work = Task.detached(priority: .userInitiated) { CLITranscriptArchive.list(sources: sources) }
        sessions = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    // MARK: - 清單

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 12, weight: .bold)).foregroundStyle(LiquidGlassTokens.brandAccent)
                Text("過去的對話").font(.system(size: 14, weight: .bold))
                Spacer(minLength: 4)
                iconButton("arrow.clockwise", "重新讀取清單") { Task { sessions = nil; await reload() } }
                iconButton("xmark", "回到終端", action: onClose)
            }
            HStack(spacing: 4) {
                filterChip("全部", engine == nil) { engine = nil }
                ForEach(CLITranscriptSession.Engine.allCases, id: \.self) { value in
                    filterChip(value.label, engine == value) { engine = value }
                }
                Spacer(minLength: 4)
                Toggle("含非互動", isOn: $showsBatch).toggleStyle(.checkbox).font(.system(size: 11))
                    .help("施工房間、腳本，以及 OS 聊天在背後跑的 session 預設不列")
            }
            TextField("找標題或資料夾", text: $query).textFieldStyle(.roundedBorder).font(.system(size: 12))
                .accessibilityLabel("篩選過去的對話")
            if sessions == nil {
                VStack { ProgressView().controlSize(.small) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                placeholder("tray", (sessions ?? []).isEmpty ? "這台設備上還沒有 CLI 對話紀錄" : "沒有符合的對話",
                            (sessions ?? []).isEmpty ? "用過 Claude 或 Codex 的 CLI 之後，它們自己存的紀錄會出現在這裡。" : "換個關鍵字，或勾「含非互動」。")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(groups) { group in
                            groupHeader(group)
                            if !collapsed.contains(group.id) { ForEach(group.sessions) { row($0) } }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(12)
    }

    private func groupHeader(_ group: Group) -> some View {
        Button {
            if !collapsed.insert(group.id).inserted { collapsed.remove(group.id) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: collapsed.contains(group.id) ? "chevron.right" : "chevron.down").font(.system(size: 8, weight: .bold)).frame(width: 10)
                Image(systemName: "folder").font(.system(size: 10))
                Text(group.title).font(.system(size: 11, weight: .bold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(group.sessions.count)").font(.system(size: 10).monospacedDigit())
            }
            .foregroundStyle(.secondary).padding(.vertical, 5).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(group.id).padding(.top, 4)
        .accessibilityLabel("\(group.title)，\(group.sessions.count) 段對話")
    }

    private func row(_ session: CLITranscriptSession) -> some View {
        let isSelected = selected?.id == session.id
        return Button { selected = session } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title).font(.system(size: 12, weight: isSelected ? .semibold : .regular)).lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    Text(session.engine.label + (session.origin == .osEngine ? " · OS 內" : "") + (session.isBatch ? " · 非互動" : ""))
                    Text("·"); Text(Self.dayFormatter.string(from: session.modifiedAt))
                    Text("·"); Text(ByteCountFormatter.string(fromByteCount: session.bytes, countStyle: .file))
                }
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(isSelected ? LiquidGlassTokens.brandAccent.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(session.title)，\(session.engine.label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func filterChip(_ title: String, _ active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: active ? .bold : .regular))
                .foregroundStyle(active ? LiquidGlassTokens.brandAccent : Color.secondary)
                .padding(.horizontal, 8).frame(height: 22).contentShape(Rectangle())
                .background(active ? LiquidGlassTokens.brandAccent.opacity(0.13) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateFormat = "M/d HH:mm"; return formatter
    }()
}

private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22).contentShape(Rectangle())
    }
    .buttonStyle(.plain).foregroundStyle(.secondary).help(label).accessibilityLabel(label)
}

private func placeholder(_ symbol: String, _ title: String, _ detail: String) -> some View {
    VStack(spacing: 8) {
        Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.secondary)
        Text(title).font(.system(size: 13, weight: .semibold))
        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
}

// MARK: - 閱讀器

private struct CLITranscriptReader: View {
    let session: CLITranscriptSession
    let onResume: (CLITranscriptSession) -> Void

    @State private var items: [CLITranscriptItem]?
    @State private var expanded: Set<Int> = []
    @State private var query = ""
    @State private var showsTools = true
    @State private var percent = 0

    /// 大的對話有上萬則；篩選結果存起來，不在每次重畫時重算。
    @State private var visible: [CLITranscriptItem] = []

    private func refilter() {
        let needle = query.trimmingCharacters(in: .whitespaces)
        visible = (items ?? []).filter {
            (showsTools || ($0.kind != .toolCall && $0.kind != .toolResult))
                && (needle.isEmpty || $0.text.range(of: needle, options: .caseInsensitive) != nil
                    || ($0.toolName ?? "").range(of: needle, options: .caseInsensitive) != nil)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(14)
            Divider()
            if items == nil {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("讀取中 \(percent)% · \(ByteCountFormatter.string(fromByteCount: session.bytes, countStyle: .file))")
                        .monospacedDigit()
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                placeholder("text.magnifyingglass", query.isEmpty ? "這個檔裡沒有可顯示的對話" : "找不到「\(query)」", "")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) { ForEach(visible) { itemView($0) } }
                        .padding(14).frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
                }
            }
        }
        .task {
            let session = session
            let work = Task.detached(priority: .userInitiated) {
                CLITranscriptArchive.read(session) { value in Task { @MainActor in percent = value } }
            }
            items = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            refilter()
        }
        .onChange(of: query) { _, _ in refilter() }
        .onChange(of: showsTools) { _, _ in refilter() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(session.title).font(.system(size: 14, weight: .bold)).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 8)
                let blocked = CLITranscriptArchive.resumeBlockedReason(session)
                Button { onResume(session) } label: {
                    Label("接續", systemImage: "play.fill").font(.system(size: 11, weight: .semibold))
                }
                .controlSize(.small).disabled(blocked != nil)
                .help(blocked ?? (session.origin == .native
                    ? "開一個終端分頁，用你自己的 \(session.engine.label) CLI 接著這段對話"
                    : "開一個 OS 內建 \(session.engine.label) 分頁接著這段對話"))
                .accessibilityLabel("接續這段對話")
                iconButton("folder", "在 Finder 顯示原檔") { NSWorkspace.shared.activateFileViewerSelecting([session.url]) }
            }
            HStack(spacing: 6) {
                Text(session.engine.label + (session.origin == .osEngine ? "（OS 內建）" : "（你的 CLI）"))
                Text("·"); Text(session.cwd.isEmpty ? "—" : (session.cwd as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                Text("·"); Text(CLITranscriptHistoryView.dayFormatter.string(from: session.modifiedAt))
                if let items { Text("·"); Text("\(items.filter { $0.kind == .user }.count) 則你的訊息") }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("在這段對話裡找", text: $query).textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(maxWidth: 280)
                    .accessibilityLabel("在這段對話裡找")
                Toggle("顯示工具", isOn: $showsTools).toggleStyle(.checkbox).font(.system(size: 11))
                if !query.isEmpty, items != nil { Text("\(visible.count) 則符合").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder
    private func itemView(_ item: CLITranscriptItem) -> some View {
        switch item.kind {
        case .user, .assistant:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.kind == .user ? "你" : session.engine.label).font(.system(size: 11, weight: .bold))
                        .foregroundStyle(item.kind == .user ? LiquidGlassTokens.brandAccent : Color.secondary)
                    if let time = item.timestamp {
                        Text(CLITranscriptHistoryView.dayFormatter.string(from: time)).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                Text(item.text).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                clippedNote(item)
            }
            .padding(item.kind == .user ? 10 : 0)
            .background(item.kind == .user ? LiquidGlassTokens.brandAccent.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        case .toolCall, .toolResult, .summary:
            let open = expanded.contains(item.id)
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    if !expanded.insert(item.id).inserted { expanded.remove(item.id) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold)).frame(width: 10)
                        Image(systemName: item.kind == .toolCall ? "wrench.and.screwdriver" : item.kind == .toolResult ? "arrow.turn.down.right" : "rectangle.compress.vertical")
                            .font(.system(size: 10))
                        Text(item.kind == .toolCall ? (item.toolName ?? "工具") : item.kind == .toolResult ? "輸出" : "壓縮摘要（引擎自己整理的前情）")
                            .font(.system(size: 11, weight: .semibold))
                        if !open {
                            Text(item.text.prefix(160).replacingOccurrences(of: "\n", with: " ")).font(.system(size: 11, design: .monospaced))
                                .lineLimit(1).truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel((item.toolName ?? (item.kind == .toolResult ? "工具輸出" : "壓縮摘要")) + (open ? "，已展開" : "，已收合"))
                if open {
                    Text(item.text).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    clippedNote(item)
                }
            }
        }
    }

    @ViewBuilder
    private func clippedNote(_ item: CLITranscriptItem) -> some View {
        if item.clipped > 0 {
            Text("還有 \(item.clipped) 個字沒顯示；完整內容在原檔裡。").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}
