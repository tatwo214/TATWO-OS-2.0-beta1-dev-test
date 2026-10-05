import AppKit
import SwiftUI

/// W180 E1：輸入框的「記憶 中」chip。外觀同模型 chip（ChatComposerModelLabel，玻璃、不用藍），點了在上方跳系統選單：
/// 關「不帶記憶」、淺「只帶很相關的」、中「帶相關的」、深「先翻記憶再回答」。只改這一條；別台上的跟下一句一起帶過去。
/// 放在：TATWO 輸入框與私訊框的模型 chip 旁、Coder 輸入框（只在 Coder，CLI 與 Bot 不顯示；對象是 ChatGPT 不顯示）。
struct TatwoMemoryStrengthChip: View {
    @ObservedObject var model: ChatPageModel
    let target: TatwoMemoryChipTarget
    var compact = true
    /// W181：私訊框用自己的膠囊 chip（GlobalDMChipLabel）；TATWO 與 Coder 照舊。
    var dmStyle = false
    @ObservedObject private var pending = TatwoMemoryStrengthPending.shared
    @State private var anchor = AssistantModelMenuAnchor()

    var body: some View {
        if let state = model.memoryChipState(target) {
            Button(action: { popUp(state) }) {
                if dmStyle {
                    // W184 F 小修正（真機：內橫縮到約 0.8 倍時模型膠囊被截成「Fa...5.1」）：寬度不夠時先縮記憶膠囊（只留強度），模型名不截。
                    ViewThatFits(in: .horizontal) {
                        GlobalDMChipLabel(title: "記憶", value: state.strength.title)
                        GlobalDMChipLabel(title: state.strength.title)
                    }
                } else {
                    ChatComposerModelLabel(title: "記憶", suffix: state.strength.title, compact: compact, selected: false)
                }
            }
            .buttonStyle(.plain)
            .background(AssistantModelMenuAnchorView(anchor: anchor))
            .disabled(!state.isEnabled)
            .opacity(state.isEnabled ? 1 : 0.55)
            .help("記憶強度：\(state.strength.title)（\(state.strength.menuDetail)）")
            .accessibilityLabel("記憶強度：\(state.strength.title)")
            .accessibilityIdentifier("tatwo-memory-strength")
        }
    }

    private func popUp(_ state: TatwoMemoryChipState) {
        guard let view = anchor.view else { return }
        let menu = Self.makeMenu(state: state) { [model, target] strength in
            model.setMemoryStrength(strength, for: target)
        }
        AssistantModelMenu.popUp(menu, above: view)
    }

    @MainActor
    static func makeMenu(state: TatwoMemoryChipState,
                         choose: @escaping @MainActor @Sendable (TatwoMemoryStrength) -> Void) -> NSMenu {
        let menu = NSMenu(title: "記憶強度")
        menu.autoenablesItems = false
        let line = NSMenuItem(title: state.headline, action: nil, keyEquivalent: "")
        line.isEnabled = false
        menu.addItem(line)
        menu.addItem(.separator())
        for strength in TatwoMemoryStrength.allCases {
            let item = AssistantModelMenuItem(title: "\(strength.title)　\(strength.menuDetail)") { choose(strength) }
            item.state = strength == state.strength ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
}

/// W180 E1：私訊框的記憶 chip：對象是助理或某條 session 才有；ChatGPT 不顯示（它的記憶在 OpenAI）。
struct GlobalDMMemoryChip: View {
    @ObservedObject var store: GlobalDMStore

    var body: some View {
        if let model = store.model, let target = Self.target(store.target) {
            TatwoMemoryStrengthChip(model: model, target: target, dmStyle: true)
        }
    }

    static func target(_ target: GlobalDMTarget) -> TatwoMemoryChipTarget? {
        switch target {
        case .assistant: return .assistant
        case .thread(let id): return .thread(id)
        case .chatGPT: return nil
        }
    }
}
