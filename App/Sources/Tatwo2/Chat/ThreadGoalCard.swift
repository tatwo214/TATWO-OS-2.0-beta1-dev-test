// W170 Coder 分頁：輸入框上方的「工作列」＝這串的目標＋/plg 派出去的討論串，合成一張卡。
// 對照稿 https://claude.ai/artifact/9h72oKxJh8TuipBs8cc533；2026-09-22 使用者：造型保留、位置改到輸入框上方、和 PLG 那列合併。
// W252：先列主線，點主線展開 loops，點 loop 展開設備、分支與步驟。
// 左列專案與子討論串完全不動。
import SwiftUI

struct ThreadGoalCard: View {
    let threadID: UUID
    @Binding var expanded: Bool
    /// 同專案的其他討論串（專案總覽用）；點一條就跳過去。
    var siblings: [(id: UUID, title: String)] = []
    var onOpen: (UUID) -> Void = { _ in }
    /// /plg 派出去的討論串：一行摘要（例如「討論串・2 工作中」）與展開後的清單；沒有派工就是 nil。
    var roomsSummary: String? = nil
    var roomsRunning = false
    /// 這串派出去的全部房間；房間畫法交給派工卡（按鈕、報告、diff 照舊）。
    var roomIDs: [UUID] = []
    var roomView: (_ ids: [UUID], _ footer: Bool) -> AnyView = { _, _ in AnyView(EmptyView()) }
    var onHideRooms: (() -> Void)? = nil

    /// 綁在某條子目標上的房間（2026-09-22 使用者選：房間併進目標那一列，不重複列兩次）。
    private func linkedRoom(_ goal: ThreadGoal) -> UUID? {
        guard let raw = goal.roomThread, let id = UUID(uuidString: raw), roomIDs.contains(id) else { return nil }
        return id
    }
    @State private var showProject = false
    @ObservedObject private var store = ThreadGoalStore.shared
    @State private var openGoals: Set<Int> = []
    @State private var editingID: Int?
    @State private var editText = ""
    @State private var message: String?

    private var list: ThreadGoalList { _ = store.revision; return store.list(threadID) }

    var body: some View {
        let list = self.list
        if !list.goals.isEmpty || !roomIDs.isEmpty {
            let linked = Set(list.goals.compactMap(linkedRoom))
            VStack(alignment: .leading, spacing: 8) {
                header(list)
                if expanded {
                    if !list.goals.isEmpty { panel(list) }
                    if !roomIDs.isEmpty {
                        roomsSection(roomIDs.filter { !linked.contains($0) }, afterGoals: !list.goals.isEmpty)
                    }
                }
            }
            .padding(10)
            .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
        }
    }

    // MARK: 收起來的那一行

