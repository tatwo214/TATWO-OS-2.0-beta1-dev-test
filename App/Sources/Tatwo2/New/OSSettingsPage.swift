// W160 設定 › OS（使用者 2026-09-22 點頭，對照稿 https://claude.ai/artifact/Ds3WqTMkunBrn2R7vZnEyS）：
// 本頁只回答「這台接了哪些 AI、讀哪個檔、對不對得上」；按「文件 ›」才進文件清單與編輯。
// 取代原本「預覽差異／寫入修復／保留已手改區塊」那套按鈕。
import SwiftUI

struct OSSettingsPage: View {
    @ObservedObject var model: ChatPageModel
    @State var showingDocuments = false
    @State private var rows: [EngineLinkRow] = []
    @State private var pendingLink: EngineLinkRow?
    @State private var linkError: String?
    @ObservedObject private var backup = EntryBackup.shared
    // W162：其他設備的引擎狀態（經 device_status）與這台的全機規則檔掃描。
    @State private var peers: [(name: String, engines: [DeviceStatusEngine]?)] = []
    @State private var scan: [EngineRuleScanItem]?
    @State private var scanning = false

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
                        OSChipButton(title: "文件 ›", isPrimary: true) { showingDocuments = true }
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
                if !peers.isEmpty { peersSection }
                scanSection
            }
            .padding(TatwoSettingsPageMetrics.inset)
        }
        .onAppear { rescan() }
        .confirmationDialog(pendingLink.map { "把 \($0.name) 接上統一入口？" } ?? "",
                            isPresented: Binding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }),
                            titleVisibility: .visible) {
            Button("接上") {
                if let row = pendingLink {
                    do { try EngineLinks.link(row); linkError = nil } catch { linkError = "接不上：\(error.localizedDescription)" }
                }
                pendingLink = nil
                rescan()
            }
            Button("取消", role: .cancel) { pendingLink = nil }
        } message: {
            Text("原本的規則檔會封存到入口 archive/engine-rules，原位置換成連到入口的檔。隨時可以還原。")
        }
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
                    do {
                        for row in pending { try EngineLinks.link(row) }
                        linkError = nil
                    } catch { linkError = "接不上：\(error.localizedDescription)" }
                    rescan()
                    SetupChecklist.shared.refresh(logins: model.engineLogins)
                }
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
                OSChipButton(title: "接上") { pendingLink = row }
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
        Task.detached {
            let records = DeviceDispatch.shared.registry.list()
            let result = records.map { ($0.name, DeviceDispatch.shared.peerStatus($0)?.engines?.value) }
            await MainActor.run { peers = result.map { (name: $0.0, engines: $0.1) } }
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
            }
            ForEach(Array(item.findings.prefix(4).enumerated()), id: \.offset) { _, finding in
                Text("第 \(finding.line) 行・\(finding.category)：\(finding.note)").font(.caption2).foregroundStyle(.secondary)
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
