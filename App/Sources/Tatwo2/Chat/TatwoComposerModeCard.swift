// W184 H4：照搬自 Chat/ChatPage+Collaboration.swift（cp 後改）——ULTRAWORK 卡（collaborationStrengthSlider 的標題、身份與模型、底列）、
// 舊版填充式玻璃拉條（collaborationSliderTrack，「#24：填充式玻璃滑軌」＋「#26：連續玻璃軌道底」）、角色模型清單
// （collaborationRoleModelPickerPanel、loopsTeamMember）從 ChatPage 的 extension 抽成獨立元件，讓每個自研輸入框的「模式選擇」開同一張卡。
// 改動：狀態從 ChatPage 的 @State 搬進元件自己；拉條從只給 S～XXL 改成任何一排檔位（速度、推理強度、記憶同一套）；拿掉打開時的淡入
// （卡片本身有淡入）；加私訊框的手機尺寸（DMPhone token）。
//
// 拉條去哪了（git 歷史，使用者 09-30：「有一版開始把我的s m l xl xxl拉桿弄不見了」）：
// - 1.0 的 2e407f0a（07-08）起，ULTRAWORK 面板是這條填充式玻璃拉條；ultrawork 關著時先只給一顆「ultrawork 單模型 thread ›」膠囊，
//   點開才展開拉條（「點開後才展開 S/M/L/XL/XXL 協作強度條」）。
// - 1.0 的 8227fb91（08-31「WIP freeze … from codex thread」）把 collaborationStrengthSlider 改成五顆分開的按鈕：選中那顆實心 brandAccent、
//   其他是 4.5% 的白（fable5 牛皮紙上幾乎看不見）→ 停在 S 時看起來只剩一顆方塊按鈕；拉條函式留著卻沒人叫。任何主題、任何狀態都一樣。
// - 2.0 的 153bbc51（09-03）照搬這一版，所以 2.0 從來沒畫過拉條。這張卡一律直接畫拉條（ultrawork 關著也畫，淡淡的；點或拖就開）。
import SwiftUI
import AppKit

/// 模式卡的尺寸：主視窗照原本 ULTRAWORK 卡的字級；私訊框照手機 token（字級只用 17／15／13／11、可按至少 44、同心圓角 28 − 12 ＝ 16）。
struct TatwoComposerModeMetrics: Equatable {
    var width: CGFloat
    /// 私訊框的卡最寬 width，框窄的時候跟著變窄；主視窗固定寬。
    var flexibleWidth: Bool
    var padding: CGFloat
    var spacing: CGFloat
    var cornerRadius: CGFloat
    var eyebrowSize: CGFloat
    var titleSize: CGFloat
    var badgeSize: CGFloat
    var badgeHeight: CGFloat
    var labelSize: CGFloat
    var hintSize: CGFloat
    var trackHeight: CGFloat
    var trackRadius: CGFloat
    var stepSize: CGFloat
    var roleSize: CGFloat
    var roleWidth: CGFloat
    var rowTitleSize: CGFloat
    var rowDetailSize: CGFloat
    var rowHeight: CGFloat
    var rowRadius: CGFloat
    var chevronSize: CGFloat
    var footSize: CGFloat
    var powerSize: CGFloat
    var listTitleSize: CGFloat
    /// 清單的品牌小標、勾勾與時鐘、返回箭頭。
    var brandSize: CGFloat
    var markSize: CGFloat
    var backSize: CGFloat
    var listRowHeight: CGFloat
    var listHeaderHeight: CGFloat
    var listMaxHeight: CGFloat
    /// W184 H4 修正（查核 #3、#11）：卡從下緣往上長（輸入框上方），上緣最多到畫面頂端往下這麼多：主視窗讓出頂列（band）＋8；
    /// 私訊框讓出框外的陰影邊＋頂列（圓鈕列）。放不下時中間那一段（身份與模型、速度、推理強度、記憶）自己捲，標題與 S～XXL 固定在上面。
    var topClearance: CGFloat
    /// 中間那一段捲動時最矮多高（再矮就不縮了）。
    var minimumScroll: CGFloat

    /// 主視窗（Coder、Bot Studio、Space 搭建）：同原本 ULTRAWORK 卡（10／13／9pt、拉條 34 高、列 38 高、圓角照主題）。
    static var main: TatwoComposerModeMetrics {
        TatwoComposerModeMetrics(
            width: 300, flexibleWidth: false, padding: 16, spacing: 12, cornerRadius: LiquidGlassTokens.radiusCard,
            eyebrowSize: 10, titleSize: 13, badgeSize: 9, badgeHeight: 22, labelSize: 10, hintSize: 9,
            trackHeight: 34, trackRadius: LiquidGlassTokens.radiusChip, stepSize: 11,
            roleSize: 10, roleWidth: 38, rowTitleSize: 11, rowDetailSize: 8, rowHeight: 38, rowRadius: 9, chevronSize: 8,
            footSize: 9, powerSize: 24, listTitleSize: 12, brandSize: 10, markSize: 10, backSize: 10,
            listRowHeight: 30, listHeaderHeight: 22, listMaxHeight: 238,
            topClearance: WindowChromeMetrics.bandHeight + 8, minimumScroll: 88)
    }

    /// 私訊框：手機 token（DMPhone）。卡圓角＝框裡的內容卡 28；內距 12（同框邊到輸入框）→ 裡面的拉條、列同心 16；
    /// 可按的東西 44 高（拉條、每一列、電源、返回）；字 15（標題、列名）、13（小標、檔位字）、11（最小的字）。
    static var dmPhone: TatwoComposerModeMetrics {
        let inner = DMPhone.concentric(DMPhone.cardRadius, inset: DMPhone.edgeInset)
        return TatwoComposerModeMetrics(
            width: 340, flexibleWidth: true, padding: DMPhone.edgeInset, spacing: 12, cornerRadius: DMPhone.cardRadius,
            eyebrowSize: DMPhone.TextSize.caption, titleSize: DMPhone.TextSize.secondary,
            badgeSize: DMPhone.TextSize.caption, badgeHeight: 24, labelSize: DMPhone.TextSize.footnote,
            hintSize: DMPhone.TextSize.caption, trackHeight: DMPhone.touch, trackRadius: inner,
            stepSize: DMPhone.TextSize.footnote, roleSize: DMPhone.TextSize.footnote, roleWidth: 44,
            rowTitleSize: DMPhone.TextSize.secondary, rowDetailSize: DMPhone.TextSize.caption,
            rowHeight: DMPhone.touch, rowRadius: inner, chevronSize: DMPhone.TextSize.caption,
            footSize: DMPhone.TextSize.footnote, powerSize: DMPhone.touch, listTitleSize: DMPhone.TextSize.secondary,
            brandSize: DMPhone.TextSize.caption, markSize: DMPhone.TextSize.footnote, backSize: DMPhone.TextSize.footnote,
            listRowHeight: DMPhone.touch, listHeaderHeight: 24, listMaxHeight: 320,
            topClearance: GlobalDMLayout.margin + DMPhone.headerHeight, minimumScroll: DMPhone.touch * 2)
    }

    /// 這張卡用到的字級（自測核對私訊框的都在 17／15／13／11 裡）。
    var textSizes: [CGFloat] {
        [eyebrowSize, titleSize, badgeSize, labelSize, hintSize, stepSize, roleSize, rowTitleSize, rowDetailSize,
         chevronSize, footSize, listTitleSize, brandSize, markSize, backSize]
    }
}

