import SwiftUI

/// W109（使用者 2026-09-19）：「我在chat session裡的瀏覽器 沒有出現在browser/session space裡 應該要有專案/session名稱
/// 點擊為瀏覽器 如果該session有多開分頁 就以書籤呈現」。
/// 聊天旁的分頁住在自己的 registry（每條討論串一個 `thread:<UUID>` space）；這裡把它們投影到 Browser 的 Session space：
/// 一條討論串一列（專案／標題），只有一個分頁就直接點開；多個分頁就展開成一列列書籤。
@MainActor
final class BrowserChatSessionSelection: ObservableObject {
    static let shared = BrowserChatSessionSelection()
    struct Pick: Equatable { let spaceID: UUID; let tabID: UUID }
    /// 目前在 Session space 裡點開的聊天旁分頁；nil＝顯示原本的 session 內容。
    @Published var pick: Pick?
    /// ChatPage 提供：討論串 UUID →（專案名，討論串標題）。Browser 這層不認識聊天資料。
    var titles: (UUID) -> (project: String, title: String)? = { _ in nil }

    static func threadID(ofSpaceNamed name: String) -> UUID? {
        name.hasPrefix("thread:") ? UUID(uuidString: String(name.dropFirst("thread:".count))) : nil
    }
}

struct BrowserChatSessionsSection: View {
    let registry: BrowserTabRegistry
    @ObservedObject private var selection = BrowserChatSessionSelection.shared
    @State private var revision = 0
    @State private var collapsed: Set<UUID> = []

    private struct Entry: Identifiable {
        let id: UUID            // space id
        let label: String
        let tabs: [BrowserTab]
    }

    private var entries: [Entry] {
        _ = revision
        return registry.spaces.compactMap { space in
            guard !space.isSessionSpace, let threadID = BrowserChatSessionSelection.threadID(ofSpaceNamed: space.name) else { return nil }
            let tabs = registry.tabs(ownedBy: .workSpace(spaceID: space.id)).filter { $0.url != nil }
            guard !tabs.isEmpty else { return nil }
            let names = selection.titles(threadID)
            let label = names.map { "\($0.project)／\($0.title)" } ?? "已不在清單上的討論串"
            return Entry(id: space.id, label: label, tabs: tabs)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BrowserSidebarMetrics.hairline) {
            Text("聊天旁的瀏覽器").font(.system(size: BrowserSidebarMetrics.metaFontSize, weight: .semibold))
                .foregroundStyle(.secondary).padding(BrowserSidebarMetrics.captionPadding)
            if entries.isEmpty {
                Text("尚未有聊天開過瀏覽器").font(.system(size: BrowserSidebarMetrics.metaFontSize))
                    .foregroundStyle(.tertiary).padding(BrowserSidebarMetrics.captionPadding)
            }
            ForEach(entries) { entry in
                if entry.tabs.count == 1, let tab = entry.tabs.first {
                    row(title: entry.label, tab: tab, spaceID: entry.id, inset: BrowserSidebarMetrics.rowHorizontalPadding)
                } else {
                    Button {
                        if collapsed.contains(entry.id) { collapsed.remove(entry.id) } else { collapsed.insert(entry.id) }
                    } label: {
                        HStack(spacing: BrowserSidebarMetrics.rowSpacing) {
                            Image(systemName: "folder.fill").foregroundStyle(LiquidGlassTokens.browserFolderFill)
                                .frame(width: BrowserSidebarMetrics.rowIconWidth)
                            Text(entry.label).fontWeight(.bold).lineLimit(1)
                            Image(systemName: collapsed.contains(entry.id) ? "chevron.right" : "chevron.down")
                                .font(.system(size: BrowserSidebarMetrics.metaFontSize)).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: BrowserSidebarMetrics.rowFontSize))
                        .padding(.vertical, BrowserSidebarMetrics.rowVerticalPadding)
                        .padding(.horizontal, BrowserSidebarMetrics.rowHorizontalPadding)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel(entry.label)
                    if !collapsed.contains(entry.id) {
                        ForEach(entry.tabs) { tab in
                            row(title: tab.title, tab: tab, spaceID: entry.id, inset: BrowserSidebarMetrics.childLeadingInset)
                        }
                    }
                }
            }
        }
        .onReceive(registry.changes) { revision &+= 1 }
        .onChange(of: entries.flatMap { $0.tabs.map(\.id) }) { _, ids in
            if let pick = selection.pick, !ids.contains(pick.tabID) { selection.pick = nil }
        }
    }

