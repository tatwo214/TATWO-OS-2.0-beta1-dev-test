import SwiftUI

/// W180 E1b：記憶主副自動同步的狀態，一行字放在玻璃 chip 裡（設定 › OS › 記憶；E1a 的記憶頁頂也會用）。
/// 同步是自動的（60 秒一次、記憶有變動幾秒內）；細節（上次時間、待送、兩版並存、錯誤）都在這一行。
/// 只有一種情況要使用者決定：一次要刪掉很多條（像整個資料夾被清空）先不套用——旁邊出一顆玻璃 chip，
/// 按了在卡片裡出確認列（問句＋說明＋先不要／刪掉），不跳系統框、不用藍按鈕。刪掉的會先封存到入口的 archive/。
struct TatwoMemorySyncStatusRow: View {
    @ObservedObject private var sync = TatwoMemorySync.shared
    @State private var confirming = false

    var body: some View {
        let status = sync.status
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(dot(status.state)).frame(width: 7, height: 7)
                    Text(status.line)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .chatGlassChip()
                .help(status.detail.map { status.line + "\n" + $0 } ?? status.line)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("記憶同步：" + status.line)
                .accessibilityIdentifier("tatwo.memory.sync.status")
                if status.state == .held, !confirming {
                    OSChipButton(title: status.heldOutgoing ? "照樣送出" : "照樣套用") { confirming = true }
                        .accessibilityIdentifier("tatwo.memory.sync.held")
                }
            }
            if status.state == .held, confirming {
                VStack(alignment: .leading, spacing: 6) {
                    Text(status.heldOutgoing ? "讓主設備也刪掉這 \(status.held) 條記憶？" : "讓這台也刪掉這 \(status.held) 條記憶？")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text((status.heldNames.isEmpty ? "" : status.heldNames + "。")
                         + (status.heldOutgoing ? "主設備" : "這台") + "會先把它們複製到入口的 archive/memory-sync-deleted-日期（附還原說明）再刪。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        OSChipButton(title: "先不要") { confirming = false }
                        OSChipButton(title: "刪掉") {
                            sync.approveHeld()
                            confirming = false
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .chatLiquidSection(cornerRadius: 12)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("tatwo.memory.sync.confirm")
            }
        }
        .onChange(of: status.state) { _, state in
            if state != .held { confirming = false }
        }
    }

    private func dot(_ state: TatwoMemorySyncStatus.State) -> Color {
        switch state {
        case .synced: .green
        case .offline, .primaryFolderMissing, .failed, .held: .orange
        case .starting, .folderMissing: Color.secondary.opacity(0.35)
        }
    }
}
