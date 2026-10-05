import SwiftUI

/// One assistant conversation, independent of the Coder selection and remote device.
/// W179 F：副設備連得到主設備時是主設備那條（同一段對話）；接不到主設備時一行說明（連線中不送；連不上、本機又全停用也不送）。
/// W182 R5／W201：自動接手與補回不在頁首報備。
/// W179 UI：輸入框、對話區跟 Coder 對齊（同一套元件、同一個欄寬）；連線中／連不上說明、送出失敗說明
/// 放在輸入框下方的狀態抽屜（同 Coder 的梯形抽屜，沒提醒時沒字），頁首只留「TATWO 助理」；主設備名在模型選單第一行。
struct AssistantSpacePane: View {
    private static let scrollSpaceName = "assistant-scroll"
    @ObservedObject var model: ChatPageModel
    /// W184 H4b：模式卡一開始就開著（自測畫卡片開著的樣子用；平常從 chip 開）。
    var modeCardOpen = false
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    @Environment(\.tatwoSurfaceKind) private var surface
    @State private var followState = ChatTranscriptScrollFollowState()
    @State private var composerFocused = false
    @State private var composerTextHeight = TatwoChatTranscriptVisualMetrics.windowComposerTextMinimumHeight
    /// W184 H4b：模式卡開著沒有（nil＝照 modeCardOpen）。
    @State private var modeOpenChoice: Bool?

    /// 對話與輸入框的欄寬：視窗模式下等於 Coder 的內容欄寬（最多 820、左右各留 18）。
    nonisolated static func columnWidth(paneWidth: CGFloat) -> CGFloat {
        min(ChatUILayout.chatColumnMaxWidth, max(320, paneWidth - 36))
    }

    var body: some View {
        GeometryReader { pane in
            let column = Self.columnWidth(paneWidth: pane.size.width)
            VStack(spacing: 12) {
                Label("TATWO 助理", systemImage: "sparkles")
                    .font(.headline)
                    .frame(width: column, alignment: .leading)
                    .frame(maxWidth: .infinity)
                transcript(column: column)
                composer(column: column)
            }
        }
        .onAppear { composerFocused = true }
    }

    // MARK: - 對話區（照 Coder：同一種訊息列、工作時間軸、打字中的點點）