/// 模式卡＝ULTRAWORK 卡擴充（使用者 09-30 02:51：「之前設計最好的推理強度小卡是ultrawork…我希望推理強度小卡是這個」）：
/// 標題（ULTRAWORK／S 協作編制／確認後・可執行）→ S～XXL 舊版漸層拉條 → 身份與模型（點一列換成那一列的模型清單）→ 速度 →
/// 推理強度 → 記憶 → 底列（執行權限綁定…＋電源）。四樣各自挑；每一區照各輸入框原本的規則（TatwoComposerMode 的來源）列或不列、變淡。
/// W184 H4 修正（查核 #3、#11）：卡從下緣往上長，上緣不超過 metrics.topClearance：放不下時（視窗矮、XL／XXL 角色多）標題與 S～XXL
/// 固定在上面，中間那一段（身份與模型、速度、推理強度、記憶）自己捲——S～XXL 一定看得到。
/// W184 H4 修正（GPT-6 H4 審查 #8）：總高度有硬上限（不超過可用高度）：先縮中間捲動區（到 minimumScroll）、再收非必要的固定區
/// （底列 → S～XXL 下面那行說明 → 標題），還不夠才把中間縮到沒有；最後 frame(maxHeight:)＋clipped 保證不超過（TatwoComposerModeFit）。
/// W184 H4 修正（審查 #6）：卡由 TatwoComposerModePopover 掛出來時收鍵盤（Esc 收卡、↑↓／Tab 換區、←→ 換檔、Return 選定；見
/// TatwoComposerModeKeyboard.swift）；Plan 畫布那張不收。
struct TatwoComposerModeCard: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let mode: TatwoComposerMode
    var metrics: TatwoComposerModeMetrics = .main
    /// 卡從下緣往上長（輸入框上方的浮層、私訊框、Bot Studio、Space 搭建）：量上面還有多高、放不下就捲。
    /// Plan 畫布那張（在計劃書側欄裡、由上往下排、外面自己會捲）不量。
    var fitsAbove = true
    @Environment(\.tatwoComposerModeDismiss) private var dismiss
    /// 正在換哪一列的模型（nil＝卡的主頁）。
    @State private var pickingRowID: String?
    /// 卡的下緣在畫面裡的位置（最上層畫面的座標，由上往下）；它減掉 topClearance＝卡最高能多高。
    @State private var cardBottom: CGFloat?
    @State private var headerHeight: CGFloat = 0
    @State private var noteHeight: CGFloat = 0
    @State private var sectionsHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    @State private var listNoteHeight: CGFloat = 0
    /// 鍵盤停在哪一區、這一區框著哪一檔（還沒按 Return，值不變）、清單頁框著哪一列。
    @State private var keyTarget: KeyTarget?
    @State private var keyStop: Int?
    @State private var keyListIndex: Int?

    /// 鍵盤能停的地方（主頁）。
    enum KeyTarget: Equatable {
        case collaboration
        case row(String)
        case steps(String)
        case power
    }

    /// initialPickingRowID：自測畫「模型清單那一頁」用（平常從主頁點一列進去）。
    init(mode: TatwoComposerMode, metrics: TatwoComposerModeMetrics = .main, fitsAbove: Bool = true,
         initialPickingRowID: String? = nil) {
        self.mode = mode
        self.metrics = metrics
        self.fitsAbove = fitsAbove
        _pickingRowID = State(initialValue: initialPickingRowID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing) {
            if let row = mode.models.first(where: { $0.id == pickingRowID }) {
                modelList(row)
            } else {
                mainPage
            }
        }
        .padding(metrics.padding)
        .coderScrollIndicators()
        .frame(width: metrics.flexibleWidth ? nil : metrics.width, alignment: .leading)
        .frame(maxWidth: metrics.flexibleWidth ? metrics.width : nil, alignment: .leading)
        // W184 H4 修正（審查 #8）：總高度不超過可用高度（上面先照 TatwoComposerModeFit 收；這一道是最後的保證，由上往下留）。
        .frame(maxHeight: available, alignment: .top)
        .clipped()
        // 同原本的面板：真 /liquid-glass-dashboard 玻璃底板（fable5 是牛皮紙 matte），不自創玻璃參數。
        .liquidGlassPanelSurface(cornerRadius: metrics.cornerRadius)
        // 量到整點（小數點的來回不重畫）；卡的下緣是固定的（從下緣往上長），卡變矮不會讓下緣跟著動。
        .onGeometryChange(for: CGFloat.self) { proxy in proxy.frame(in: .global).maxY.rounded() } action: { bottom in
            cardBottom = bottom
        }
        .background {
            if let dismiss { TatwoComposerModeKeyMonitor(onKey: handleKey, isLive: dismiss.isPresented) }
        }
        .modifier(TatwoComposerModeKeyTargetReport(target: keyTarget.map { "\($0)" }))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("模式選擇")
        .accessibilityIdentifier(TatwoComposerMode.cardIdentifier)
    }

    /// 卡最高能多高；Plan 畫布那張或還沒量到＝nil（不限）。
    private var available: CGFloat? {
        guard fitsAbove, let cardBottom else { return nil }
        return max(0, cardBottom - metrics.topClearance)
    }

    /// W184 H4 修正第二輪（GPT-6 H4b 審查 #6）：底列只剩說明（電源搬到 S～XXL 旁邊）；沒有說明就不畫。
    private var showsFooter: Bool { mode.footnote != nil }
    private var hasSections: Bool { !mode.models.isEmpty || mode.speed != nil || mode.effort != nil || mode.memory != nil }

    /// 這一次怎麼擺（放得下＝全部照畫；放不下＝中間捲、再收非必要的固定區）。
    private var fit: TatwoComposerModeFit {
        let sizes = TatwoComposerModeFit.Sizes(
            padding: metrics.padding, spacing: metrics.spacing, header: headerHeight,
            track: mode.collaboration == nil ? 0 : metrics.trackHeight,
            note: mode.collaboration?.note == nil ? 0 : noteHeight,
            sections: hasSections ? max(sectionsHeight, 1) : 0,
            footer: showsFooter ? footerHeight : 0)
        return TatwoComposerModeFit.plan(available: available, sizes: sizes, minimumScroll: metrics.minimumScroll)
    }

    @ViewBuilder
    private var mainPage: some View {
        let fit = self.fit
        // 固定在上面：標題＋S～XXL（使用者：「有一版開始把我的s m l xl xxl拉桿弄不見了」——卡再矮也看得到）。
        if fit.showsHeader || mode.collaboration != nil {
            VStack(alignment: .leading, spacing: metrics.spacing) {
                if fit.showsHeader {
                    header
                        .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.height.rounded(.up) } action: { headerHeight = $0 }
                }
                if let collaboration = mode.collaboration {
                    VStack(alignment: .leading, spacing: 6) {
                        // W184 H4 修正第二輪（審查 #6）：電源（關閉 ultrawork）跟 S～XXL 並排、一起固定在上面——卡再矮也按得到。
                        HStack(spacing: 8) {
                            collaborationTrack(collaboration)
                            powerButton(collaboration)
                        }
                        if fit.showsNote, let note = collaboration.note {
                            noteLine(note)
                                .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.height.rounded(.up) } action: { noteHeight = $0 }
                        }
                    }
                }
            }
        }
        // 中間：身份與模型 → 速度 → 推理強度 → 記憶；放不下時這一段自己捲（TatwoComposerModeFitScroll）。
        if hasSections, fit.showsSections {
            // W184 H4 修正第二輪（審查 #5）：鍵盤框到中間這一段的哪一區，就把那一區捲進看得到的地方（focusID）。
            TatwoComposerModeFitScroll(limit: fit.scrollLimit, onHeight: { sectionsHeight = $0 },
                                       focusID: keyTarget.flatMap(Self.scrollID)) {
                VStack(alignment: .leading, spacing: metrics.spacing) {
                    if !mode.models.isEmpty { modelSection }
                    if let speed = mode.speed { stepsSection(speed) }
                    if let effort = mode.effort { stepsSection(effort) }
                    if let memory = mode.memory { stepsSection(memory) }
                }
            }
        }
        if showsFooter, fit.showsFooter {
            footer
                .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.height.rounded(.up) } action: { footerHeight = $0 }
        }
    }

    // MARK: 標題（照搬 collaborationStrengthSlider 的第一列）

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.eyebrow)
                    .font(.system(size: metrics.eyebrowSize, weight: .black, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(LiquidGlassTokens.brandAccent)
                Text(mode.title)
                    .font(.system(size: metrics.titleSize, weight: .bold))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let badge = mode.badge {
                let tone = badge.positive ? LiquidGlassTokens.loopsPositive : Color.secondary
                Text(badge.text)
                    .font(.system(size: metrics.badgeSize, weight: .black, design: .rounded))
                    .foregroundStyle(tone)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(height: metrics.badgeHeight)
                    .background(tone.opacity(0.10), in: Capsule())
            }
        }
    }

    // MARK: S～XXL（舊版拉條，一律直接畫）

    private func collaborationTrack(_ collaboration: TatwoComposerMode.Collaboration) -> some View {
        let options = ChatCollaborationLevel.allCases.filter { $0 != .off }
        let active = collaboration.level != .off
        let keyed = keyTarget == .collaboration
        return TatwoComposerFilledTrack(
            titles: options.map(\.title),
            selectedIndex: active ? options.firstIndex(of: collaboration.level) : nil,
            isEnabled: collaboration.isEnabled,
            metrics: metrics,
            identifiers: options.map { "ultrawork-mode-\($0.title.lowercased())" },
            accessibilityLabel: "Chat collaboration level",
            help: active
                ? "點擊字母之間或拖曳切換 S/M/L/XL/XXL；收據 gate 仍負責收尾證據。"
                : "向右拖曳或點擊字母之間啟動 Ultrawork 協作。",
            keyFocused: keyed,
            keyStop: keyed ? keyStop : nil,
            onCommit: { index in
                guard options.indices.contains(index) else { return }
                collaboration.setLevel(options[index])
            })
            .accessibilityIdentifier("tatwo.composer.mode.ultrawork")
            .background { if keyed { TatwoComposerModeKeyFocusMarker() } }
    }

    /// W184 H4 修正第二輪（GPT-6 H4b 審查 #6）：關閉 ultrawork 的電源鈕，跟 S～XXL 並排（原本在底列：卡矮時底列先收，電源跟著不見）。
    /// 同拉條的玻璃邊與圓角、跟拉條一樣高（私訊框 44：手機可按的大小）；ultrawork 關著、這個入口不帶 ultrawork 時變淡、按不了。
    private func powerButton(_ collaboration: TatwoComposerMode.Collaboration) -> some View {
        let active = collaboration.level != .off
        let usable = active && collaboration.isEnabled
        let shape = RoundedRectangle(cornerRadius: metrics.trackRadius, style: LiquidGlassTokens.shapeStyle)
        let keyed = keyTarget == .power
        return Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                collaboration.setLevel(.off)
            }
        } label: {
            Image(systemName: "power")
                .font(.system(size: metrics.stepSize, weight: .black))
                .foregroundStyle(.secondary)
                .frame(width: metrics.trackHeight, height: metrics.trackHeight)
                .background(Color.white.opacity(0.045), in: shape)
                .overlay { shape.strokeBorder(LiquidGlassTokens.glassRimGradient, lineWidth: 1) }
                // 鍵盤停在電源（審查 #6）：Return＝關閉。
                .overlay { if keyed { shape.strokeBorder(LiquidGlassTokens.brandAccent, lineWidth: 2) } }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .opacity(usable ? 1 : 0.45)
        .help("關閉 Ultrawork 協作；回到單模型 thread。")
        .accessibilityLabel("關閉 Ultrawork")
        .accessibilityIdentifier("tatwo.composer.mode.off")
        .background(TatwoComposerModePowerMarker())
        .background { if keyed { TatwoComposerModeKeyFocusMarker() } }
    }

    // MARK: 身份與模型（照搬 loopsTeamRow／loopsTeamMember）

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(mode.modelHeading)
                    .font(.system(size: metrics.labelSize, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let hint = mode.modelHint, mode.models.contains(where: { $0.isEnabled && !$0.options.isEmpty }) {
                    Text(hint)
                        .font(.system(size: metrics.hintSize, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(mode.models) { modelRow($0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let note = mode.modelNote {
                noteLine(note)
            }
            if let action = mode.modelNoteAction {
                GlobalDMChipButton(title: "打開 ChatGPT", action: action)
                    .accessibilityIdentifier("tatwo.composer.mode.openChatGPT")
            }
        }
    }

    private func modelRow(_ row: TatwoComposerMode.ModelRow) -> some View {
        let canPick = row.isEnabled && !row.options.isEmpty
        let shape = RoundedRectangle(cornerRadius: metrics.rowRadius, style: .continuous)
        let keyed = keyTarget == .row(row.id)
        return Button {
            guard canPick else { return }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                pickingRowID = row.id
            }
        } label: {
            HStack(spacing: 9) {
                Text(row.role)
                    .font(.system(size: metrics.roleSize, weight: .black, design: .rounded))
                    .foregroundStyle(row.tint)
                    .lineLimit(1)
                    .frame(width: metrics.roleWidth, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .font(.system(size: metrics.rowTitleSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.primary.opacity(0.86))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail = row.detail {
                        Text(detail)
                            .font(.system(size: metrics.rowDetailSize, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                if canPick {
                    Image(systemName: "chevron.down")
                        .font(.system(size: metrics.chevronSize, weight: .black))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 9)
            .frame(minHeight: metrics.rowHeight)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.045), in: shape)
            .overlay(shape.strokeBorder(row.tint.opacity(0.20), lineWidth: 1))
            // 鍵盤停在這一列（審查 #6）：Return＝進這一列的模型清單。
            .overlay { if keyed { shape.strokeBorder(LiquidGlassTokens.brandAccent, lineWidth: 2) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .opacity(row.isEnabled ? 1 : 0.55)
        .help(canPick ? "設定\(row.role)的模型" : (mode.modelNote ?? row.title))
        .accessibilityLabel("\(row.role)：\(row.title)")
        .accessibilityIdentifier(row.identifier)
        .id(Self.scrollKey(.row(row.id)))
        .background { if keyed { TatwoComposerModeKeyFocusMarker() } }
    }

    // MARK: 速度、推理強度、記憶（跟 S～XXL 同一條拉條）

    private func stepsSection(_ steps: TatwoComposerMode.Steps) -> some View {
        let keyed = keyTarget == .steps(steps.identifier)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(steps.title)
                    .font(.system(size: metrics.labelSize, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                if let detail = steps.detail {
                    Text(detail)
                        .font(.system(size: metrics.hintSize, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 0) {
                TatwoComposerFilledTrack(
                    titles: steps.sliderOptions.map(\.title),
                    selectedIndex: steps.sliderSelectedIndex,
                    isEnabled: steps.isEnabled,
                    metrics: metrics,
                    identifiers: steps.sliderOptions.map { "\(steps.identifier).\($0.id)" },
                    accessibilityLabel: steps.title,
                    help: steps.note ?? steps.detail,
                    keyFocused: keyed,
                    keyStop: keyed ? keyStop : nil,
                    onCommit: { index in
                        guard steps.sliderOptions.indices.contains(index) else { return }
                        steps.choose(steps.sliderOptions[index].id)
                    })
                if steps.hasUltra {
                    // 玻璃拉條最後一格：只按這一格才啟用 Ultra，拖曳／方向鍵不會意外越入。
                    Button("Ultra") { steps.choose(TatwoCodexReasoningEffort.ultra.rawValue) }
                        .font(.system(size: metrics.stepSize, weight: .bold, design: .rounded))
                        .foregroundStyle(steps.selectedID == TatwoCodexReasoningEffort.ultra.rawValue ? LiquidGlassTokens.browserInk : Color.secondary)
                        .frame(width: 48, height: metrics.trackHeight)
                        .background {
                            Rectangle().fill(LiquidGlassTokens.ultraworkGradient)
                                .opacity(steps.selectedID == TatwoCodexReasoningEffort.ultra.rawValue ? 1 : 0.16)
                        }
                        .contentShape(Rectangle())
                        .buttonStyle(.plain)
                        .disabled(!steps.isEnabled)
                        .accessibilityIdentifier("\(steps.identifier).list.ultra")
                        .accessibilityLabel(TatwoCodexReasoningEffort.ultra.displayName)
                        .accessibilityAddTraits(steps.selectedID == TatwoCodexReasoningEffort.ultra.rawValue ? .isSelected : [])
                        .help(TatwoComposerMode.ultraWarning)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: metrics.trackRadius, style: .continuous))
            .accessibilityIdentifier(steps.identifier)
            .accessibilityValue(steps.selectedTitle ?? "未設定")
            if steps.selectedID == TatwoCodexReasoningEffort.ultra.rawValue {
                noteLine(TatwoComposerMode.ultraWarning)
            }
            if let note = steps.note {
                noteLine(note)
            }
        }
        .id(Self.scrollKey(.steps(steps.identifier)))
        .background { if keyed { TatwoComposerModeKeyFocusMarker() } }
    }

    // MARK: 底列（照搬 collaborationStrengthSlider 的最後一列：權限說明；W184 H4 修正第二輪：電源搬到 S～XXL 旁邊）

    private var footer: some View {
        HStack(spacing: 7) {
            if let footnote = mode.footnote {
                Image(systemName: footnote.icon)
                    .font(.system(size: metrics.footSize, weight: .bold))
                Text(footnote.text)
                    .font(.system(size: metrics.footSize, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
    }

    private func noteLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: metrics.hintSize, weight: .medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 模型清單（照搬 collaborationRoleModelPickerPanel／modelPickerInlineRouteRow；在卡裡換頁，不另開面板）

    struct BrandGroup {
        let brand: ChatRouteBrandGroup
        let options: [TatwoComposerMode.ModelOption]
    }

    /// 照品牌分段，段的順序照清單裡第一次出現的順序（Coder 目前選的品牌排最前；助理照原本選單的 pickerOrder）。
    static func brandGroups(_ options: [TatwoComposerMode.ModelOption]) -> [BrandGroup] {
        var order: [ChatRouteBrandGroup] = []
        var buckets: [ChatRouteBrandGroup: [TatwoComposerMode.ModelOption]] = [:]
        for option in options {
            if buckets[option.brand] == nil { order.append(option.brand) }
            buckets[option.brand, default: []].append(option)
        }
        return order.map { BrandGroup(brand: $0, options: buckets[$0] ?? []) }
    }

    private func modelList(_ row: TatwoComposerMode.ModelRow) -> some View {
        let groups = Self.brandGroups(row.options)
        let flat = groups.flatMap(\.options)
        let listHeight = CGFloat(row.options.count) * metrics.listRowHeight
            + CGFloat(groups.count) * metrics.listHeaderHeight + 3
        // W184 H4 修正（審查 #8）：清單也照卡的可用高度（不再「至少三列」就可能把卡撐出上緣）；卡本身另有硬上限。
        let chrome = metrics.padding * 2 + metrics.powerSize + 9 + (mode.modelNote != nil ? listNoteHeight + 6 : 0)
            + (mode.modelNoteAction != nil ? GlobalDMChatLayout.chipHeight + 6 : 0)
        let listCap = min(metrics.listMaxHeight, available.map { max(0, $0 - chrome) } ?? metrics.listMaxHeight)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.spring(response: 0.20, dampingFraction: 0.86)) {
                        pickingRowID = nil
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: metrics.backSize, weight: .bold))
                        .frame(width: metrics.powerSize, height: metrics.powerSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("回模式選擇")
                .accessibilityIdentifier("tatwo.composer.mode.back")
                Text(row.role == "模型" ? "模型" : "\(row.role)的模型")
                    .font(.system(size: metrics.listTitleSize, weight: .semibold))
                Spacer(minLength: 8)
            }
            Divider().opacity(0.12).padding(.vertical, 4)
            // W184 H4 修正第二輪（GPT-6 H4b 審查 #5）：鍵盤框到清單外面的那一列時，捲到看得到（最少的捲動）。
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(groups, id: \.brand) { group in
                            Text(group.brand.rawValue)
                                .font(.system(size: metrics.brandSize, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, minHeight: metrics.listHeaderHeight, alignment: .leading)
                            ForEach(group.options) { option in
                                listRow(option, row: row, keyed: keyListIndex.map { flat.indices.contains($0) && flat[$0].id == option.id } ?? false)
                                    .id(Self.listScrollID(option.id))
                            }
                        }
                    }
                    .padding(.bottom, 3)
                }
                .onChange(of: keyListIndex, initial: true) { _, index in
                    guard let index, flat.indices.contains(index) else { return }
                    // 下一輪才捲（同私訊框捲到底的做法）：這一輪框才剛換上去，清單還沒排好。
                    let id = Self.listScrollID(flat[index].id)
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: nil) }
                }
            }
            .frame(height: min(listHeight, listCap))
            if let note = mode.modelNote {
                noteLine(note)
                    .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.height.rounded(.up) } action: { listNoteHeight = $0 }
                    .padding(.top, 6)
            }
            if let action = mode.modelNoteAction {
                GlobalDMChipButton(title: "打開 ChatGPT", action: action)
                    .padding(.top, 6)
                    .accessibilityIdentifier("tatwo.composer.mode.openChatGPT")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(row.id.hasPrefix("role-") ? "ultrawork-role-model-picker" : "tatwo.composer.mode.models")
    }

    private func listRow(_ option: TatwoComposerMode.ModelOption, row: TatwoComposerMode.ModelRow, keyed: Bool) -> some View {
        Button {
            guard !option.isDisabled else { return }
            row.choose(option.id)
            withAnimation(.spring(response: 0.20, dampingFraction: 0.86)) {
                pickingRowID = nil
            }
        } label: {
            HStack(spacing: 8) {
                Text(option.title)
                    .font(.system(size: metrics.listTitleSize, weight: option.isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if option.isPending {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: metrics.markSize, weight: .black))
                        .accessibilityLabel("下一輪")
                } else if option.isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: metrics.markSize, weight: .black))
                }
            }
            .foregroundStyle(option.isSelected || option.isPending ? LiquidGlassTokens.brandAccent : Color.primary)
            .padding(.horizontal, 8)
            .frame(height: metrics.listRowHeight)
            .contentShape(Rectangle())
            .chatMenuRowHover(isSelected: option.isSelected)
            // 鍵盤框著這一列（審查 #6）：Return＝選它。
            .overlay {
                if keyed {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(LiquidGlassTokens.brandAccent, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(option.isDisabled)
        .opacity(option.isDisabled ? 0.45 : 1)
        .accessibilityIdentifier("tatwo.composer.mode.models.\(option.id)")
        .background { if keyed { TatwoComposerModeKeyFocusMarker() } }
    }

    // MARK: 鍵盤（W184 H4 修正：審查 #6）

    /// 鍵盤能停的地方（主頁，由上往下、由左往右）：能用的 S～XXL、開著時的電源（在它旁邊）、每一列能換的模型、能用的速度／推理強度／
    /// 記憶。變淡的不停。W184 H4 修正第二輪（GPT-6 H4b 審查 #5）：卡太矮、中間那一段整個收掉時，那一段不能停（看不到的不給選）；
    /// 捲動中的那一段可以停——停到哪一區就捲到哪一區（TatwoComposerModeFitScroll 的 focusID）。
    private var keyTargets: [KeyTarget] {
        var targets: [KeyTarget] = []
        if mode.collaboration?.isEnabled == true { targets.append(.collaboration) }
        if let collaboration = mode.collaboration, collaboration.isEnabled, collaboration.level != .off { targets.append(.power) }
        guard hasSections, fit.showsSections else { return targets }
        for row in mode.models where row.isEnabled && !row.options.isEmpty { targets.append(.row(row.id)) }
        for steps in [mode.speed, mode.effort, mode.memory].compactMap({ $0 }) where steps.isEnabled {
            targets.append(.steps(steps.identifier))
        }
        return targets
    }

    /// 中間那一段每一區的捲動識別（固定在上面的 S～XXL、電源不用捲：nil）。
    static func scrollID(_ target: KeyTarget) -> String? {
        switch target {
        case .row, .steps: return scrollKey(target)
        case .collaboration, .power: return nil
        }
    }

    /// 每一區的 .id（非 optional，跟 scrollTo 的值一模一樣）。
    static func scrollKey(_ target: KeyTarget) -> String {
        switch target {
        case .row(let id): return "tatwo.composer.mode.scroll.row.\(id)"
        case .steps(let id): return "tatwo.composer.mode.scroll.steps.\(id)"
        case .collaboration: return "tatwo.composer.mode.scroll.collaboration"
        case .power: return "tatwo.composer.mode.scroll.power"
        }
    }

    static func listScrollID(_ optionID: String) -> String { "tatwo.composer.mode.scroll.option.\(optionID)" }

    private func stepsFor(_ identifier: String) -> TatwoComposerMode.Steps? {
        [mode.speed, mode.effort, mode.memory].compactMap { $0 }.first { $0.identifier == identifier }
    }

    /// 這一區現在那一檔（沒有＝第一檔）；模型列、電源沒有檔。
    private func currentStop(_ target: KeyTarget) -> Int? {
        switch target {
        case .collaboration:
            let options = ChatCollaborationLevel.allCases.filter { $0 != .off }
            return mode.collaboration.flatMap { options.firstIndex(of: $0.level) } ?? 0
        case .steps(let id):
            return stepsFor(id)?.sliderSelectedIndex ?? 0
        case .row, .power:
            return nil
        }
    }

    private func stopCount(_ target: KeyTarget) -> Int {
        switch target {
        case .collaboration: return ChatCollaborationLevel.allCases.count - 1
        case .steps(let id): return stepsFor(id)?.sliderOptions.count ?? 0
        case .row, .power: return 0
        }
    }

    /// 卡開著時卡要的鍵：Esc 收卡；其他（↑↓ Tab ←→ Return）一律卡收下——沒有能選的也不交回輸入框送出。
    private func handleKey(_ key: TatwoComposerModeKeyboard.Key) -> Bool {
        if key == .escape {
            guard let dismiss else { return false }
            dismiss.action()
            return true
        }
        if let rowID = pickingRowID, let row = mode.models.first(where: { $0.id == rowID }) {
            handleListKey(key, row: row)
            return true
        }
        let targets = keyTargets
        guard !targets.isEmpty else { return true }
        guard let target = keyTarget, targets.contains(target) else {
            // 還沒停在任何一區：↑／Shift＋Tab 從最後一區開始，其他從第一區開始。
            let first = key == .previous ? targets[targets.count - 1] : targets[0]
            keyTarget = first
            keyStop = currentStop(first)
            return true
        }
        switch key {
        case .next, .previous:
            let index = targets.firstIndex(of: target) ?? 0
            let next = key == .next ? (index + 1) % targets.count : (index - 1 + targets.count) % targets.count
            keyTarget = targets[next]
            keyStop = currentStop(targets[next])
        case .left, .right:
            let count = stopCount(target)
            guard count > 0 else { break }
            let now = keyStop ?? currentStop(target) ?? 0
            keyStop = min(max(now + (key == .right ? 1 : -1), 0), count - 1)
        case .commit:
            commitKey(target)
        case .escape:
            break
        }
        return true
    }

    private func commitKey(_ target: KeyTarget) {
        switch target {
        case .collaboration:
            guard let collaboration = mode.collaboration else { return }
            let options = ChatCollaborationLevel.allCases.filter { $0 != .off }
            let index = keyStop ?? currentStop(target) ?? 0
            if options.indices.contains(index) { collaboration.setLevel(options[index]) }
        case .row(let id):
            guard let row = mode.models.first(where: { $0.id == id }) else { return }
            let flat = Self.brandGroups(row.options).flatMap(\.options)
            keyListIndex = flat.firstIndex(where: { $0.isSelected && !$0.isDisabled }) ?? flat.firstIndex(where: { !$0.isDisabled })
            withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) { pickingRowID = id }
        case .steps(let id):
            guard let steps = stepsFor(id) else { return }
            let index = keyStop ?? steps.sliderSelectedIndex ?? 0
            if steps.sliderOptions.indices.contains(index) { steps.choose(steps.sliderOptions[index].id) }
        case .power:
            mode.collaboration?.setLevel(.off)
            keyTarget = .collaboration
            keyStop = 0
        }
    }

    /// 清單頁：↑↓／Tab 換一列（跳過停用的）、Return 選定並回主頁、← 回主頁。
    private func handleListKey(_ key: TatwoComposerModeKeyboard.Key, row: TatwoComposerMode.ModelRow) {
        let flat = Self.brandGroups(row.options).flatMap(\.options)
        let enabled = flat.indices.filter { !flat[$0].isDisabled }
        switch key {
        case .next, .previous:
            guard !enabled.isEmpty else { return }
            let next: Int
            if let at = keyListIndex.flatMap({ enabled.firstIndex(of: $0) }) {
                next = key == .next ? min(at + 1, enabled.count - 1) : max(at - 1, 0)
            } else {
                next = key == .next ? 0 : enabled.count - 1
            }
            keyListIndex = enabled[next]
        case .left:
            keyListIndex = nil
            keyTarget = .row(row.id)
            withAnimation(.spring(response: 0.20, dampingFraction: 0.86)) { pickingRowID = nil }
        case .commit:
            guard let index = keyListIndex, flat.indices.contains(index), !flat[index].isDisabled else { return }
            row.choose(flat[index].id)
            keyListIndex = nil
            keyTarget = .row(row.id)
            withAnimation(.spring(response: 0.20, dampingFraction: 0.86)) { pickingRowID = nil }
        case .right, .escape:
            return
        }
    }
}

/// W184 H4 修正（審查 #8）：卡怎麼放進可用高度（純計算，自測直接算它）。
/// 卡＝上下內距＋［標題（＋間距）＋S～XXL（＋6＋說明）］＋間距＋中間（身份與模型、速度、推理強度、記憶）＋間距＋底列。
/// 放不下時：先縮中間（捲，最矮 minimumScroll）→ 收底列 → 收 S～XXL 下面那行說明 → 收標題 → 中間再縮（到 0＝不畫）。S～XXL 一直留著。
struct TatwoComposerModeFit: Equatable {
    struct Sizes: Equatable {
        var padding: CGFloat
        var spacing: CGFloat
        var header: CGFloat
        var track: CGFloat
        var note: CGFloat
        var sections: CGFloat
        var footer: CGFloat
    }

    /// 中間那一段最多多高（nil＝不限：放得下、沒量到、Plan 畫布那張）。
    var scrollLimit: CGFloat?
    var showsHeader = true
    var showsNote = true
    var showsFooter = true
    var showsSections = true

    /// 照這個安排、中間畫 middle 高（nil＝中間不畫）時整張卡多高。
    func height(_ s: Sizes, middle: CGFloat?) -> CGFloat {
        var children: [CGFloat] = []
        var top: CGFloat = 0
        var topParts = 0
        if showsHeader, s.header > 0 {
            top += s.header
            topParts += 1
        }
        if s.track > 0 {
            if topParts > 0 { top += s.spacing }
            top += s.track + (showsNote && s.note > 0 ? 6 + s.note : 0)
            topParts += 1
        }
        if topParts > 0 { children.append(top) }
        if let middle { children.append(middle) }
        if showsFooter, s.footer > 0 { children.append(s.footer) }
        return s.padding * 2 + children.reduce(0, +) + s.spacing * CGFloat(max(children.count - 1, 0))
    }

    static func plan(available: CGFloat?, sizes s: Sizes, minimumScroll: CGFloat) -> TatwoComposerModeFit {
        var fit = TatwoComposerModeFit()
        guard let available, s.sections > 0 else { return fit }
        if fit.height(s, middle: s.sections) <= available { return fit }
        let least = min(s.sections, minimumScroll)
        func settled() -> TatwoComposerModeFit? {
            guard fit.height(s, middle: least) <= available else { return nil }
            var done = fit
            done.scrollLimit = max(0, available - fit.height(s, middle: 0))
            return done
        }
        if let done = settled() { return done }
        fit.showsFooter = false
        if let done = settled() { return done }
        fit.showsNote = false
        if let done = settled() { return done }
        fit.showsHeader = false
        if let done = settled() { return done }
        let room = available - fit.height(s, middle: 0)
        if room < 8 {
            fit.showsSections = false
            fit.scrollLimit = 0
        } else {
            fit.scrollLimit = room
        }
        return fit
    }
}

/// W184 H4 修正（查核 #3、#11）：內容多高就多高，超過 limit 才變成捲動（同 ThreadGoalCard 的 CappedScroll：ScrollView 本身會撐滿
/// 可用高度，所以量內容自己的高）；limit＝nil（Plan 畫布、還沒量到）＝不限。
/// W184 H4 修正（審查 #4）：捲的時候墊一個可視範圍的定位點（TatwoComposerModeViewportMarker），交給裡面的拉條：被捲走、
/// 落在固定的標題／S～XXL／底列上的按下不接。onHeight：內容自己的高（卡用它排 TatwoComposerModeFit）。
struct TatwoComposerModeFitScroll<Content: View>: View {
    let limit: CGFloat?
    var onHeight: (@MainActor (CGFloat) -> Void)? = nil
    /// W184 H4 修正第二輪（GPT-6 H4b 審查 #5）：鍵盤框著的那一區（.id）；變了就捲到它整個看得到（最少的捲動）。
    var focusID: String? = nil
    let content: Content
    @State private var height: CGFloat = 0
    @State private var viewport = TatwoComposerModeViewport()

    init(limit: CGFloat?, onHeight: (@MainActor (CGFloat) -> Void)? = nil, focusID: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.limit = limit
        self.onHeight = onHeight
        self.focusID = focusID
        self.content = content()
    }

    var body: some View {
        if let limit, height > limit + 0.5 {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    measured
                        .environment(\.tatwoComposerModeViewport, viewport)
                }
                .onChange(of: focusID, initial: true) { _, id in
                    guard let id else { return }
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: nil) }   // 下一輪才捲（框剛換上去）
                }
                .coderScrollIndicators()
            }
            .frame(height: limit)
            .background(TatwoComposerModeViewportMarker(viewport: viewport))
            .accessibilityIdentifier("tatwo.composer.mode.scroll")
        } else {
            measured
        }
    }

    private var measured: some View {
        content.onGeometryChange(for: CGFloat.self) { proxy in proxy.size.height.rounded(.up) } action: { value in
            height = value
            onHeight?(value)
        }
    }
}

// MARK: - 自測看鍵盤框在哪（W184 H4 修正第二輪：審查 #5、#6）

#if DEBUG
/// 自測讀：鍵盤停在哪一區、Tab 走過哪幾區。只在 DEBUG 記。
@MainActor
enum TatwoComposerModeKeyProbe {
    /// 鍵盤停在哪一區（KeyTarget 的描述，例 row("single")、steps("…memory")、power）；nil＝還沒停。
    static var target: String?
    static var visited: [String] = []
    static func reset() { target = nil; visited = [] }
}
#endif

/// 鍵盤停的那一區換了就記下來（自測看 Tab 走過哪幾區；只在 DEBUG）。
struct TatwoComposerModeKeyTargetReport: ViewModifier {
    let target: String?

    func body(content: Content) -> some View {
        #if DEBUG
        content.onChange(of: target) { _, target in
            TatwoComposerModeKeyProbe.target = target
            if let target { TatwoComposerModeKeyProbe.visited.append(target) }
        }
        #else
        content
        #endif
    }
}

/// 鍵盤框著的那一塊墊一個不畫、不接點擊的定位點（只有框著時才有）：自測照 AppKit 的真位置量它是不是在捲動區看得到的範圍裡
/// （捲動不一定重新回報 SwiftUI 的位置，量 NSView 才準）。
struct TatwoComposerModeKeyFocusMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> TatwoComposerModeKeyFocusMarkerView { TatwoComposerModeKeyFocusMarkerView() }
    func updateNSView(_ view: TatwoComposerModeKeyFocusMarkerView, context: Context) {}
}

final class TatwoComposerModeKeyFocusMarkerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 電源鈕的定位點（不畫、不接點擊）：自測量它在不在卡裡、真的點它。
struct TatwoComposerModePowerMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> TatwoComposerModePowerMarkerView { TatwoComposerModePowerMarkerView() }
    func updateNSView(_ view: TatwoComposerModePowerMarkerView, context: Context) {}
}

final class TatwoComposerModePowerMarkerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - 舊版填充式玻璃拉條（照搬 collaborationSliderTrack）

/// 拉條的幾何與「放開後停在哪一檔」（照搬 collaborationSliderTrack 的算法；自測直接算它）。
struct TatwoComposerFilledTrackGeometry: Equatable {
    let count: Int
    let width: CGFloat

    var lastIndex: Int { max(count - 1, 0) }
    var segmentWidth: CGFloat { width / CGFloat(max(count, 1)) }
    var laneInset: CGFloat { segmentWidth / 2 }
    var laneWidth: CGFloat { max(1, width - segmentWidth) }
    var denominator: Int { max(count - 1, 1) }

    func ratio(of index: Int) -> CGFloat {
        count > 1 ? CGFloat(min(max(index, 0), lastIndex)) / CGFloat(denominator) : 0
    }

    /// #24：填充式——左邊固定，最少一格（第一檔），最多整條（最後一檔）；不是移動的小塊。
    func fillWidth(ratio: CGFloat) -> CGFloat {
        segmentWidth + min(max(ratio, 0), 1) * laneWidth
    }

    func index(nearest ratio: CGFloat) -> Int {
        min(max(Int((min(max(ratio, 0), 1) * CGFloat(denominator)).rounded()), 0), lastIndex)
    }

    func laneRatio(forLocalX x: CGFloat) -> CGFloat {
        min(max((x - laneInset) / laneWidth, 0), 1)
    }

    /// 拖動時記方向的最小距離。
    var directionSampleThreshold: CGFloat { min(CGFloat(0.01), CGFloat(1.5) / laneWidth) }

    /// 放開（或點一下）時停在哪一檔：離中點夠遠看位置；在中點附近的小帶子才看拖的方向——
    /// 快停下時一兩個像素的抖動不會跳一整檔（照舊的遲滯）。
    func target(forRelease ratio: CGFloat, dragDelta: CGFloat, direction: CGFloat) -> Int {
        let clampedRatio = min(max(ratio, 0), 1)
        let rawPosition = Double(clampedRatio) * Double(denominator)
        let releaseDirection = abs(direction) > 0 ? direction : dragDelta
        let lowerIndex = min(max(Int(floor(rawPosition)), 0), denominator)
        let upperIndex = min(lowerIndex + 1, denominator)
        let nearestIndex = min(max(Int(rawPosition.rounded()), 0), denominator)
        let segmentMidpoint = (CGFloat(lowerIndex) + 0.5) / CGFloat(denominator)
        let midpointHysteresis = min(CGFloat(0.04), CGFloat(5) / laneWidth)
        let minimumDirectionalTravel = min(CGFloat(0.03), CGFloat(3) / laneWidth)
        let hasDirectionalTravel = abs(dragDelta) >= minimumDirectionalTravel
        let targetIndex: Int
        if lowerIndex == upperIndex {
            targetIndex = lowerIndex
        } else if clampedRatio < segmentMidpoint - midpointHysteresis {
            targetIndex = lowerIndex
        } else if clampedRatio > segmentMidpoint + midpointHysteresis {
            targetIndex = upperIndex
        } else if hasDirectionalTravel, releaseDirection < 0 {
            // Direction only resolves the small midpoint band. Outside it, position wins,
            // so a near-stop one-pixel move cannot jump a full level.
            targetIndex = lowerIndex
        } else if hasDirectionalTravel, releaseDirection > 0 {
            targetIndex = upperIndex
        } else {
            targetIndex = nearestIndex
        }
        return min(max(targetIndex, 0), lastIndex)
    }
}

/// 舊版填充式玻璃拉條（使用者 09-30：「這是舊版的拉條」＝31 那張）：一整條玻璃軌道（#26），從左往右用 ultrawork 漸層填到目前那一檔（#24）；
/// 顏色跟著主題：極光＝粉紫藍，fable5＝和諧色階 珊瑚橘→鼠尾草綠→古金（TatwoActivePalette 的 accentPink／Violet／Blue）。
/// 填到的檔白字、沒填到的次要色。手感照舊（Apple Music 進度條式）：拖著走、放開後滑到最近的一檔（中點附近看拖的方向），點字母之間也一樣；
/// 值在放開的當下就寫回，只有拉條自己慢慢停好。滑鼠照舊由 ChatSliderPointerOverlay 接（本機事件監看，不擋底下的點擊）。
/// S～XXL、速度、推理強度、記憶都用它；每一檔另外是一個可按的無障礙元素（VoiceOver 一檔一檔按，識別碼例 ultrawork-mode-s）。
struct TatwoComposerFilledTrack: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let titles: [String]
    /// 目前那一檔（0 起算）；nil＝還沒開（ultrawork 關）：拉條淡淡的、字是次要色，點或拖就開到那一檔。
    let selectedIndex: Int?
    var isEnabled = true
    let metrics: TatwoComposerModeMetrics
    let identifiers: [String]
    let accessibilityLabel: String
    var help: String? = nil
    /// W184 H4 修正（審查 #6）：鍵盤停在這一條：外框亮起、keyStop 那一檔框起來（還沒按 Return，值不變）。
    var keyFocused = false
    var keyStop: Int? = nil
    let onCommit: @MainActor (Int) -> Void

    /// W184 H4 修正（審查 #4）：卡中間那一段在捲時的可視範圍；交給滑鼠監看，看不到的地方按下不接。
    @Environment(\.tatwoComposerModeViewport) private var viewport
    @State private var editing = false
    @State private var settling = false
    @State private var hovering = false
    @State private var visualRatio: CGFloat?
    @State private var dragStartRatio: CGFloat?
    @State private var dragDirection: CGFloat = 0
    @State private var settleGeneration = 0
    @State private var pendingIndex: Int?

    var body: some View {
        GeometryReader { proxy in
            let geometry = TatwoComposerFilledTrackGeometry(count: titles.count, width: max(1, proxy.size.width))
            track(geometry, height: proxy.size.height)
        }
        .frame(height: metrics.trackHeight)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(selectedIndex.flatMap { titles.indices.contains($0) ? titles[$0] : nil } ?? "關")
    }

    private func track(_ geometry: TatwoComposerFilledTrackGeometry, height: CGFloat) -> some View {
        let width = geometry.width
        let committedIndex = min(max(pendingIndex ?? selectedIndex ?? 0, 0), geometry.lastIndex)
        let ratio = min(max(visualRatio ?? geometry.ratio(of: committedIndex), 0), 1)
        let lit = selectedIndex != nil || editing || settling || pendingIndex != nil
        let visualIndex = geometry.index(nearest: ratio)
        let shape = RoundedRectangle(cornerRadius: metrics.trackRadius, style: LiquidGlassTokens.shapeStyle)
        return ZStack(alignment: .leading) {
            // #26：連續玻璃軌道底（整條完整玻璃，非只有選中小塊）。
            shape
                .fill(LiquidGlassTokens.ultraworkGradient)
                .opacity(lit ? 0.30 : 0.16)
                .overlay { shape.strokeBorder(LiquidGlassTokens.glassRimGradient, lineWidth: 1) }
                .frame(width: width, height: height)

            // #24：填充式玻璃滑軌——左錨定，寬度隨等級增長（S→XXL 從左往右越拉越長，非移動小塊）。
            shape
                .fill(LiquidGlassTokens.ultraworkGradient)
                .overlay { shape.strokeBorder(LiquidGlassTokens.glassRimGradient, lineWidth: 1) }
                .frame(width: geometry.fillWidth(ratio: ratio), height: height)
                .opacity(lit ? 1 : LiquidGlassTokens.tintOpacity)
                .shadow(
                    color: LiquidGlassTokens.brandAccent.opacity(
                        hovering ? LiquidGlassTokens.tintOpacity : LiquidGlassTokens.shadowOpacity),
                    radius: LiquidGlassTokens.shadowRadius,
                    x: LiquidGlassTokens.shadowOffsetX,
                    y: LiquidGlassTokens.shadowOffsetY)

            HStack(spacing: 0) {
                ForEach(Array(titles.enumerated()), id: \.offset) { entry in
                    // 被玻璃填到的等級（<= 當前）用白/主色，未填到用次要色，強化「越拉越長」填充感。
                    let filled = lit && entry.offset <= visualIndex
                    let isCurrent = lit && visualIndex == entry.offset
                    Text(entry.element)
                        .font(.system(size: metrics.stepSize,
                                      weight: isCurrent ? .black : (filled ? .heavy : .bold), design: .rounded))
                        .foregroundStyle(filled ? LiquidGlassTokens.browserInk : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(width: width, height: height)
        .contentShape(shape)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(editing ? nil : .easeInOut, value: ratio)
        .overlay(alignment: .leading) {
            if isEnabled {
                ChatSliderPointerOverlay(
                    onBegan: { localX in begin(geometry.laneRatio(forLocalX: localX)) },
                    onChanged: { localX in update(geometry.laneRatio(forLocalX: localX), geometry) },
                    onEnded: { localX in
                        let releaseRatio = geometry.laneRatio(forLocalX: localX)
                        update(releaseRatio, geometry)
                        commit(releaseRatio, geometry)
                    },
                    onCancelled: { cancel() },
                    pendingSettleActive: settling || pendingIndex != nil,
                    viewport: viewport)
                    .frame(width: width, height: height)
                    .accessibilityHidden(true)
                    .allowsHitTesting(true)
            }
        }
        .overlay { accessibilityStops }
        .overlay(alignment: .leading) {
            if keyFocused {
                ZStack(alignment: .leading) {
                    shape.strokeBorder(LiquidGlassTokens.brandAccent, lineWidth: 2)
                    if let keyStop, titles.indices.contains(keyStop) {
                        RoundedRectangle(cornerRadius: max(2, metrics.trackRadius - 4), style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.75), lineWidth: 1.5)
                            .frame(width: max(1, geometry.segmentWidth - 6), height: max(1, height - 8))
                            .offset(x: geometry.segmentWidth * CGFloat(keyStop) + 3)
                    }
                }
                .frame(width: width, height: height, alignment: .leading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.10)) { hovering = inside }
        }
        .help(help ?? accessibilityLabel)
    }

    /// 每一檔一個可按的無障礙元素（不接滑鼠；滑鼠交給上面的 pointer overlay）。
    private var accessibilityStops: some View {
        HStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { entry in
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .accessibilityElement()
                    .accessibilityLabel(entry.element)
                    .accessibilityAddTraits(selectedIndex == entry.offset ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier(identifiers.indices.contains(entry.offset) ? identifiers[entry.offset] : "")
                    .accessibilityAction {
                        guard isEnabled else { return }
                        onCommit(entry.offset)
                    }
            }
        }
        .allowsHitTesting(false)
    }

    private func begin(_ startRatio: CGFloat) {
        settleGeneration &+= 1
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            editing = true
            settling = false
            pendingIndex = nil
            dragStartRatio = startRatio
            dragDirection = 0
            // A new mouse-down owns a fresh visual start. Never inherit the previous settle position.
            visualRatio = startRatio
        }
    }

    private func update(_ currentRatio: CGFloat, _ geometry: TatwoComposerFilledTrackGeometry) {
        if dragStartRatio == nil {
            begin(currentRatio)
        }
        let startRatio = dragStartRatio ?? currentRatio
        let previousRatio = visualRatio ?? startRatio
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            let delta = currentRatio - previousRatio
            if abs(delta) >= geometry.directionSampleThreshold {
                dragDirection = delta
            }
            visualRatio = currentRatio
        }
    }

    private func commit(_ laneRatio: CGFloat, _ geometry: TatwoComposerFilledTrackGeometry) {
        let clampedRatio = min(max(laneRatio, 0), 1)
        let next = geometry.target(forRelease: clampedRatio,
                                   dragDelta: clampedRatio - (dragStartRatio ?? clampedRatio),
                                   direction: dragDirection)
        settleGeneration &+= 1
        let generation = settleGeneration
        let snappedRatio = geometry.ratio(of: next)
        let settleDistance = abs(snappedRatio - clampedRatio)
        // Apple Music progress-bar feel: the glass tracks the pointer directly, then glides into the selected stop
        // with a damped, short-travel settle — a "rubberized scrubber", not a segmented-control magnet or a toy bounce.
        let settleResponse = 0.68 + min(0.16, Double(settleDistance) * 0.34)
        let intermediateHold = 0.052
        let settleAnimation = Animation.easeInOut(duration: settleResponse)
        let settleDelay = intermediateHold + settleResponse + 0.34
        var releaseTransaction = Transaction()
        releaseTransaction.animation = nil
        withTransaction(releaseTransaction) {
            // 值在放開的當下就寫回（同舊版：下方角色格不落後將近一秒）；只有拉條本身保留緩動 settle。
            onCommit(next)
            editing = false
            settling = true
            pendingIndex = next
            // Keep the visible fill exactly where the user released or tapped first; the later snap travels from there.
            visualRatio = clampedRatio
            dragStartRatio = nil
            dragDirection = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + intermediateHold) {
            guard settleGeneration == generation, pendingIndex == next, settling else { return }
            withAnimation(settleAnimation) {
                visualRatio = snappedRatio
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
            guard settleGeneration == generation, pendingIndex == next, settling else { return }
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                pendingIndex = nil
                visualRatio = nil
                dragStartRatio = nil
                dragDirection = 0
                editing = false
                settling = false
            }
        }
    }

    private func cancel() {
        settleGeneration &+= 1
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            pendingIndex = nil
            visualRatio = nil
            dragStartRatio = nil
            dragDirection = 0
            editing = false
            settling = false
        }
    }
}

// MARK: - 卡浮在輸入框上方（私訊框、Bot Studio、Space 搭建；主視窗 Coder 照舊用 chatFloatingPanelOverlay）

/// 卡的下緣離輸入框（或工具列）上緣 gap、右緣對齊；點卡以外的地方收起（按在 chip 上不算：chip 自己開關），點擊照樣交給底下的東西。
/// W184 H4 修正（查核 #4）：anchor 可以不給——模式選擇 chip 自己墊了定位點（TatwoComposerModeChipAnchor），同一個視窗裡的都認得。
struct TatwoComposerModePopover<Card: View>: ViewModifier {
    @Binding var isPresented: Bool
    var anchor: AssistantModelMenuAnchor? = nil
    var gap: CGFloat = 8
    let card: () -> Card
    /// W184 H4 修正（審查 #6）：掛卡的那個輸入框（收卡後焦點交回它裡面的文字輸入）。
    @State private var host = TatwoComposerModeHostRef()

    func body(content: Content) -> some View {
        content
            .background(TatwoComposerModeHostMarker(ref: host))
            .overlay {
                if isPresented {
                    // 用 frame 的對齊擺（第一版的 alignmentGuide 在 overlay 裡沒有生效，自測 PNG 看到卡掛在下面）：
                    // 高 0、寬＝輸入框寬的框貼在輸入框上緣，卡照 bottomTrailing 對齊＝卡的下緣、右緣貼著那一點往上長；再往上移 gap。
                    GeometryReader { proxy in
                        card()
                            // W184 H4 修正（審查 #6）：卡的 Esc 收起（鍵盤監看在卡裡；私訊框的 routeEscape 也是先收卡）。
                            .environment(\.tatwoComposerModeDismiss,
                                         TatwoComposerModeDismiss(action: { isPresented = false }, isPresented: { isPresented }))
                            .fixedSize(horizontal: false, vertical: true)
                            .background(TatwoComposerModeClickAway(anchor: anchor) { isPresented = false })
                            .frame(width: proxy.size.width, height: 0, alignment: .bottomTrailing)
                            .offset(y: -gap)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                }
            }
            // 收卡後焦點回輸入框（Esc、chip、點卡外、按了送出都是；剛剛點到別的輸入的地方就不搶）。
            .onChange(of: isPresented) { was, now in
                if was && !now { host.restoreFocusSoon() }
            }
    }
}

extension View {
    /// W184 H4：模式卡（開關由呼叫端的 chip 管；anchor＝chip 的位置，點 chip 不算「點外面」；不給也行，見 TatwoComposerModeChipAnchor）。
    func tatwoComposerModeCard<Card: View>(isPresented: Binding<Bool>, anchor: AssistantModelMenuAnchor? = nil, gap: CGFloat = 8,
                                          @ViewBuilder card: @escaping () -> Card) -> some View {
        modifier(TatwoComposerModePopover(isPresented: isPresented, anchor: anchor, gap: gap, card: card))
    }
}

/// 點卡以外的地方收起卡：本機事件監看（同 ChatSliderPointerCaptureView 的做法），不吃事件；只畫在卡的底下、不接點擊。
struct TatwoComposerModeClickAway: NSViewRepresentable {
    let anchor: AssistantModelMenuAnchor?
    let onClickAway: () -> Void

    func makeNSView(context: Context) -> TatwoComposerModeClickAwayView {
        let view = TatwoComposerModeClickAwayView()
        view.anchor = anchor
        view.onClickAway = onClickAway
        return view
    }

    func updateNSView(_ view: TatwoComposerModeClickAwayView, context: Context) {
        view.anchor = anchor
        view.onClickAway = onClickAway
    }

    static func dismantleNSView(_ view: TatwoComposerModeClickAwayView, coordinator: ()) {
        view.stop()
    }
}

final class TatwoComposerModeClickAwayView: NSView {
    var anchor: AssistantModelMenuAnchor?
    var onClickAway: (() -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else { start() }
    }

    private func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    isolated deinit {
        stop()
    }

    private func handle(_ event: NSEvent) {
        guard let window, let onClickAway else { return }
        let point = event.window === window ? event.locationInWindow : nil
        var chips = TatwoComposerModeChipAnchorView.frames(in: window)
        if let anchorRect = anchor?.view.flatMap({ $0.window === window ? $0.convert($0.bounds, to: nil) : nil }) {
            chips.append(anchorRect)
        }
        guard Self.shouldClose(click: point, card: convert(bounds, to: nil), chips: chips) else { return }
        DispatchQueue.main.async { onClickAway() }
    }

    /// 點在別的視窗（point 是 nil）＝收；點在卡上、點在任何一顆模式選擇 chip 上＝不收（chip 自己開關）；其他地方＝收。
    static func shouldClose(click point: NSPoint?, card: NSRect, chips: [NSRect]) -> Bool {
        guard let point else { return true }
        if card.contains(point) { return false }
        return !chips.contains { $0.contains(point) }
    }
}

/// W184 H4 修正（查核 #4、#12）：每一顆模式選擇 chip 墊在自己底下的定位點（不畫東西、不接點擊）。點卡以外的地方收卡時，按在同一個
/// 視窗裡任何一顆模式選擇 chip 上都不算「外面」（chip 自己開關——不會先被收掉、又被 chip 打開）；自測用它找 chip 在哪、真的去點。
struct TatwoComposerModeChipAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> TatwoComposerModeChipAnchorView { TatwoComposerModeChipAnchorView() }
    func updateNSView(_ view: TatwoComposerModeChipAnchorView, context: Context) {}
}

final class TatwoComposerModeChipAnchorView: NSView {
    private static let live = NSHashTable<TatwoComposerModeChipAnchorView>.weakObjects()

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { Self.live.remove(self) } else { Self.live.add(self) }
    }

    /// 這個視窗裡每一顆模式選擇 chip 的位置（視窗座標）。
    static func frames(in window: NSWindow) -> [NSRect] {
        live.allObjects.compactMap { $0.window === window ? $0.convert($0.bounds, to: nil) : nil }
    }
}

// MARK: - 私訊框的包裝（對象是助理或 Coder session；ChatGPT 對象的輸入框照 ChatGPT 原版，不在這裡）

/// 私訊框的「模式選擇」chip：看 store、那台的 model（記憶強度、模型）、別台記憶的暫存，值一變摘要就跟著變。
struct GlobalDMModeChip: View {
    @ObservedObject var store: GlobalDMStore
    @Binding var isOpen: Bool
    let anchor: AssistantModelMenuAnchor

    var body: some View {
        if let model = store.model {
            GlobalDMModeObserver(model: model) { chip }
        } else {
            chip
        }
    }

    @ViewBuilder
    private var chip: some View {
        if let mode = TatwoComposerMode.dm(store: store) {
            ChatComposerModeChip(segments: mode.segments, selected: isOpen, style: .dmPhone, help: mode.help) {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) { isOpen.toggle() }
            }
            .background(AssistantModelMenuAnchorView(anchor: anchor))
            .layoutPriority(1)
        }
    }
}

/// 私訊框的模式卡（手機尺寸）。
struct GlobalDMModeCard: View {
    @ObservedObject var store: GlobalDMStore

    var body: some View {
        if let model = store.model {
            GlobalDMModeObserver(model: model) { card }
        } else {
            card
        }
    }

    @ViewBuilder
    private var card: some View {
        if let mode = TatwoComposerMode.dm(store: store) {
            TatwoComposerModeCard(mode: mode, metrics: .dmPhone)
        }
    }
}

/// 只為了在 ChatPageModel（記憶強度、模型選擇）與別台記憶暫存變的時候重畫裡面（同原本記憶 chip 看的東西）。
private struct GlobalDMModeObserver<Content: View>: View {
    @ObservedObject var model: ChatPageModel
    @ObservedObject private var pending = TatwoMemoryStrengthPending.shared
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}
