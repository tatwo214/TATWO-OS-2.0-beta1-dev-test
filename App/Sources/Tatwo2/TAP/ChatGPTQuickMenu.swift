import SwiftUI

// W184 G3b（使用者 09-29 17:35 看了 .030：「＋號也跟chatgpt原版的快捷小視窗不一樣」；17:50 附 ChatGPT iPhone App 截圖）：
// ChatGPT 原版那種 ＋ 小卡——自繪的圓角卡片（不是系統選單、沒有藍色反白）：每列左邊一個圓形底的圖示＋一行字；
// 照片、檔案、外掛程式 ›（點了在同一張卡換頁：工具與 App，一行一個、名字＋一行說明截斷）、認真思考（✓＝開著）。
// 截圖的「相機」在 Mac 上接不到（接續互通相機要系統選單呼叫），不列。有最大高度、可以捲。
// W184 G3b 第二輪（使用者：「快捷指令直接參照chatgpt那邊有什麼 這邊chatgpt space、duo就有什麼」）：內容只放 ChatGPT 那邊有的——
// 工具與 App 是 TAP 從 ChatGPT 網頁讀到的那一份（名稱、順序、分層照網頁）；私訊框自己加的「貼上剪貼簿圖片」拿掉（⌘V 照舊）。
// ChatGPT Space 與私訊框的 ＋、「/」指令都用這一個元件；位置由 ChatGPTPopoverAnchorKey 交給對話區那一層
// （ChatGPTFloatingCardLayer：點外面就收，Esc 各自接）。

/// 卡片裡的一列。
struct ChatGPTQuickMenuRow: Identifiable, Equatable {
    let id: String
    let symbol: String
    let title: String
    var detail = ""
    /// 勾著（目前選的工具、認真思考開著）。
    var selected = false
    /// 點了換頁（「外掛程式 ›」）。
    var opens = false
    /// 只是一行說明（例如還沒讀到 ChatGPT 的清單），不能點。
    var info = false
}

/// 一個分區（標題可以沒有）。
struct ChatGPTQuickMenuSection: Identifiable, Equatable {
    let id: String
    var title: String?
    var rows: [ChatGPTQuickMenuRow]
}

/// 小卡要浮在哪一顆鈕（或輸入框）上面。
enum ChatGPTPopoverAnchor: Hashable {
    case plus, slash
}

