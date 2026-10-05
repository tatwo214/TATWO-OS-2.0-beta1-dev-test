import SwiftUI

// W180 E3b：專案地圖上的「請助理整理分類」、「分類建議」、「最近搬移」。
// 助理只提議；搬不搬由使用者在這裡按（卡片內玻璃確認列，不跳系統框）。搬移只改對話屬於哪個專案，不動資料夾。
// 本機的建議直接照這台的文件做；主設備上的建議（副設備看）只送提案 id＋決定，主設備自己搬。

/// 頂端一顆玻璃 chip：切回 TATWO 對話，送一句固定的請求給助理（送不出去就放進草稿，不蓋掉你打到一半的字）。
@MainActor
enum AssistantClassificationActions {
    @discardableResult
    static func askAssistant(model: ChatPageModel) -> Bool {
        AssistantSpaceTabStore.shared.returnToConversation()
        let text = ProjectClassification.assistantRequest
        let sent = model.sendToAssistant(text: text)
        if !sent, model.assistantPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.assistantPrompt = text
        }
        return sent
    }
}

struct AssistantClassificationChip: View {
    @ObservedObject var model: ChatPageModel

    var body: some View {
        OSChipButton(title: "請助理整理分類", systemImage: "sparkles") {
            AssistantClassificationActions.askAssistant(model: model)
        }
        .help("切到 TATWO 對話，請助理看看哪些對話該歸到哪個專案；助理只會提議，你核准才搬")
        .accessibilityIdentifier("tatwo-classify-ask")
    }
}

/// 本機的提案與搬移紀錄（小檔案，存檔一改就重讀）；副設備的決定在背景送給主設備。
@MainActor
final class ProjectClassificationBoard: ObservableObject {
    static let shared = ProjectClassificationBoard()

    enum Action: String, Sendable { case approve, reject, undo }

    enum RemoteResult: Equatable, Sendable {
        case done(String)
        case failed(code: String, reasons: [String])
    }

    @Published private(set) var proposals: [ProjectProposal] = []
    @Published private(set) var moves: [ProjectMoveRecord] = []
    @Published private(set) var busy: Set<UUID> = []
    @Published var message: String?
    private var root: URL?
    private var viewers = 0
    private var observer: NSObjectProtocol?

    func start(model: ChatPageModel) {
        root = model.localLiveForBridge?.store.url.deletingLastPathComponent()
        viewers += 1
        if viewers == 1 {
            observer = NotificationCenter.default.addObserver(
                forName: ProjectClassificationStore.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
        reload()
    }

    func stop() {
        viewers = max(0, viewers - 1)
        guard viewers == 0, let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
    }

    var isWatching: Bool { observer != nil }

    func reload() {
        guard let root else { return }
        let store = ProjectClassificationStore(root: root)
        let nextProposals = store.proposals(), nextMoves = store.moves()
        if nextProposals != proposals { proposals = nextProposals }
        if nextMoves != moves { moves = nextMoves }
    }

    /// 本機這一份：照這台現在的文件算（在跑的、目標不在了，都寫在卡片上）。
    func localCards(model: ChatPageModel) -> [ProjectProposalCard] {
        guard let live = model.localLiveForBridge else { return [] }
        return ProjectClassification.cards(proposals: proposals, moves: moves, doc: live.doc,
                                           running: ProjectClassification.running(live))
    }

    func decideLocal(model: ChatPageModel, id: UUID, action: Action) {
        guard let engine = model.localLiveForBridge else { return }
        do {
            switch action {
            case .approve:
                let record = try ProjectClassification.approve(id, engine: engine)
                message = "已搬好 \(record.entries.count) 條（含子討論串）。要反悔可以在「最近搬移」按復原。"
            case .reject:
                try ProjectClassification.reject(id, engine: engine)
                message = "好，這則建議不採用。"
            case .undo:
                let record = try ProjectClassification.undo(id, engine: engine)
                let later = record.laterEntries?.count ?? 0
                message = "已搬回原本的專案" + (later > 0 ? "（含後來開的 \(later) 條子討論串）" : "")
                    + (record.archivedProjects.isEmpty ? "。" : "；新建的專案變空了，已封存（沒有刪）。")
            }
        } catch let error as ProjectClassificationError {
            message = ProjectClassification.userMessage(code: error.code, reasons: error.reasons)
        } catch {
            message = "存檔失敗，沒有改任何東西。"
        }
        reload()
    }

    func decideRemote(model: ChatPageModel, deviceID: String, name: String, id: UUID, action: Action, summary: String = "") {
        guard let link = model.remoteSessions.first(where: { $0.device.id == deviceID && $0.engine != nil })?.link else {
            // W182 R5：主設備離線：先排隊，連回後自動送（主設備自己照提案搬）；其他設備照舊請你連上再試。
            if deviceID.lowercased() == model.assistantPrimaryDevice?.id.lowercased(),
               model.primaryOutbox?.enqueueClassification(deviceID: deviceID, id: id, action: action.rawValue, summary: summary) != nil {
                message = nil // W201：已排入的事安靜處理；項目自己的取消列照舊。
            } else {
                message = "\(name) 現在連不上，連上後再試。"
            }
            return
        }
        guard busy.insert(id).inserted else { return }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Self.sendDecision(link: link, id: id, action: action) }.value
            guard let self else { return }
            self.busy.remove(id)
            switch result {
            case .done:
                self.message = action == .approve ? "\(name) 已搬好。要反悔可以在「最近搬移」按復原。"
                    : action == .reject ? "好，這則建議不採用。" : "\(name) 已搬回原本的專案。"
            case .failed(let code, let reasons):
                self.message = ProjectClassification.userMessage(code: code, reasons: reasons, remoteName: name)
            }
            await AssistantOverviewReader.shared.refreshRemoteNow()
        }
    }

