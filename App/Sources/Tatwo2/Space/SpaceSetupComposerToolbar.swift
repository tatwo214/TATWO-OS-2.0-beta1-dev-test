import SwiftUI

/// Uses the same visual controls as Chat, with domain-local fixture actions only.
/// Menus demonstrate choices; they do not grant permission or configure an engine.
/// W184 H4：模型（含推理強度、速度）與協作收進一顆「模式選擇」chip（同 Coder 輸入框）；
/// 規則照舊（TatwoComposerMode.spaceSetup）：預覽只改畫面上的選擇；正式搭建時協作不能選、推理強度與速度不列，選了 Bot 模型沿用 Bot。
/// W184 H4b：模式卡的開關（modeOpen）從這裡往上傳給輸入框那張玻璃卡（SpaceSetupPreviewView 的 composer）：卡掛在整個輸入框上方 8、
/// 右緣對齊，不再掛在工具列上（那樣卡的下緣在工具列上方，會蓋住打字區）；工具列只管那顆 chip。
struct SpaceSetupComposerToolbar: View {
    @ObservedObject var domain: SpaceSetupPreviewState.Domain
    let compact: Bool
    @Binding var modeOpen: Bool

    var body: some View {
        let mode = TatwoComposerMode.spaceSetup(domain: domain)
        ChatComposerToolbarRow(compact: compact) {
            Menu {
                Button("貼上剪貼簿圖片", systemImage: "doc.on.clipboard") { previewOnly("貼上圖片") }
                Button("附加檔案…", systemImage: "paperclip") { previewOnly("附加檔案") }
                Button("連接 iPad…", systemImage: "ipad") { previewOnly("連接 iPad") }
                Divider()
                Button("搜尋對話…", systemImage: "magnifyingglass") { previewOnly("搜尋對話") }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help(domain.isProduction ? "搭建需求目前使用文字輸入" : "加入內容：UI 預覽，不讀取檔案或剪貼簿")
            .disabled(domain.isProduction)

            Menu {
                ForEach(TatwoPermissionPreset.allCases) { preset in
                    Button {
                        domain.composerPermission = preset
                    } label: {
                        Label(preset.displayName, systemImage: domain.composerPermission == preset
                              ? "checkmark.circle.fill" : "circle")
                    }
                    .help(preset.subtitle)
                }
                Divider()
                if !domain.isProduction { Text("UI 預覽，不變更實際權限") }
            } label: {
                ChatComposerPermissionLabel(
                    symbol: permissionSymbol,
                    title: domain.isProduction && !domain.chosenBotID.isEmpty
                        ? "沿用 Bot" : domain.composerPermission.shortDisplayName,
                    tint: permissionTint)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: true, vertical: false)
            .controlSize(.small)
            .disabled(domain.isProduction && !domain.chosenBotID.isEmpty)

            Spacer(minLength: compact ? 8 : 14)
            // W184 H4：原本的模型選單（推理強度、速度在子選單）＋協作選單 → 一顆「模式選擇」（開關是上一層的 modeOpen）。
            ChatComposerModeChip(segments: mode.segments, selected: modeOpen, help: mode.help) {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) { modeOpen.toggle() }
            }
            .layoutPriority(1)

            ChatComposerSendButton(enabled: domain.canPreview) { domain.previewResult() }
                .accessibilityLabel(domain.isProduction ? "送出搭建需求" : "預覽搭建後動線，不送出訊息")
                .help(domain.isProduction ? "送出至此 Space 的搭建對話" : "預覽搭建後動線，不會真正送出")
        }
    }

    private var permissionSymbol: String {
        switch domain.composerPermission {
        case .askFirst: "hand.raised"
        case .approveForMe: "checkmark.bubble"
        case .fullAccess: "exclamationmark.shield"
        case .configFile: "gearshape"
        }
    }

    private var permissionTint: Color {
        switch domain.composerPermission {
        case .fullAccess: Color.red.opacity(0.88)
        case .approveForMe: Color.orange.opacity(0.86)
        case .askFirst, .configFile: Color.secondary
        }
    }

    private func previewOnly(_ action: String) {
        domain.validationMessage = "\(action)尚未接線；未讀取資料或呼叫服務。"
    }
}