struct ChatGPTPopoverAnchorKey: PreferenceKey {
    static let defaultValue: [ChatGPTPopoverAnchor: Anchor<CGRect>] = [:]
    static func reduce(value: inout [ChatGPTPopoverAnchor: Anchor<CGRect>], nextValue: () -> [ChatGPTPopoverAnchor: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 小卡本身（圓角卡片）。pick 收到被點的那一列的 id。
struct ChatGPTQuickMenu: View {
    let sections: [ChatGPTQuickMenuSection]
    /// 鍵盤指著的那一列（「/」指令用上下鍵選）。
    var highlighted: String? = nil
    let metrics: ChatGPTComposerMetrics
    var identifier = "chatgpt.quickMenu"
    let pick: (String) -> Void

    static let width: CGFloat = 300
    static let maxHeight: CGFloat = 380
    /// 卡片四周的留白、分區之間的分隔線（0.5 的線＋上下各 4）。
    static let padding: CGFloat = 8
    static let separatorHeight: CGFloat = 8.5
    /// 分區標題（「工具」「App」）那一行的高。
    static func titleHeight(_ metrics: ChatGPTComposerMetrics) -> CGFloat { (metrics.menuCaption * 2).rounded() }

    /// 卡片內容多高（純計算：列高、分區標題、分隔線、留白都是固定值）。ScrollView 本身會撐滿可用高度，所以高度直接算好給它：
    /// 內容短＝卡片跟著內容高（不留一大片空白）；超過 maxHeight 才捲動（外掛程式那一頁 App 很多時）。
    static func contentHeight(_ sections: [ChatGPTQuickMenuSection], metrics: ChatGPTComposerMetrics) -> CGFloat {
        var height = padding * 2
        for (index, section) in sections.enumerated() {
            if index > 0 { height += separatorHeight }
            if section.title != nil { height += titleHeight(metrics) }
            for row in section.rows { height += row.detail.isEmpty ? metrics.menuRowHeight : metrics.menuDetailRowHeight }
        }
        return height.rounded(.up)   // 0.5 的分隔線對齊像素時多出來的零頭不要變成一點點捲動
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.menuRadius, style: .continuous)
        let height = min(Self.contentHeight(sections, metrics: metrics), Self.maxHeight)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        if index > 0 {
                            Rectangle().fill(metrics.chrome.secondaryText.opacity(0.18)).frame(height: 0.5)
                                .padding(.vertical, 4).padding(.horizontal, 12)
                        }
                        if let title = section.title {
                            Text(title)
                                .font(.system(size: metrics.menuCaption, weight: .semibold))
                                .foregroundStyle(metrics.chrome.secondaryText)
                                .lineLimit(1)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 2)
                                .frame(height: Self.titleHeight(metrics), alignment: .bottomLeading)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(section.rows) { row in
                            ChatGPTQuickMenuRowView(row: row, highlighted: row.id == highlighted, metrics: metrics) { pick(row.id) }
                                .id(row.id)
                        }
                    }
                }
                .padding(Self.padding)
            }
            .scrollIndicators(.automatic)
            // 「/」用上下鍵選到看不見的那一列：捲過去。
            .onChange(of: highlighted) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
        // 內容多高就多高、最多 maxHeight（超過才捲）；按鈕上面放不下時跟著可用的高度縮（浮卡層讓卡片先拿高度），一樣可以捲。
        .frame(width: Self.width)
        .frame(minHeight: 0, idealHeight: height, maxHeight: height)
        .background { ChatGPTQuickMenuSurface(shape: shape) }
        .clipShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// 一列：左邊圓形底的圖示＋一行字（有說明就在下面一行灰字，太長截斷）；勾著的打勾、會換頁的有 ›。
struct ChatGPTQuickMenuRowView: View {
    let row: ChatGPTQuickMenuRow
    let highlighted: Bool
    let metrics: ChatGPTComposerMetrics
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        if row.info {
            // 一行說明：不是按鈕、沒有滑過的底。
            label(background: Color.clear)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chatgpt.quickMenu.\(row.id)")
        } else {
            Button(action: action) {
                // 滑過淡灰；鍵盤指著（「/」）用 App 的強調色淡底——都不是藍色系統反白。
                label(background: highlighted ? LiquidGlassTokens.brandAccent.opacity(0.14) : (hover ? ChatGPTPalette.hover : Color.clear))
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .accessibilityLabel(row.detail.isEmpty ? row.title : "\(row.title)，\(row.detail)")
            .accessibilityAddTraits(row.selected || highlighted ? .isSelected : [])
            .accessibilityIdentifier("chatgpt.quickMenu.\(row.id)")
        }
    }

    private func label(background: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: row.symbol)
                .font(.system(size: metrics.menuText))
                .foregroundStyle(metrics.chrome.primaryText)
                .frame(width: metrics.menuIcon, height: metrics.menuIcon)
                .background(Circle().fill(ChatGPTPalette.pressed))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: metrics.menuText))
                    .foregroundStyle(metrics.chrome.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.system(size: metrics.menuCaption))
                        .foregroundStyle(metrics.chrome.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
            if row.selected {
                Image(systemName: "checkmark")
                    .font(.system(size: metrics.menuCaption, weight: .semibold))
                    .foregroundStyle(metrics.chrome.primaryText)
                    .accessibilityHidden(true)
            }
            if row.opens {
                Image(systemName: "chevron.right")
                    .font(.system(size: metrics.menuCaption, weight: .semibold))
                    .foregroundStyle(metrics.chrome.secondaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: row.detail.isEmpty ? metrics.menuRowHeight : metrics.menuDetailRowHeight)
        .background {
            RoundedRectangle(cornerRadius: metrics.menuRowRadius, style: .continuous).fill(background)
        }
        .contentShape(Rectangle())
    }
}

/// 卡片的底：照 ChatGPT 原版的面板（淺色白、深色深灰）、細框、淡陰影（ChatGPT Space 與私訊框一樣）。
struct ChatGPTQuickMenuSurface: View {
    let shape: RoundedRectangle

