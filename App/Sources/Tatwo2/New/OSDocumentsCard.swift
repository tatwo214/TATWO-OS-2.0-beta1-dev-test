// 2.0 新畫面（不是照搬）：設定頁「文件」— os.md／skillet.md／os-upstream.md（你改）、todo.md／issue.md（工程用）在 App 裡可看可改。
// 使用者 2026-09-05 點頭；2026-09-22 改成唯讀顯示＋畫布編輯，拿掉「請 AI 整理」。改動先備份再寫檔。
import SwiftUI

struct OSDocumentsCard: View {
    @ObservedObject var model: ChatPageModel
    @State private var selectedID: String?
    @State private var draft = ""
    @State private var loadedFor: String?
    @State private var baseText = ""
    @State private var proposals: [DeviceInbox.Proposal] = []
    @State private var dispatchStatus = ""
    @State private var acceptedProposalID: String?
    /// W160：從設定 › OS 的「文件 ›」進來時有返回鈕。
    var onBack: (() -> Void)? = nil
    /// W160（使用者 2026-09-22）：內文預設唯讀，按「編輯」才開畫布改，避免誤觸。
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: TatwoSettingsPageMetrics.sectionSpacing) {
        TatwoSettingsPageHeader(title: onBack == nil ? "文件" : "OS › 文件",
                                subtitle: OSDocuments.isPrimary ? "本機是主設備，改了直接存進入口並記版本。"
                                    : "正本在主設備；這台改了會送去主設備核准。") {
            if let onBack { OSChipButton(title: "‹ OS", action: onBack) }
        }
        Group {
            if !TatwoEntry().exists {
                VStack(alignment: .leading, spacing: 8) {
                    Text("找不到入口 \(TatwoEntry().root.path)")
                        .textSelection(.enabled)
                    if TatwoEntry().status == .brokenSymbolicLink {
                        Text("入口連結已斷開").foregroundStyle(.secondary)
                    }
                    Button("重新讀取") { syncDraft() }
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    list
                        .frame(width: 240)
                    editor
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(TatwoSettingsPageMetrics.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if selectedID == nil { selectedID = model.osDocuments.first?.id }
            syncDraft()
        }
        .onChange(of: selectedID) { _ in syncDraft() }
        .onChange(of: model.osDocumentText) { _ in
            if let id = selectedID, loadedFor != id, let text = model.osDocumentText[id] {
                draft = text; baseText = text; loadedFor = id
            }
        }
        .task {
            while !Task.isCancelled {
                proposals = DeviceInbox.shared.proposals()
                if let id = selectedID, let sent = proposals.last(where: { $0.document == id }),
                   sent.status == "sent", sent.id != acceptedProposalID,
                   baseText == sent.base || baseText == sent.text {
                    baseText = sent.text; acceptedProposalID = sent.id
                    // Refresh the accepted baseline, never replace a draft that the
                    // user continued editing while the request was in flight.
                    model.loadOSDocument(id: id)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // MARK: 左列

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // os-upstream 由 os.md 產生，不再列給使用者。
                section("", model.osDocuments.filter { $0.id != "os-upstream" })
                Text("記憶").font(.caption).foregroundStyle(.secondary)
                memoryRow("記憶提案", subtitle: "AI 或聊天「記住…」提的，核准才寫進 user.md", id: "memory")
                memoryRow("GBrain", subtitle: "決策、教訓、環境事實；需要時才查", id: "gbrain")
            }
        }
    }

    private func memoryRow(_ title: String, subtitle: String, id: String) -> some View {
        Button { selectedID = id } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(selectedID == id ? .semibold : .regular))
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(selectedID == id ? LiquidGlassTokens.brandAccent.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 這份文件被誰讀（W160 使用者要求：看得出每份文件被哪些 AI 引擎使用）。
    static func readers(_ id: String) -> [String] {
        switch id {
        case "os": return ["產生 agents.md"]
        case "agents": return ["Claude", "Codex", "OpenClaw", "內建"]
        case "user": return ["全部引擎"]
        case "skillet": return ["$skillet"]
        case "todo", "issue": return ["需要時讀"]
        default: return []
        }
    }

    private func section(_ title: String, _ docs: [OSDocument]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(docs) { doc in
                Button {
                    selectedID = doc.id
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(doc.title)
                            .font(.subheadline.weight(selectedID == doc.id ? .semibold : .regular))
                        Text(doc.whatItIsFor)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        HStack(spacing: 4) {
                            ForEach(Self.readers(doc.id), id: \.self) { reader in
                                Text(reader).font(.caption2).lineLimit(1).fixedSize()
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .foregroundStyle(.secondary)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(selectedID == doc.id ? LiquidGlassTokens.brandAccent.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 右邊：編輯

    @ViewBuilder
    private var editor: some View {
        if selectedID == "gbrain" {
            GBrainSettingsView()
        } else if selectedID == "memory" {
            MemoryProposalsView(onAccepted: { model.loadOSDocument(id: "user") })
        } else if let id = selectedID, let doc = model.osDocuments.first(where: { $0.id == id }) {
            if let error = model.osDocumentReadErrors[id] {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).textSelection(.enabled)
                    Text(doc.path).font(.caption).textSelection(.enabled)
                    Button("重新讀取") { syncDraft() }
                }
            } else if model.osDocumentText[id] != nil {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(doc.title).font(.headline)
                    Spacer()
                    if doc.isEditable {
                        OSChipButton(title: "編輯", systemImage: "square.and.pencil") {
                            draft = model.osDocumentText[id] ?? ""; editing = true
                        }
                    } else {
                        Text("唯讀").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(doc.path).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(doc.path).textSelection(.enabled)
                if let status = model.osDocumentSaveStatus[id] {
                    Text(status).font(.footnote).textSelection(.enabled)
                } else if (id == "todo" || id == "issue") && !OSDocuments.isPrimary {
                    Text("副設備：未提交").font(.footnote).foregroundStyle(.secondary)
                }
                if !dispatchStatus.isEmpty { Text(dispatchStatus).font(.footnote).textSelection(.enabled) }
                if !OSDocuments.isPrimary, let proposal = proposals.last(where: { $0.document == id }) {
                    Text(proposal.status == "sent" ? "已送主設備並讀回同版" :
                         proposal.status == "conflict" ? "● 衝突：兩邊原件保留，請選三方差異" : "待送出的修改（原件未改）")
                        .font(.footnote).foregroundStyle(proposal.status == "conflict" ? Color.red : Color.secondary)
                    if proposal.status == "sent", let date = proposal.updated {
                        Text("最後同步：\(date.formatted())").font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = proposal.error { Text(error).font(.caption).foregroundStyle(.orange) }
                    if proposal.status == "conflict" {
                        ScrollView(.horizontal) {
                            HStack(alignment: .top) {
                                conflictColumn("共同基準", proposal.base)
                                conflictColumn("本次修改", proposal.text)
                                conflictColumn("主設備目前", proposal.primaryText ?? "")
                                if let local = proposal.localText { conflictColumn("本機原件另有修改", local) }
                            }
                        }.frame(maxHeight: 220)
                        HStack {
                            OSChipButton(title: "選本次修改") { resolve(proposal, useProposal: true) }
                            OSChipButton(title: "選主設備版本") { resolve(proposal, useProposal: false) }
                        }
                    }
                }
                ScrollView {
                    Text(Self.rendered(model.osDocumentText[id] ?? ""))
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(minHeight: 260, maxHeight: .infinity)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("每次存檔前會先備份一份到同目錄的 .tatwo2-backups/；主設備存檔同時在入口記一版（有開 GitHub 備份就一併推上去）。")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .sheet(isPresented: $editing) { canvas(id: id, doc: doc) }
            } else {
                ProgressView("讀取文件")
            }
        } else {
            Text("左邊選一份文件。")
                .foregroundStyle(.secondary)
        }
    }

    /// 畫布：在這裡改完按「存檔」才寫檔；「取消」什麼都不動。
    private func canvas(id: String, doc: OSDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("編輯 \(doc.title)").font(.headline)
                Spacer()
                OSChipButton(title: "取消") { editing = false }
                OSChipButton(title: "存檔", isPrimary: true) {
                    saveDocument(id: id, text: draft); editing = false
                }
                .disabled(draft == (model.osDocumentText[id] ?? ""))
            }
            TextEditor(text: $draft)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(OSDocuments.isPrimary ? "存檔後舊版先備份，並在入口記一版。" : "存檔後送去主設備核准；主設備寫入後這台會收到同一版。")
                .font(.footnote).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(minWidth: 720, idealWidth: 860, minHeight: 560, idealHeight: 680)
    }

    /// 唯讀顯示用：保留換行，行內 Markdown（粗體、程式碼）照樣呈現；解析失敗就顯示原文。
    static func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private func syncDraft() {
        guard let id = selectedID else { return }
        guard id != "gbrain" else { return }
        loadedFor = nil
        draft = ""
        model.loadOSDocument(id: id)
        if let text = model.osDocumentText[id] { draft = text; baseText = text; loadedFor = id }
        dispatchStatus = ""
    }

    private func saveDocument(id: String, text: String) {
        if OSDocuments.isPrimary || id == "os-upstream" {
            model.saveOSDocument(id: id, text: text)
        } else {
            do {
                _ = try DeviceInbox.shared.enqueue(id: id, text: text, base: baseText)
                dispatchStatus = "已存成本機待送出的修改；連線後自動送主設備"
            } catch { dispatchStatus = error.localizedDescription }
            proposals = DeviceInbox.shared.proposals()
        }
    }
    private func conflictColumn(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption.bold())
            ScrollView { Text(text).font(.caption.monospaced()).textSelection(.enabled) }
        }.frame(width: 240)
    }
    private func resolve(_ proposal: DeviceInbox.Proposal, useProposal: Bool) {
        do {
            try DeviceInbox.shared.resolve(id: proposal.id, useProposal: useProposal)
            proposals = DeviceInbox.shared.proposals()
        } catch { dispatchStatus = error.localizedDescription }
    }
}

private struct GBrainSettingsView: View {
    @ObservedObject private var service = GBrainService.shared
    @State private var openAI = ""
    @State private var anthropic = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GBrain").font(.headline)
            Text("OS 的共用記憶庫（在主設備）").foregroundStyle(.secondary)
            Label(service.status, systemImage: service.healthy ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(service.healthy ? Color.green : Color.orange)
            if let count = service.pageCount { Text("頁數：\(count)") }
            Text("最後寫入：\(service.lastWrite.isEmpty ? "尚無資料" : service.lastWrite)")
            Text(service.directory).font(.caption).textSelection(.enabled)
            Button("在 Finder 打開") { NSWorkspace.shared.open(URL(fileURLWithPath: service.directory)) }
            HStack {
                Button("重新查詢") { service.refresh() }
                Button("啟動") { service.start() }
                Button("停止") { service.stop() }
            }
            DisclosureGroup("API 金鑰") {
                VStack(alignment: .leading, spacing: 10) {
                    if !service.isPrimary {
                        Text("語意搜尋在主設備 \(service.primaryName) 執行，請在主設備設定").foregroundStyle(.secondary)
                    }
                    keyRow("OpenAI", provider: "openai", configured: service.openAIConfigured, text: $openAI)
                    keyRow("Anthropic（選用）", provider: "anthropic", configured: service.anthropicConfigured, text: $anthropic)
                    Toggle("語意搜尋", isOn: Binding(get: { service.semanticEnabled }, set: { service.setSemantic($0) }))
                        .disabled(!service.isPrimary || !service.openAIConfigured)
                        .disabled(service.mode == "legacy")
                    if service.mode == "legacy" {
                        Text("既有 Postgres 的搜尋沿用原服務，本單不變更設定").foregroundStyle(.secondary)
                    } else if !service.semanticEnabled { Text("目前只有關鍵字搜尋").foregroundStyle(.secondary) }
                }.disabled(!service.isPrimary)
            }
            if !service.message.isEmpty { Text(service.message).font(.caption) }
        }.onAppear { service.refresh(); service.start() }
    }
    private func keyRow(_ label: String, provider: String, configured: Bool, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
            if configured { Text("已設定").foregroundStyle(.secondary) }
            else { SecureField("API 金鑰", text: text) }
            HStack {
                Button("儲存到鑰匙圈") { service.saveKey(text.wrappedValue, provider: provider); text.wrappedValue = "" }
                    .disabled(text.wrappedValue.isEmpty || configured)
                Button("測試") { service.testKey(provider: provider) }.disabled(!configured)
                Button("移除") { service.removeKey(provider: provider) }.disabled(!configured)
            }
        }
    }
}

/// 設定頁統一的小按鈕：沿用 App 的玻璃 chip，不用系統藍色按鈕（使用者 2026-09-22：不要一堆藍色框）。
struct OSChipButton: View {
    let title: String
    var systemImage: String? = nil
    var isPrimary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: isPrimary ? .semibold : .regular))
            }
            .foregroundStyle(isPrimary ? LiquidGlassTokens.brandAccent : Color.primary)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .chatGlassChip(isSelected: isPrimary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// W163 記憶提案：任一台都能看、能核准；主設備寫進 user.md 的「最近記住」。
struct MemoryProposalsView: View {
    var onAccepted: () -> Void = {}
    @State private var items: [UserMemoryProposal] = []
    @State private var offline = false
    @State private var publicIDs: Set<String> = []
    @State private var message = ""
    @State private var busy = false

    private var pending: [UserMemoryProposal] { items.filter { $0.status == "pending" } }
    private var decided: [UserMemoryProposal] { items.filter { $0.status != "pending" }.prefix(8).map { $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("記憶提案").font(.headline)
                Spacer()
                OSChipButton(title: "匯入 Claude 記憶") { importClaude() }
                OSChipButton(title: "重新整理") { refresh() }
            }
            Text(offline ? "連不上主設備：只顯示這台還沒送出的提案，連上後會自動送。"
                 : "核准的句子會加進 user.md 的「最近記住」，所有 AI 下一條對話就讀得到。標「公開」的才會給對外的 bot。")
                .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if pending.isEmpty {
                        Text("沒有待核准的提案。在聊天裡說「記住…」，或讓 AI 用 user_remember 提。")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                    ForEach(pending) { item in row(item) }
                    if !decided.isEmpty {
                        Text("最近決定").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                        ForEach(decided) { item in
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.status == "accepted" ? "已收" : "不要").font(.caption2).foregroundStyle(.secondary)
                                Text(item.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear(perform: refresh)
        .disabled(busy)
    }

    private func row(_ item: UserMemoryProposal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.text).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("\(item.source)・\(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Toggle("公開", isOn: Binding(get: { publicIDs.contains(item.id) || item.isPublic },
                                             set: { if $0 { publicIDs.insert(item.id) } else { publicIDs.remove(item.id) } }))
                    .toggleStyle(.checkbox).font(.caption)
                OSChipButton(title: "不要") { decide(item, accept: false) }
                OSChipButton(title: "收下", isPrimary: true) { decide(item, accept: true) }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func refresh() {
        busy = true
        Task.detached {
            let result = UserMemoryStore.shared.list()
            await MainActor.run { items = result.items; offline = result.offline; busy = false }
        }
    }

    private func decide(_ item: UserMemoryProposal, accept: Bool) {
        let isPublic = publicIDs.contains(item.id) || item.isPublic
        busy = true
        Task.detached {
            let error = Result { try UserMemoryStore.shared.decide(id: item.id, accept: accept, isPublic: isPublic) }
            await MainActor.run {
                if case .failure(let e) = error { message = "沒完成：\(e.localizedDescription)" }
                else { message = accept ? "已寫進 user.md" : "已略過"; if accept { onAccepted() } }
                busy = false
            }
            await MainActor.run { refresh() }
        }
    }

    private func importClaude() {
        busy = true
        Task.detached {
            let result = UserMemoryStore.shared.importClaudeMemories()
            await MainActor.run { message = "從 Claude 記憶提了 \(result.added) 條（\(result.skipped) 條已有）"; busy = false }
            await MainActor.run { refresh() }
        }
    }
}
