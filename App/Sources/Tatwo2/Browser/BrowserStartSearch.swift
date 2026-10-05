import SwiftUI

/// Browser work space 沒有分頁（或空白的新分頁）時置中的搜尋框：放大鏡＋「Search」、左下 ＋（加入分頁）、右下 ↑（送出）、
/// 打字時上面浮一排建議；背後一圈品牌色的淡光。
/// W184 G2d（使用者 09-30：「還沒有分頁的搜尋狀態也要一樣」「你就只是把現成的browser space做成duo自適應尺寸而已 不要越搞越遠」）：
/// 從 BrowserWorkSpaceDesignView 抽出來，主視窗與私訊框的 Browser 用同一份——外面給字、焦點、建議與按下去做什麼；
/// 樣子與尺寸同一套（搜尋框最寬 560、窄的時候跟著框寬，左右各留 24）。
struct BrowserStartSearch<Field: Hashable, SearchMenu: View>: View {
    @Binding var query: String
    let focus: FocusState<Field?>.Binding
    let field: Field
    let canAddTab: Bool
    let suggestions: [BrowserWorkSpaceStore.Suggestion]
    let notice: String
    var identifier = "browser.startSearch"
    let onSubmit: () -> Void
    let onAddTab: () -> Void
    let onSuggestion: (BrowserWorkSpaceStore.Suggestion) -> Void
    @ViewBuilder let searchMenu: () -> SearchMenu

    private var palette: TatwoThemePalette { TatwoActivePalette.current }
    private var fieldFill: Color { LiquidGlassTokens.browserFieldFill }
    private var shadowColor: Color { LiquidGlassTokens.browserShadowColor }

    var body: some View {
        ZStack {
            RadialGradient(colors: [palette.brandAccent.opacity(BrowserSidebarMetrics.searchGlowOpacity), .clear],
                           center: .center, startRadius: BrowserSidebarMetrics.zero, endRadius: BrowserSidebarMetrics.searchGlowRadius)
                .frame(maxWidth: BrowserSidebarMetrics.searchGlowWidth, maxHeight: BrowserSidebarMetrics.searchGlowHeight).allowsHitTesting(false)
            searchBox
                .frame(maxWidth: BrowserSidebarMetrics.searchMaxWidth)
                .padding(.horizontal, BrowserSidebarMetrics.laneCardOuterInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay(alignment: .bottom) {
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary).padding(BrowserSidebarMetrics.laneRowSpacing) }
        }
    }

    private var searchBox: some View {
        VStack(spacing: BrowserSidebarMetrics.zero) {
            HStack(spacing: BrowserSidebarMetrics.downloadsPadding) {
                Image(systemName: "magnifyingglass").font(.system(size: BrowserSidebarMetrics.searchIconSize)).foregroundStyle(.secondary)
                TextField("Search", text: $query).font(.system(size: BrowserSidebarMetrics.searchFontSize))
                    .textFieldStyle(.plain).focused(focus, equals: field)
                    .accessibilityIdentifier(identifier)
                    .onSubmit(onSubmit).contextMenu { searchMenu() }
            }.padding(.horizontal, BrowserSidebarMetrics.childGap).padding(.top, BrowserSidebarMetrics.childGap).padding(.bottom, BrowserSidebarMetrics.laneRowSpacing)
            HStack {
                roundButton("加入分頁", "plus", action: onAddTab).disabled(!canAddTab)
                Spacer()
                roundButton("搜尋", "arrow.up", action: onSubmit)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.top, BrowserSidebarMetrics.searchTopInset).padding(.horizontal, BrowserSidebarMetrics.settingsCardHorizontalPadding).padding(.bottom, BrowserSidebarMetrics.searchBottomInset)
        .background(fieldFill, in: RoundedRectangle(cornerRadius: BrowserSidebarMetrics.laneCardCornerRadius))
        .shadow(color: shadowColor.opacity(BrowserSidebarMetrics.searchShadowOpacity), radius: BrowserSidebarMetrics.searchShadowRadius, x: BrowserSidebarMetrics.zero, y: BrowserSidebarMetrics.downloadsPadding)
        .overlay(alignment: .top) {
            // An overlay does not move the centered box when suggestions appear.
            if !suggestions.isEmpty {
                suggestionList.offset(y: BrowserSidebarMetrics.searchSuggestionsOffset)
            }
        }
    }

    private func roundButton(_ label: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: BrowserSidebarMetrics.searchIconSize))
                .frame(width: BrowserSidebarMetrics.searchButtonSize, height: BrowserSidebarMetrics.searchButtonSize).background(palette.surfaceBorder.opacity(BrowserSidebarMetrics.searchButtonOpacity), in: Circle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }

    private var suggestionList: some View {
        VStack(spacing: BrowserSidebarMetrics.zero) {
            ForEach(suggestions) { suggestion in
                Button {
                    onSuggestion(suggestion)
                } label: {
                    HStack {
                        Text(suggestion.section).font(.caption).foregroundStyle(.secondary)
                        Text(suggestion.title).font(.system(size: BrowserSidebarMetrics.rowFontSize)).lineLimit(1)
                        Spacer(minLength: 0)
                    }.padding(BrowserSidebarMetrics.downloadsPadding).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.background(fieldFill, in: RoundedRectangle(cornerRadius: BrowserSidebarMetrics.rowSpacing))
    }
}

/// W184 G2d（GPT-6 審查 G2d #5：主視窗的搜尋框右鍵有搜尋引擎選單，私訊框給的是空的）：置中搜尋框右鍵的「搜尋引擎」——主視窗 Browser space
/// 與私訊框的 Browser 同一份；選了＝存進同一個 Browser 設定（settings.json 的 searchEngine；兩邊打字搜尋都照它）。存不進去怎麼說由外面決定。
struct BrowserSearchEngineMenu: View {
    let engine: BrowserSearchEngine
    let choose: (BrowserSearchEngine) -> Void

    var body: some View {
        Picker("搜尋引擎", selection: Binding(get: { engine }, set: choose)) {
            Text("Google").tag(BrowserSearchEngine.google)
            Text("DuckDuckGo").tag(BrowserSearchEngine.duckduckgo)
            Text("Bing").tag(BrowserSearchEngine.bing)
        }
    }

    /// 存進 Browser 設定；存不進去＝回一句話（主視窗、私訊框各自擺在自己的地方）。
    static func save(_ engine: BrowserSearchEngine) -> String? {
        do {
            try BrowserSettings(searchEngine: engine).save()
            return nil
        } catch {
            return "搜尋設定未儲存：\(error.localizedDescription)"
        }
    }
}
