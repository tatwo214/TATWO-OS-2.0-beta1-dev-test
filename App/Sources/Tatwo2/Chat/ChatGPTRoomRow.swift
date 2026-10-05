import SwiftUI

/// Existing hands root remains engine-readable. The sheet only displays tool metadata, never dialogue.
struct ChatGPTRoomRow: View {
    let projectID: UUID
    let workdir: String
    let openThread: (UUID) -> Void
    var roomJournal: HandsRoomJournal = HandsService.shared.roomJournal
    var sourceProjectName: String? = nil
    #if DEBUG
    var testVisible: ((Bool) -> Void)? = nil
    var testSource: ((String?) -> Void)? = nil
    #endif
    @State private var showing = false
    @State private var calls: [HandsRoomCall] = []
    @State private var mappingName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
        if !calls.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
            if let sourceProjectName {
                Text("來源：\(sourceProjectName)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    #if DEBUG
                    .onAppear { testSource?(sourceProjectName) }
                    .onDisappear { testSource?(nil) }
                    #endif
            }
            if let mappingName {
                Text("ChatGPT 專案：\(mappingName)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Button {
                showing = true
            } label: {
                Label("ChatGPT 房", systemImage: "wrench.and.screwdriver")
                    .font(.caption).padding(.horizontal, 10).frame(height: 28)
                    .chatGlassChip()
            }
            .buttonStyle(.plain)
            #if DEBUG
            .onAppear { testVisible?(true) }
            .onDisappear { testVisible?(false) }
            #endif
            .sheet(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("ChatGPT 房").font(.headline)
                        Spacer()
                        GlobalDMChipButton(title: "關閉") { showing = false }
                    }
                    Text("只記工具、時間、結果摘要與核准，不保存 ChatGPT 對話。")
                        .font(.caption).foregroundStyle(.secondary)
                    GlobalDMChipButton(title: "在 Coder 開啟紀錄") {
                        if let id = HandsService.shared.rootThread(projectID: projectID) {
                            showing = false
                            openThread(id)
                        }
                    }
                    if calls.isEmpty { Text("這個專案還沒有 ChatGPT 工具紀錄").foregroundStyle(.secondary) }
                    List(calls.reversed()) { row in
                        DisclosureGroup {
                            Text(row.summaryTitle).textSelection(.enabled)
                            if let approval = row.approvalTitle { Text("操作畫面：\(approval)") }
                            if row.app != nil { Text("App：要求操作的 App") }
                            if let minutes = row.leaseMinutes { Text("核准時限：\(minutes) 分鐘") }
                            if let workspaceID = row.workspaceID {
                                GlobalDMChipButton(title: "開啟工作區") {
                                    showing = false; openThread(workspaceID)
                                }
                            }
                        } label: {
                            HStack {
                                Text(row.at, style: .time).monospacedDigit()
                                Text(row.toolTitle)
                                Text(row.summaryTitle).foregroundStyle(.secondary).lineLimit(1)
                            }.font(.caption)
                        }
                    }
                }
                .padding().frame(minWidth: 600, minHeight: 360)
            }
        }
        }
        }
        .task(id: "\(projectID.uuidString)|\(workdir)") {
            mappingName = await Task.detached { HandsTapMap.name(workdir: workdir) }.value
            await reloadCalls()
        }
        .onReceive(NotificationCenter.default.publisher(for: HandsRoomJournal.didChange).receive(on: RunLoop.main)) { _ in
            Task { await reloadCalls() }
        }
        .onReceive(NotificationCenter.default.publisher(for: TapProjectMapStore.didChange).receive(on: RunLoop.main)) { _ in
            Task { mappingName = await Task.detached { HandsTapMap.name(workdir: workdir) }.value }
        }
    }

    func sourceProject(_ name: String) -> Self {
        var row = self
        row.sourceProjectName = name
        return row
    }

    private func reloadCalls() async {
        let loaded = await Task.detached { roomJournal.rows(projectID: projectID) }.value
        guard !Task.isCancelled else { return }
        calls = loaded
    }
}
