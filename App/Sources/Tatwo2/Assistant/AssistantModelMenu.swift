import AppKit
import SwiftUI

/// W179 F：助理輸入框的模型選單。名稱用友善名稱；本機跑時被停用的引擎標「已停用」且不能選。只改助理那條，不動 Coder 的模型。
/// W179 UI：觸發鈕就是 Coder 輸入框那顆模型 chip（`ChatComposerModelLabel`，一樣是 Button，整顆都點得到），
/// 點了在 chip 上方跳系統選單（NSMenu）。不用 SwiftUI Menu：borderless 樣式只畫 label 的字——玻璃底、框、箭頭都被丟掉，
/// 而且只有字點得到（離屏實測）；按鈕樣式的 SwiftUI Menu 又是 D2 不要的寫法。
struct AssistantModelMenu: View {
    @ObservedObject var model: ChatPageModel
    @State private var anchor = AssistantModelMenuAnchor()

    var body: some View {
        let title = model.assistantModelChipTitle
        Button(action: popUp) {
            ChatComposerModelLabel(title: title, suffix: nil, compact: false, selected: false)
        }
        .buttonStyle(.plain)
        .background(AssistantModelMenuAnchorView(anchor: anchor))
        .disabled(model.assistantIsRunning)
        .help("助理的模型，不更動 Coder")
        .accessibilityLabel("助理的模型：\(title)")
        .accessibilityIdentifier("tatwo-assistant-model")
    }

    private func popUp() {
        guard let view = anchor.view else { return }
        Self.popUp(Self.menu(for: model), above: view)
    }

    @MainActor
    static func menu(for model: ChatPageModel) -> NSMenu {
        makeMenu(primaryName: model.assistantPrimaryName, options: model.assistantModelOptions) { [model] id in
            model.setAssistantModel(id)
        }
    }

    /// 跟 Coder 的模型面板一樣往上開（輸入框在視窗底部）：選單底邊在 chip 上緣上方 4pt；放不下時系統自己挪。
    /// W180：私訊框的模型 chip 與「＋」也用這個。
    @MainActor
    static func popUp(_ menu: NSMenu, above view: NSView) {
        let height = menu.size.height
        let topLeft = NSPoint(x: 0, y: view.isFlipped ? view.bounds.minY - 4 - height : view.bounds.maxY + 4 + height)
        menu.popUp(positioning: nil, at: topLeft, in: view)
    }

    /// 選單內容：第一行說明在哪台跑（不能點），接著每個品牌一段；選中的打勾，停用的反灰不能選。
    @MainActor
    static func makeMenu(primaryName: String?, options: [AssistantModelOption],
                         choose: @escaping @MainActor @Sendable (String) -> Void) -> NSMenu {
        let menu = NSMenu(title: "助理的模型")
        menu.autoenablesItems = false
        if let primaryName {
            let line = NSMenuItem(title: "在主設備「\(primaryName)」上跑；沒選就照那邊的設定", action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
        }
        for brand in ChatRouteBrandGroup.pickerOrder {
            let group = options.filter { $0.route.brandGroup == brand }
            guard !group.isEmpty else { continue }
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: brand.rawValue))
            for option in group {
                let routeID = option.route.id
                let item = AssistantModelMenuItem(title: option.title) { choose(routeID) }
                item.state = option.isSelected ? .on : .off
                item.isEnabled = !option.isDisabled
                menu.addItem(item)
            }
        }
        return menu
    }

    /// W180：第一行換成自己的說明（例：session 在哪一台上跑），其餘同上。
    @MainActor
    static func makeMenu(headline: String?, options: [AssistantModelOption],
                         choose: @escaping @MainActor @Sendable (String) -> Void) -> NSMenu {
        let menu = makeMenu(primaryName: nil, options: options, choose: choose)
        guard let headline else { return menu }
        let line = NSMenuItem(title: headline, action: nil, keyEquivalent: "")
        line.isEnabled = false
        menu.insertItem(line, at: 0)
        if menu.numberOfItems > 1 { menu.insertItem(.separator(), at: 1) }
        return menu
    }
}

/// 點了就跑一段程式的選單項目。
final class AssistantModelMenuItem: NSMenuItem {
    private let run: @MainActor @Sendable () -> Void

    init(title: String, run: @escaping @MainActor @Sendable () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(AssistantModelMenuItem.fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    /// 選單項目的動作一定在主執行緒送出。只把（主執行緒的）閉包帶進去，不帶選單項目本身。
    @objc private func fire() {
        let run = self.run
        MainActor.assumeIsolated { run() }
    }
}

/// 記住 chip 底下那個 NSView，選單從它的位置跳出來。
@MainActor
final class AssistantModelMenuAnchor {
    weak var view: NSView?
}

/// 只當選單的定位點：不畫東西、不接點擊（點擊交給上面的 chip）。W180：私訊框的 chip 與「＋」共用。
struct AssistantModelMenuAnchorView: NSViewRepresentable {
    let anchor: AssistantModelMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// 開始使用與助理輸入框讀同一個模型設定。
struct AssistantSetupModel: Equatable {
    let title: String
    let isExplicit: Bool
    let engineKind: ClaudeSidecar.Kind?
}

extension ChatPageModel {
    func recordAssistantModelSelection(threadID: UUID) {
        UserDefaults.standard.set(true, forKey: "tatwo2.assistantModelSelected.\(threadID.uuidString)")
    }

    var assistantSetupModel: AssistantSetupModel {
        let isExplicit = assistantTranscriptThreadID.map {
            UserDefaults.standard.bool(forKey: "tatwo2.assistantModelSelected.\($0.uuidString)")
        } ?? false
        return AssistantSetupModel(title: assistantModelChipTitle,
                                   isExplicit: isExplicit,
                                   engineKind: AssistantModelRouting.engineKind(for: assistantRouteChoice))
    }
}