    /// 背景：RemoteHostLink.call 會等 SSH，主執行緒一律不准走。只送提案 id＋決定，搬移由主設備照提案做。
    nonisolated static func sendDecision(link: RemoteHostLink, id: UUID, action: Action) -> RemoteResult {
        dispatchPrecondition(condition: .notOnQueue(.main))
        do {
            let reply = try link.call(method: "project_proposal_decide", params: ["id": id.uuidString, "action": action.rawValue])
            return .done(reply["status"] as? String ?? action.rawValue)
        } catch RemoteHostLinkError.remoteError(let text) {
            return parseRemoteError(text)
        } catch {
            return .failed(code: "transport", reasons: [])
        }
    }

    /// 主設備回的錯誤是「代碼: 原因；原因」。
    nonisolated static func parseRemoteError(_ text: String) -> RemoteResult {
        guard let range = text.range(of: ": ") else { return .failed(code: text, reasons: []) }
        let reasons = text[range.upperBound...].split(separator: "；").map { String($0.prefix(300)) }
        return .failed(code: String(text[..<range.lowerBound]), reasons: Array(reasons.prefix(20)))
    }
}

/// 「分類建議」與「最近搬移」兩節（專案地圖頂端 chip 下方）。
struct AssistantClassificationSection: View {
    @ObservedObject var model: ChatPageModel
    @ObservedObject private var board = ProjectClassificationBoard.shared
    @ObservedObject private var reader = AssistantOverviewReader.shared
    @State private var confirming: Confirm?
    /// W182 R5：佇列一變就重畫（排隊中／沒送成那一行）。
    @State private var outboxRevision = 0

    private struct Confirm: Equatable {
        var key: String
        var action: ProjectClassificationBoard.Action
    }

    /// 建議從哪一台來：這台，或某一台遠端（通常是主設備）。
    private struct Source: Equatable {
        var deviceID: String
        var name: String
        var isThisDevice: Bool
        /// W182 R5：主設備離線，列的是上次看到的建議（按了先排隊）。
        var offline = false
    }

    private struct ProposalGroup: Identifiable {
        var source: Source
        var cards: [ProjectProposalCard]
        var id: String { source.deviceID }
    }

    private struct Entry: Identifiable {
        var source: Source
        var card: ProjectProposalCard
        var id: String { source.deviceID + "|" + card.id.uuidString }
    }

