import SwiftUI

/// W180 E1：TATWO Space「記憶」頁——全部、搜尋、依類型篩、最近 7 天記下的（每條可撤銷）、待核准（W163 提案）、
/// 兩版並存、單條改（標題、別名、內文）、忘記（封存可還原）、最近忘記的（還原）。範圍欄位只存、畫面不出現。
/// 頁頂一行是記憶同步狀態（E1b 的 TatwoMemorySyncStatusRow）。按鈕一律玻璃 chip，確認用卡片內的確認列，不跳系統框。
struct TatwoMemoryPage: View {
    @ObservedObject var model: ChatPageModel
    @StateObject private var page = TatwoMemoryPageModel()
    @ObservedObject private var tabs = AssistantSpaceTabStore.shared

    var body: some View {
        GeometryReader { pane in
            let column = AssistantSpacePane.columnWidth(paneWidth: pane.size.width)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Label("記憶", systemImage: "brain").font(.headline)
                            Spacer(minLength: 8)
                            TatwoMemorySyncStatusRow()
                        }
                        if page.snapshot == nil {
                            ProgressView("讀取中…").frame(maxWidth: .infinity).padding(.vertical, 40)
                        } else if page.folderMissing {
                            folderMissingCard
                        } else {
                            searchField
                            filterChips
                            if let message = page.message {
                                Text(message).font(.caption).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("tatwo-memory-message")
                            }
                            content
                        }
                    }
                    .frame(width: column, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
                .onChange(of: page.highlightedID) { _, id in
                    guard let id else { return }
                    DispatchQueue.main.async { withAnimation { proxy.scrollTo("memory-\(id)", anchor: .center) } }
                }
            }
        }
        .accessibilityIdentifier("tatwo-memory-page")
        .task {
            await page.reload()
            consumeFocus()
        }
        .onChange(of: tabs.memoryFocusID) { _, _ in consumeFocus() }
    }

    private func consumeFocus() {
        guard let id = tabs.memoryFocusID, page.snapshot != nil else { return }
        tabs.memoryFocusID = nil
        page.focus(id)
    }

    // MARK: - 資料夾沒接上

    private var folderMissingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(TatwoMemoryPageModel.folderMissingText)
                .font(.system(size: 13))
                .accessibilityIdentifier("tatwo-memory-folder-missing")
            OSChipButton(title: "打開 設定 › OS", systemImage: "gearshape") {
                NotificationCenter.default.post(name: .tatwoOpenSettingsSection, object: TatwoSettingsPage.Section.os.rawValue)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
    }

    // MARK: - 搜尋與篩選

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
            ChatChipTextField(title: "搜尋記憶（字面或別名）", text: $page.query)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("tatwo-memory-search")
            if !page.query.isEmpty {
                Button { page.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜尋")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .chatGlassChip(isSelected: false)
    }

    private var filterChips: some View {
        var filters: [TatwoMemoryPageModel.Filter] = [.all, .recent, .pending]
        if page.conflictCount > 0 { filters.append(.conflicts) }
        filters.append(.forgotten)
        filters += page.types.map { .type($0) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(filters, id: \.self) { filter in
                    let selected = page.filter == filter
                    Button { page.filter = filter; page.cancelEdit() } label: {
                        Text(chipTitle(filter))
                            .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .chatGlassChip(isSelected: selected)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private func chipTitle(_ filter: TatwoMemoryPageModel.Filter) -> String {
        switch filter {
        case .all: "全部 \(page.entries.count)"
        case .conflicts: "兩版並存 \(page.conflictCount)"
        default: filter.title
        }
    }

    // MARK: - 內容

    @ViewBuilder
    private var content: some View {
        switch page.filter {
        case .pending:
            MemoryProposalsView()
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
                .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
        case .forgotten:
            forgottenList
        default:
            let rows = page.visible()
            if rows.isEmpty {
                Text(emptyText).font(.callout).foregroundStyle(.secondary).padding(.vertical, 24)
            }
            ForEach(rows) { entry in
                entryCard(entry).id("memory-\(entry.id)")
            }
        }
    }

    private var emptyText: String {
        if !page.query.trimmingCharacters(in: .whitespaces).isEmpty { return "找不到符合的記憶。" }
        switch page.filter {
        case .recent: return "最近 7 天沒有新記下的。"
        case .conflicts: return "沒有兩版並存的記憶。"
        default: return "還沒有記憶。在對話裡說「記住…」，或讓助理用 memory_save 記下來。"
        }
    }

    private func entryCard(_ entry: TatwoMemoryEntry) -> some View {
        let editing = page.editingID == entry.id
        let highlighted = page.highlightedID == entry.id
        return VStack(alignment: .leading, spacing: 8) {
            Button { editing ? page.cancelEdit() : page.beginEdit(entry) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        if entry.file.isConflictCopy { tag("兩版並存") }
                        Spacer(minLength: 6)
                        if let type = entry.file.type, !type.isEmpty { tag(TatwoMemoryPageModel.typeName(type)) }
                    }
                    if !entry.summary.isEmpty {
                        Text(entry.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        if !entry.file.aliases.isEmpty {
                            Text("別名：" + entry.file.aliases.joined(separator: "、"))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text(entry.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tatwo-memory-row-\(entry.id)")
            if editing {
                editor(entry)
            } else if page.isRecent(entry) && page.filter == .recent {
                HStack {
                    Spacer()
                    OSChipButton(title: "撤銷") { page.confirmForgetID = entry.id }
                }
                if page.confirmForgetID == entry.id { forgetConfirm(entry) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
        .overlay {
            if highlighted {
                RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusCard, style: .continuous)
                    .strokeBorder(LiquidGlassTokens.brandAccent.opacity(0.45), lineWidth: 1.5)
            }
        }
    }

    private func editor(_ entry: TatwoMemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            field("標題") {
                TextField("一句話", text: $page.draftTitle).textFieldStyle(.plain)
                    .accessibilityIdentifier("tatwo-memory-edit-title")
            }
            field("別名（用「、」分開，挑記憶時會比對）") {
                TextField("例：飲食、忌口、點餐", text: $page.draftAliases).textFieldStyle(.plain)
                    .accessibilityIdentifier("tatwo-memory-edit-aliases")
            }
            field("內容") {
                TextEditor(text: $page.draftContent)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 110, maxHeight: 220)
                    .accessibilityIdentifier("tatwo-memory-edit-content")
            }
            if let source = entry.file.source, !source.isEmpty {
                Text("出處：" + source).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                OSChipButton(title: "忘記", role: .destructive) { page.confirmForgetID = entry.id }
                    .accessibilityIdentifier("tatwo-memory-forget")
                Spacer()
                OSChipButton(title: "取消") { page.cancelEdit() }
                OSChipButton(title: "存", isPrimary: true) { Task { await page.saveEdit() } }
                    .accessibilityIdentifier("tatwo-memory-save")
            }
            .disabled(page.busy)
            if page.confirmForgetID == entry.id { forgetConfirm(entry) }
        }
    }

    /// 卡片內的確認列（不跳系統框）。
    private func forgetConfirm(_ entry: TatwoMemoryEntry) -> some View {
        HStack(spacing: 8) {
            Text("忘記這條？會移到封存，可以在「最近忘記的」還原。")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            OSChipButton(title: "先不要") { page.confirmForgetID = nil }
            OSChipButton(title: "忘記", role: .destructive) { Task { await page.forget(entry.id) } }
                .accessibilityIdentifier("tatwo-memory-forget-confirm")
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .disabled(page.busy)
    }

    private var forgottenList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if page.forgotten.isEmpty {
                Text("最近沒有忘記的記憶。").font(.callout).foregroundStyle(.secondary).padding(.vertical, 24)
            }
            ForEach(page.forgotten) { record in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        Text("\(record.forgottenAt.formatted(date: .abbreviated, time: .shortened))・封存在 \(record.archivePath)")
                            .font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    OSChipButton(title: "還原") { Task { await page.restore(record) } }
                        .disabled(page.busy)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
            }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            content()
                .font(.system(size: 12.5))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).frame(height: 17)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }
}
