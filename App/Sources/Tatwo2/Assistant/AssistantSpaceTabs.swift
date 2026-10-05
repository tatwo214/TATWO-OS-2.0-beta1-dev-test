import SwiftUI

/// W180 E2：TATWO Space 的分頁（側欄一格＝一頁）。團隊之後再做，先點不了。
/// 側欄（AssistantSidebarList）與頁首 chip 都由 allCases＋stageNote 產生，只有這一份。
/// W180 E1：記憶頁接上了（stageNote 是 nil、host 的 memory 分支是 TatwoMemoryPage）。
enum AssistantSpaceTab: String, CaseIterable, Identifiable, Sendable {
    case conversation, memory, status, projectMap, team

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conversation: "對話"
        case .memory: "記憶"
        case .status: "全域狀態"
        case .projectMap: "專案地圖"
        case .team: "團隊"
        }
    }

    var symbol: String {
        switch self {
        case .conversation: "bubble.left.and.bubble.right"
        case .memory: "brain"
        case .status: "chart.bar"
        case .projectMap: "map"
        case .team: "person.2"
        }
    }

    /// 還沒開的分頁在側欄右邊寫的小字；nil＝可以點。
    var stageNote: String? {
        switch self {
        case .team: "之後"
        case .conversation, .memory, .status, .projectMap: nil
        }
    }

    var isSelectable: Bool { stageNote == nil }
}

/// 選中的分頁只放在這裡，不寫進 ChatPageModel（換分頁不動 Coder 的選取、草稿與模式）。
@MainActor
final class AssistantSpaceTabStore: ObservableObject {
    static let shared = AssistantSpaceTabStore()

    @Published private(set) var selected: AssistantSpaceTab = .conversation
    /// W180 E1：「用了 N 條記憶」按「打開」時要捲到的那一條（記憶頁看到就清掉）。
    @Published var memoryFocusID: String?
    /// W180 E1：「打開」會切到 TATWO（切 Space 時會回對話分頁）；這之前的兩秒內不回對話，停在記憶頁。
    private var memoryHoldUntil: Date?

    /// 還沒開的分頁（團隊）點了不動。
    func select(_ tab: AssistantSpaceTab) {
        guard tab.isSelectable, selected != tab else { return }
        selected = tab
    }

    func returnToConversation() {
        if selected == .memory, let hold = memoryHoldUntil, hold > Date() { return }   // W180 E1
        if selected != .conversation { selected = .conversation }
    }

    /// W180 E1：切到記憶頁並捲到那一條。
    func openMemory(focus id: String?) {
        memoryFocusID = id
        memoryHoldUntil = Date().addingTimeInterval(2)
        selected = .memory
    }

    /// mode 每被指定一次就叫一次（包括已經在 TATWO、又被 selectLocalThread／selectRemote 導到助理那條）。
    func modeAssigned(_ mode: ChatRunMode) {
        if mode == .tatwo { returnToConversation() }
    }

    /// Coder 選到的討論串變成助理那條時，也回到對話。
    func selectedThreadChanged(_ threadID: UUID?, assistantThreadID: UUID?) {
        guard let threadID, threadID == assistantThreadID else { return }
        returnToConversation()
    }
}

/// TATWO 主畫面：依選中的分頁換頁。對話頁由外面傳進來（原本的 AssistantSpacePane），其他頁在這裡建。
/// 側欄收起（或面板模式沒有側欄）時，頁首多一排分頁 chip，跟側欄同一組、同一個順序。
struct AssistantSpaceTabHost<Conversation: View>: View {
    @ObservedObject private var model: ChatPageModel
    @ObservedObject private var tabs = AssistantSpaceTabStore.shared
    private let showsTabChips: Bool
    private let conversation: () -> Conversation

    init(model: ChatPageModel, showsTabChips: Bool, @ViewBuilder conversation: @escaping () -> Conversation) {
        _model = ObservedObject(wrappedValue: model)
        self.showsTabChips = showsTabChips
        self.conversation = conversation
    }

    var body: some View {
        VStack(spacing: 8) {
            if showsTabChips {
                AssistantSpaceTabChips(tabs: tabs)
            }
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 從別的 Space 切回 TATWO（這個 host 只在 TATWO 模式存在，所以每次切回來都會重新出現）。
        .onAppear { tabs.returnToConversation() }
        // 已經在 TATWO、又從別處打開助理那條（ChatPageModel 會再指定一次 mode = .tatwo）。
        .onReceive(model.$mode.dropFirst()) { tabs.modeAssigned($0) }
        .onChange(of: model.selectedThreadID) { _, threadID in
            tabs.selectedThreadChanged(threadID, assistantThreadID: model.assistantThreadID)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch tabs.selected {
        case .conversation:
            conversation()
        case .status:
            AssistantStatusPage(model: model)
        case .projectMap:
            AssistantProjectMapPage(model: model)
        case .memory:
            TatwoMemoryPage(model: model)   // W180 E1
        case .team:
            // 團隊之後。
            AssistantSpacePlaceholderPage(tab: tabs.selected)
        }
    }
}

/// 側欄收起時頁首那排分頁：小玻璃 chip，點不了的淡掉。
struct AssistantSpaceTabChips: View {
    @ObservedObject var tabs: AssistantSpaceTabStore

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AssistantSpaceTab.allCases) { tab in
                let selected = tabs.selected == tab
                Button { tabs.select(tab) } label: {
                    Label(tab.title, systemImage: tab.symbol)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .chatGlassChip(isSelected: selected)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ChatGlassChipButtonStyle())
                .disabled(!tab.isSelectable)
                .help(tab.stageNote.map { "\(tab.title)：\($0)" } ?? tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("tatwo-tab-chip-\(tab.rawValue)")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
        .accessibilityIdentifier("tatwo-tab-chips")
    }
}

/// 還沒開的分頁（正常點不到；萬一被選到也不會空白）。
struct AssistantSpacePlaceholderPage: View {
    let tab: AssistantSpaceTab

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: tab.symbol).font(.largeTitle).foregroundStyle(.secondary)
            Text(tab.title).font(.title3)
            Text(tab.stageNote.map { "\($0)再開。" } ?? "").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