    var body: some View {
        let groups = self.groups
        let pending = groups.flatMap { group in group.cards.filter(\.isPending).map { Entry(source: group.source, card: $0) } }
        let moved = groups.flatMap { group in group.cards.filter { $0.movedAt != nil }.map { Entry(source: group.source, card: $0) } }
        VStack(alignment: .leading, spacing: 10) {
            if let message = board.message {
                Text(message)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tatwo-classify-message")
            }
            Text("分類建議").font(.system(size: 13, weight: .semibold))
            if pending.isEmpty {
                Text("還沒有建議。按「請助理整理分類」，助理看完會把建議放在這裡。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tatwo-classify-empty")
            }
            ForEach(pending) { entry in
                proposalCard(entry.card, source: entry.source, showsDevice: groups.count > 1 || !entry.source.isThisDevice)
            }
            if !moved.isEmpty {
                Text("最近搬移").font(.system(size: 13, weight: .semibold)).padding(.top, 4)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(moved) { entry in
                        if entry.id != moved.first?.id { Divider() }
                        moveRow(entry.card, source: entry.source, showsDevice: groups.count > 1 || !entry.source.isThisDevice)
                    }
                }
                .padding(.horizontal, 12)
                .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
                .accessibilityIdentifier("tatwo-classify-moves")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("tatwo-classify-section")
        .onAppear { board.start(model: model) }
        .onDisappear { board.stop() }
        .onReceive(NotificationCenter.default.publisher(for: PrimaryOutbox.didChange)) { _ in outboxRevision += 1 }   // W182 R5
    }

    /// 這台的一組，加上每一台在線、有回分類建議的遠端（主設備在前）。
    private var groups: [ProposalGroup] {
        var result: [ProposalGroup] = []
        let local = board.localCards(model: model)
        if !local.isEmpty {
            let id = reader.map.devices.first(where: \.isThisDevice)?.id ?? "local"
            result.append(ProposalGroup(source: Source(deviceID: id, name: "這台", isThisDevice: true), cards: local))
        }
        let primaryID = model.assistantPrimaryDevice?.id
        let remotes = model.remoteSessions.filter { $0.engine != nil }
            .sorted { ($0.device.id == primaryID ? 0 : 1) < ($1.device.id == primaryID ? 0 : 1) }
        for session in remotes {
            guard let cards = reader.remoteProposals[session.device.id], !cards.isEmpty else { continue }
            result.append(ProposalGroup(source: Source(deviceID: session.device.id, name: session.device.name, isThisDevice: false),
                                cards: cards))
        }
        // W182 R5：主設備離線時照樣列出上次看到的建議（按了先排隊，連回後自動送）。
        if let primary = model.assistantPrimaryDevice, !result.contains(where: { $0.source.deviceID == primary.id }),
           model.remoteSessions.contains(where: { $0.device.id == primary.id && $0.engine == nil }),
           let cards = reader.remoteProposals[primary.id], !cards.isEmpty {
            result.append(ProposalGroup(source: Source(deviceID: primary.id, name: primary.displayName, isThisDevice: false,
                                                       offline: true), cards: cards))
        }
        return result
    }

    /// W182 R5：這則建議在佇列裡的那筆（排隊中或主設備說不能做）；這台的建議沒有。
    private func queued(_ card: ProjectProposalCard, source: Source) -> PrimaryOutboxItem? {
        _ = outboxRevision
        guard !source.isThisDevice else { return nil }
        return model.primaryOutbox?.item(.classifyDecide, key: "id", value: card.id.uuidString)
    }

    /// 排隊中（可以取消）或沒送成（寫原因，可以移除）。
    @ViewBuilder private func queuedRow(_ item: PrimaryOutboxItem, source: Source) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.refused == true ? "exclamationmark.circle" : "clock")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(item.refused == true ? "沒送成：\(item.reason ?? "")"
                 : item.state == .sending ? "送出中…" : "等送出")
                .font(.caption).foregroundStyle(item.refused == true ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            OSChipButton(title: item.refused == true ? "移除" : "取消") { model.primaryOutbox?.cancel(item.id) }
                .disabled(item.state == .sending)
                .accessibilityIdentifier("tatwo-classify-queued-cancel")
        }
        .accessibilityIdentifier("tatwo-classify-queued")
    }

    private var now: Date { reader.refreshedAt ?? Date() }

    // MARK: - 分類建議

    private func proposalCard(_ card: ProjectProposalCard, source: Source, showsDevice: Bool) -> some View {
        let key = source.deviceID + "|" + card.id.uuidString
        let isBusy = board.busy.contains(card.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("助理的建議・" + OverviewText.relative(card.createdAt, now: now))
                    .font(.caption).foregroundStyle(.secondary)
                if showsDevice { tag(source.isThisDevice ? "這台" : source.offline ? "在 \(source.name)（離線）" : "在 \(source.name)") }
                Spacer(minLength: 0)
                if isBusy { ProgressView().controlSize(.small) }
            }
            ForEach(Array(card.items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: item.isNewProject ? "folder.badge.plus" : "arrow.right.circle")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(item.isNewProject ? "新專案：\(item.targetName)" : item.targetName)
                            .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    }
                    Text(item.reason)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(item.threads) { thread in
                        threadRow(thread, source: source)
                    }
                }
            }
            ForEach(card.blocked, id: \.self) { reason in
                Label(reason, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(ProjectClassification.ruleLine)
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let queuedItem = queued(card, source: source) {   // W182 R5
                queuedRow(queuedItem, source: source)
            } else if confirming == Confirm(key: key, action: .approve) {
                confirmRow(question: "把這 \(card.threadCount) 條對話搬到\(card.targetSummary)？",
                           detail: "子討論串會一起搬；只改對話屬於哪個專案，不動任何資料夾。之後可以在「最近搬移」復原。",
                           confirmTitle: "搬移") {
                    decide(card, source: source, action: .approve)
                }
            } else {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    OSChipButton(title: "不要") { decide(card, source: source, action: .reject) }
                        .accessibilityIdentifier("tatwo-classify-reject")
                    OSChipButton(title: "核准搬移", systemImage: "checkmark", isPrimary: true) {
                        confirming = Confirm(key: key, action: .approve)
                    }
                    .disabled(!card.blocked.isEmpty)
                    .accessibilityIdentifier("tatwo-classify-approve")
                }
                .disabled(isBusy)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo-classify-card")
    }

    private func threadRow(_ thread: ProjectProposalCard.Thread, source: Source) -> some View {
        Button {
            AssistantOverviewNavigation.open(model: model, deviceID: source.deviceID,
                                             isThisDevice: source.isThisDevice, threadID: thread.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left").font(.system(size: 10)).foregroundStyle(.tertiary)
                Text(thread.title).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3).padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chatMenuRowHover()
        .help("在 Coder 打開")
    }

    // MARK: - 最近搬移

    private func moveRow(_ card: ProjectProposalCard, source: Source, showsDevice: Bool) -> some View {
        let key = source.deviceID + "|" + card.id.uuidString
        let isBusy = board.busy.contains(card.id)
        var when = card.movedAt.map { "搬於 " + OverviewText.relative($0, now: now) } ?? ""
        if let undone = card.undoneAt { when += "・已復原（" + OverviewText.relative(undone, now: now) + "）" }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(card.threadCount) 條 → \(card.targetSummary)")
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(when).font(.caption).foregroundStyle(.secondary)
                }
                if showsDevice { tag(source.isThisDevice ? "這台" : source.offline ? "在 \(source.name)（離線）" : "在 \(source.name)") }
                Spacer(minLength: 8)
                if isBusy { ProgressView().controlSize(.small) }
                if card.canUndo, confirming != Confirm(key: key, action: .undo), queued(card, source: source) == nil {
                    OSChipButton(title: "復原", systemImage: "arrow.uturn.backward") {
                        confirming = Confirm(key: key, action: .undo)
                    }
                    .disabled(isBusy)
                    .accessibilityIdentifier("tatwo-classify-undo")
                }
            }
            if let queuedItem = queued(card, source: source) { queuedRow(queuedItem, source: source) }   // W182 R5
            if card.undoneAt == nil {
                ForEach(card.blocked, id: \.self) { reason in
                    Label(reason, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if confirming == Confirm(key: key, action: .undo) {
                confirmRow(question: "把這 \(card.threadCount) 條搬回原本的專案？",
                           detail: "後來在底下開的子討論串會一起搬回；這次新建的專案如果變空會封存，不刪。",
                           confirmTitle: "復原") {
                    decide(card, source: source, action: .undo)
                }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - 共用

    /// W179 UI 記憶卡的做法：問句＋說明＋取消／確定兩顆玻璃 chip，在卡片裡，不跳系統確認框。
    private func confirmRow(question: String, detail: String, confirmTitle: String,
                            onConfirm: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                OSChipButton(title: "取消") { confirming = nil }
                OSChipButton(title: confirmTitle) {
                    confirming = nil
                    onConfirm()
                }
                .accessibilityIdentifier("tatwo-classify-confirm")
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatLiquidSection(cornerRadius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo-classify-confirm-row")
    }

    private func decide(_ card: ProjectProposalCard, source: Source, action: ProjectClassificationBoard.Action) {
        if source.isThisDevice {
            board.decideLocal(model: model, id: card.id, action: action)
        } else {
            board.decideRemote(model: model, deviceID: source.deviceID, name: source.name, id: card.id, action: action,
                               summary: "\(card.threadCount) 條 → \(card.targetSummary)")   // W182 R5：排隊清單上那一行
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .chatGlassChip()
    }
}