    private func row(title: String, tab: BrowserTab, spaceID: UUID, inset: CGFloat) -> some View {
        let selected = selection.pick?.tabID == tab.id
        return BrowserTabRow(title: title, tabID: tab.id.uuidString, host: tab.url?.host ?? "", favicon: tab.faviconPNG,
            selected: selected, sleeping: tab.isSleeping, leadingInset: inset,
            onSelect: { selection.pick = .init(spaceID: spaceID, tabID: tab.id) })
            .help(tab.url?.absoluteString ?? tab.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Session space 裡點開的聊天旁分頁：用聊天旁自己的 runtime（同一個 profile，登入照舊）直接顯示那一頁。
/// 聊天模式下面板不在畫面上，所以不會跟面板搶同一個 CEF 容器。
struct BrowserChatSessionSurface: View {
    let pick: BrowserChatSessionSelection.Pick
    let source: BrowserTabRegistry
    @State private var command: EmbeddedBrowserCommand?

    var body: some View {
        let registry = BrowserTabRegistry.chatInspectorRegistry(source: source)
        let runtime = BrowserWorkSpaceRuntime.forChat("chat-browser-inspector", registry: registry, adoptsWorkSpaceTabs: true)
        VStack(spacing: 0) {
            // 上方那條工具列綁的是獨立 Browser 的分頁，在這裡不會作用；聊天旁的頁面用自己這一排導覽鈕。
            BrowserChatSessionControls(runtime: runtime, tabID: pick.tabID) { command = EmbeddedBrowserCommand(action: $0) }
            BrowserWorkSpaceCEFSurface(tabID: pick.tabID, spaceID: pick.spaceID, command: command, onPopup: { _, _ in },
                runtime: runtime)
                .id(pick.tabID)
        }
        .onChange(of: pick) { _, _ in command = nil }
    }
}

private struct BrowserChatSessionControls: View {
    @ObservedObject var runtime: BrowserWorkSpaceRuntime
    let tabID: UUID
    let send: (EmbeddedBrowserCommand.Action) -> Void

    var body: some View {
        let state = runtime.navigationTabID == tabID ? runtime.navigationState : .blank
        HStack(spacing: BrowserOmniboxMetrics.controlGap) {
            button("chevron.left", "上一頁", state.canGoBack, .goBack)
            button("chevron.right", "下一頁", state.canGoForward, .goForward)
            button(state.isLoading ? "xmark" : "arrow.clockwise", state.isLoading ? "停止載入" : "重新載入", true,
                   state.isLoading ? .stopLoading : .reload)
            Text(BrowserOmniboxPresentation.domain(for: state.urlString))
                .font(.system(size: BrowserOmniboxMetrics.domainFontSize)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, BrowserOmniboxMetrics.horizontalInset)
        .frame(height: BrowserOmniboxMetrics.collapsedHeight)
    }

    private func button(_ symbol: String, _ label: String, _ enabled: Bool, _ action: EmbeddedBrowserCommand.Action) -> some View {
        Button { send(action) } label: {
            Image(systemName: symbol).font(.system(size: BrowserOmniboxMetrics.iconSize))
                .frame(width: BrowserOmniboxMetrics.collapsedHeight, height: BrowserOmniboxMetrics.collapsedHeight)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled).help(label).accessibilityLabel(label)
    }
}
