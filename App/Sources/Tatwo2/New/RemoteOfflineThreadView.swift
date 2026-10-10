// W182 R4 新畫面：那台連不上時 Coder 的唯讀畫面（輸入框換成一行說明＋玻璃 chip「在這台接著聊」）、
// 沒讀過的那條的說明、複製來的串那台連回時串頂一行、設定 › 設備 的離線副本一行（卡片內確認列）。
// 使用者裁決：不要藍按鈕藍框，用玻璃 chip；確認在卡片內，不跳系統框；中文短、白話。
import SwiftUI

/// Coder 輸入框：選著的遠端串那台連不上時換成說明＋「在這台接著聊」；連回來自動換回輸入框。
/// 「在這台接著聊」之後游標回到輸入框（新串已選好）。
struct RemoteOfflineComposerSwap: ViewModifier {
    @ObservedObject var model: ChatPageModel
    var focus: FocusState<Bool>.Binding
    @ObservedObject private var signals = RemoteOfflineContinueSignals.shared

    func body(content: Content) -> some View {
        Group {
            if let state = model.remoteOfflineReadOnly {
                RemoteOfflineComposerBar(model: model, state: state)
            } else {
                content
            }
        }
        .onReceive(signals.$composerFocusRequest.dropFirst()) { _ in
            DispatchQueue.main.async { focus.wrappedValue = true }
        }
    }
}

struct RemoteOfflineComposerBar: View {
    @ObservedObject var model: ChatPageModel
    let state: RemoteOfflineReadOnlyState
    @State private var working = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(RemoteOfflineContinue.readOnlyLine(deviceName: state.deviceName,
                                                    synced: state.syncedAt.map(RemoteDeviceSidebarSection.seen)))
                .font(.system(size: 12.5))
                .foregroundStyle(Color.primary.opacity(0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            OSChipButton(title: RemoteOfflineContinue.chipTitle, systemImage: "arrow.turn.down.right") {
                working = true
                model.continueOfflineThreadHere(deviceID: state.deviceID, threadID: state.threadID) { _ in working = false }
            }
            .disabled(working)
            .help("把這條複製一份到這台，用這台的模型接著聊；\(state.deviceName)上的原串不動")
            .accessibilityIdentifier("chat-remote-offline-continue")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassPanelSurface(cornerRadius: LiquidGlassTokens.radiusPrimary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-remote-offline-readonly")
    }
}

/// 那台連不上、這條離線前沒讀過：對話區一行說明。
struct RemoteOfflineEmptyTranscript: View {
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-remote-offline-not-read")
    }
}

/// 設定 › 設備 一台的展開區：這台存的離線副本。
struct RemoteOfflineCacheRow: View {
    @ObservedObject var model: ChatPageModel
    let device: DeviceRecord

    var body: some View {
        if let usage = model.remoteOfflineUsageLine(deviceID: device.id) {
            Text(usage)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
