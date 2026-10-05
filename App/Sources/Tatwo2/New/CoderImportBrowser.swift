import AppKit
import SwiftUI

/// W181 R1：「從 Codex／Claude Code 匯入…」。照各家自己左邊欄的專案挑：左欄專案、中欄這個專案的對話、右欄預覽。
/// 讀檔都在背景、可以取消；原檔只讀。匯入沿用 E3（ChatPageModel.importCLISessions → ChatLiveEngine.importCLISessions）。
struct CoderImportBrowser: View {
    @ObservedObject var model: ChatPageModel
    let roots: CoderImportCatalog.Roots?
    /// 串的右鍵「看原檔」：用出處（家別＋session id）找那一則，直接打開完整紀錄。
    var focus: CoderImportFocus? = nil
    let onClose: () -> Void
    @ObservedObject private var job = CoderImportJob.shared

    @State private var engine: CLITranscriptSession.Engine = .codex
    @State private var catalogs: [CLITranscriptSession.Engine: [CoderImportProject]] = [:]
    @State private var projectIDs: [CLITranscriptSession.Engine: String] = [:]
    @State private var conversationID: String?
    @State private var showsProjectless = false
    /// 「看原檔」那則不在清單裡（子代理、背景執行，或原檔已不在）時單獨預覽。
    @State private var outside: CoderImportConversation?
    @State private var focusNote: String?

    private var projects: [CoderImportProject] { catalogs[engine] ?? [] }
    private var project: CoderImportProject? { projects.first { $0.id == projectIDs[engine] } }
    private var conversation: CoderImportConversation? {
        project?.conversations.first { $0.id == conversationID } ?? (outside?.id == conversationID ? outside : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.coderImportViewOnly { note(CoderImport.viewOnlyHint, symbol: "info.circle") }
            header
            if let focusNote { note(focusNote, symbol: "doc.text.magnifyingglass") }
            Divider()
            HStack(spacing: 0) {
                projectColumn.frame(width: 240)
                Divider()
                conversationColumn.frame(width: 350)
                Divider()
                if let conversation {
                    CoderImportPreviewPane(conversation: conversation, imported: isImported(conversation), busy: job.isRunning,
                                           startsFull: focus.map { $0.matches(conversation.session) } ?? false) {
                        importOne(conversation)
                    }
                        .id(conversation.id)
                } else {
                    placeholder("text.bubble", "選一則對話來看", "右邊先顯示最近的內容；要看全部按「讀完整紀錄」。工具呼叫與輸出不會匯入。")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 980, minHeight: 600)
        .task(id: engine) { await load(engine) }
        .task { await focusOnSource() }
        .accessibilityIdentifier("coder.import.browser")
    }

    // MARK: 上方

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28).chatGlassChip().contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("關閉（Esc）").accessibilityLabel("關閉").accessibilityIdentifier("coder.import.close")
            .coderSheetTestFrame("close")
            Text("從 Codex／Claude Code 匯入").font(.system(size: 14, weight: .bold)).lineLimit(1)
            HStack(spacing: 6) {
                sourceChip(.codex, "Codex")
                sourceChip(.claude, "Claude Code")
            }
            .padding(.leading, 6)
            Spacer(minLength: 8)
            OSChipButton(title: "完成", isPrimary: true, action: onClose)
                .help("關閉這個視窗（Esc）").accessibilityIdentifier("coder.import.done")
                .coderSheetTestFrame("done")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func sourceChip(_ value: CLITranscriptSession.Engine, _ title: String) -> some View {
        let active = engine == value
        return Button { engine = value } label: {
            Text(title).font(.system(size: 12, weight: active ? .semibold : .regular))
                .padding(.horizontal, 11).padding(.vertical, 5).chatGlassChip(isSelected: active).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: 左欄：專案

    private var projectColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(engine == .codex ? "Codex 的專案" : "Claude Code 的專案")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
            if catalogs[engine] == nil {
                loading(engine == .codex ? "讀取 Codex 的專案…" : "讀取 Claude Code 的專案…")
            } else if projects.isEmpty {
                placeholder("tray", engine == .codex ? "這台沒有 Codex App 的專案" : "這台沒有 Claude Code 的對話",
                            roots == nil ? "示範資料模式不讀真的紀錄。" : "用過之後，它們左邊欄的專案會出現在這裡。")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(projects.filter { !$0.isProjectless }) { projectRow($0) }
                        if let loose = projects.first(where: \.isProjectless) {
                            Button { showsProjectless.toggle() } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: showsProjectless ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                                    Text(CoderImportCatalog.projectlessName).font(.system(size: 11, weight: .semibold))
                                    Spacer(minLength: 4)
                                    Text("\(loose.conversations.count)").font(.system(size: 10).monospacedDigit())
                                }
                                .foregroundStyle(.secondary).padding(.horizontal, 6).padding(.top, 10).padding(.bottom, 4).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if showsProjectless { projectRow(loose) }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(10)
    }

    private func projectRow(_ item: CoderImportProject) -> some View {
        let selected = projectIDs[engine] == item.id
        return Button {
            projectIDs[engine] = item.id
            conversationID = nil
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if item.isPinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.secondary) }
                    Text(item.isProjectless ? "全部 \(item.conversations.count) 則" : item.name)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular)).lineLimit(1)
                }
                Text(item.conversations.isEmpty ? "還沒有對話"
                     : "\(item.conversations.count) 則 · 最後 \(Self.day(item.lastActivity ?? .distantPast))")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(selected ? LiquidGlassTokens.brandAccent.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.root.isEmpty ? item.name : (item.root as NSString).abbreviatingWithTildeInPath)
        .accessibilityLabel("\(item.name)，\(item.conversations.count) 則")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: 中欄：這個專案的對話

