import SwiftUI
import AppKit

/// 名稱只活在畫面記憶體，ID 才用於跳轉；不新增存檔格式。
struct ChatGPTSessionLink: Equatable, Sendable {
    let threadID: UUID
    let osProject: String
    let osThread: String
    let chatGPTProjectID: String
    let chatGPTProject: String
    let conversationID: String
}

struct ChatGPTSessionMappingRequest: Equatable, Sendable {
    enum Side: Equatable, Sendable { case coder, chatGPT }
    struct Candidate: Equatable, Sendable {
        let threadID: UUID
        let project: String
        let thread: String
        let folder: URL
    }
    let side: Side
    let threadID: UUID?
    let conversationID: String?
    let candidates: [Candidate]
    let revision: Int

    @MainActor init(pageModel: ChatPageModel, spaceModel: ChatGPTSpaceModel, side: Side, revision: Int) {
        self.side = side
        self.revision = revision
        threadID = side == .coder && pageModel.selectedRemote == nil ? pageModel.selectedThreadID : nil
        conversationID = side == .chatGPT ? spaceModel.selectedID : nil
        guard let engine = pageModel.localLiveForBridge else { candidates = []; return }
        let doc = engine.doc
        let selected = threadID
        let projects = Dictionary(doc.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let threads = side == .coder ? doc.threads.first { $0.id == selected }.map { [$0] } ?? [] : doc.threads
        candidates = threads.filter { !$0.isArchived && !doc.isAssistantThread($0.id) }.compactMap { thread in
            let standalone = thread.projectID == nil || thread.projectID == doc.generalProjectID
            let project = standalone ? nil : thread.projectID.flatMap { projects[$0] }
            guard standalone || project != nil else { return nil }
            return Candidate(threadID: thread.id, project: project?.name ?? "無專案", thread: thread.title,
                folder: project.map { URL(fileURLWithPath: $0.workdir, isDirectory: true) } ?? engine.tapInboxFolder)
        }
    }

    func resolve() async -> ChatGPTSessionLink? {
        guard side == .coder ? threadID != nil : conversationID != nil else { return nil }
        var maps: [URL: TapProjectMap] = [:]
        var read: Set<URL> = []
        var matches: [ChatGPTSessionLink] = []
        for candidate in candidates {
            guard !Task.isCancelled else { return nil }
            if read.insert(candidate.folder).inserted {
                maps[candidate.folder] = TapProjectMapStore.displayMap(at: candidate.folder)
            }
            guard let map = maps[candidate.folder], let id = map.threads[candidate.threadID.uuidString], !id.isEmpty,
                  side != .chatGPT || id == conversationID else { continue }
            matches.append(ChatGPTSessionLink(threadID: candidate.threadID, osProject: candidate.project, osThread: candidate.thread,
                chatGPTProjectID: map.chatgpt_project_id, chatGPTProject: map.name, conversationID: id))
        }
        // 損壞或重複對應不能猜要開哪條。
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Coder 與 Space 共用同一行與同一個查表入口；沒有對應就不占畫面。
struct ChatGPTSessionMappingRow: View {
    @WorkspaceObservedObject var pageModel: ChatPageModel
    @WorkspaceObservedObject var spaceModel: ChatGPTSpaceModel
    let side: ChatGPTSessionMappingRequest.Side
    var topInset: CGFloat = 0
    var displayTap: any ConversationTap = ChatGPTTap.shared
    @State private var link: ChatGPTSessionLink?
    @State private var fetchedTitle: String?
    @State private var revision = 0
    #if DEBUG
    final class Probe {
        var link: ChatGPTSessionLink?
        var label: String?
        var button: CGRect?
    }
    var testProbe: Probe? = nil
    #endif

    private var request: ChatGPTSessionMappingRequest {
        .init(pageModel: pageModel, spaceModel: spaceModel, side: side, revision: revision)
    }
    private func label(_ link: ChatGPTSessionLink) -> String {
        if side == .chatGPT { return "OS：\(link.osProject) › \(link.osThread)" }
        let project = spaceModel.projects.first { $0.id == link.chatGPTProjectID }?.title ?? link.chatGPTProject
        let title = (spaceModel.conversations.first { $0.id == link.conversationID }
            ?? spaceModel.projectConversations.values.lazy.flatMap { $0 }.first { $0.id == link.conversationID })?.title ?? fetchedTitle ?? link.osThread
        return "ChatGPT：\(project) › \(title)"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let link {
                HStack(spacing: 8) {
                    Text(label(link)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(label(link))
                    Spacer(minLength: 4)
                    Button {
                        if side == .coder {
                            pageModel.openMappedChatGPTConversation(link, spaceModel: spaceModel)
                        } else {
                            pageModel.openMappedOSThread(link)
                        }
                    } label: {
                        Text(side == .coder ? "在 ChatGPT 打開" : "在 OS 打開")
                            .font(.caption).padding(.horizontal, 10).frame(height: 28).chatGlassChip()
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(side == .coder ? "mapping.openChatGPT" : "mapping.openOS")
                    #if DEBUG
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { testProbe?.button = $0 }
                    #endif
                }
                .padding(.horizontal, 24).padding(.vertical, 4)
                .padding(.top, topInset)
                .accessibilityIdentifier(side == .coder ? "mapping.chatGPT" : "mapping.os")
                #if DEBUG
                .onAppear { testProbe?.link = link; testProbe?.label = label(link) }
                .onChange(of: label(link)) { _, value in testProbe?.label = value }
                .onDisappear { testProbe?.link = nil; testProbe?.label = nil; testProbe?.button = nil }
                #endif
            }
        }
        .task(id: request) {
            link = nil
            fetchedTitle = nil
            let loaded = await request.resolve()
            guard !Task.isCancelled else { return }
            link = loaded
            if side == .coder, let loaded, displayTap.connection == .ready {
                let conversations = try? await displayTap.conversations(inProject: loaded.chatGPTProjectID)
                guard !Task.isCancelled else { return }
                fetchedTitle = conversations?.first { $0.id == loaded.conversationID }?.title
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TapProjectMapStore.didChange).receive(on: RunLoop.main)) { _ in
            revision += 1
        }
    }
}

extension ChatPageModel {
    func openMappedChatGPTConversation(_ link: ChatGPTSessionLink, spaceModel: ChatGPTSpaceModel) {
        guard localLiveForBridge?.threadRecord(link.threadID) != nil else { return }
        spaceModel.openMappedConversation(link.conversationID)
        mode = .chatgpt
        NotificationCenter.default.post(name: .tatwoOpenWorkOSWindow, object: TatwoPage.chat.rawValue)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openMappedOSThread(_ link: ChatGPTSessionLink) {
        guard let thread = localLiveForBridge?.threadRecord(link.threadID), !thread.isArchived else { return }
        mode = .chat
        selectLocalThread(link.threadID)
        NotificationCenter.default.post(name: .tatwoOpenWorkOSWindow, object: TatwoPage.chat.rawValue)
        NSApp.activate(ignoringOtherApps: true)
    }
}
