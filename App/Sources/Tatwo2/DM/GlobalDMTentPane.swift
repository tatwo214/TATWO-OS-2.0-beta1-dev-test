import AppKit
import SwiftUI

// W184 E（使用者 09-29：「倒放 預設作為影片子畫面」；對照稿 Tent-Video／Tent-Approve／Tent-Reply／Tent-Code；
// 施工單 briefs/w184-e-tent.md 第 10–12 條）：倒放框的畫面。
// - 有影片：整塊是那個 Browser 分頁的頁面（DMTentVideo 借來的 CEF 畫面，沒有頂列）；滑鼠移入才浮出
//   「<網域>・Browser 分頁」「回到 Browser」「關掉子畫面」（鈕 44、玻璃、掛 BrowserChromeHitLayer 讓 CEF 讓出點擊）。
// - 沒有影片：一句話＋一顆鈕（「Browser 沒有在播影片」＋「打開 Browser」）。
// - 有事時蓋上來（等你核准 ＞ 配對進行中 ＞ 回覆中；事情結束回到影片）：卡片蓋著時影片藏在下面、聲音照播。
//   核准仍在 Island（D54）；配對卡只讀到期時間，倒放框裡不顯示配對碼（碼只在綁住的那一頁看得到時顯示）。
// - 不持有 WindowCaptureShield（框裡沒有敏感內容）。
// 數值從 DMPhone 組（DMTentLayout）；字級只用 17／15／13／11；顏色照 GlobalDMPalette 的規則用玻璃 token 與系統語意色。

// MARK: - 版面（從 DMPhone 的 token 組出來）

enum DMTentLayout {
    /// 滑鼠移入的控制列：上 18（頂列上緣 14＋圓鈕列裁切邊 4）、左右 20（內螢幕留白）、鈕與鈕之間 8。
    static let controlsTop: CGFloat = DMPhone.headerTop + DMPhone.Strip.inset
    static let controlsSide: CGFloat = DMPhone.wideMargin
    static let controlsSpacing: CGFloat = DMPhone.Strip.spacing
    /// 蓋上來的卡（對照稿內距 36／36／34、兩欄間距 28、右欄 220 寬、鈕與鈕之間 14、字與字之間 10）。
    static let cardPadding: CGFloat = DMPhone.wideMargin + DMPhone.margin
    static let cardGap: CGFloat = DMPhone.wideMargin + DMPhone.Strip.spacing
    static let cardButtonWidth: CGFloat = DMPhone.touch * 5
    static let cardButtonSpacing: CGFloat = DMPhone.headerTop
    static let cardTextSpacing: CGFloat = DMPhone.headerBottom
    /// 標頭圖示與字之間。
    static let iconSpacing: CGFloat = DMPhone.Strip.spacing
    /// 空狀態：圖示、一句話、一顆鈕之間。
    static let emptySpacing: CGFloat = DMPhone.headerTop
    /// 回覆預覽最多幾行（施工單：兩三行）；取最後這麼多字。
    static let previewLines = 3
    static let previewCharacters = 180
}

// MARK: - 有事時蓋上來的卡（純資料，好測）

enum DMTentCardAction: String, CaseIterable, Identifiable, Sendable {
    case approveInIsland, later, openPairing, stop, openBox

    var id: String { rawValue }

    var title: String {
        switch self {
        case .approveInIsland: "到 Island 核准"
        case .later: "稍後"
        case .openPairing: "打開配對頁"
        case .stop: "停止"
        case .openBox: "打開私訊框"
        }
    }

    var identifier: String {
        switch self {
        case .approveInIsland: "tatwo.dm.tent.card.approval.island"
        case .later: "tatwo.dm.tent.card.approval.later"
        case .openPairing: "tatwo.dm.tent.card.pairing.open"
        case .stop: "tatwo.dm.tent.card.reply.stop"
        case .openBox: "tatwo.dm.tent.card.reply.open"
        }
    }

    enum Style: Sendable { case accent, glass, stop }

    var style: Style {
        switch self {
        case .approveInIsland, .openPairing: .accent
        case .stop: .stop
        case .later, .openBox: .glass
        }
    }
}

enum DMTentCard: Equatable, Sendable {
    /// 等你核准（這個對象的工具在等核准；核准本身只在 Island）。
    case approval(target: String)
    /// 配對進行中（只帶剩幾秒；不帶配對碼）。
    case pairing(remaining: TimeInterval)
    /// 對象回覆中（最新一段預覽）。
    case reply(target: String, preview: String)