    @ViewBuilder
    private var conversationColumn: some View {
        if let project {
            VStack(alignment: .leading, spacing: 8) {
                Text(project.isProjectless ? CoderImportCatalog.projectlessName : project.name)
                    .font(.system(size: 14, weight: .bold)).lineLimit(1)
                Text(project.isProjectless ? projectlessNote(project) : (project.root as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                projectImportChip(project)
                Divider()
                if project.conversations.isEmpty {
                    placeholder("tray", "這個專案沒有可以匯入的對話", "子代理、背景執行（exec、SDK、-p）與封存的不列。")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(project.conversations) { conversationRow($0, in: project) }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .padding(12)
        } else if let outside {
            VStack(alignment: .leading, spacing: 8) {
                Text("這則原檔").font(.system(size: 14, weight: .bold))
                conversationRow(outside, in: nil)
                Spacer(minLength: 0)
            }
            .padding(12)
        } else {
            placeholder("folder", catalogs[engine] == nil ? "讀取中…" : "選左邊一個專案", "")
        }
    }

    private func projectImportChip(_ project: CoderImportProject) -> some View {
        let available = project.conversations.filter(\.fileExists)
        let pending = available.filter { !isImported($0) }.count
        let title = pending > 0 ? "匯入這個專案（\(pending) 則）" : available.isEmpty ? "沒有可以匯入的對話" : "都已匯入"
        return OSChipButton(title: title, systemImage: pending > 0 ? "square.and.arrow.down" : "checkmark", isPrimary: pending > 0) {
            model.importCoderProject(project)
        }
        .disabled(pending == 0 || job.isRunning)
        .help(pending > CoderImport.maxSessionsPerBatch
              ? "一次最多 \(CoderImport.maxSessionsPerBatch) 則，先匯入最近的；再按一次接著匯入"
              : "放進 Coder 的「\(model.coderImportDestination(project)?.name ?? project.name)」專案（沒有就建一個）")
        .accessibilityIdentifier("coder.import.project")
    }

    private func conversationRow(_ item: CoderImportConversation, in project: CoderImportProject?) -> some View {
        let selected = conversationID == item.id
        let imported = isImported(item)
        return HStack(alignment: .center, spacing: 8) {
            Button { conversationID = item.id } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 12.5, weight: selected ? .semibold : .regular)).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(Self.day(item.activity)).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !item.fileExists {
                Text("原檔已不在").font(.system(size: 10.5)).foregroundStyle(.secondary)
            } else {
                Button { importOne(item) } label: {
                    Text(imported ? "已匯入・打開" : "匯入").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        .padding(.horizontal, 9).frame(height: 24).chatGlassChip(isSelected: !imported).contentShape(Rectangle())
                }
                .buttonStyle(.plain).fixedSize().disabled(job.isRunning)
                .accessibilityLabel(imported ? "打開已匯入的「\(item.title)」" : "匯入「\(item.title)」")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(selected ? LiquidGlassTokens.brandAccent.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: 下方

    private var footer: some View {
        HStack(spacing: 8) {
            if job.isRunning || !job.status.isEmpty {
                if job.isRunning { ProgressView().controlSize(.small) }
                Text(job.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 8)
                if job.isRunning { OSChipButton(title: "取消") { job.cancel() } }
            } else if let notice = CoderImportCatalog.nearCapNotice(used: model.coderImportUsedBytes) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.orange)
                Text(notice).font(.system(size: 11)).lineLimit(2)
                Spacer(minLength: 0)
            } else {
                Text("匯入的對話放進 Coder 的同名專案，每則放最近的內容，會跟著 Coder 同步到配對設備；原檔只讀，不搬不改。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func projectlessNote(_ project: CoderImportProject) -> String {
        guard let destination = model.coderImportDestination(project) else { return "沒有歸在專案裡的對話；匯入時照各則自己的資料夾放。" }
        return "沒有歸在專案裡的對話；匯入時一起放進 Coder 的「\(destination.name)」專案。"
    }

    private func note(_ text: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 7)
        .background(LiquidGlassTokens.brandAccent.opacity(0.07))
    }

    // MARK: 動作

    /// 家別＋session id（跟 E3 去重一樣），不比路徑字串：~/.codex、~/.claude 是捷徑時也對得上。
    private func isImported(_ item: CoderImportConversation) -> Bool { model.coderImportIsImported(item) }

    private func importOne(_ item: CoderImportConversation) {
        if let project { model.importCoderConversation(item, in: project) } else { model.importCLISessions([item.session]) }
    }

    private func load(_ value: CLITranscriptSession.Engine) async {
        guard catalogs[value] == nil else { return }
        guard let roots else { catalogs[value] = []; return }
        let work = Task.detached(priority: .userInitiated) { CoderImportCatalog.load(value, roots: roots) }
        let loaded = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled else { return }
        catalogs[value] = loaded
        if projectIDs[value] == nil { projectIDs[value] = (loaded.first { !$0.isProjectless } ?? loaded.first)?.id }
    }

    /// 串的右鍵「看原檔」：用出處的家別＋session id 找到它在哪個專案，直接選好；不在清單裡的（子代理、背景執行）
    /// 用出處的家別單獨讀，不從路徑猜是哪一家。
    private func focusOnSource() async {
        guard let focus else { return }
        let order: [CLITranscriptSession.Engine] = focus.engine.map { [$0] } ?? [.codex, .claude]
        for value in order {
            await load(value)
            guard !Task.isCancelled else { return }
            if let hit = CoderImportCatalog.locate(focus, in: catalogs[value] ?? []) {
                engine = value
                projectIDs[value] = hit.project.id
                if hit.project.isProjectless { showsProjectless = true }
                conversationID = hit.conversation.id
                return
            }
        }
        let path = CoderImportCatalog.resolvedPath(focus.path)
        let info = CoderImportCatalog.fileInfo(path)
        guard info.exists else { focusNote = "原檔已不在（可能被 CLI 自己的保留期清掉了）；Coder 裡這條的內容還在。"; return }
        let owner = focus.engine ?? guessEngine(path)
        let url = URL(fileURLWithPath: path)
        let source = CLITranscriptArchive.Source(root: url.deletingLastPathComponent(), engine: owner, origin: .native)
        guard let session = await Task.detached(priority: .userInitiated, operation: { CLITranscriptArchive.describe(url, source: source) }).value
        else { return }
        focusNote = "這則不在 \(owner == .codex ? "Codex" : "Claude Code") 左邊欄的專案裡（可能是子代理或背景執行），只在這裡看。"
        let item = CoderImportConversation(session: session, activity: session.modifiedAt, fileExists: true)
        engine = owner
        projectIDs[owner] = nil
        outside = item
        conversationID = item.id
    }

    /// 舊的匯入串沒有家別時才用：看原檔在哪一家的資料夾底下（兩邊都解開捷徑再比）。
    private func guessEngine(_ path: String) -> CLITranscriptSession.Engine {
        guard let roots else { return .claude }
        let codex = CoderImportCatalog.resolvedPath(roots.codexHome.path)
        return path.hasPrefix(codex + "/") ? .codex : .claude
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "M/d HH:mm" : "yyyy/M/d"
        return formatter.string(from: date)
    }
}

// MARK: - 右欄：預覽（先讀原檔最後一段；「讀完整紀錄」照 W110 整份讀）

private struct CoderImportPreviewPane: View {
    let conversation: CoderImportConversation
    let imported: Bool
    let busy: Bool
    let onImport: () -> Void
    /// 最近的內容（只讀檔尾）。
    @State private var items: [CLITranscriptItem]?
    @State private var partial = false
    /// W181 審查修正：完整紀錄（「看原檔」直接打開；W110 的讀檔：整份、背景、有進度、切走就取消）。
    @State private var full: Bool
    @State private var record: [CLITranscriptItem]?
    @State private var percent = 0
    @State private var query = ""
    @State private var showsTools = false
    @State private var visible: [CLITranscriptItem] = []
    @State private var expanded: Set<Int> = []

    init(conversation: CoderImportConversation, imported: Bool, busy: Bool, startsFull: Bool, onImport: @escaping () -> Void) {
        self.conversation = conversation
        self.imported = imported
        self.busy = busy
        self.onImport = onImport
        _full = State(initialValue: startsFull)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(14)
            Divider()
            if full { fullRecord } else { recent }
        }
        .task(id: full) { await load() }
        .task(id: "\(query)|\(showsTools)|\(record?.count ?? -1)") { await refilter() }
    }

    @ViewBuilder
    private var recent: some View {
        if items == nil {
            loading("讀取最近的內容…")
        } else if items?.isEmpty == true {
            placeholder("text.magnifyingglass", conversation.fileExists ? "這則沒有可顯示的對話" : "原檔已不在", "")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if partial {
                        Text("只顯示最近的內容；要看全部按上面的「讀完整紀錄」。").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                    ForEach(items ?? []) { row($0) }
                }
                .padding(14).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var fullRecord: some View {
        if record == nil {
            loading("讀取完整紀錄 \(percent)% · \(ByteCountFormatter.string(fromByteCount: conversation.session.bytes, countStyle: .file))")
        } else if visible.isEmpty {
            placeholder("text.magnifyingglass", query.isEmpty ? "這個檔裡沒有可顯示的對話" : "找不到「\(query)」", "")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) { ForEach(visible) { fullRow($0) } }
                    .padding(14).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
            }
        }
    }

    private func load() async {
        guard conversation.fileExists else { items = []; record = []; return }
        let session = conversation.session
        if full {
            guard record == nil else { return }
            percent = 0
            let work = Task.detached(priority: .userInitiated) {
                CLITranscriptArchive.read(session) { value in Task { @MainActor in percent = value } }
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            record = result
        } else {
            guard items == nil else { return }
            let work = Task.detached(priority: .userInitiated) { CoderImportCatalog.previewItems(session) }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            items = result.items
            partial = result.partial
        }
    }

    /// 篩選也在背景算：大的對話有上萬則，不在主執行緒逐則比對。
    private func refilter() async {
        guard let record else { visible = []; return }
        let needle = query, tools = showsTools
        let work = Task.detached(priority: .userInitiated) { CoderImportCatalog.filter(record, query: needle, showsTools: tools) }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled else { return }
        visible = result
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(conversation.title).font(.system(size: 14, weight: .bold)).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 8)
                if conversation.fileExists {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([conversation.session.url]) } label: {
                        Image(systemName: "folder").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("在 Finder 顯示原檔").accessibilityLabel("在 Finder 顯示原檔")
                    OSChipButton(title: imported ? "已匯入・打開" : "匯入", systemImage: imported ? "arrow.up.right.square" : "square.and.arrow.down",
                                 isPrimary: !imported, action: onImport)
                        .disabled(busy)
                }
            }
            HStack(spacing: 6) {
                Text(conversation.session.engine == .codex ? "Codex" : "Claude Code")
                if !conversation.session.cwd.isEmpty {
                    Text("·"); Text((conversation.session.cwd as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                }
                Text("·"); Text(CoderImportBrowser.day(conversation.activity))
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            if conversation.fileExists {
                HStack(spacing: 8) {
                    OSChipButton(title: full ? "只看最近" : "讀完整紀錄", systemImage: full ? "text.append" : "doc.text.magnifyingglass") { full.toggle() }
                        .help(full ? "回到最近的內容" : "整份讀原檔（只讀）：大的對話要讀一下，切走就停")
                        .accessibilityIdentifier("coder.import.fullRecord")
                    if full {
                        ChatChipTextField(title: "在這段對話裡找", text: $query).textFieldStyle(.plain).font(.system(size: 12))
                            .padding(.horizontal, 10).frame(width: 220, height: 26).chatGlassChip()
                            .accessibilityLabel("在這段對話裡找")
                        Button { showsTools.toggle() } label: {
                            Text("顯示工具").font(.system(size: 11, weight: showsTools ? .semibold : .regular))
                                .padding(.horizontal, 10).frame(height: 26).chatGlassChip(isSelected: showsTools).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityAddTraits(showsTools ? .isSelected : [])
                        if !query.isEmpty, record != nil { Text("\(visible.count) 則符合").font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    private func speaker(_ item: CLITranscriptItem) -> String {
        item.kind == .user ? "你" : item.kind == .summary ? "前情摘要" : (conversation.session.engine == .codex ? "Codex" : "Claude")
    }

    private func row(_ item: CLITranscriptItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(speaker(item))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(item.kind == .user ? LiquidGlassTokens.brandAccent : Color.secondary)
            Text(item.text.count > 1_500 ? String(item.text.prefix(1_500)) + "…" : item.text)
                .font(.system(size: 12.5)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(item.kind == .user ? 10 : 0)
        .background(item.kind == .user ? LiquidGlassTokens.brandAccent.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
    }

    /// 完整紀錄的一則：你說的、AI 回的整段顯示；工具呼叫、輸出、壓縮摘要收起來，點開看（照 W110）。
    @ViewBuilder
    private func fullRow(_ item: CLITranscriptItem) -> some View {
        switch item.kind {
        case .user, .assistant:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(speaker(item)).font(.system(size: 11, weight: .bold))
                        .foregroundStyle(item.kind == .user ? LiquidGlassTokens.brandAccent : Color.secondary)
                    if let time = item.timestamp { Text(CoderImportBrowser.day(time)).font(.system(size: 10)).foregroundStyle(.tertiary) }
                }
                Text(item.text).font(.system(size: 12.5)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
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

private func loading(_ text: String) -> some View {
    VStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

private func placeholder(_ symbol: String, _ title: String, _ detail: String) -> some View {
    VStack(spacing: 8) {
        Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.secondary)
        Text(title).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.center)
        if !detail.isEmpty {
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 300)
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(16)
}

// MARK: - 自測用：記下 ✕／完成在畫面上的位置（只在 DEBUG；正式版什麼都不做）

#if DEBUG
@MainActor enum CoderSheetTestFrames {
    static var frames: [String: CGRect] = [:]
}
#endif

extension View {
    @MainActor @ViewBuilder func coderSheetTestFrame(_ key: String) -> some View {
        #if DEBUG
        background(GeometryReader { proxy in
            Color.clear
                .onAppear { CoderSheetTestFrames.frames[key] = proxy.frame(in: .global) }
                .onChange(of: proxy.frame(in: .global)) { _, value in CoderSheetTestFrames.frames[key] = value }
        })
        #else
        self
        #endif
    }
}
