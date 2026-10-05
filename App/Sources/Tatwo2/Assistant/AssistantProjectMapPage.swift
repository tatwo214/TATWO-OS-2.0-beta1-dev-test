import SwiftUI

/// W180 E2：兩頁共用的「在 Coder 打開」與「到 Island 查看」。只切畫面、選討論串，不改任何資料。
@MainActor
enum AssistantOverviewNavigation {
    /// 先切到 Coder，再選那條：本機用 selectLocalThread，遠端用 selectRemote。找不到那條就不動。
    /// 助理那條（本機或遠端）不切 mode：切一次 mode 就會停掉電腦操作、收回瀏覽器請求，
    /// 正在等你核准的那件事會被打斷——只回到 TATWO 的對話分頁。
    @discardableResult
    static func open(model: ChatPageModel, deviceID: String, isThisDevice: Bool, threadID: UUID) -> Bool {
        if isThisDevice {
            guard let live = model.localLiveForBridge, live.threadRecord(threadID) != nil else { return false }
            if live.doc.isAssistantThread(threadID) { return returnToAssistant(model: model) }
            model.mode = .chat
            model.selectLocalThread(threadID)
            return true
        }
        guard let remote = remoteEngine(model: model, deviceID: deviceID),
              remote.threadRecord(threadID) != nil else { return false }
        if remote.doc.isAssistantThread(threadID) { return returnToAssistant(model: model) }
        model.mode = .chat
        return model.selectRemote(deviceID: deviceID, threadID: threadID)
    }

    static func canOpenRemote(model: ChatPageModel, deviceID: String, threadID: UUID) -> Bool {
        remoteEngine(model: model, deviceID: deviceID)?.threadRecord(threadID) != nil
    }

    private static func remoteEngine(model: ChatPageModel, deviceID: String) -> RemoteLiveEngine? {
        model.remoteSessions.first { $0.device.id == deviceID }?.engine
    }

    /// 這兩頁只在 TATWO 裡，mode 本來就是 .tatwo：只換回對話分頁，mode 不重設。
    private static func returnToAssistant(model: ChatPageModel) -> Bool {
        if model.mode != .tatwo { model.mode = .tatwo }
        AssistantSpaceTabStore.shared.returnToConversation()
        return true
    }

    /// 核准只在 Island（D54）：這裡只帶你過去，不另做核准。
    static func openApprovals() {
        IslandExceptionsNavigation.openWork()
    }
}

/// W180 E2：TATWO Space「專案地圖」——依設備分組（不合併同名專案），專案卡展開後列出討論串。
/// 只讀；點討論串在 Coder 打開。離線的設備整組變灰、點不動。
struct AssistantProjectMapPage: View {
    @ObservedObject var model: ChatPageModel
    @ObservedObject private var reader = AssistantOverviewReader.shared
    @State private var expanded: Set<String> = []

