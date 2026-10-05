import SwiftUI

struct AssistantSidebarList: View {
    // W180 E2：分頁選取放在 AssistantSpaceTabStore（不寫進 ChatPageModel）。
    // 列由 AssistantSpaceTab.allCases 產生（跟頁首 chip 同一份，名稱、圖示、順序都在 enum）。
    // 還沒開的分頁（stageNote 不是 nil）是停用列；E1 開記憶只要改 enum 的 stageNote，這裡不用動。
    @ObservedObject private var tabs = AssistantSpaceTabStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // None of these rows selects a Coder thread.
            // W179 UI：選中樣式同 Coder 側欄的選中列（淡錨色底＋錨色字），不是灰塊。
            ForEach(AssistantSpaceTab.allCases) { tab in
                if tab.isSelectable {
                    tabRow(tab)
                } else {
                    placeholder(tab.title, symbol: tab.symbol, stage: tab.stageNote ?? "")
                }
            }
        }
        .padding(.horizontal, 10)
    }

    private func tabRow(_ tab: AssistantSpaceTab) -> some View {
        let isSelected = tabs.selected == tab
        return Button { tabs.select(tab) } label: {
            Label(tab.title, systemImage: tab.symbol)
                .foregroundStyle(isSelected ? LiquidGlassTokens.brandAccent : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LiquidGlassTokens.brandAccent.opacity(isSelected ? 0.10 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chatMenuRowHover(isSelected: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("tatwo-tab-\(tab.rawValue)")
    }

    private func placeholder(_ title: String, symbol: String, stage: String) -> some View {
        Button(action: {}) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text(stage).font(.caption)
            }
            .foregroundStyle(.secondary)
            .padding(10)
        }
        .buttonStyle(.plain)
        .disabled(true)
    }
}
