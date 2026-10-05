// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPage+Transcript.swift；改動 36 行（原因：保留既有改動，cli-ui 最小掛接；新增 UI 邏輯在 New、資料在 Facade）
import SwiftUI
import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers
import Darwin

extension ChatPage {
    var cliTerminalPane: some View {
        CLIWorkbenchSurface(tabs: model.cliWorkbenchTabs,
            selectedTabID: model.cliSelectedWorkbenchID, panes: model.cliWorkbenchPanes,
            appearance: .osTheme(TatwoActivePalette.current),
            editingOptions: model.cliWorkbenchDocument.editingOptions,
            pendingCloseTitle: model.cliPendingCloseTitle,
            send: model.sendCLIWorkbench) { pane in
                if let session = model.cliTabPTYSession(for: pane.id) {
                    if let error = session.error {
                        Text(error).font(.caption).textSelection(.enabled).padding()
                    } else {
                        NativeTerminalPTYView(session: session,
                            focused: model.cliFocusedWorkbenchPaneID == pane.id)
                    }
                } else {
                    ScrollView {
                        Text(model.cliTabLines(for: pane.id).map(\.plainText).joined(separator: "\n"))
                            .font(.system(size: CLIWorkbenchMetrics.terminalFont, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(CLIWorkbenchMetrics.inset)
                    }
                }
            }
            .padding(.top, surface == .window ? WindowChromeMetrics.bandHeight : 0)
            .onAppear { model.loadPersistedCLISessionBook(); model.prepareCLITabs() }
    }

    @ViewBuilder
    func messageArea(contentMaxWidth: CGFloat?) -> some View {
        if model.isLoadingStore {
            ProgressView("載入對話")
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.selectedThreadID == nil {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isRemoteTranscriptLoading {
            // W100：遠端逐字稿在背景拉，第一次沒有快取時顯示「載入對話…」而不是空白（W201：不報連線狀態）。
            ProgressView("載入對話…")
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let note = model.remoteOfflineEmptyNote {
            RemoteOfflineEmptyTranscript(text: note)   // W182 R4：那台離線、這條離線前沒讀過
        } else {
            VStack(spacing: 8) {
                if model.mode == .chat {
                    ChatGPTSessionMappingRow(pageModel: model, spaceModel: .shared, side: .coder,
                                            topInset: surface == .window ? WindowChromeMetrics.bandHeight : 0)
                }
                if let engine = model.localLiveForBridge {
                    if let notice = engine.documentSafetyNotice {
                        Text(notice).font(.caption).textSelection(.enabled)
                    }
                    if let candidate = engine.recoveryCandidate {
                        ConversationRecoveryRow(candidate: candidate, isDisabled: engine.store.isReadOnly) {
                            engine.restoreUnreadableConversation()
                            if let id = engine.doc.selectedThreadID { model.selectLocalThread(id) }
                        }
                    }
                }
            transcript(contentMaxWidth: contentMaxWidth)
                if let id = model.selectedThreadID {
                    let state = model.chatGPTTurnState
                    if let thinking = state?.thinking {
                        ChatGPTThinkingRow(thinking: thinking).frame(maxWidth: contentMaxWidth, alignment: .leading)
                    }
                    if let failure = state?.failure {
                        ChatGPTTurnFailureRow(failure: failure) { model.restoreChatGPTInput(failure, in: id) }
                            .frame(maxWidth: contentMaxWidth, alignment: .leading)
                    }
                    if state?.thinking == nil, let note = ChatGPTThinking.doneText(state?.thoughtSeconds) {
                        Text(note).font(.system(size: 13)).foregroundStyle(.secondary)
                            .accessibilityIdentifier("chatgpt.thoughtDuration")
                    }
                }
            }
        }
    }

    func transcript(contentMaxWidth: CGFloat?) -> some View {
        let rowWidth = contentMaxWidth ?? composerMaxWidth ?? ChatUILayout.chatColumnMaxWidth
        return TranscriptScrollView(
            threadID: model.selectedThreadID,
            mcpAllowBlockedNote: model.mcpAllowBlockedNote(threadID: model.selectedThreadID),
            messages: model.transcriptMessages,
            selectedSessionReference: model.selectedSessionReference,
            assistantRoute: model.routeChoice,
            rowWidth: rowWidth,
            gitChangedFiles: model.gitChangedFiles,
            gitChangedFileCount: model.gitChangedFileCount,
            gitChangedLineAdditions: model.gitChangedLineAdditions,
            gitChangedLineDeletions: model.gitChangedLineDeletions,
            isRunning: model.isRunning,
            latestTurnArtifacts: model.latestTurnArtifacts,
            artifactStore: model.selectedRemote == nil ? model.localLiveForBridge?.turnArtifacts : nil,
            onOpenArtifact: { model.openArtifact(path: $0) },
            canRetryTurn: model.canRetryLastTurn,
            onRetryTurn: { model.resendLastUserMessage() },
            assistantTranscriptCache: model.assistantTranscriptCache,
            planArtifact: model.activePlanArtifact,
            isPlanWriting: model.isActivePlanTurnWriting,
            activePlanTurnAssistantMessageID:
                model.activePlanTurnAssistantMessageID,
            planInspectorPresented: $planInspectorPresented,
            onOpenChangedFiles: {
                rightPanelContent = .diff
                rightPanelPreference = true
                isRightPanelOpen = true
            },
            isPanel: isPanel)
            .id("\(model.selectedRemote?.deviceID ?? "local"):\(model.selectedThreadID?.uuidString ?? "")")
    }

    private struct TranscriptBottomYPreferenceKey: PreferenceKey {
        static let defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    private struct TranscriptContentHeightPreferenceKey: PreferenceKey {
        static let defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    private struct TranscriptScrollView: View {
        // W180 D3：這串逐字稿屬於哪條（上面 .id 也以它為鍵，換條就重建），權限放行鈕寫這條。
        let threadID: UUID?
        // W180 D3：這條不能在這台放行（Coder 正在看遠端那條）時，放行鈕換成的那行字。
        let mcpAllowBlockedNote: String?
        let messages: [ChatMessage]
        let selectedSessionReference: TatwoNativeChatSessionReference?
        let assistantRoute: ChatRouteChoice
        let rowWidth: CGFloat
        let gitChangedFiles: [ChatGitChangedFileSummary]
        let gitChangedFileCount: Int
        let gitChangedLineAdditions: Int
        let gitChangedLineDeletions: Int
        let isRunning: Bool
        let latestTurnArtifacts: TurnArtifactIndex?
        let artifactStore: TurnArtifacts?
        let onOpenArtifact: (String) -> Void
        let canRetryTurn: Bool
        let onRetryTurn: () -> Void
        let assistantTranscriptCache: TatwoAssistantTranscriptCache
        let planArtifact: TatwoPlanArtifactV1?
        let isPlanWriting: Bool
        let activePlanTurnAssistantMessageID: String?
        @Binding var planInspectorPresented: Bool
        let onOpenChangedFiles: () -> Void
        let isPanel: Bool

        @State private var artifactIndices: [String: TurnArtifactIndex] = [:]
        @State private var followState = ChatTranscriptScrollFollowState()
        /// 歷史條跳轉後要抖動＋短暫陰影的那一列（serial 讓同一列連點也會再播一次）。
        @State private var historyArrival: ChatHistoryArrival?
        @State private var cachedDisplayItems: [ChatTranscriptDisplayItem] = []
        @State private var cachedDisplayFingerprint = ChatTranscriptDisplayFingerprint()
        @State private var transcriptContentHeight: CGFloat = 0
        @State private var scrollIsScheduled = false
        @State private var initialFocusClaimedPlanQuestionMessageIDs:
            Set<String> = []

        /// The projection cache stamps the tail with a model-owned revision.
        /// Constructing this key is therefore O(1), even for long transcripts.
        private var displayFingerprint: ChatTranscriptDisplayFingerprint {
            ChatTranscriptDisplayFingerprint(
                messages,
                planArtifactSourceMessageID:
                    planArtifact?.sourceAssistantMessageID,
                activePlanTurnAssistantMessageID:
                    activePlanTurnAssistantMessageID,
                isPlanWriting: isPlanWriting)
        }

        private var displayItems: [ChatTranscriptDisplayItem] {
            let fingerprint = displayFingerprint
            let items = fingerprint == cachedDisplayFingerprint
                ? cachedDisplayItems
                : ChatTranscriptDisplayBuilder.build(planThoughtPresentationMessages)
            return ChatPlanArtifactTranscriptProjection.displayItems(
                items, placement: planArtifactPlacement,
                sourceAssistantMessageID: planArtifactMessageID)
        }

        private var latestAssistantMessageID: String? {
            displayFingerprint.latestAssistantMessageID
        }

        private var gitChangedSummaryFingerprint: String {
            [
                String(gitChangedFileCount),
                String(gitChangedLineAdditions),
                String(gitChangedLineDeletions),
                gitChangedFiles.map {
                    "\($0.path):\($0.additions):\($0.deletions)"
                }.joined(separator: "|"),
            ].joined(separator: "#")
        }

        private var planArtifactMessageID: String? {
            planArtifact?.sourceAssistantMessageID
        }

        private var planArtifactPlacement:
            ChatPlanArtifactTranscriptProjection.Placement
        {
            ChatPlanArtifactTranscriptProjection.placement(
                hasArtifact: planArtifact != nil,
                sourceAssistantMessageID:
                    planArtifactMessageID,
                isPlanWriting: isPlanWriting)
        }

        private var shouldRenderPlanWritingSummary: Bool {
            planArtifactPlacement.includesWritingRow
        }

        private var planThoughtPresentationMessages: [ChatMessage] {
            ChatPlanThoughtPresentation.projectedMessages(
                messages,
                planArtifactSourceMessageID:
                    planArtifactMessageID,
                activePlanTurnAssistantMessageID:
                    activePlanTurnAssistantMessageID)
        }

        private var latestAssistantHasPlanQuestions: Bool {
            displayFingerprint.latestAssistantHasPlanQuestions
        }

        private func scrollDestination(
            viewportHeight: CGFloat
        ) -> ChatTranscriptScrollDestination {
            ChatTranscriptScrollDestination.resolve(
                latestAssistantMessageID: latestAssistantMessageID,
                hasPlanArtifact: planArtifact != nil,
                isPlanWriting: isPlanWriting,
                latestAssistantHasPlanQuestions:
                    latestAssistantHasPlanQuestions,
                contentHeight: transcriptContentHeight,
                viewportHeight: viewportHeight)
        }

        private static let bottomAnchorID = "tatwo-chat-transcript-bottom"
        private static let coordinateSpaceName = "tatwo-chat-transcript-scroll"

        var body: some View {
            GeometryReader { viewport in
                let projection = CoderTurnProjection(displayItems, messages: messages, isRunning: isRunning)
                let currentTurn = messages.last(where: { $0.role == .user })?.turnID
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottom) {
                        ScrollView {
                            LazyVStack(
                                alignment: .leading,
                                spacing: TatwoChatTranscriptVisualMetrics.messageSpacing
                            ) {
                                ForEach(projection.items) { item in
                                    Group {
                                        switch item {
                                        case .message(let message):
                                            messageRow(message, details: projection.details[message.id] ?? [], ownsTurn: projection.owners[message.turnID ?? message.id] == message.id, isTurnRunning: isRunning && message.turnID == currentTurn)
                                                .frame(
                                                    width: rowWidth,
                                                    alignment: message.role == .user ? .trailing : .leading)
                                        case .workTimeline(let timeline):
                                            ChatInlineWorkTimelineView(
                                                timeline: timeline,
                                                assistantRoute: assistantRoute,
                                                rowWidth: rowWidth - 38,
                                                planSourceText: timeline.messages.contains { $0.id == planArtifactMessageID }
                                                    ? messages.first { $0.id == planArtifactMessageID && $0.role == .assistant && $0.eventKind == .message }?.text
                                                    : nil)
                                                .padding(.leading, timeline.presentation.isActive ? 38 : 3)
                                        case .planSummary:
                                            PlanTranscriptSummaryView(
                                                artifact: planArtifact,
                                                isWriting: false,
                                                isSidePanelPresented: $planInspectorPresented)
                                                .frame(width: rowWidth - 38, alignment: .leading).padding(.leading, 38)
                                                .id(item.id)
                                                .accessibilityIdentifier("plan-transcript-summary")
                                        }
                                    }
                                    .modifier(ChatHistoryArrivalNudge(id: item.id, arrival: historyArrival))
                                }
                                if showsTypingIndicator && !displayItems.contains(where: {
                                    if case .workTimeline(let timeline) = $0 {
                                        return timeline.presentation.isActive
                                    }
                                    return false
                                }) {
                                    ChatTypingIndicatorRow(route: assistantRoute, rowWidth: rowWidth)
                                        .id("tatwo-chat-typing-indicator")
                                }
                                if shouldRenderPlanWritingSummary {
                                    PlanTranscriptSummaryView(
                                        artifact: nil,
                                        isWriting: true,
                                        isSidePanelPresented:
                                            $planInspectorPresented)
                                        .frame(
                                            width: rowWidth - 38,
                                            alignment: .leading).padding(.leading, 38)
                                        .id("tatwo-plan-writing-summary")
                                        .accessibilityIdentifier(
                                            "plan-transcript-summary")
                                }
                                Color.clear
                                    .frame(height: 1)
                                    .id(Self.bottomAnchorID)
                                    .background {
                                        GeometryReader { bottom in
                                            Color.clear.preference(
                                                key: TranscriptBottomYPreferenceKey.self,
                                                value: bottom.frame(
                                                    in: .named(Self.coordinateSpaceName)).maxY)
                                        }
                                    }
                            }
                            .frame(width: rowWidth, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, isPanel ? 0 : 18)
                            // #1(回滾貼底)+#4:Codex 式頂部 inset——首句從上方起，
                            // 但留出交通燈 band(34)+間隔，與紅黃綠水平清楚區隔；不再貼底也不貼交通燈。
                            .padding(.top, isPanel ? 8 : 50)
                            .background {
                                GeometryReader { content in
                                    Color.clear.preference(
                                        key:
                                            TranscriptContentHeightPreferenceKey
                                                .self,
                                        value: content.size.height)
                                }
                            }
                        }
                        .coordinateSpace(name: Self.coordinateSpaceName)
                        .coderScrollIndicators()
                        .background(ChatTranscriptScrollIntentObserver {
                            followState.detachFromLatest()
                        })
                        // #1 頂部淡出 mask 已移除：在 live 大視窗會把 ScrollView 內文遮成透明(內文消失 bug)。
                        // 區隔改由頂部 inset 50px 提供；不用遮罩。
                        .onPreferenceChange(TranscriptBottomYPreferenceKey.self) { bottomY in
                            followState.update(
                                bottomY: bottomY,
                                viewportHeight: viewport.size.height)
                        }
                        .onPreferenceChange(
                            TranscriptContentHeightPreferenceKey.self
                        ) { height in
                            let isInitialMeasurement =
                                transcriptContentHeight <= 0 && height > 0
                            let didChange =
                                abs(transcriptContentHeight - height) > 0.5
                            transcriptContentHeight = height
                            guard isInitialMeasurement
                                    || (didChange
                                        && followState
                                            .shouldAutoScrollOnContentChange)
                            else {
                                return
                            }
                            scrollToLatest(
                                using: proxy,
                                viewportHeight: viewport.size.height)
                        }
                        .task(id: latestTurnArtifacts?.turnID) {
                            guard let artifactStore, let threadID else { return }
                            var indices: [String: TurnArtifactIndex] = [:]
                            for turn in Set(messages.compactMap(\.turnID)) {
                                if let index = try? await artifactStore.list(threadID: threadID, turnID: turn) { indices[turn] = index }
                            }
                            if !Task.isCancelled { artifactIndices = indices }
                        }
                        .onAppear {
                            followState.jumpToLatest()
                            scrollToLatest(
                                using: proxy,
                                viewportHeight: viewport.size.height)
                        }
                        .onChange(of: viewport.size.width) { _, _ in
                            // Docking a browser reflows LazyVStack without changing
                            // message IDs. Keep the latest anchor visible, but never
                            // pull a reader away from intentionally scrolled history.
                            guard followState.shouldAutoScrollOnContentChange else { return }
                            scrollToLatest(using: proxy, viewportHeight: viewport.size.height)
                        }
                        .onChange(of: selectedSessionReference) { _, _ in
                            followState.jumpToLatest()
                            scrollToLatest(
                                using: proxy,
                                viewportHeight: viewport.size.height)
                        }
                        .onChange(of: displayFingerprint, initial: true) { _, fingerprint in
                            cachedDisplayFingerprint = fingerprint
                            cachedDisplayItems = ChatTranscriptDisplayBuilder.build(
                                planThoughtPresentationMessages)
                        }
                        .onChange(of: displayFingerprint) { _, _ in
                            guard followState.shouldAutoScrollOnContentChange else {
                                return
                            }
                            scrollToLatest(
                                using: proxy,
                                viewportHeight: viewport.size.height)
                        }
                        .onChange(of: planArtifact?.markdownExport()) { _, _ in
                            guard followState.shouldAutoScrollOnContentChange else {
                                return
                            }
                            scrollToLatest(
                                using: proxy,
                                viewportHeight: viewport.size.height)
                        }
                        .onChange(of: gitChangedSummaryFingerprint) { _, _ in
                            guard followState.shouldAutoScrollOnContentChange else {
                                return
                            }
                            scrollToLatest(
                                using: proxy,
                                viewportHeight: viewport.size.height)
                        }
                        // Codex 式歷史 minimap（使用者 #62 逐格 parity：找歷史指令）；左側刻度條、hover預覽、點擊跳轉。
                        .overlay(alignment: .leading) {
                            if !isPanel {
                                ChatHistoryMinimap(
                                    items: projection.items
                                ) { id in
                                    followState.detachFromLatest()
                                    // 2026-09-11 使用者：跳到的訊息不要貼齊上緣 → 落在視窗約 12% 高度；
                                    // 不要滑動過去（訊息多會卡頓）→ 直接切過去。
                                    proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.12))
                                    let serial = (historyArrival?.serial ?? 0) + 1
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        historyArrival = ChatHistoryArrival(id: id, serial: serial)
                                    }
                                }
                            }
                        }

                        if followState.showsJumpToLatest {
                            Button {
                                followState.jumpToLatest()
                                scrollToLatest(
                                    using: proxy,
                                    viewportHeight: viewport.size.height)
                            } label: {
                                Label("跳至最新", systemImage: "arrow.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 12)
                                    .frame(height: 30)
                                    .tatwoAdaptiveCapsule(material: .regularMaterial)
                                    .overlay {
                                        Capsule()
                                            .strokeBorder(
                                                Color.white.opacity(0.14),
                                                lineWidth: 1)
                                    }
                            }
                            .buttonStyle(.plain)
                            .shadow(
                                color: .black.opacity(0.12),
                                radius: 8,
                                x: 0,
                                y: 4)
                            .padding(.bottom, 10)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .accessibilityLabel("跳至最新訊息")
                        }
                    }
                }
                .animation(
                    .easeInOut(duration: 0.16),
                    value: followState.showsJumpToLatest)
            }
        }

        @ViewBuilder
        private func messageRow(_ message: ChatMessage, details: [ChatTranscriptDisplayItem], ownsTurn: Bool, isTurnRunning: Bool) -> some View {
            let candidate = message.turnID.flatMap { artifactIndices[$0] } ?? latestTurnArtifacts
            let index = candidate.flatMap { $0.threadID == threadID && ($0.messageID == message.id || ($0.messageID == nil && $0.turnID == message.turnID && ownsTurn)) && !$0.artifacts.isEmpty ? $0 : nil }
            let changed = message.id == latestAssistantMessageID && gitChangedFileCount > 0 && index == nil
            let hasDetails = !details.isEmpty || (!isTurnRunning && (index != nil || changed))
            if let error = ChatErrorCardPresentation.resolve(message) {
                ChatErrorCard(
                    presentation: error,
                    rowWidth: rowWidth,
                    canRetry: canRetryTurn,
                    onRetry: onRetryTurn)
                    .padding(.leading, 38)
                    .id("tatwo-chat-error-\(message.id)")
            } else if let note = ChatSystemNotePresentation.resolve(message) {
                ChatSystemNoteRow(presentation: note, rowWidth: rowWidth - 38)
                    .padding(.leading, 32)
                    .id("tatwo-chat-note-\(message.id)")
            } else {
                ChatBubble(
                    message: message,
                    threadID: threadID,
                    mcpAllowBlockedNote: mcpAllowBlockedNote,
                    assistantRoute: assistantRoute,
                    rowWidth: rowWidth,
                    assistantTranscriptCache: assistantTranscriptCache,
                    planArtifact: nil,
                    isLatestAssistantMessage:
                        message.id == latestAssistantMessageID,
                    initialPlanQuestionFocusClaimed:
                        initialFocusClaimedPlanQuestionMessageIDs
                            .contains(message.id),
                    onInitialPlanQuestionFocusClaimed: {
                        initialFocusClaimedPlanQuestionMessageIDs
                            .insert(message.id)
                    },
                    planInspectorPresented: $planInspectorPresented,
                    coderTranscript: true,
                    turnDetails: hasDetails ? AnyView(VStack(alignment: .leading, spacing: 8) {
                        ForEach(details.sorted { a, b in if case .workTimeline = a { if case .workTimeline = b { return false }; return true }; return false }) { item in
                            switch item {
                            case .workTimeline(let timeline):
                                ForEach(ChatInlineWorkTimelineDetailProjection.rows(for: timeline, isExpanded: true)) { detail in
                                    ChatInlineWorkDetailRow(detail: detail, symbolName: detail.state == .failed ? "exclamationmark.triangle" : "checkmark.circle", symbolTint: detail.state == .failed ? .red : .secondary)
                                }
                                if timeline.messages.contains(where: { $0.id == planArtifactMessageID }), let text = messages.first(where: { $0.id == planArtifactMessageID && $0.role == .assistant && $0.eventKind == .message })?.text {
                                    ChatAssistantTranscriptBlockView(document: TatwoAssistantTranscriptPresentation.document(markdown: text), copyAllText: text)
                                }
                            case .message(let note):
                                if let presentation = ChatSystemNotePresentation.resolve(note) { ChatSystemNoteRow(presentation: presentation, rowWidth: nil, revealsMemory: true) }
                            case .planSummary: EmptyView()
                            }
                        }
                        if !isTurnRunning, let index {
                            ChatArtifactsCard(index: index, onView: onOpenChangedFiles, onOpen: onOpenArtifact, initiallyExpanded: true)
                        } else if !isTurnRunning && changed {
                            ChatChangedFilesSummaryView(files: gitChangedFiles, totalFileCount: gitChangedFileCount,
                                totalAdditions: gitChangedLineAdditions, totalDeletions: gitChangedLineDeletions, onView: onOpenChangedFiles)
                        }
                    }) : nil)
                    .padding(.leading, message.role == .system ? 38 : 0)
            }
        }

        private var showsTypingIndicator: Bool {
            guard isRunning else { return false }
            guard let last = messages.last else { return true }
            if last.role == .assistant, last.eventKind == .message, !last.text.isEmpty { return false }
            return true
        }

        private func scrollToLatest(
            using proxy: ScrollViewProxy,
            viewportHeight: CGFloat
        ) {
            guard followState.shouldAutoScrollOnContentChange, !scrollIsScheduled else { return }
            scrollIsScheduled = true
            // LazyVStack may still be committing a streamed delta or a shorter
            // final answer. Defer one runloop so the stable sentinel reflects
            // the latest layout before scrolling.
            DispatchQueue.main.async {
                scrollIsScheduled = false
                // The user may have scrolled up or selected history while this
                // layout callback was queued. Do not apply an old follow intent.
                guard followState.shouldAutoScrollOnContentChange else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                switch scrollDestination(viewportHeight: viewportHeight) {
                case .none:
                    break
                case .bottom:
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                case .itemTop(let id):
                    proxy.scrollTo(id, anchor: .top)
                }
                }
            }
        }
    }

    func activeGoalInlineCard(contentMaxWidth: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: activeGoalDetailsExpanded ? 7 : 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    activeGoalDetailsExpanded.toggle()
                }
            } label: {
                Group {
                    if activeGoalDetailsExpanded {
                        HStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(activeGoalCodexTint.opacity(0.12))
                                    .frame(width: 24, height: 24)
                                Image(systemName: "target")
                                    .font(.system(size: 10, weight: .black))
                                    .foregroundStyle(activeGoalCodexTint.opacity(0.82))
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 7) {
                                    Text(activeGoalCodexStatusText)
                                        .font(.system(size: 9, weight: .black, design: .rounded))
                                        .foregroundStyle(.secondary)
                                    if !model.isLive {
                                        activeGoalFlatMeta(model.activeGoalElapsedLabel, systemImage: "clock")
                                            .id(model.activeGoalClock)
                                    }
                                }
                                Text(model.activeGoalObjectiveLabel)
                                    .font(.caption.weight(.black))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: 8)
                            if !model.isLive {
                                activeGoalFlatMeta(model.activeGoalHeaderProgressLabel, systemImage: "checkmark.seal")
                                activeGoalStatusPill(model.activeGoalPaused ? "paused" : model.selectedWorkOSGoalStatusLabel)
                            }
                            if model.selectedThreadHasWorkOSGoal {
                                activeGoalControlButton(
                                    icon: model.activeGoalPaused ? "play.fill" : "pause.fill",
                                    tint: .orange,
                                    help: model.activeGoalPaused ? "續跑目標" : "暫停目標") {
                                        model.toggleActiveGoalPause()
                                    }
                                    .disabled(!model.canControlActiveGoal || (model.activeGoalPaused && !model.canResumeActiveGoal))
                                    .opacity(model.activeGoalPaused && !model.canResumeActiveGoal ? 0.45 : 1)
                                activeGoalControlButton(
                                    icon: model.canJudgeAndCompleteActiveGoal
                                        ? "checkmark"
                                        : "stop.fill",
                                    tint: model.canJudgeAndCompleteActiveGoal
                                        ? .green
                                        : .red,
                                    help: model.canJudgeAndCompleteActiveGoal
                                        ? "驗收並完成 Goal"
                                        : "結束目標") {
                                    model.endActiveGoal()
                                }
                                .disabled(!model.canControlActiveGoal)
                            }
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.black))
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                        }
                        .frame(minHeight: 34)
                    } else {
                        HStack(spacing: 7) {
                            Image(systemName: "target")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(activeGoalCodexTint.opacity(0.78))
                            Text(activeGoalCodexStatusText)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(activeGoalCodexTint.opacity(0.82))
                                .lineLimit(1)
                            Text("# \(model.activeGoalObjectiveLabel)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(model.activeGoalElapsedLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .id(model.activeGoalClock)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.black))
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                        }
                        .frame(height: 32)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if activeGoalDetailsExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider().opacity(0.28)
                    if !model.selectedRouteCooldownStatusText.isEmpty {
                        Label(
                            model.selectedRouteCooldownStatusText,
                            systemImage: "exclamationmark.octagon.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("模型路線暫停")
                    }
                    if model.isLive {
                        HStack {
                            Label(model.activeGoalHeaderProgressLabel, systemImage: "number")
                            Spacer(minLength: 8)
                            Label(model.activeGoalElapsedLabel, systemImage: "clock")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                    activeGoalProgressCluster
                    HStack(spacing: 7) {
                        chip(systemImage: "bolt.horizontal", text: model.activeWorkOSModeLabel)
                        chip(systemImage: "person.crop.circle.badge.checkmark", text: "Plan \(model.activeWorkOSLeadLabel)")
                        chip(systemImage: "arrow.triangle.2.circlepath", text: "Loops \(model.activeWorkOSLoopsLabel)")
                        Spacer(minLength: 0)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        activeGoalInfoColumn("Receipts", model.activeGoalHeaderProgressLabel)
                        activeGoalInfoColumn("Changed", "\(model.gitChangedFileCount) files")
                        activeGoalInfoColumn("Next", model.activeGoalNextActionLabel, lineLimit: 2)
                    }
                    }
                }
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, activeGoalDetailsExpanded ? 13 : 12)
        .padding(.vertical, activeGoalDetailsExpanded ? 9 : 0)
        .frame(maxWidth: contentMaxWidth ?? composerMaxWidth, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: ChatUILayout.panelRadius, style: .continuous)
                // fable5 深度改造：base 用不透明暖紙(去玻璃/blur)；aurora 維持 ultraThinMaterial。
                .fill(TatwoActivePalette.current.usesGlass
                    ? AnyShapeStyle(.ultraThinMaterial)
                    : AnyShapeStyle(TatwoActivePalette.current.surfaceFill))
                .overlay {
                    RoundedRectangle(cornerRadius: ChatUILayout.panelRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(activeGoalDetailsExpanded ? 0.150 : 0.115),
                                    activeGoalCodexTint.opacity(activeGoalDetailsExpanded ? 0.058 : 0.034),
                                    Color.white.opacity(0.082)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
        }
        .overlay(alignment: .top) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: ChatUILayout.panelRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(activeGoalDetailsExpanded ? 0.30 : 0.22),
                                activeGoalCodexTint.opacity(activeGoalDetailsExpanded ? 0.20 : 0.115),
                                Color.white.opacity(0.14)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1)
                if activeGoalDetailsExpanded && !model.isLive {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        activeGoalCodexTint,
                                        LiquidGlassTokens.accentViolet
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .opacity(LiquidGlassTokens.tintOpacity)
                            .frame(width: max(18, geometry.size.width * CGFloat(activeGoalProgressFraction)), height: 2)
                            .padding(.horizontal, 12)
                            .padding(.top, 1)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .overlay(alignment: .leading) {
            if activeGoalDetailsExpanded {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                activeGoalCodexTint,
                                LiquidGlassTokens.accentViolet
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(LiquidGlassTokens.tintOpacity)
                    .frame(width: 3)
                    .padding(.vertical, 12)
                    .padding(.leading, 2)
            }
        }
        .shadow(color: .black.opacity(activeGoalDetailsExpanded ? 0.050 : 0.026), radius: activeGoalDetailsExpanded ? 14 : 8, x: 0, y: activeGoalDetailsExpanded ? 8 : 4)
        .frame(maxWidth: .infinity, alignment: .center)
        .onAppear {
            model.startActiveGoalTimerIfNeeded()
        }
        .onDisappear {
            model.stopActiveGoalTimer()
        }
        .help(model.isLive ? "原生目標狀態；點開查看計量與控制。" : "目前討論串的目標。")
    }

    var activeGoalProgressFraction: Double {
        let progress = model.activeGoalStepProgress
        return Double(progress.current) / Double(max(progress.total, 1))
    }

    var activeGoalCodexStatusText: String {
        if model.isLive { return model.activeGoalStatusPresentationLabel }
        if !model.selectedRouteCooldownStatusText.isEmpty {
            return "模型路線暫停"
        }
        return model.activeGoalPaused
            ? "目標已暫停"
            : model.activeGoalStatusPresentationLabel
    }

    var activeGoalCodexTint: Color {
        if !model.selectedRouteCooldownStatusText.isEmpty {
            return .red
        }
        switch model.selectedWorkOSGoalStatusLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "human_gate", "paused", "blocked", "failed", "cancelled", "rollback_required":
            return .red
        case "dispatching", "running":
            return .orange
        default:
            return LiquidGlassTokens.brandAccent
        }
    }

    // 目標狀態列的暫停/結束小圓鈕（巢狀在展開 header 內；.plain 讓各自吃點擊）。
    func activeGoalControlButton(icon: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(tint.opacity(0.9))
                .frame(width: 20, height: 18)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    var activeGoalProgressCluster: some View {
        let progress = model.activeGoalStepProgress
        let names = ["Goal", "Plan", "Loops", "Receipts", "Close"]
        func align(_ index: Int) -> Alignment {
            index == 0 ? .leading : (index == progress.total - 1 ? .trailing : .center)
        }
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Spacer(minLength: 0)
                Label(model.activeGoalStepProgressLabel, systemImage: "checkmark.seal")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(LiquidGlassTokens.brandAccent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            // 圓點列與標籤列用「同一套全寬對齊」→ 每個點正對它的標籤，不再錯位看起來相反。
            HStack(spacing: 0) {
                ForEach(0..<progress.total, id: \.self) { index in
                    goalSpineDot(isDone: index + 1 < progress.current, isCurrent: index + 1 == progress.current)
                        .frame(maxWidth: .infinity, alignment: align(index))
                }
            }
            HStack(spacing: 0) {
                ForEach(0..<progress.total, id: \.self) { index in
                    Text(names.indices.contains(index) ? names[index] : "\(index + 1)")
                        .font(.system(size: 8, weight: index + 1 == progress.current ? .black : .semibold, design: .rounded))
                        .foregroundStyle(
                            index + 1 <= progress.current
                                ? LiquidGlassTokens.brandAccent
                                : Color.secondary.opacity(
                                    LiquidGlassTokens.nodeCardTintOpacity
                                )
                        )
                        .frame(maxWidth: .infinity, alignment: align(index))
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            LinearGradient(
                colors: [
                    LiquidGlassTokens.tint.opacity(LiquidGlassTokens.chipFillOpacity),
                    LiquidGlassTokens.accentViolet.opacity(LiquidGlassTokens.subtleFillOpacity),
                    LiquidGlassTokens.tint.opacity(LiquidGlassTokens.subtleFillOpacity)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.white.opacity(0.11), lineWidth: 1))
    }

    // 單一進度圓點（給全寬對齊的進度列用）。
    func goalSpineDot(isDone: Bool, isCurrent: Bool) -> some View {
        ZStack {
            Circle()
                .fill(
                    (isDone || isCurrent ? LiquidGlassTokens.brandAccent : LiquidGlassTokens.tint)
                        .opacity(isCurrent ? LiquidGlassTokens.tintOpacity : LiquidGlassTokens.chipFillOpacity)
                )
                .frame(width: isCurrent ? 16 : 13, height: isCurrent ? 16 : 13)
            Circle()
                .fill(
                    (isDone || isCurrent)
                        ? LiquidGlassTokens.brandAccent
                        : Color.secondary.opacity(LiquidGlassTokens.strokeOpacity)
                )
                .frame(width: isCurrent ? 7 : 5, height: isCurrent ? 7 : 5)
        }
    }

    func activeGoalFlatMeta(_ text: String, systemImage: String) -> some View {
        Label(text.isEmpty ? "—" : text, systemImage: systemImage)
            .font(.system(size: 9, weight: .black, design: .rounded))
            .lineLimit(1)
            .foregroundStyle(.secondary)
    }

    func activeGoalStatusPill(_ text: String) -> some View {
        Text(text.isEmpty ? "planned" : text)
            .font(.system(size: 9, weight: .black, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .chatGlassChip(isSelected: true)
    }

    func activeGoalInfoColumn(_ title: String, _ value: String, lineLimit: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .black, design: .rounded))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value.isEmpty ? "—" : value)
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(lineLimit)
                .truncationMode(title == "Contract" ? .middle : .tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.038), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.070), lineWidth: 1))
    }

}

/// 確認之前只顯示副本資訊，不覆寫文件。
struct ConversationRecoveryRow: View {
    #if DEBUG
    final class Probe {
        var button: CGRect?
        var confirming = false
    }
    var testProbe: Probe? = nil
    #endif
    let candidate: URL
    let isDisabled: Bool
    let restore: () -> Void
    @State private var showsConfirmation = false

    var body: some View {
        HStack(spacing: 8) {
            Button { showsConfirmation = true } label: {
                Text("還原對話紀錄").font(.caption).padding(.horizontal, 10).frame(height: 28).chatGlassChip()
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            #if DEBUG
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { testProbe?.button = $0 }
            .onChange(of: showsConfirmation) { testProbe?.confirming = $0 }
            #endif
            .alert("還原對話紀錄？", isPresented: $showsConfirmation) {
                Button("取消", role: .cancel) {}
                Button("先另存目前文件，再還原", action: restore)
            } message: {
                Text("會用這份副本取代目前的對話紀錄；還原前會先另存目前文件。")
            }
            Text("副本日期：" + ChatLiveStore.backupDate(candidate).formatted(date: .numeric, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