    private func transcript(column: CGFloat) -> some View {
        let messages = model.assistantMessages
        let latestAssistantID = messages.last?.id
        let items = ChatTranscriptDisplayBuilder.build(messages)
        let hasActiveTimeline = items.contains { item in
            if case .workTimeline(let timeline) = item { return timeline.presentation.isActive }
            return false
        }
        let route = model.assistantRouteChoice
        // W180 D3：這串訊息屬於哪條（本機那條或主設備那條）；主設備那條這台放行不了，放行鈕換成一行說明。
        let threadID = model.assistantTranscriptThreadID
        let allowNote = model.mcpAllowBlockedNote(threadID: threadID)
        return GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: TatwoChatTranscriptVisualMetrics.messageSpacing) {
                        if model.assistantMessages.isEmpty, model.assistantTranscriptLoading {
                            // 主設備那條還在第一次拉：不顯示空白的歡迎畫面。
                            ProgressView("載入對話…")
                                .frame(width: column)
                                .padding(.vertical, 48)
                                .accessibilityIdentifier("tatwo-assistant-loading")
                        } else if messages.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "sparkles").font(.largeTitle)
                                Text("有什麼我可以幫你的？").font(.title3)
                                Text("我熟悉 TATWO OS 和你，幫你處理設定、設備、記憶和派工協調。")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: column)
                            .padding(.vertical, 48)
                        }
                        ForEach(items) { item in
                            switch item {
                            case .message(let message):
                                messageRow(message, width: column, route: route,
                                           isLatest: message.id == latestAssistantID,
                                           threadID: threadID, allowNote: allowNote)
                                    .frame(width: column, alignment: message.role == .user ? .trailing : .leading)
                            case .workTimeline(let timeline):
                                ChatInlineWorkTimelineView(timeline: timeline, assistantRoute: route, rowWidth: column)
                            case .planSummary:
                                EmptyView()
                            }
                        }
                        if showsTypingIndicator(messages) && !hasActiveTimeline {
                            ChatTypingIndicatorRow(route: route, rowWidth: column)
                        }
                        Color.clear.frame(height: 1).id("assistant-tail")
                            .background {
                                GeometryReader { tail in
                                    Color.clear.preference(key: AssistantBottomPreferenceKey.self,
                                        value: tail.frame(in: .named(Self.scrollSpaceName)).maxY)
                                }
                            }
                    }
                    .frame(width: column, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
                .coordinateSpace(name: Self.scrollSpaceName)
                .background(ChatTranscriptScrollIntentObserver { followState.detachFromLatest() })
                .onPreferenceChange(AssistantBottomPreferenceKey.self) {
                    followState.update(bottomY: $0, viewportHeight: geometry.size.height)
                }
                .onAppear { scrollToTail(proxy) }
                .onChange(of: model.assistantMessages.last?.text) { _, _ in
                    scrollToTail(proxy)
                }
                .onChange(of: model.assistantMessages.count) { _, _ in
                    scrollToTail(proxy)
                }
                .onChange(of: geometry.size.width) { _, _ in scrollToTail(proxy) }
                .overlay(alignment: .bottom) {
                    if followState.showsJumpToLatest {
                        AssistantJumpToLatestButton {
                            followState.jumpToLatest()
                            scrollToTail(proxy)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.16), value: followState.showsJumpToLatest)
            }
        }
    }

    /// 同 Coder：回覆中、最後一則還沒有文字時顯示打字中的點點。
    private func showsTypingIndicator(_ messages: [ChatMessage]) -> Bool {
        guard model.assistantIsRunning else { return false }
        guard let last = messages.last else { return true }
        if last.role == .assistant, last.eventKind == .message, !last.text.isEmpty { return false }
        return true
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage, width: CGFloat, route: ChatRouteChoice, isLatest: Bool,
                            threadID: UUID?, allowNote: String?) -> some View {
        if let error = ChatErrorCardPresentation.resolve(message) {
            ChatErrorCard(presentation: error, rowWidth: width, canRetry: false, onRetry: {})
        } else if let note = ChatSystemNotePresentation.resolve(message) {
            ChatSystemNoteRow(presentation: note, rowWidth: width)
        } else {
            ChatBubble(message: message, threadID: threadID, mcpAllowBlockedNote: allowNote, assistantRoute: route,
                rowWidth: width, assistantTranscriptCache: model.assistantTranscriptCache,
                planArtifact: nil, isLatestAssistantMessage: isLatest,
                initialPlanQuestionFocusClaimed: true, onInitialPlanQuestionFocusClaimed: {},
                planInspectorPresented: .constant(false))
        }
    }

    // MARK: - 輸入框（同 Coder 的結構：文字元件、玻璃卡、工具列、送出／停止鈕、下方狀態抽屜）

    private func composer(column: CGFloat) -> some View {
        let minH = surface == .window
            ? TatwoChatTranscriptVisualMetrics.windowComposerTextMinimumHeight
            : TatwoChatTranscriptVisualMetrics.panelComposerTextMinimumHeight
        let maxH = surface == .window
            ? TatwoChatTranscriptVisualMetrics.windowComposerTextMaximumHeight
            : TatwoChatTranscriptVisualMetrics.panelComposerTextMaximumHeight
        let compact = column < 720
        let trimmedEmpty = model.assistantPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let status = AssistantComposerStatus.resolve(hint: model.assistantPrimaryHint,
                                                     // W182 R5／W201：自動接手安靜；送不到的新一句只在輸入框位置說明
                                                     placementNote: model.assistantPlacementNote,
                                                     isConnecting: isConnecting,
                                                     isDelivering: model.assistantIsDelivering,
                                                     isRunning: model.assistantIsRunning)
        // 外層間距要是 8：抽屜 -13 往上塞，扣掉這 8 只被輸入框蓋住 5pt（同 Coder）。
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                ChatComposerTextView(text: $model.assistantPrompt, contentHeight: $composerTextHeight,
                                     isFocused: composerFocused, placeholder: "傳訊息給 TATWO 助理",
                                     isMonospaced: false, minimumHeight: minH, maximumHeight: maxH,
                                     onSubmit: submit, onFocusChange: { composerFocused = $0 },
                                     accessibilityTextLabel: "TATWO 助理訊息", slashCommands: [])
                    .accessibilityIdentifier("tatwo-assistant-input")
                    .frame(height: min(maxH, max(minH, composerTextHeight)))
                    .padding(.horizontal, 20)
                    .padding(.top, 15)
                    .padding(.bottom, 8)
                ChatComposerToolbarRow(compact: compact) {
                    Spacer(minLength: compact ? 8 : 14)
                    // W184 H4b：記憶（W180 E1）、模型收進一顆「模式選擇」chip（同 Coder 輸入框的那一顆）；按了在輸入框上方開模式卡
                    // （TatwoComposerMode.assistantSpace；舊識別碼 tatwo-assistant-model、tatwo-memory-strength 在 chip 的兩段上）。
                    AssistantSpaceModeChip(model: model, isOpen: modeOpen)
                    // 回覆中不收下一句（同一條助理串一次一輪），所以一律顯示停止鈕。
                    if model.assistantIsRunning {
                        ChatComposerStopButton(action: model.stopAssistant)
                            .accessibilityLabel("停止")
                            .accessibilityIdentifier("tatwo-assistant-stop")
                    } else {
                        ChatComposerSendButton(enabled: model.assistantCanSend && !trimmedEmpty) { submit() }
                            .help("送出")
                            .accessibilityLabel("送出")
                            .accessibilityIdentifier("tatwo-assistant-send")
                    }
                }
                .padding(.horizontal, 11)
                .padding(.bottom, 8)
            }
            .frame(minHeight: surface == .window
                ? TatwoChatTranscriptVisualMetrics.windowComposerMinimumHeight
                : TatwoChatTranscriptVisualMetrics.panelComposerMinimumHeight)
            .liquidGlassPanelSurface(cornerRadius: LiquidGlassTokens.radiusPrimary)
            .globalDMComposerFrame(.tatwo, active: surface == .window)
            // W184 H4b：模式卡浮在整個輸入框上方 8、右緣對齊輸入框；點卡以外的地方收起（同私訊框、Coder 的掛法）。
            .tatwoComposerModeCard(isPresented: modeOpen) { AssistantSpaceModeCard(model: model) }
            ChatComposerStatusDrawer(text: status.text, tone: status.tone)
                .accessibilityIdentifier(status.identifier)
                .zIndex(-1)
                .padding(.top, -13)
        }
        .frame(width: column)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 18)
    }

    /// 正在連主設備（連上就能說話）：抽屜顯示進行中，不是警告。
    private var isConnecting: Bool {
        if case .unreachable(_, .connecting) = model.assistantPlacement { return true }
        return false
    }

    /// W184 H4b：模式卡的開關（chip 在工具列、卡掛在整個輸入框上，兩邊接同一個）。
    private var modeOpen: Binding<Bool> {
        Binding(get: { modeOpenChoice ?? modeCardOpen }, set: { modeOpenChoice = $0 })
    }

    private func submit() {
        guard !model.assistantIsRunning, model.assistantCanSend,
              !model.assistantPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        followState.jumpToLatest()
        model.sendAssistantDraft()
    }

    private func scrollToTail(_ proxy: ScrollViewProxy) {
        guard followState.shouldAutoScrollOnContentChange else { return }
        DispatchQueue.main.async {
            if followState.shouldAutoScrollOnContentChange { proxy.scrollTo("assistant-tail", anchor: .bottom) }
        }
    }
}

