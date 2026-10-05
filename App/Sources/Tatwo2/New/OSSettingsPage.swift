// W160 設定 › OS（使用者 2026-09-22 點頭，對照稿 https://claude.ai/artifact/Ds3WqTMkunBrn2R7vZnEyS）：
// 本頁只回答「這台接了哪些 AI、讀哪個檔、對不對得上」；按「文件 ›」才進文件清單與編輯。
// 取代原本「預覽差異／寫入修復／保留已手改區塊」那套按鈕。
import SwiftUI

struct OSSettingsPage: View {
    @ObservedObject var model: ChatPageModel
    @State var showingDocuments = false
    @State private var rows: [EngineLinkRow] = []
    // W180 D1：等著在卡片裡確認的「接上」（單列一個；初始設定的「接上 N 個」是多個）。
    @State private var pendingLinks: [EngineLinkRow] = []
    @State private var linkError: String?
    @ObservedObject private var backup = EntryBackup.shared
    // W162：其他設備的引擎狀態（經 device_status）與這台的全機規則檔掃描。
    @State private var peers: [(name: String, engines: [DeviceStatusEngine]?)] = []
    @State private var scan: [EngineRuleScanItem]?
    @State private var scanning = false
    // W179：Claude、Codex 共用入口的 memory/。
    @State private var memory: EngineMemoryStatus?
    @State private var memoryConfirm: MemoryConfirm?
    @State private var memoryBusy = false
    @State private var memoryMessage: String?
    @State private var memoryFailed = false

    private struct MemoryConfirm {
        let restore: Bool
        let rows: [EngineMemoryRow]
        init(restore: Bool, row: EngineMemoryRow) { self.restore = restore; rows = [row] }
        /// W180 D1：初始設定的「接上 N 個」也先在卡片裡確認，再一次接上。
        init(linking rows: [EngineMemoryRow]) { restore = false; self.rows = rows }
        var names: String { rows.map(\.name).joined(separator: "、") }
        var engines: Set<EngineMemoryEngine> { Set(rows.map(\.engine)) }
    }

    var body: some View {
        if showingDocuments {
            OSDocumentsCard(model: model, onBack: { showingDocuments = false })
        } else {
            engines
        }
    }

