import AppKit
import SwiftUI

/// W104（使用者 2026-09-19：「設計成更好的ui方式」）：這條聊天的工作資料夾裡，AI 到底改了什麼。
/// 一眼看得到的順序：總數 → 每個檔案（狀態、路徑、增刪比例）→ 點開才看逐行。沒東西可看時講清楚原因，不留一片空白。
struct ChatWorkspaceChangesView: View {
    let load: () async -> WorkspaceChanges
    var onClose: (() -> Void)? = nil

    @State private var changes: WorkspaceChanges?
    @State private var expanded: Set<String> = []
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Group {
                if let changes {
                    switch changes.state {
                    case .changed: fileList(changes)
                    case .clean: placeholder("checkmark.circle", "目前沒有未提交的變更", "AI 改過檔案後，這裡會列出每個檔案與逐行差異。")
                    case .notGit: placeholder("folder.badge.questionmark", "這個工作資料夾不是 git 專案", "變更是用 git 比對出來的；把聊天的專案資料夾設成一個 git 倉庫就看得到。")
                    case .failed(let reason): placeholder("exclamationmark.triangle", "讀不到變更", reason)
                    }
                } else {
                    VStack { ProgressView().controlSize(.small) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await reload() }
    }

    private func reload() async {
        loading = true
        let fresh = await load()
        changes = fresh
        // 只有一個檔案就直接攤開，省一次點擊。
        if fresh.diff.files.count == 1, let only = fresh.diff.files.first { expanded = [key(only)] }
        loading = false
    }

    // MARK: - 標頭

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "plus.forwardslash.minus")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(LiquidGlassTokens.brandAccent)
                Text("變更").font(.system(size: 14, weight: .bold))
                Spacer(minLength: 4)
                Button { Task { await reload() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(loading ? 180 : 0)).animation(.easeInOut(duration: 0.3), value: loading)
                        .frame(width: 22, height: 22).contentShape(Rectangle())   // 兩顆圖示鈕同一個點擊範圍
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("重新讀取").accessibilityLabel("重新讀取變更")
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 10.5, weight: .semibold))
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("關閉").accessibilityLabel("關閉變更面板")
                }
            }
            if let changes, changes.state == .changed || changes.state == .clean {
                HStack(spacing: 6) {
                    Text(URL(fileURLWithPath: changes.root).lastPathComponent).fontWeight(.semibold)
                    if let branch = changes.branch { Text("·"); Image(systemName: "arrow.triangle.branch").font(.system(size: 9)); Text(branch) }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if let changes, changes.state == .changed {
                HStack(spacing: 6) {
                    chip("\(changes.fileCount) 個檔案", .secondary)
                    chip("+\(changes.added)", .green)
                    chip("−\(changes.removed)", .red)
                    Spacer(minLength: 4)
                    if changes.diff.files.count > 1 {
                        let allOpen = expanded.count >= changes.diff.files.count
                        Button(allOpen ? "全部收合" : "全部展開") {
                            expanded = allOpen ? [] : Set(changes.diff.files.map(key))
                        }
                        .buttonStyle(.link).font(.system(size: 11))
                    }
                }
                if changes.truncated {
                    Text("差異很大，逐行內容只顯示前面一部分；檔案清單與統計是完整的。")
                        .font(.system(size: 10.5)).foregroundStyle(.orange)
                }
            }
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(color)
            .padding(.horizontal, 7).frame(height: 18)
            .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - 檔案清單

    private func fileList(_ changes: WorkspaceChanges) -> some View {
        let peak = max(1, changes.diff.files.map { $0.addedCount + $0.removedCount }.max() ?? 1)
        return ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(changes.diff.files, id: \.newPath) { file in fileCard(file, root: changes.root, peak: peak) }
                if !changes.untracked.isEmpty {
                    Text("新檔案（還沒加入 git）").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.top, 6)
                    ForEach(changes.untracked, id: \.self) { path in
                        HStack(spacing: 7) {
                            badge("新", .green)
                            pathLabel(path)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(cardFill)
                        .contextMenu { fileMenu(path, root: changes.root) }
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private var cardFill: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04))
    }

    private func key(_ file: TatwoDiffFile) -> String { file.newPath.isEmpty ? file.oldPath : file.newPath }

    private func fileCard(_ file: TatwoDiffFile, root: String, peak: Int) -> some View {
        let id = key(file)
        let isOpen = expanded.contains(id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if isOpen { expanded.remove(id) } else { expanded.insert(id) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0)).frame(width: 9)
                    kindBadge(file.changeKind)
                    pathLabel(file.changeKind == .renamed && file.oldPath != file.newPath ? "\(file.oldPath) → \(file.newPath)" : id)
                    Spacer(minLength: 6)
                    if file.isBinary {
                        Text("二進位").font(.system(size: 9.5)).foregroundStyle(.secondary)
                    } else {
                        ratioBar(added: file.addedCount, removed: file.removedCount, peak: peak)
                        Text("+\(file.addedCount)").foregroundStyle(.green)
                        Text("−\(file.removedCount)").foregroundStyle(.red)
                    }
                }
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 9).padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(id)，新增 \(file.addedCount) 行，刪除 \(file.removedCount) 行")
            .contextMenu { fileMenu(id, root: root) }
            if isOpen, !file.isBinary {
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in hunkView(hunk) }
            }
        }
        .background(cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 資料夾部分淡、檔名粗：一長串路徑裡先看得到是哪個檔。
    private func pathLabel(_ path: String) -> some View {
        let url = URL(fileURLWithPath: path)
        let folder = url.deletingLastPathComponent().relativePath
        return HStack(spacing: 0) {
            if folder != "." && !folder.isEmpty && !path.contains(" → ") {
                Text(folder + "/").foregroundStyle(.secondary).fontWeight(.regular)
                Text(url.lastPathComponent).foregroundStyle(.primary)
            } else {
                Text(path).foregroundStyle(.primary)
            }
        }
        .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.head)
    }

    /// 這個檔在整批變更裡佔多大、增刪各多少，一條小橫條就看得出來。
    private func ratioBar(added: Int, removed: Int, peak: Int) -> some View {
        let total = max(1, added + removed)
        let width = max(6, 46 * CGFloat(total) / CGFloat(peak))
        return HStack(spacing: 0) {
            Rectangle().fill(Color.green.opacity(0.75)).frame(width: width * CGFloat(added) / CGFloat(total))
            Rectangle().fill(Color.red.opacity(0.75)).frame(width: width * CGFloat(removed) / CGFloat(total))
        }
        .frame(height: 5).clipShape(Capsule()).frame(width: 46, alignment: .trailing)
        .accessibilityHidden(true)
    }

    private func kindBadge(_ kind: TatwoDiffChangeKind) -> some View {
        switch kind {
        case .added: badge("新", .green)
        case .modified: badge("改", LiquidGlassTokens.brandAccent)
        case .deleted: badge("刪", .red)
        case .renamed: badge("移", .orange)
        }
    }

    private func badge(_ label: String, _ color: Color) -> some View {
        Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(color)
            .frame(width: 16, height: 16).background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    @ViewBuilder
    private func fileMenu(_ relative: String, root: String) -> some View {
        let url = URL(fileURLWithPath: root).appendingPathComponent(relative)
        Button("在 Finder 顯示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            .disabled(!FileManager.default.fileExists(atPath: url.path))
        Button("複製路徑") {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string)
        }
    }

    // MARK: - 逐行

    private func hunkView(_ hunk: TatwoDiffHunk) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(hunk.header).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05))
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in lineRow(line) }
        }
    }

    /// 面板常常只有 270 點寬：行號只留一欄（新增／原樣看新行號，刪除看舊行號），內容自動換行，不會被硬切到看不出後面還有字。
    private func lineRow(_ line: TatwoDiffLine) -> some View {
        let tint: Color? = line.kind == .added ? .green : (line.kind == .removed ? .red : nil)
        let number = line.kind == .removed ? line.oldLineNumber : (line.newLineNumber ?? line.oldLineNumber)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(number.map(String.init) ?? "").foregroundStyle(.tertiary).frame(width: 32, alignment: .trailing)
            Text(line.kind == .added ? "+" : (line.kind == .removed ? "−" : " "))
                .fontWeight(.bold).foregroundStyle(tint ?? .clear).frame(width: 14)
            Text(line.text.isEmpty ? " " : line.text).foregroundStyle(.primary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .padding(.vertical, 1.5).padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((tint ?? .clear).opacity(0.10))
    }

    private func placeholder(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(.secondary.opacity(0.75))
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
            Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