/// 「跳至最新」：同 Coder 對話區底部那顆。
private struct AssistantJumpToLatestButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("跳至最新", systemImage: "arrow.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .tatwoAdaptiveCapsule(material: .regularMaterial)
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
        .padding(.bottom, 10)
        .accessibilityLabel("跳至最新訊息")
    }
}

private struct AssistantBottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// W184 H4b：助理頁的「模式選擇」chip（模型＋速度／推理強度、記憶的摘要；TatwoComposerMode.assistantSpace）。
/// 看 model 與別台記憶的暫存（接主設備時選了還沒送到的值），值一變摘要就跟著變（同原本記憶 chip 看的東西）。
private struct AssistantSpaceModeChip: View {
    @ObservedObject var model: ChatPageModel
    @ObservedObject private var pending = TatwoMemoryStrengthPending.shared
    @Binding var isOpen: Bool

    var body: some View {
        let mode = TatwoComposerMode.assistantSpace(model: model)
        ChatComposerModeChip(segments: mode.segments, selected: isOpen, help: mode.help) {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) { isOpen.toggle() }
        }
        .layoutPriority(1)
    }
}

/// 助理頁的模式卡（ULTRAWORK 卡擴充，主視窗尺寸）；同樣看 model 與記憶暫存。
private struct AssistantSpaceModeCard: View {
    @ObservedObject var model: ChatPageModel
    @ObservedObject private var pending = TatwoMemoryStrengthPending.shared

    var body: some View {
        TatwoComposerModeCard(mode: TatwoComposerMode.assistantSpace(model: model), metrics: .main)
    }
}