    /// 優先序：等你核准 ＞ 配對進行中 ＞ 回覆中；都沒有＝回到影片。「稍後」只收這一次的核准（核准結束就重置）。
    static func resolve(approval: Bool, approvalSnoozed: Bool, pairingExpiresAt: Date?, running: Bool,
                        target: String, preview: String, now: Date) -> DMTentCard? {
        if approval, !approvalSnoozed { return .approval(target: target) }
        if let expires = pairingExpiresAt, expires > now { return .pairing(remaining: expires.timeIntervalSince(now)) }
        if running { return .reply(target: target, preview: preview) }
        return nil
    }

    /// 配對進行中只讀到期時間：配對碼只在綁住的那一頁看得到時顯示，倒放框裡不顯示（防釣魚）。
    static func pairingExpiry(_ card: HandsConnectCard?) -> Date? {
        guard case .pairing(let view) = card else { return nil }
        return view.expiresAt
    }

    /// 剩 m:ss。
    static func remainingText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 回覆預覽：最新那一則回覆的最後一段（換行、連續空白收成一個空白）。
    static func preview(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > DMTentLayout.previewCharacters else { return flat }
        return "…" + flat.suffix(DMTentLayout.previewCharacters)
    }

    var icon: String {
        switch self {
        case .approval: "hand.raised"
        case .pairing: "lock"
        case .reply: "ellipsis.bubble"
        }
    }

    var header: String {
        switch self {
        case .approval: "等你核准"
        case .pairing(let remaining): "配對進行中・剩 \(Self.remainingText(remaining))"
        case .reply(let target, _): "\(target)・回覆中"
        }
    }

    var body: String {
        switch self {
        case .approval(let target): "\(target) 有一個動作要你核准"
        case .pairing: "碼只在配對頁上顯示"
        case .reply(_, let preview): preview.isEmpty ? "正在想…" : preview
        }
    }

    var footnote: String? {
        switch self {
        case .approval: "核准只在 Island"
        case .pairing, .reply: nil
        }
    }

    var actions: [DMTentCardAction] {
        switch self {
        case .approval: [.approveInIsland, .later]
        case .pairing: [.openPairing]
        case .reply: [.stop, .openBox]
        }
    }

    var identifier: String {
        switch self {
        case .approval: "tatwo.dm.tent.card.approval"
        case .pairing: "tatwo.dm.tent.card.pairing"
        case .reply: "tatwo.dm.tent.card.reply"
        }
    }

    /// 卡上看得到的所有字（自測核對：配對卡的字裡沒有碼）。
    var allText: [String] { [header, body] + (footnote.map { [$0] } ?? []) + actions.map(\.title) }
}

/// 空狀態那一句話與那一顆鈕。
enum DMTentEmpty {
    static func text(playingElsewhere: Bool) -> String {
        playingElsewhere ? "影片在 Browser 分頁播放" : "Browser 沒有在播影片"
    }
    static let buttonTitle = "打開 Browser"
}

/// 滑鼠移入的控制列上的字。
enum DMTentControlsText {
    static func source(host: String?) -> String { host.map { "\($0)・Browser 分頁" } ?? "Browser 分頁" }
    static let back = "回到 Browser"
    static let dismiss = "關掉子畫面"
}

// MARK: - 倒放框

/// 倒放框（GlobalDMTentContent 放這個）：底下是影片的原生容器（一直在，identity 不變），上面依狀態疊控制列／空狀態／卡。
struct GlobalDMTentPane: View {
    @ObservedObject var store: GlobalDMStore
    @ObservedObject var model: ChatPageModel
    @ObservedObject var video: DMTentVideo
    @ObservedObject private var hands = HandsConnectFlow.shared
    /// 自測畫面證據用：控制列固定浮出。
    var forceControls = false
    @StateObject private var hover = DMTentHover()
    @Environment(\.globalDMScreenRadius) private var radius
    /// ［連線］卡蓋在整支手機上時影片也藏起來（原生畫面會蓋住 SwiftUI 的卡、吃掉點擊）。
    @Environment(\.globalDMWebSheetActive) private var webSheetActive
    @State private var cardShowing = false

    init(store: GlobalDMStore, model: ChatPageModel, video: DMTentVideo, forceControls: Bool = false) {
        self.store = store
        self.model = model
        self.video = video
        self.forceControls = forceControls
    }

