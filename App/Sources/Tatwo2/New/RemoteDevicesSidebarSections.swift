// 2.0 新畫面（不是照搬）：每台已配對設備在左列有自己的區塊，列它的專案與討論串；點了就在那台跑。
// 使用者 2026-09-05：遠端跟本地並行，不做遙控模式開關。
import SwiftUI

/// W98d：設備頁「遠端設備專案」→ 側欄的帶路訊號（展開那台的區塊並捲過去）。nonce 讓同一台按第二次也生效。
struct SidebarDeviceFocus: Equatable {
    let deviceID: String
    let nonce: Int
}

/// W98d（使用者 2026-09-18 裁決「要像圈起來的大分類」）：一台遠端設備＝一個跟「專案」「聊天」同層的
/// 側欄區塊。標題列照 `ChatPage+Sidebar` 的 `projectSidebarSectionHeader`（字級、chevron、間距、右側
/// 控制位置），點標題只收合／展開，不進遠端模式；要進遠端模式一律點裡面的討論串。
/// 預設展開，展開狀態只在這個 View、不持久化（同「專案」區的做法）。
struct RemoteDeviceSidebarSection: View {
    @ObservedObject var model: ChatPageModel
    let deviceID: String
    let deviceName: String
    let iconName: String
    let isOnline: Bool
    @State private var isExpanded = true

    /// 設備頁「遠端設備專案」要捲到這個區塊用的錨點。
    static func anchorID(_ deviceID: String) -> String { "chat-sidebar-remote-device-\(deviceID)" }

    var body: some View {
        let section = model.remoteSidebarSections.first { $0.deviceID == deviceID }
        LazyVStack(alignment: .leading, spacing: 5) {
            header
            if isExpanded, let section {
                RemoteDeviceSectionContent(model: model, section: section)
            }
        }
        .onReceive(model.$sidebarDeviceFocus) { focus in
            guard let focus, focus.deviceID == deviceID, !isExpanded else { return }
            withAnimation(.easeInOut(duration: 0.12)) { isExpanded = true }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("遠端設備（\(deviceName)）" + (isOnline ? "" : "・離線"))
                        .font(ChatTypography.sidebarHeader)
                        .lineLimit(1)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .black))
                }
                .foregroundStyle(.secondary.opacity(0.72))
                .opacity(isOnline ? 1 : 0.55)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "收起「\(deviceName)」" : "展開「\(deviceName)」")
            .accessibilityIdentifier("chat-sidebar-remote-device")
            .frame(minHeight: 30)
            Spacer(minLength: 8)
            // 「專案」區同一個位置是「＋」；這裡放設備圖示（純顯示），正在遙控的那台用 brandAccent。
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.remoteMode?.id == deviceID ? LiquidGlassTokens.brandAccent : Color.secondary)
                .frame(width: 26, height: 26)
                .help(isOnline ? "「\(deviceName)」在線" : "「\(deviceName)」目前離線")
        }
        .padding(.top, 2)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    static func seen(_ date: Date) -> String {
        let now = ChatPageModel.exportChatScene != nil ? Date(timeIntervalSinceReferenceDate: 800_000_000) : Date()
        let s = Int(now.timeIntervalSince(date))
        if s < 3_600 { return "\(max(1, s / 60)) 分鐘前" }
        if s < 86_400 { return "\(s / 3_600) 小時前" }
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f.string(from: date)
    }
}

/// 一台遠端設備區塊的內容（專案→討論串）。
/// W98c：專案不再攤平——每個專案是自己的可展開列（chevron＋專案名，照本機 `projectSection` 的寫法），
/// 討論串只在該專案展開後才列。專案的寫入動作（右鍵、開新聊天）遠端這邊不給。
/// W98d：設備升格成側欄區塊後少掉一層，專案列與本機專案列同一個縮排級距。
struct RemoteDeviceSectionContent: View {
    @ObservedObject var model: ChatPageModel
    let section: RemoteSidebarSection
    /// W98c：專案列預設收合，展開狀態只活在這個 View（設備列一收合就整個丟掉），不持久化。
    @State private var expandedProjects: Set<UUID> = []

    var body: some View {
        if section.isOnline {
            if section.projects.isEmpty {
                Text("這台還沒有專案")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 20)
            }
            ForEach(section.projects) { project in
                let isExpanded = expandedProjects.contains(project.id)
                VStack(alignment: .leading, spacing: 3) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            if expandedProjects.contains(project.id) {
                                expandedProjects.remove(project.id)
                            } else {
                                expandedProjects.insert(project.id)
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                            Text(project.name)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .chatMenuRowHover()
                    .help(isExpanded ? "收起「\(project.name)」" : "展開「\(project.name)」")
                    .accessibilityLabel(isExpanded ? "收起專案 \(project.name)" : "展開專案 \(project.name)")
                    .accessibilityIdentifier("chat-sidebar-remote-project")

                    if isExpanded {
                        ForEach(project.threads) { thread in
                            RemoteThreadRowView(model: model, deviceID: section.deviceID, thread: thread)
                                .padding(.leading, 24)
                        }
                    }
                }
            }
        } else {
            Text("離線・\(RemoteDeviceSidebarSection.seen(section.lastSeenAt))")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .padding(.leading, 20)
        }
    }
}

private struct RemoteThreadRowView: View {
    @ObservedObject var model: ChatPageModel
    let deviceID: String
    let thread: RemoteThreadRow

    private var isSelected: Bool {
        guard let sel = model.selectedRemote else { return false }
        return sel.deviceID == deviceID && sel.threadID == thread.id
    }

    var body: some View {
        Button {
            _ = model.selectRemote(deviceID: deviceID, threadID: thread.id)
        } label: {
            label
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("拉到這台（複製一份到本機）") { _ = model.pullThreadFromDevice(deviceID, thread.id) }
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(thread.title)
                    .font(ChatTypography.sidebarThreadTitle)
                    .lineLimit(1)
                if !thread.statusLine.isEmpty {
                    Text(thread.statusLine)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if thread.isRunning {
                Circle().fill(Color.green).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    private var rowBackground: Color {
        isSelected ? LiquidGlassTokens.brandAccent.opacity(0.14) : Color.clear
    }
}
