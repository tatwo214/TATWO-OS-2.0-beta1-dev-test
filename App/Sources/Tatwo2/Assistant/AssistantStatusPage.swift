import SwiftUI

/// W180 E2：TATWO Space「全域狀態」——每台設備上在跑、等你核准、卡住與失敗、目標、背景工作與終端機、設備。
/// 只讀。核准只在 Island（D54），這頁只帶你過去；點討論串在 Coder 打開。看不到的寫「看不到」＋原因，不寫 0。
struct AssistantStatusPage: View {
    @ObservedObject var model: ChatPageModel
    @ObservedObject private var reader = AssistantOverviewReader.shared

    var body: some View {
        GeometryReader { pane in
            let column = AssistantSpacePane.columnWidth(paneWidth: pane.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Label("全域狀態", systemImage: "chart.bar")
                        .font(.headline)
                    summary
                    approvals
                    runningSection
                    troubleSection
                    goalSection
                    jobSection
                    deviceSection
                }
                .frame(width: column, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityIdentifier("tatwo-status-page")
        .onAppear { reader.start(model: model) }
        .onDisappear { reader.stop() }
    }

    private var snapshot: OverviewStatusSnapshot { reader.status }
    private var now: Date { reader.refreshedAt ?? Date() }
    private var reporting: [OverviewDeviceStatus] { snapshot.devices.filter(\.reportsWork) }
    /// 離線或正在連的設備：它們上面的工作看不到，每張卡片都寫出來（不讓「沒有…」讀起來像全部都沒有）。
    private var silent: [OverviewDeviceStatus] { snapshot.devices.filter { !$0.reportsWork } }

    // MARK: - 摘要

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(reader.refreshedAt == nil ? "讀取中…" : OverviewText.summary(snapshot))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .accessibilityIdentifier("tatwo-status-summary")
            if !snapshot.awaitingUnseen.isEmpty {
                Text(snapshot.awaitingUnseen.joined(separator: "、") + " 的待核准看不到，不算在裡面。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !snapshot.silentDevices.isEmpty {
                Text(snapshot.silentDevices.joined(separator: "、") + " 沒連上，它上面的工作看不到。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 等你核准

    private var approvals: some View {
        card("等你核准", symbol: "checkmark.shield", id: "tatwo-status-approvals") {
            ForEach(snapshot.devices) { device in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(OverviewText.awaiting(device))
                            .font(.system(size: 12))
                            .foregroundStyle(device.awaitingCount == nil ? Color.secondary : Color.primary)
                        Spacer(minLength: 8)
                        if device.isThisDevice, (device.awaitingCount ?? 0) > 0 {
                            OSChipButton(title: "到 Island 查看", systemImage: "bell") {
                                AssistantOverviewNavigation.openApprovals()
                            }
                            .accessibilityIdentifier("tatwo-status-open-island")
                        }
                    }
                    ForEach(device.awaiting ?? []) { row in
                        threadRow(row, device: device)
                    }
                    ForEach(Array((device.requestTitles ?? []).enumerated()), id: \.offset) { _, title in
                        Text("Island 請求：" + title)
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                            .padding(.leading, 6)
                    }
                    if let note = OverviewText.staleNote(device.detail, now: now), device.awaitingCount != nil {
                        Text(note).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - 正在跑

    private var runningSection: some View {
        card("正在跑", symbol: "play.circle", id: "tatwo-status-running") {
            if reporting.allSatisfy({ $0.running.isEmpty }) {
                empty(silent.isEmpty ? "現在沒有在跑的工作。" : "看得到的設備上沒有在跑的工作。")
            }
            ForEach(reporting.filter { !$0.running.isEmpty }) { device in
                deviceHeader(device)
                ForEach(device.running) { row in threadRow(row, device: device) }
            }
            silentLines
        }
    }

    // MARK: - 卡住與失敗

    private var troubleSection: some View {
        card("卡住與失敗", symbol: "exclamationmark.triangle", id: "tatwo-status-troubles") {
            if reporting.allSatisfy({ $0.stalled.isEmpty && $0.failed.isEmpty }) {
                empty(silent.isEmpty ? "沒有卡住或失敗的工作。" : "看得到的設備上沒有卡住或失敗的工作。")
            }
            ForEach(reporting.filter { !$0.stalled.isEmpty || !$0.failed.isEmpty }) { device in
                deviceHeader(device)
                ForEach(device.stalled + device.failed) { row in threadRow(row, device: device) }
            }
            silentLines
        }
    }

    // MARK: - 目標

    private var goalSection: some View {
        card("目標", symbol: "target", id: "tatwo-status-goals") {
            if reporting.allSatisfy({ $0.goals?.isEmpty == true }) {
                empty(silent.isEmpty ? "沒有未完成的目標。" : "看得到的設備上沒有未完成的目標。")
            }
            ForEach(reporting.filter { $0.goals?.isEmpty != true }) { device in
                deviceHeader(device)
                if let unseen = OverviewText.goals(device) {
                    empty(unseen)
                }
                ForEach(device.goals ?? []) { row in goalRow(row, device: device) }
                if let note = OverviewText.staleNote(device.detail, now: now), device.goals != nil {
                    Text(note).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            silentLines
        }
    }

    private func goalRow(_ row: OverviewGoalRow, device: OverviewDeviceStatus) -> some View {
        Button { open(device, row.threadID) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if row.hasNativeGoal {
                        Text("原生 /goal").font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(OverviewText.goalProgress(row.goal))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
                }
                Text([row.projectName, row.goal.activeTitle.map { "進行中：" + $0 }]
                        .compactMap { $0 }.joined(separator: "・"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chatMenuRowHover()
        .help("在 Coder 打開")
    }

    // MARK: - 背景工作與終端機

    private var jobSection: some View {
        card("背景工作與終端機", symbol: "terminal", id: "tatwo-status-jobs") {
            if reporting.allSatisfy({ ($0.jobs?.isEmpty ?? false) && ($0.cli?.isEmpty ?? false) }) {
                empty(silent.isEmpty ? "沒有背景工作或終端機。" : "看得到的設備上沒有背景工作或終端機。")
            }
            ForEach(reporting.filter { !(($0.jobs?.isEmpty ?? false) && ($0.cli?.isEmpty ?? false)) }) { device in
                deviceHeader(device)
                if device.jobs == nil || device.cli == nil {
                    empty(OverviewText.unseen(OverviewText.unseenReason(device.detail, name: device.name,
                                                                        connection: device.connection)))
                }
                let jobs = (device.jobs ?? []).sorted { rank($0) < rank($1) }
                ForEach(Array(jobs.prefix(8).enumerated()), id: \.offset) { _, job in
                    line(job.name, trailing: jobState(job), symbol: "gearshape")
                }
                if jobs.count > 8 { empty("還有 \(jobs.count - 8) 個背景工作。") }
                if let truncated = OverviewText.jobsTruncated(jobs) { empty(truncated) }
                ForEach(Array((device.cli ?? []).prefix(8).enumerated()), id: \.offset) { _, session in
                    line(session.title, trailing: session.running ? "在跑" : "已結束", symbol: "terminal")
                }
                if let note = OverviewText.staleNote(device.detail, now: now), device.jobs != nil {
                    Text(note).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            silentLines
        }
    }

    private func rank(_ job: OverviewJob) -> Int { job.isRunning ? 0 : job.isFailed ? 1 : 2 }

    private func jobState(_ job: OverviewJob) -> String {
        let state = job.isRunning ? "在跑" : job.isFailed ? "失敗" : job.state == "exited" ? "已結束" : job.state
        guard let started = job.startedAt else { return state }
        return state + "・" + OverviewText.relative(started, now: now) + "開始"
    }

    // MARK: - 設備

    private var deviceSection: some View {
        card("設備", symbol: "desktopcomputer", id: "tatwo-status-devices") {
            ForEach(snapshot.devices) { device in
                HStack(spacing: 8) {
                    Image(systemName: device.isThisDevice ? "laptopcomputer" : "desktopcomputer")
                        .foregroundStyle(.secondary)
                    Text(device.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if device.isPrimary { tag("主設備") }
                    Spacer(minLength: 8)
                    Text(deviceLine(device)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func deviceLine(_ device: OverviewDeviceStatus) -> String {
        var text = OverviewText.connection(device.connection, isThisDevice: device.isThisDevice)
        if !device.isThisDevice, let seen = device.lastSeenAt {
            text += "・最後上線 " + OverviewText.relative(seen, now: now)
        }
        return text
    }

    // MARK: - 共用

    /// 每張卡片最後：看不到的設備各一行「看不到（原因）」。
    private var silentLines: some View {
        ForEach(silent) { device in
            deviceHeader(device)
            empty(OverviewText.silent(device))
                .accessibilityIdentifier("tatwo-status-unseen")
        }
    }

    private func card<Content: View>(_ title: String, symbol: String, id: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
        .accessibilityIdentifier(id)
    }

    private func deviceHeader(_ device: OverviewDeviceStatus) -> some View {
        HStack(spacing: 6) {
            Text(device.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if device.isPrimary { tag("主設備") }
        }
        .padding(.top, 4)
    }

    private func threadRow(_ row: OverviewThreadRow, device: OverviewDeviceStatus) -> some View {
        Button { open(device, row.threadID) } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(row.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if row.hasNativeGoal {
                            Text("原生 /goal").font(.system(size: 9.5)).foregroundStyle(.secondary)
                        }
                    }
                    Text([row.projectName, row.stage].compactMap { $0 }.joined(separator: "・"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("最後輸出 " + OverviewText.relative(row.since, now: now))
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chatMenuRowHover()
        .help(row.isAssistant ? "回到 TATWO 對話" : "在 Coder 打開")
    }

    private func line(_ title: String, trailing: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 8)
            Text(trailing).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .chatGlassChip()
    }

    private func open(_ device: OverviewDeviceStatus, _ threadID: UUID) {
        AssistantOverviewNavigation.open(model: model, deviceID: device.id,
                                         isThisDevice: device.isThisDevice, threadID: threadID)
    }
}