    var body: some View {
        shape.fill(ChatGPTPalette.surface)
            .overlay(shape.strokeBorder(ChatGPTPalette.thumbBorder.opacity(0.6), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }
}

// MARK: - 列出什麼（ChatGPT Space 與私訊框同一份規則）

extension ChatGPTQuickMenu {
    /// 工具的圖示（照網頁：生圖、網路搜尋、深入研究、Canvas／Sketch、學習…；App 一律是 App 圖示）。
    static func symbol(for tool: TapTool) -> String {
        if tool.isApp { return "square.grid.2x2" }
        switch tool.id {
        case "picture_v2", "image", "imagegen": return "photo"
        case "search", "web_search", "browse": return "magnifyingglass"
        case "research", "deep_research": return "text.magnifyingglass"
        case "canvas", "sketch": return "pencil.and.outline"
        case "study", "study_mode": return "graduationcap"
        case "agent", "agent_mode": return "cursorarrow.rays"
        default: return "sparkles"
        }
    }

    static func row(_ tool: TapTool, selectedID: String?) -> ChatGPTQuickMenuRow {
        ChatGPTQuickMenuRow(id: "tool:" + tool.id, symbol: symbol(for: tool), title: tool.title, detail: tool.detail,
                            selected: tool.id == selectedID)
    }

    /// 還沒讀到過 ChatGPT 的工具與 App 時，外掛程式那一頁只有這一行（不自己編預設清單）。
    static let toolsNotice = ChatGPTQuickMenuRow(id: "none", symbol: "info.circle", title: "還沒讀到 ChatGPT 的工具與 App",
                                                 detail: "連上 ChatGPT 之後會列出來", info: true)

    /// 「＋」小卡（照 ChatGPT iPhone App 的樣子，內容只放 ChatGPT 那邊有的）：照片、檔案、外掛程式 ›、認真思考（這個模型沒有檔位可選就不列）。
    /// W184 G3b 第二輪：私訊框自己加的「貼上剪貼簿圖片」拿掉（⌘V 照舊）；ChatGPT 有、這裡接不到的「相機」不列。
    /// showingPlugins＝換到「外掛程式」那一頁：照 ChatGPT 網頁「＋」的分層與順序（ChatGPTSpaceModel.plusTools／plusApps／moreTools，
    /// ChatGPT Space 原本的「＋」同一套規則）——有名次的前 4 個工具、最近用過的 App、其他收進「更多」；清單是 TAP 從 ChatGPT 網頁讀到的那一份
    /// （讀不到用上次讀到的；從沒讀過＝一行說明）。
    /// W183 R11（主導 A：「外掛程式頁」要有一眼看懂的「連線」）：tatwo＝TATWO 的連線那一列（HandsConnectEntry.menuRow；沒開 ChatGPT build＝nil），
    /// 排在外掛程式那一頁的最上面（返回的下一列），ChatGPT 的工具與 App 照舊在下面。
    static func plusSections(tools: [TapTool], recentApps: [String], selectedToolID: String?,
                             thinking: Bool?, showingPlugins: Bool, tatwo: ChatGPTQuickMenuRow? = nil) -> [ChatGPTQuickMenuSection] {
        if showingPlugins {
            var sections = [ChatGPTQuickMenuSection(id: "back", rows: [ChatGPTQuickMenuRow(id: "back", symbol: "chevron.left", title: "外掛程式")])]
            let groups: [(id: String, title: String, items: [TapTool])] = [
                ("tools", "工具", ChatGPTSpaceModel.plusTools(tools)),
                ("apps", "App", ChatGPTSpaceModel.plusApps(tools, recent: recentApps)),
                ("more", "更多", ChatGPTSpaceModel.moreTools(tools, recent: recentApps)),
            ]
            for group in groups where !group.items.isEmpty {
                sections.append(ChatGPTQuickMenuSection(id: group.id, title: group.title,
                                                        rows: group.items.map { row($0, selectedID: selectedToolID) }))
            }
            if sections.count == 1 { sections.append(ChatGPTQuickMenuSection(id: "none", rows: [toolsNotice])) }
            if let tatwo { sections.insert(ChatGPTQuickMenuSection(id: "tatwo", title: "TATWO", rows: [tatwo]), at: 1) }   // W183 R11：返回的下一列
            return sections
        }
        var rows = [ChatGPTQuickMenuRow(id: "photos", symbol: "photo", title: "照片"),
                    ChatGPTQuickMenuRow(id: "files", symbol: "paperclip", title: "檔案")]
        let pluginSelected = selectedToolID != nil
        rows.append(ChatGPTQuickMenuRow(id: "plugins", symbol: "at", title: "外掛程式", selected: pluginSelected, opens: true))
        if let thinking {
            rows.append(ChatGPTQuickMenuRow(id: "thinking", symbol: "gauge.with.dots.needle.67percent", title: "認真思考", selected: thinking))
        }
        return [ChatGPTQuickMenuSection(id: "main", rows: rows)]
    }

    /// 「/」指令：網頁的工具在前（有名次的照名次），接著其他工具、App；打的字比對名字與代號（不分大小寫）。
    static func slashTools(_ tools: [TapTool], query: String) -> [TapTool] {
        let visible = tools.filter { !$0.hidden }
        let ranked = visible.filter { !$0.isApp && $0.rank != nil }.sorted { ($0.rank ?? 0) < ($1.rank ?? 0) }
        let others = visible.filter { !$0.isApp && $0.rank == nil }
        let apps = visible.filter(\.isApp)
        let all = ranked + others + apps
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(text) || $0.id.localizedCaseInsensitiveContains(text) }
    }
}

// MARK: - 「/」指令（ChatGPT Space 與私訊框同一份規則、同一個清單元件、同一份資料）

/// W184 G3b 第二輪（使用者：「快捷指令直接參照chatgpt那邊有什麼 這邊chatgpt space、duo就有什麼」）：「/」清單＝TAP 從 ChatGPT 網頁讀到的
/// 工具與 App（ChatGPTSpaceModel.tools；私訊框經 chatGPTCatalog 拿同一份），名稱與順序照網頁、分「工具」「App」兩組；讀不到用上次讀到的，
/// 從沒讀過＝一行說明（不自己編預設清單）。ChatGPT Space 的輸入框與私訊框都有，鍵盤規則也同一套。
@MainActor
enum ChatGPTSlash {
    /// 還沒讀到過清單時的那一行。
    static let notice = ChatGPTQuickMenuRow(id: "none", symbol: "info.circle", title: "還沒讀到 ChatGPT 的指令清單",
                                            detail: "連上 ChatGPT 之後會列出來", info: true)

