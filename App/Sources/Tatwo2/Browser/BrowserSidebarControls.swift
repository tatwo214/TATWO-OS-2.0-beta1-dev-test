import SwiftUI

/// One Dia-style control: open and keep the sidebar, or release and collapse it.
/// W184 G2d（使用者 09-30：「你就只是把現成的browser space做成duo自適應尺寸而已」）：私訊框的 Browser 用同一顆
/// （init(collapsed:toggle:)：它自己的側欄固定／收合）；主視窗照舊用 init(store:)。
struct BrowserSidebarControls: View {
    /// 側欄現在收著（主視窗＝store.focusMode）。
    let collapsed: Bool
    let toggle: @MainActor () -> Void

    init(store: BrowserWorkSpaceStore) {
        collapsed = store.focusMode
        toggle = store.toggleSidebar
    }

    init(collapsed: Bool, toggle: @escaping @MainActor () -> Void) {
        self.collapsed = collapsed
        self.toggle = toggle
    }

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "sidebar.leading")
                .frame(width: BrowserOmniboxMetrics.collapsedHeight, height: BrowserOmniboxMetrics.collapsedHeight)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(collapsed ? "展開並固定側欄" : "收合側欄")
        .accessibilityIdentifier("browser.sidebarToggle")
        .accessibilityValue(collapsed ? "已收合" : "已展開")
        .help(collapsed ? "展開並固定側欄" : "收合側欄")
        .font(.system(size: BrowserOmniboxMetrics.iconSize))
        .buttonStyle(.plain)
    }
}