    private func header(_ list: ThreadGoalList) -> some View {
        let (done, total) = ThreadGoalRules.progress(list)
        let active = list.goals.first { $0.status == .active && $0.parent == nil && !$0.proposed }
        return Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
            HStack(spacing: 7) {
                if !list.goals.isEmpty {
                    Circle().fill(active == nil ? Color.secondary.opacity(0.4) : LiquidGlassTokens.brandAccent).frame(width: 7, height: 7)
                    Text(active.map { "\($0.id). \($0.title)" } ?? "這串的目標").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text("\(done)／\(total)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().layoutPriority(1)
                }
                if let roomsSummary {
                    if !list.goals.isEmpty { Text("・").font(.system(size: 11)).foregroundStyle(.tertiary) }
                    if roomsRunning { ProgressView().controlSize(.mini).accessibilityLabel("子討論串工作中") }
                    Text(roomsSummary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
                }
                Spacer(minLength: 6)
                Image(systemName: expanded ? "chevron.down" : "chevron.up").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(list.goals.isEmpty ? (roomsSummary ?? "") : "這串的目標，已完成 \(done) 條，共 \(total) 條")
    }

    /// 沒綁目標的房間集中在這裡；「全部停／合併報告」也在這裡（全部房間共用）。
    private func roomsSection(_ unlinked: [UUID], afterGoals: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if afterGoals { Divider().opacity(0.5) }
            HStack {
                sectionTitle(unlinked.isEmpty ? "派出去的工作" : "討論串（沒綁目標的工作）")
                Spacer()
                if let onHideRooms {
                    Button(action: onHideRooms) {
                        Image(systemName: "eye.slash").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("隱藏討論串列；輸入 /顯示討論串 叫回")
                    .accessibilityLabel("隱藏討論串列")
                    .accessibilityIdentifier("discussion-tray-hide")
                }
            }
            roomView(unlinked, true)
        }
    }

    // MARK: 清單

    private func panel(_ list: ThreadGoalList) -> some View {
        let (done, total) = ThreadGoalRules.progress(list)
        let main = list.goals.filter { !$0.proposed && $0.parent == nil }
        let proposals = list.goals.filter(\.proposed)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(showProject ? "整個專案" : "這串的目標").font(.system(size: 13, weight: .bold))
                Spacer()
                if siblings.count > 1 {
                    OSChipButton(title: showProject ? "這串" : "整個專案") { showProject.toggle() }
                }
                Text("\(done)／\(total) 完成").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(LiquidGlassTokens.brandAccent).frame(width: total == 0 ? 0 : proxy.size.width * CGFloat(done) / CGFloat(total))
                }
            }
            .frame(height: 4)
            if !showProject { CappedScroll(maxHeight: 300) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.ordered(main)) { goal in row(goal, list: list) }
                    if !proposals.isEmpty {
                        sectionTitle("AI 提議（你點頭才算）")
                        ForEach(proposals) { goal in proposalRow(goal) }
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } }
            if showProject { projectOverview }
            if let message { Text(message).font(.caption2).foregroundStyle(.secondary) }
            Text("用 /goal 加一條；新目標只會加在清單裡，不會蓋掉舊的。").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// 專案總覽：同專案每條討論串還沒完成的主線目標。
    private var projectOverview: some View {
        let rows = siblings.compactMap { sibling -> (UUID, String, [ThreadGoal], (Int, Int))? in
            let list = store.list(sibling.id)
            let open = list.goals.filter { $0.status != .done && !$0.proposed && $0.parent == nil }
            guard !open.isEmpty else { return nil }
            let progress = ThreadGoalRules.progress(list)
            return (sibling.id, sibling.title, open, (progress.done, progress.total))
        }
        return CappedScroll(maxHeight: 300) {
            VStack(alignment: .leading, spacing: 8) {
                if rows.isEmpty { Text("這個專案沒有未完成的目標。").font(.caption).foregroundStyle(.secondary) }
                ForEach(rows, id: \.0) { id, title, open, progress in
                    Button { onOpen(id); showProject = false } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Spacer()
                                Text("\(progress.0)／\(progress.1)").font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            ForEach(open.prefix(3)) { goal in
                                Text("\(ThreadGoalRules.symbol(goal)) \(goal.id). \(goal.title)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(id == threadID ? LiquidGlassTokens.brandAccent.opacity(0.08) : Color.primary.opacity(0.03),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).padding(.top, 4)
    }

    static func ordered(_ goals: [ThreadGoal]) -> [ThreadGoal] {
        let order: [ThreadGoal.Status] = [.active, .review, .pending, .paused, .done]
        return goals.sorted { a, b in
            let x = order.firstIndex(of: a.status)!, y = order.firstIndex(of: b.status)!
            return x == y ? a.id < b.id : x < y
        }
    }

    static func timeLabel(_ goal: ThreadGoal, now: Date = Date()) -> String {
        switch goal.status {
        case .active:
            if let eta = goal.etaAt {
                let minutes = Int(ceil(abs(eta.timeIntervalSince(now)) / 60))
                return eta >= now ? "剩 \(minutes) 分" : "超時 \(minutes) 分"
            }
            return "已跑 \(max(0, Int(now.timeIntervalSince(goal.startedAt ?? now) / 60))) 分"
        case .review: return "等你"
        case .pending: return "排隊"
        case .paused: return "暫停"
        case .done:
            let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"
            return formatter.string(from: goal.updatedAt)
        }
    }

    private func toggle(_ id: Int) {
        withAnimation(.easeOut(duration: 0.15)) {
            if openGoals.contains(id) { openGoals.remove(id) } else { openGoals.insert(id) }
        }
    }

    static func loopSummary(_ goal: ThreadGoal) -> String {
        if goal.status == .done { return "已完成，變暗" }
        let progress = goal.status == .active ? goal.progress.map { "\(Int(min(1, max(0, $0)) * 100))%，" } ?? "" : ""
        return progress + timeLabel(goal)
    }

    private func title(_ goal: ThreadGoal) -> some View {
        Group {
            if editingID == goal.id {
                TextField("目標", text: $editText, onCommit: { save(goal) }).textFieldStyle(.roundedBorder)
            } else {
                Text(goal.parent == nil ? "\(goal.id). \(goal.title)" : goal.title).lineLimit(1)
            }
        }
        .font(.system(size: goal.parent == nil ? LiquidGlassTokens.islandNoticeInfoFontSize : LiquidGlassTokens.islandNoticeDetailSize,
                      weight: goal.status == .active ? .semibold : .regular))
        .foregroundStyle(LiquidGlassTokens.browserOmniboxInk)
    }

    private func row(_ goal: ThreadGoal, list: ThreadGoalList) -> some View {
        let children = Self.ordered(list.goals.filter { $0.parent == goal.id && !$0.proposed })
        return VStack(alignment: .leading, spacing: LiquidGlassTokens.islandNoticeLineSpacing) {
            HStack(spacing: LiquidGlassTokens.islandNoticeButtonSpacing) {
                if editingID == goal.id { title(goal) }
                else {
                    Button { toggle(goal.id) } label: {
                        HStack(spacing: LiquidGlassTokens.islandNoticeButtonSpacing) {
                            statusMark(goal)
                            title(goal)
                            Spacer(minLength: LiquidGlassTokens.islandNoticeButtonSpacing)
                            Text("loops \(children.filter { $0.status == .done }.count)／\(children.count)")
                                .font(.system(size: LiquidGlassTokens.islandNoticeCountdownSize)).foregroundStyle(.secondary).monospacedDigit()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("goal.main.\(goal.id)")
                }
            }
            .opacity(goal.status == .done ? LiquidGlassTokens.routePulseOpacity : 1)
            if openGoals.contains(goal.id) {
                if let words = goal.userWords { detailText("你的原話：「\(words)」") }
                if let evidence = goal.evidence { detailText("證據：\(evidence)") }
                ForEach(children) { child in loopRow(child) }
            }
        }
        .padding(.vertical, LiquidGlassTokens.islandNoticeLineSpacing)
        .contextMenu { actions(goal) }
    }

    private func loopRow(_ child: ThreadGoal) -> some View {
        VStack(alignment: .leading, spacing: LiquidGlassTokens.islandNoticeLineSpacing) {
            if editingID == child.id { title(child) }
            else {
                Button { toggle(child.id) } label: {
                    HStack(spacing: LiquidGlassTokens.islandNoticeButtonSpacing) {
                        statusMark(child)
                        title(child)
                        Spacer(minLength: LiquidGlassTokens.islandNoticeButtonSpacing)
                        if child.status == .active, let progress = child.progress {
                            ZStack(alignment: .leading) {
                                Capsule().fill(LiquidGlassTokens.browserOmniboxInk.opacity(LiquidGlassTokens.chipFillOpacity))
                                Capsule().fill(LiquidGlassTokens.brandAccent).frame(width: 64 * min(1, max(0, progress)))
                            }.frame(width: 64, height: 3)
                                .accessibilityElement().accessibilityLabel("loop 進度")
                                .accessibilityValue("\(Int(min(1, max(0, progress)) * 100))%")
                                .accessibilityIdentifier("goal.progress.\(child.id)")
                        }
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(Self.timeLabel(child, now: context.date))
                                .font(.system(size: LiquidGlassTokens.islandNoticeCountdownSize)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("goal.loop.\(child.id)")
                    .accessibilityValue(Self.loopSummary(child))
            }
            if openGoals.contains(child.id) {
                let location = [child.device, child.branch].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !location.isEmpty { detailText(location).accessibilityIdentifier("goal.location.\(child.id)") }
                let steps = (child.doneSteps ?? []).map { "✓ " + $0 } + (child.queue ?? []).map { "○ " + $0 }
                if !steps.isEmpty { detailText(steps.joined(separator: "   ")).accessibilityIdentifier("goal.steps.\(child.id)") }
                if let evidence = child.evidence { detailText("證據：\(evidence)") }
                if let room = linkedRoom(child) {
                    roomView([room], false)
                }
            }
        }
        .padding(.vertical, LiquidGlassTokens.islandNoticeLineSpacing)
        .opacity(child.status == .done ? LiquidGlassTokens.routePulseOpacity : 1)
        .contextMenu { actions(child) }
    }

    private func detailText(_ text: String) -> some View {
        Text(text).font(.system(size: LiquidGlassTokens.islandNoticeCountdownSize))
            .foregroundStyle(LiquidGlassTokens.browserOmniboxMutedInk).textSelection(.enabled)
    }

    @ViewBuilder private func actions(_ goal: ThreadGoal) -> some View {
        if goal.status != .active { Button("設為進行中") { set(goal, .active) } }
        if goal.status != .done { Button("標為完成") { set(goal, .done) } }
        if goal.status != .paused { Button("暫停") { set(goal, .paused) } } else { Button("恢復為待做") { set(goal, .pending) } }
        Button("改文字") { editingID = goal.id; editText = goal.title }
        Divider()
        Button("刪除這一條", role: .destructive) { remove(goal) }
    }

    private func proposalRow(_ goal: ThreadGoal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                statusMark(goal)
                Text("\(goal.id). \(goal.title)").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Spacer()
                OSChipButton(title: "不要") { decide(goal, accept: false) }
                OSChipButton(title: "加入主線", isPrimary: true) { decide(goal, accept: true) }
            }
        }
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Color.secondary.opacity(0.4)))
    }

    @ViewBuilder
    private func statusMark(_ goal: ThreadGoal) -> some View {
        switch (goal.proposed, goal.status) {
        case (true, _):
            Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [2, 2])).foregroundStyle(Color.secondary).frame(width: 14, height: 14)
        case (_, .done):
            Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(LiquidGlassTokens.loopsPositive)
        case (_, .active):
            Circle().strokeBorder(LiquidGlassTokens.brandAccent, lineWidth: 2).overlay(Circle().fill(LiquidGlassTokens.brandAccent).padding(4)).frame(width: 14, height: 14)
        case (_, .review):
            Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.6, dash: [3, 2])).foregroundStyle(LiquidGlassTokens.loopsCaution).frame(width: 14, height: 14)
        case (_, .paused):
            Image(systemName: "pause.circle").font(.system(size: 14)).foregroundStyle(.secondary)
        default:
            Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.4).frame(width: 14, height: 14)
        }
    }

    // MARK: 動作（都以使用者身分）

    private func set(_ goal: ThreadGoal, _ status: ThreadGoal.Status) {
        run { try ThreadGoalRules.setStatus(&$0, id: goal.id, to: status, evidence: status == .done ? (goal.evidence ?? "使用者手動標記") : nil, actor: .user) }
    }
    private func decide(_ goal: ThreadGoal, accept: Bool) { run { try ThreadGoalRules.decideProposal(&$0, id: goal.id, accept: accept) } }
    private func remove(_ goal: ThreadGoal) { run { try ThreadGoalRules.edit(&$0, id: goal.id, title: nil, remove: true, actor: .user) } }
    private func save(_ goal: ThreadGoal) {
        run { try ThreadGoalRules.edit(&$0, id: goal.id, title: editText, remove: false, actor: .user) }
        editingID = nil
    }
    private func run(_ change: (inout ThreadGoalList) throws -> Void) {
        do { try store.update(threadID, change); message = nil } catch { message = "\(error)" }
    }
}

/// 內容多高就多高，超過上限才捲動（ScrollView 本身會撐滿可用高度，面板因此留一大片空白）。
private struct CappedScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content.background(GeometryReader { proxy in
                Color.clear.preference(key: CappedScrollHeight.self, value: proxy.size.height)
            })
        }
        .frame(height: min(max(height, 1), maxHeight))
        .onPreferenceChange(CappedScrollHeight.self) { height = $0 }
    }
}

private struct CappedScrollHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