    /// 要比對的字：草稿最前面是「/」、後面還沒有空白或換行；Esc 收起後（dismissed＝收起時的草稿）草稿沒變就不再出來。
    static func query(_ text: String, dismissed: String?) -> String? {
        guard text.hasPrefix("/"), !text.dropFirst().contains(where: { $0.isWhitespace || $0.isNewline }), dismissed != text else { return nil }
        return String(text.dropFirst())
    }

    /// 清單開不開：有符合的就開；ChatGPT 的清單還沒讀到過（空的）也開，只列一行說明。
    static func isOpen(query: String?, catalog: [TapTool], matches: [TapTool]) -> Bool {
        query != nil && (catalog.isEmpty || !matches.isEmpty)
    }

    /// 按了鍵之後指著哪一列：↓ 下一列（最後一列再下去回到第一列）、↑ 上一列、Enter＝目前這一列；nil＝不吃（第一列再往上交還輸入框）。
    static func moved(_ key: ChatComposerSuggestionKey, index: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let current = min(max(index, 0), count - 1)
        switch key {
        case .next: return (current + 1) % count
        case .prev: return current > 0 ? current - 1 : nil
        case .commit: return current
        }
    }

    /// 清單的樣子：照 ChatGPT 的順序分兩組（工具、App；只有一組就不寫組名）；清單是空的＝一行說明。
    static func sections(_ matches: [TapTool], catalogEmpty: Bool, selectedID: String?) -> [ChatGPTQuickMenuSection] {
        if catalogEmpty { return [ChatGPTQuickMenuSection(id: "none", rows: [notice])] }
        let tools = matches.filter { !$0.isApp }, apps = matches.filter(\.isApp)
        var sections: [ChatGPTQuickMenuSection] = []
        if !tools.isEmpty {
            sections.append(ChatGPTQuickMenuSection(id: "tools", title: apps.isEmpty ? nil : "工具",
                                                    rows: tools.map { ChatGPTQuickMenu.row($0, selectedID: selectedID) }))
        }
        if !apps.isEmpty {
            sections.append(ChatGPTQuickMenuSection(id: "apps", title: tools.isEmpty ? nil : "App",
                                                    rows: apps.map { ChatGPTQuickMenu.row($0, selectedID: selectedID) }))
        }
        return sections
    }
}