    var body: some View {
        ZStack {
            DMTentVideoSurface(video: video, hover: hover, covered: cardShowing || webSheetActive, radius: radius)
            // W184 G1b：倒放沒有頂列：上緣那一條＝拖曳區，在影片上面、在控制列與卡的底下（W184 AB：不畫把手，靠游標）。
            GlobalDMTentGrabBand()
            // 1 秒重算一次（配對倒數、ChatGPT 回覆中這些不經過 model 的狀態）；影片容器在外面，不跟著重建。
            TimelineView(.periodic(from: .now, by: 1)) { context in
                overlay(card: card(now: context.date))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(video.shown != nil && !cardShowing ? Color.black : Color.clear)
        .onChange(of: store.isAwaitingApproval) { _, waiting in
            if !waiting, video.approvalSnoozed { video.approvalSnoozed = false }
        }
    }

    private func card(now: Date) -> DMTentCard? {
        let approval = store.isAwaitingApproval
        let pairing = DMTentCard.pairingExpiry(hands.card)
        let running = store.isRunning
        // 沒事就不去算對象名稱與預覽（每秒都會算一次）。
        guard (approval && !video.approvalSnoozed) || (pairing.map { $0 > now } ?? false) || running else { return nil }
        return DMTentCard.resolve(approval: approval, approvalSnoozed: video.approvalSnoozed, pairingExpiresAt: pairing,
                                  running: running, target: store.title(for: store.target),
                                  preview: running ? replyPreview() : "", now: now)
    }

    @ViewBuilder
    private func overlay(card: DMTentCard?) -> some View {
        Group {
            if let card {
                DMTentCardView(card: card, perform: perform)
            } else if let shown = video.shown {
                if hover.inside || forceControls {
                    DMTentControls(source: DMTentControlsText.source(host: shown.host),
                                   back: { video.backToBrowser() }, dismiss: { video.dismiss() })
                        .transition(.opacity)
                }
            } else if video.entering || video.leaving {
                // 轉進倒放、走完就會收影片：先放黑底，不閃空狀態那句；W184 F／G1（查證 #8）：帶著影片離開倒放的淡出那一小段也是
                Color.black
            } else {
                DMTentEmptyView(playingElsewhere: video.playingElsewhere) { video.openBrowser() }
            }
        }
        .onChange(of: card != nil, initial: true) { _, showing in
            if cardShowing != showing { cardShowing = showing }
        }
    }

    /// 最新那一則回覆（助理、這條 session、ChatGPT）的最後一段。
    private func replyPreview() -> String {
        let bubbles: [GlobalDMBubble]
        switch store.target {
        case .assistant: bubbles = GlobalDMBubble.rows(model.assistantMessages)
        case .thread(let id): bubbles = GlobalDMBubble.rows(model.dmTranscript(for: id))
        case .chatGPT: bubbles = GlobalDMBubble.rows(store.chatGPT.messages, answering: false)
        }
        return DMTentCard.preview(bubbles.last { $0.kind == .theirs }?.text ?? "")
    }

    private func perform(_ action: DMTentCardAction) {
        switch action {
        case .approveInIsland:
            store.revealApprovalInIsland()   // 核准仍在 Island（D54），這裡只帶過去
        case .later:
            video.approvalSnoozed = true
        case .openPairing:
            // 回到有 Browser 的形態，把配對分頁叫到前面：碼在那一頁照常顯示（倒放框裡不顯示）。
            GlobalDMDeskController.shared.setForm(.outerPortrait)
            DMBrowser.shared.revealConnectTab()
        case .stop:
            store.stop()
        case .openBox:
            // W184 審查（房 AB #4）：走 showContent——轉換中排隊、倒放先立起到外直，不會因為正在轉換就被拒掉。
            GlobalDMDeskController.shared.showContent {
                store.isBrowsing = false   // 打開的是對話（不是 Browser 那一頁）
            }
        }
    }
}

// MARK: - 影片的原生容器（一直在；有卡蓋著時影片藏在下面）

struct DMTentVideoSurface: NSViewRepresentable {
    let video: DMTentVideo
    let hover: DMTentHover
    let covered: Bool
    let radius: CGFloat

    func makeNSView(context: Context) -> DMTentVideoContainer {
        let container = DMTentVideoContainer(frame: .zero)
        container.video = video
        container.hover = hover
        container.covered = covered
        container.cornerRadius = radius
        video.claim(container)
        return container
    }

    func updateNSView(_ container: DMTentVideoContainer, context: Context) {
        container.hover = hover
        container.covered = covered
        container.cornerRadius = radius
    }

    static func dismantleNSView(_ container: DMTentVideoContainer, coordinator: ()) {
        container.hover?.detach()
        container.video?.release(container)
    }
}

// MARK: - 滑鼠移入的控制列

struct DMTentControls: View {
    let source: String
    let back: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DMTentLayout.controlsSpacing) {
                HStack(spacing: DMTentLayout.iconSpacing) {
                    Image(systemName: "globe")
                        .font(.system(size: DMPhone.TextSize.footnote, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(source)
                        .font(.system(size: DMPhone.TextSize.footnote, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, DMPhone.edgeInset)
                .frame(height: DMPhone.chipHeight)
                .background(GlobalDMGlassCapsule())
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("tatwo.dm.tent.source")
                Spacer(minLength: DMTentLayout.controlsSpacing)
                Button(action: back) {
                    Text(DMTentControlsText.back)
                        .font(.system(size: DMPhone.TextSize.secondary, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .padding(.horizontal, DMPhone.margin)
                        .frame(height: DMPhone.touch)
                        .background(GlobalDMGlassCapsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .background(BrowserChromeHitLayer())
                .help("回到主視窗的 Browser 分頁")
                .accessibilityLabel(DMTentControlsText.back)
                .accessibilityIdentifier("tatwo.dm.tent.backToBrowser")
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: DMPhone.TextSize.secondary, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.78))
                        .frame(width: DMPhone.touch, height: DMPhone.touch)
                        .background(GlobalDMGlassCircle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .background(BrowserChromeHitLayer())
                .help("關掉子畫面（影片回到 Browser 分頁繼續播）")
                .accessibilityLabel(DMTentControlsText.dismiss)
                .accessibilityIdentifier("tatwo.dm.tent.dismiss")
            }
            .padding(.top, DMTentLayout.controlsTop)
            .padding(.horizontal, DMTentLayout.controlsSide)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo.dm.tent.controls")
    }
}

// MARK: - 空狀態

struct DMTentEmptyView: View {
    let playingElsewhere: Bool
    let open: () -> Void

    var body: some View {
        VStack(spacing: DMTentLayout.emptySpacing) {
            Image(systemName: "play.rectangle")
                .font(.system(size: DMPhone.TextSize.body, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(DMTentEmpty.text(playingElsewhere: playingElsewhere))
                .font(.system(size: DMPhone.TextSize.body, weight: .semibold))
                .multilineTextAlignment(.center)
            Button(action: open) {
                Text(DMTentEmpty.buttonTitle)
                    .font(.system(size: DMPhone.TextSize.secondary, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, DMPhone.wideMargin)
                    .frame(minWidth: DMPhone.touch * 2, minHeight: DMPhone.touch)
                    .background(GlobalDMGlassCapsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(DMTentEmpty.buttonTitle)
            .accessibilityIdentifier("tatwo.dm.tent.openBrowser")
        }
        .padding(DMTentLayout.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo.dm.tent.empty")
    }
}

// MARK: - 有事時蓋上來的卡

struct DMTentCardView: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let card: DMTentCard
    let perform: (DMTentCardAction) -> Void

    init(card: DMTentCard, perform: @escaping (DMTentCardAction) -> Void) {
        self.card = card
        self.perform = perform
    }

    /// 停止：同私訊框的停止鈕（極光用系統紅，fable5 用品牌色）。
    private var stopTint: Color {
        TatwoActivePalette.current.usesGlass ? Color(nsColor: .systemRed) : LiquidGlassTokens.brandAccent
    }

    var body: some View {
        HStack(alignment: .center, spacing: DMTentLayout.cardGap) {
            VStack(alignment: .leading, spacing: DMTentLayout.cardTextSpacing) {
                HStack(spacing: DMTentLayout.iconSpacing) {
                    Image(systemName: card.icon).accessibilityHidden(true)
                    Text(card.header).lineLimit(1)
                }
                .font(.system(size: DMPhone.TextSize.secondary, weight: .semibold))
                .foregroundStyle(LiquidGlassTokens.brandAccent)
                Text(card.body)
                    .font(.system(size: DMPhone.TextSize.body, weight: .semibold))
                    .lineLimit(DMTentLayout.previewLines)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
                if let footnote = card.footnote {
                    Text(footnote)
                        .font(.system(size: DMPhone.TextSize.footnote))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            VStack(spacing: DMTentLayout.cardButtonSpacing) {
                ForEach(card.actions) { action in
                    Button { perform(action) } label: { label(action) }
                        .buttonStyle(.plain)
                        .background(BrowserChromeHitLayer())
                        .accessibilityLabel(action.title)
                        .accessibilityIdentifier(action.identifier)
                }
            }
            .frame(width: DMTentLayout.cardButtonWidth)
        }
        .padding(DMTentLayout.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(card.identifier)
    }

    @ViewBuilder
    private func label(_ action: DMTentCardAction) -> some View {
        let text = Text(action.title)
            .font(.system(size: DMPhone.TextSize.secondary, weight: .semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: DMPhone.touch)
            .contentShape(Capsule())
        switch action.style {
        case .accent:
            text.foregroundStyle(.white).background(Capsule().fill(LiquidGlassTokens.brandAccent))
        case .stop:
            text.foregroundStyle(.white)
                .background(Capsule().fill(LinearGradient(colors: [stopTint, stopTint.opacity(0.78)], startPoint: .top, endPoint: .bottom)))
        case .glass:
            text.foregroundStyle(.primary).background(GlobalDMGlassCapsule())
        }
    }
}