    var body: some View {
        GeometryReader { pane in
            let column = AssistantSpacePane.columnWidth(paneWidth: pane.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Label("專案地圖", systemImage: "map")
                            .font(.headline)
                        Spacer(minLength: 8)
                        AssistantClassificationChip(model: model)   // W180 E3b：請助理整理分類
                    }
                    AssistantClassificationSection(model: model)   // W180 E3b：分類建議、最近搬移
                    if reader.map.devices.isEmpty {
                        Text(reader.refreshedAt == nil ? "讀取中…" : "還沒有專案。")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("tatwo-project-map-empty")
                    }
                    ForEach(reader.map.devices) { device in
                        deviceGroup(device)
                    }
                }
                .frame(width: column, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityIdentifier("tatwo-project-map-page")
        .onAppear { reader.start(model: model) }
        .onDisappear { reader.stop() }
    }

    private var now: Date { reader.refreshedAt ?? Date() }

    // MARK: - 設備

    private func deviceGroup(_ device: OverviewMapDevice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: device.isThisDevice ? "laptopcomputer" : "desktopcomputer")
                    .foregroundStyle(.secondary)
                Text(device.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if device.isPrimary { tag("主設備") }
                Spacer(minLength: 8)
                Text(connectionLine(device)).font(.caption).foregroundStyle(.secondary)
            }
            if !device.canOpen {
                Text(device.connection == .connecting ? "連線中，連上後可以打開" : "離線，連上後可以打開")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !device.goalsVisible {
                Text("目標" + OverviewText.unseen(OverviewText.unseenReason(device.detail, name: device.name,
                                                                           connection: device.connection)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let empty = OverviewText.mapEmpty(device) {
                Text(empty)
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier(device.projectsUnseen ? "tatwo-project-map-unseen" : "tatwo-project-map-device-empty")
            }
            ForEach(device.projects) { project in
                projectCard(project, device: device)
            }
        }
        .opacity(device.canOpen ? 1 : 0.55)
        .disabled(!device.canOpen)
        .accessibilityIdentifier("tatwo-project-map-device")
    }

    private func connectionLine(_ device: OverviewMapDevice) -> String {
        var text = OverviewText.connection(device.connection, isThisDevice: device.isThisDevice)
        if !device.isThisDevice, device.connection != .online, let seen = device.lastSeenAt {
            text += "・最後上線 " + OverviewText.relative(seen, now: now)
        }
        return text
    }

    // MARK: - 專案卡

    private func projectCard(_ project: OverviewMapProject, device: OverviewMapDevice) -> some View {
        let key = device.id + "|" + project.id.uuidString
        let isExpanded = expanded.contains(key)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    if let latest = project.latestThreadID { open(device, latest) }
                } label: {
                    Text(project.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(project.latestThreadID == nil)
                .help(project.latestThreadID == nil ? "還沒有討論串" : "在 Coder 打開最近的一條")
                Spacer(minLength: 8)
                if !project.threads.isEmpty {
                    Button {
                        if isExpanded { expanded.remove(key) } else { expanded.insert(key) }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "收起" : "展開")
                }
            }
            Text(countsLine(project, device: device))
                .font(.caption).foregroundStyle(.secondary)
            Text(activityLine(project, device: device))
                .font(.caption).foregroundStyle(.secondary)
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(project.threads) { thread in
                        threadRow(thread, device: device)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
        .accessibilityIdentifier("tatwo-project-card")
    }

    private func countsLine(_ project: OverviewMapProject, device: OverviewMapDevice) -> String {
        let running = device.isSnapshot ? "在跑 看不到" : "在跑 \(project.runningCount)"
        return "主串 \(project.mainCount)・子討論串 \(project.subCount)・\(running)"
    }

    private func activityLine(_ project: OverviewMapProject, device: OverviewMapDevice) -> String {
        if device.isSnapshot { return "離線前的資料：最後活動與目標看不到" }
        let activity = project.lastActivity.map { "最後活動 " + OverviewText.relative($0, now: now) } ?? "還沒有討論串"
        let goals = project.openGoals.map { "未完成目標 \($0)" } ?? "目標看不到"
        return activity + "・" + goals
    }

    private func threadRow(_ thread: OverviewMapThread, device: OverviewMapDevice) -> some View {
        Button { open(device, thread.threadID) } label: {
            HStack(spacing: 6) {
                if thread.isSub {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                        .padding(.leading, 10)
                }
                Circle()
                    .fill(thread.isRunning ? Color.green.opacity(0.85) : Color.clear)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(!thread.isRunning)
                    .accessibilityLabel(thread.isRunning ? "在跑" : "")
                Text(thread.title).font(.system(size: 12)).lineLimit(1)
                if thread.hasNativeGoal {
                    Text("原生 /goal").font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let goal = thread.goal, goal.total > 0 {
                    Text("目標 \(goal.done)／\(goal.total)")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
                }
                if let activity = thread.lastActivity {
                    Text(OverviewText.relative(activity, now: now))
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chatMenuRowHover()
        .help("在 Coder 打開")
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .chatGlassChip()
    }

    private func open(_ device: OverviewMapDevice, _ threadID: UUID) {
        guard device.canOpen else { return }
        AssistantOverviewNavigation.open(model: model, deviceID: device.id,
                                         isThisDevice: device.isThisDevice, threadID: threadID)
    }
}
