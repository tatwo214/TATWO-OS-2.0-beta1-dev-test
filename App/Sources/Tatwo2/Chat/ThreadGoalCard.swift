// W170 Coder 分頁：輸入框上方的「工作列」＝這串的目標＋/plg 派出去的討論串，合成一張卡。
// 對照稿 https://claude.ai/artifact/9h72oKxJh8TuipBs8cc533；2026-09-22 使用者：造型保留、位置改到輸入框上方、和 PLG 那列合併。
// 收起來一行（●目前那條＋完成數・討論串幾個在跑），展開是整份清單：進行中、待驗收、待做、暫停、AI 提議、已完成，下面接討論串。
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
    @State private var showDone = false
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
        let groups: [(String, [ThreadGoal])] = [
            ("進行中", main.filter { $0.status == .active }),
            ("待驗收", main.filter { $0.status == .review }),
            ("待做", main.filter { $0.status == .pending }),
            ("暫停", main.filter { $0.status == .paused }),
        ]
        let proposals = list.goals.filter(\.proposed)
        let finished = main.filter { $0.status == .done }
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
                    ForEach(groups, id: \.0) { title, goals in
                        if !goals.isEmpty {
                            sectionTitle(title)
                            ForEach(goals) { goal in row(goal, list: list) }
                        }
                    }
                    if !proposals.isEmpty {
                        sectionTitle("AI 提議（你點頭才算）")
                        ForEach(proposals) { goal in proposalRow(goal) }
                    }
                    if !finished.isEmpty {
                        HStack {
                            sectionTitle("已完成 \(finished.count)")
                            Spacer()
                            OSChipButton(title: showDone ? "收起" : "展開") { showDone.toggle() }
                        }
                        if showDone { ForEach(finished) { goal in row(goal, list: list) } }
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
            return open.isEmpty ? nil : (sibling.id, sibling.title, open, ThreadGoalRules.progress(list))
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

    private func row(_ goal: ThreadGoal, list: ThreadGoalList) -> some View {
        let children = list.goals.filter { $0.parent == goal.id }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 8) {
                statusMark(goal)
                VStack(alignment: .leading, spacing: 2) {
                    if editingID == goal.id {
                        TextField("目標", text: $editText, onCommit: { save(goal) })
                            .textFieldStyle(.roundedBorder).font(.system(size: 12.5))
                    } else if let room = linkedRoom(goal) {
                        roomView([room], false)
                    } else {
                        Text("\(goal.id). \(goal.title)")
                            .font(.system(size: 12.5, weight: goal.status == .active ? .semibold : .regular))
                            .foregroundStyle(goal.status == .done ? .secondary : .primary)
                            .strikethrough(goal.status == .done, color: .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let words = goal.userWords, words != goal.title, goal.status != .done {
                        Text("你的原話：「\(words)」").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if let evidence = goal.evidence {
                        Text("證據：\(evidence)").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            ForEach(children) { child in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .center, spacing: 6) {
                        Text(ThreadGoalRules.symbol(child)).font(.system(size: 10)).foregroundStyle(.secondary)
                        if let room = linkedRoom(child) {
                            // 派出去的房間直接長在這條子目標上：狀態、看報告、停、開啟、⋯ 都在這一列。
                            roomView([room], false)
                        } else {
                            Text(child.title + (child.status == .review ? "（待驗收）" : "")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if let evidence = child.evidence {
                        Text("證據：\(evidence)").font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(2).textSelection(.enabled)
                            .padding(.leading, 16)
                    }
                }
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 7)
        .background(goal.status == .active ? LiquidGlassTokens.brandAccent.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contextMenu {
            if goal.status != .active { Button("設為進行中") { set(goal, .active) } }
            if goal.status != .done { Button("標為完成") { set(goal, .done) } }
            if goal.status != .paused { Button("暫停") { set(goal, .paused) } } else { Button("恢復為待做") { set(goal, .pending) } }
            Button("改文字") { editingID = goal.id; editText = goal.title }
            Divider()
            Button("刪除這一條", role: .destructive) { remove(goal) }
        }
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
            Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Color.green.opacity(0.75))
        case (_, .active):
            Circle().strokeBorder(LiquidGlassTokens.brandAccent, lineWidth: 2).overlay(Circle().fill(LiquidGlassTokens.brandAccent).padding(4)).frame(width: 14, height: 14)
        case (_, .review):
            Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.6, dash: [3, 2])).foregroundStyle(Color.orange).frame(width: 14, height: 14)
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