    private var engines: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TatwoSettingsPageMetrics.sectionSpacing) {
                TatwoSettingsPageHeader(title: "OS", subtitle: "這台接了哪些 AI、各自讀哪個規則檔。所有 AI 讀同一份入口的 agents.md。") {
                    HStack(spacing: 8) {
                        OSChipButton(title: "重新檢查") { rescan() }
                            .accessibilityLabel("重新檢查規則檔")
                        OSChipButton(title: "文件 ›", isPrimary: true) { showingDocuments = true }
                            .accessibilityLabel("打開文件")
                    }
                }
                setupBanner
                Text(summaryLine)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        rowView(row)
                    }
                }
                .padding(.horizontal, 12)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                // W180 D1：「接上」「接上 N 個」都在卡片裡確認（同記憶卡：問句＋說明＋取消／接上兩顆中性玻璃 chip），不跳系統確認框。
                if !pendingLinks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("把 \(pendingLinks.map(\.name).joined(separator: "、")) 接上統一入口？")
                            .font(.system(size: 13, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("原本的規則檔會封存到入口 archive/engine-rules，原位置換成連到入口的檔。隨時可以還原。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            OSChipButton(title: "取消") { pendingLinks = [] }
                            OSChipButton(title: "接上") { linkRules(pendingLinks) }
                        }
                        .padding(.top, 2)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .chatLiquidSection(cornerRadius: 12)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("tatwo.settings.rules.confirm")
                }
                if let linkError {
                    Text(linkError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    legend(.green, "已接")
                    legend(.orange, "還沒接")
                    legend(Color.secondary.opacity(0.35), "不適用或沒安裝")
                    Spacer()
                    Text(backup.statusLine).font(.caption).foregroundStyle(.secondary)
                }
                .font(.caption).foregroundStyle(.secondary)
                memorySection
                if !peers.isEmpty { peersSection }
                scanSection
            }
            .padding(TatwoSettingsPageMetrics.inset)
        }
        .onAppear { rescan() }
    }

    private func linkRules(_ pending: [EngineLinkRow]) {
        do {
            for row in pending { try EngineLinks.link(row) }
            linkError = nil
        } catch { linkError = "接不上：\(error.localizedDescription)" }
        pendingLinks = []
        rescan()
        SetupChecklist.shared.refresh(logins: model.engineLogins)
    }

    /// W171 初始設定：把這台裝了的 AI 一次接上統一規則（原件封存到入口 archive，隨時可還原）。
    @ViewBuilder private var setupBanner: some View {
        let installed = rows.filter { ["claude", "codex", "openclaw"].contains($0.id) && $0.state != .notInstalled }
        let pending = installed.filter { $0.state == .notLinked && !$0.links.isEmpty }
        if !installed.isEmpty {
            SetupBanner(done: pending.isEmpty,
                        text: pending.isEmpty
                            ? installed.map(\.name).joined(separator: "、") + " 已改用統一規則。原檔在入口的 archive/engine-rules，隨時能換回去。"
                            : "這台有 " + pending.map(\.name).joined(separator: "、") + "。要讓它們改用 TATWO OS 的規則嗎？原本的規則檔會先備份，隨時能換回去。") {
                OSChipButton(title: pending.count > 1 ? "接上 \(pending.count) 個" : "接上", isPrimary: true) {
                    pendingLinks = pending
                }
                .accessibilityLabel(pending.count > 1 ? "\(pending.count) 個 AI 都接上統一規則" : "接上統一規則")
            }
        }
    }

    private func rowView(_ row: EngineLinkRow) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle().fill(color(row.state)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.subheadline.weight(.semibold))
                Text(row.pathText).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if row.state == .notLinked, !row.links.isEmpty {
                OSChipButton(title: "接上") { pendingLinks = [row] }
                    .accessibilityLabel("讓 \(row.name) 接上統一規則")
            } else {
                Text(row.statusText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 8, height: 8); Text(text) }
    }

    private func color(_ state: EngineLinkRow.State) -> Color {
        switch state {
        case .linked: .green
        case .notLinked: .orange
        case .notInstalled, .notApplicable: Color.secondary.opacity(0.35)
        }
    }

    private var summaryLine: String {
        let entry = TatwoEntry()
        let role = OSDocuments.isPrimary ? "本機是主設備，持有正本" : "本機是副設備，正本在主設備、這裡是派發來的副本"
        let agents = entry.root.appendingPathComponent(AgentsFile.fileName)
        let stamp = (try? Data(contentsOf: agents)).map { "agents.md " + String(ManagedFile.sha256($0).prefix(8)) } ?? "入口還沒有 agents.md"
        return "\(role)・入口 \(entry.root.path)・\(stamp)"
    }

    private func rescan() {
        rows = EngineLinks.scan(); backup.refreshStatus()
        // 確認列開著時別的按鈕還能按：已經接好（或不見了）的就從確認列拿掉，全接好了確認列自己收起來。
        pendingLinks = pendingLinks.compactMap { old in
            rows.first { $0.id == old.id && $0.state == .notLinked && !$0.links.isEmpty }
        }
        memory = EngineMemoryLinks.scan()
        if let confirm = memoryConfirm, let memory {
            let wanted: EngineMemoryRow.State = confirm.restore ? .linked : .notLinked
            let stillPending = confirm.rows.allSatisfy { old in memory.rows.contains { $0.id == old.id && $0.state == wanted } }
            if !stillPending { memoryConfirm = nil }
        }
        EngineMemoryWatcher.shared.start()
        Task.detached {
            let records = DeviceDispatch.shared.registry.list()
            let result = records.map { ($0.name, DeviceDispatch.shared.peerStatus($0)?.engines?.value) }
            await MainActor.run { peers = result.map { (name: $0.0, engines: $0.1) } }
        }
    }

    // MARK: 記憶（W179）

    /// 每個引擎一列：狀態、「接上」／「還原」；下面是記憶資料夾路徑與條數。內文唯讀。
    @ViewBuilder private var memorySection: some View {
        if let memory {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("記憶").font(.subheadline.weight(.semibold))
                    Spacer()
                    if memoryBusy { ProgressView().controlSize(.small) }
                }
                Text("Claude、Codex 各自記的東西合成一份，每個 AI 都讀得到；原本的會先備份。")
                    .font(.caption).foregroundStyle(.secondary)
                if !memory.installed.isEmpty {
                    SetupBanner(done: memory.pending.isEmpty, label: "初始設定 · 記憶",
                                text: memory.pending.isEmpty
                                    ? memory.installed.map(\.name).joined(separator: "、") + " 已共用入口的記憶。原本的在入口的 archive/engine-memory-日期，隨時能還原。"
                                    : "這台有 " + memory.pending.map(\.name).joined(separator: "、") + "。要讓它們共用同一份記憶嗎？原本的記憶與設定會先備份，隨時能還原。") {
                        OSChipButton(title: memory.pending.count > 1 ? "接上 \(memory.pending.count) 個" : "接上", isPrimary: true) {
                            memoryConfirm = MemoryConfirm(linking: memory.pending)
                        }
                        .accessibilityLabel(memory.pending.count > 1 ? "\(memory.pending.count) 個 AI 都共用記憶" : "共用記憶")
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(memory.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        memoryRow(row)
                    }
                }
                .padding(.horizontal, 12)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                // W179 UI：確認在卡片裡（問句＋說明＋取消／確定兩顆玻璃 chip），不跳系統確認框（不要藍按鈕）；
                // 中性的玻璃底，不用強調色（強調色只給選中狀態）。
                if let confirm = memoryConfirm {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(confirm.restore ? "把 \(confirm.names) 的記憶設定換回接上前的樣子？"
                                : "讓 \(confirm.names) 共用 TATWO 的記憶？")
                            .font(.system(size: 13, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(memoryConfirmMessage)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            OSChipButton(title: "取消") { memoryConfirm = nil }
                            OSChipButton(title: confirm.restore ? "還原" : "接上") {
                                runMemory(restore: confirm.restore, engines: confirm.engines)
                                memoryConfirm = nil
                            }
                        }
                        .padding(.top, 2)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .chatLiquidSection(cornerRadius: 12)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("tatwo.settings.memory.confirm")
                }
                Text(memory.folderLine).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                TatwoMemorySyncStatusRow() // W180 E1b：主副自動同步的狀態（一行字）
                if let memoryMessage {
                    Text(memoryMessage).font(.caption).foregroundStyle(memoryFailed ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var memoryConfirmMessage: String {
        guard let confirm = memoryConfirm else { return "" }
        if confirm.restore { return "設定與原本的記憶資料夾會從封存放回去；入口的 memory/ 留著。" }
        // W180 D1：一次接好幾個只放一句白話；各自動了哪幾行留給單列的確認。
        if confirm.rows.count > 1 {
            return "\(confirm.names) 原本的記憶和設定會先備份到入口的 archive，設定只改共用記憶需要的那幾行，其他不動，隨時能還原。"
        }
        return confirm.rows.first?.engine == .claude
            ? "原本的記憶與 settings.json 會先封存到入口 archive/engine-memory-日期，接著在設定加一行 autoMemoryDirectory，其他設定不動。隨時能還原。"
            : "原本的記憶與 config.toml 會先封存；config.toml 只動兩行：打開 Codex 的記憶功能（[features] memories = true）、generate_memories = false，其他不動。Codex 改讀 OS 從記憶產生的摘要。隨時能還原。"
    }

    private func memoryRow(_ row: EngineMemoryRow) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle().fill(color(row.state)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.subheadline.weight(.semibold))
                Text(row.pathText).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Text(row.statusText).font(.caption).foregroundStyle(.secondary)
            if row.state == .notLinked {
                OSChipButton(title: "接上") { memoryConfirm = MemoryConfirm(restore: false, row: row) }
                    .accessibilityLabel("讓 \(row.name) 共用記憶")
            } else if row.state == .linked, row.canRestore {
                OSChipButton(title: "還原") { memoryConfirm = MemoryConfirm(restore: true, row: row) }
                    .accessibilityLabel("還原 \(row.name) 的記憶設定")
            }
        }
        .padding(.vertical, 10)
    }

    private func color(_ state: EngineMemoryRow.State) -> Color {
        switch state {
        case .linked: .green
        case .notLinked: .orange
        case .notInstalled: Color.secondary.opacity(0.35)
        }
    }

    /// 接上／還原會複製檔案、跑 git（副設備還可能連主設備），放背景做完再回畫面。
    private func runMemory(restore: Bool, engines: Set<EngineMemoryEngine>) {
        guard !memoryBusy else { return }
        memoryBusy = true
        memoryMessage = nil
        memoryFailed = false
        Task.detached {
            let outcome = Result<[String], Error>(catching: { () throws -> [String] in
                if restore { return try EngineMemoryLinks.restore(engines) }
                return try EngineMemoryLinks.link(engines).notes
            })
            await MainActor.run {
                memoryBusy = false
                switch outcome {
                case .success(let notes):
                    memoryMessage = notes.isEmpty ? nil : notes.joined(separator: "；")
                case .failure(let error):
                    memoryFailed = true
                    memoryMessage = (restore ? "還原不了：" : "接不上：") + error.localizedDescription
                }
                rescan()
                SetupChecklist.shared.refresh(logins: model.engineLogins)
            }
        }
    }

    // MARK: 其他設備

    private var peersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("其他設備").font(.subheadline.weight(.semibold))
            ForEach(Array(peers.enumerated()), id: \.offset) { _, peer in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(peer.name).font(.caption.weight(.semibold)).frame(width: 110, alignment: .leading)
                    if let engines = peer.engines {
                        ForEach(engines, id: \.id) { engine in
                            HStack(spacing: 4) {
                                Circle().fill(color(engine.state)).frame(width: 7, height: 7)
                                Text(engine.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    } else {
                        Text("連不上，或那台還是舊版").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func color(_ state: String) -> Color {
        switch state {
        case "linked": .green
        case "notLinked": .orange
        default: Color.secondary.opacity(0.35)
        }
    }

    // MARK: 全機規則檔

    private var scanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("這台的全部規則檔與技能").font(.subheadline.weight(.semibold))
                Spacer()
                if scanning { ProgressView().controlSize(.small) }
                OSChipButton(title: scan == nil ? "掃描這台" : "重新掃描") { runScan() }
                    .accessibilityLabel(scan == nil ? "掃描這台的規則檔與技能" : "重新掃描這台的規則檔與技能")
            }
            Text("找各專案的 CLAUDE.md／AGENTS.md、技能、MCP 與 Hook 設定，檢查外來指示、疑似金鑰（只報位置）、會執行指令的設定。只看不改。")
                .font(.caption).foregroundStyle(.secondary)
            if let scan {
                let flagged = scan.filter { !$0.findings.isEmpty }
                Text(EngineRuleAudit.Kind.allCases.map { kind in "\(kind.rawValue) \(scan.filter { $0.kind == kind }.count)" }
                    .joined(separator: "・") + "・需要注意 \(flagged.count)")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(flagged.prefix(40)) { item in scanRow(item) }
                DisclosureGroup("全部 \(scan.count) 個") {
                    ForEach(scan.prefix(400)) { item in scanRow(item) }
                }
                .font(.caption)
            }
        }
    }

    private func scanRow(_ item: EngineRuleScanItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(item.findings.contains { $0.category != "會執行指令" } ? Color.red
                              : item.findings.isEmpty ? Color.secondary.opacity(0.35) : Color.orange).frame(width: 7, height: 7)
                Text(item.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
                Text(Self.tilde(item.path)).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if item.linkedToEntry { Text("已連入口").font(.caption2).foregroundStyle(.green) }
                Spacer(minLength: 4)
                OSChipButton(title: "顯示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
                    .accessibilityLabel("在 Finder 顯示")
            }
            ForEach(Array(item.findings.prefix(4).enumerated()), id: \.offset) { _, finding in
                Text("\(finding.line > 0 ? "第 \(finding.line) 行・" : "")\(finding.category)：\(finding.note)").font(.caption2).foregroundStyle(.secondary)   // W183 R6c：0＝整個檔（連到 chatgpt/）
                    .padding(.leading, 13)
            }
        }
        .padding(.vertical, 3)
    }

    private func runScan() {
        scanning = true
        Task.detached {
            let items = EngineRuleScanner.scan()
            await MainActor.run { scan = items; scanning = false }
        }
    }

    private static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
