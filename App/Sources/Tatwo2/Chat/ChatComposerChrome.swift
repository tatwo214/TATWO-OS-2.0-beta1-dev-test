import SwiftUI

/// Shared Chat chrome only. Actions and state remain owned by the caller;
/// rendering this file never creates a Chat model, engine or persistent store.
struct ChatComposerToolbarRow<Content: View>: View {
    let compact: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if DEBUG
        let _ = ChatRenderProbe.record("ChatComposerToolbarRow.body")
        #endif
        HStack(spacing: compact ? 7 : 9, content: content)
            .frame(height: 28)
    }
}

struct ChatComposerPermissionLabel: View {
    let symbol: String
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
            Text(title).font(.caption2.weight(.black)).lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .black)).opacity(0.82)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .frame(height: 24)
        .contentShape(Capsule())
    }
}

struct ChatComposerModelLabel: View {
    let title: String
    let suffix: String?
    let compact: Bool
    let selected: Bool

    static func width(compact: Bool) -> CGFloat { compact ? 90 : 110 }

    var body: some View {
        HStack(spacing: compact ? 4 : 5) {
            Text(title)
                .font(.caption2.weight(.black))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: compact ? 38 : 63, alignment: .leading)
            if let suffix {
                Text(suffix)
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .lineLimit(1)
                    .frame(width: 24, alignment: .center)
            } else {
                Color.clear.frame(width: 24, height: 1)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .black))
        }
        .padding(.horizontal, compact ? 5 : 7)
        .frame(width: Self.width(compact: compact), height: 24)
        .chatGlassChip(isSelected: selected)
        .contentShape(RoundedRectangle(
            cornerRadius: LiquidGlassTokens.radiusChip,
            style: LiquidGlassTokens.shapeStyle))
    }
}

struct ChatComposerCollaborationLabel: View {
    let compact: Bool
    let active: Bool
    let level: String
    let selected: Bool

    static func width(compact: Bool) -> CGFloat { compact ? 116 : 126 }

    var body: some View {
        HStack(spacing: compact ? 5 : 7) {
            Image(systemName: active ? "point.3.connected.trianglepath.dotted" : "target")
                .font(.system(size: 10, weight: .semibold))
            Text("ultrawork")
                .font(.caption2.weight(.semibold))
                .frame(width: compact ? 50 : 56, alignment: .leading)
                .lineLimit(1)
            Text(active ? level : "XL")
                .font(.system(size: 9, weight: .black, design: .rounded))
                .lineLimit(1)
                .frame(width: 18)
                .opacity(active ? 1 : 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .black))
        }
        .padding(.horizontal, compact ? 7 : 9)
        .frame(width: Self.width(compact: compact), height: 24)
        .chatGlassChip(isSelected: selected || active, tint: LiquidGlassTokens.brandAccent)
        .contentShape(RoundedRectangle(
            cornerRadius: LiquidGlassTokens.radiusChip,
            style: LiquidGlassTokens.shapeStyle))
    }
}

// MARK: - W184 H4：模式選擇 chip（記憶、模型、ultrawork、速度收進一顆；主視窗、私訊框、Bot Studio、Space 搭建共用）

/// 「模式選擇」chip：一顆玻璃 chip，裡面依序是 模型（含速度或推理強度）・記憶・ultrawork 的簡稱（TatwoComposerMode.Segment）。
/// 每一段各自是一個可按的無障礙元素，沿用舊 chip 的識別碼（例：tatwo.dm.model、tatwo-memory-strength）；按哪一段、按 chip 的空白處
/// 都打開同一張模式卡。整顆 chip 的識別碼是 tatwo.composer.mode。窄的時候縮短（「6 fast・記憶淺・ultrawork S」→「6・記淺・◎S」：
/// W184 H4 修正（查核 #6）圖示照樣畫、記憶寫「記淺」、關著的 ultrawork 只剩淡圖示——縮了還看得出哪一段是什麼）。
/// 主視窗照 Coder 模型 chip 的尺寸（24 高、chatGlassChip）；私訊框照手機 token（32 高膠囊、13／11pt，GlobalDMChatLayout）。
struct ChatComposerModeChip: View {
    enum Style { case main, dmPhone }

    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let segments: [TatwoComposerMode.Segment]
    let selected: Bool
    var style: Style = .main
    var help = ""
    let action: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(short: false)
            row(short: true)
        }
        // W184 H4 修正（查核 #4、#12）：chip 自己墊一個定位點：點卡以外的地方收卡時，按在 chip 上不算（chip 自己開關）；自測照它真的去點。
        .background(TatwoComposerModeChipAnchor())
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("模式選擇")
        .accessibilityIdentifier(TatwoComposerMode.identifier)
        .help(help)
    }

    private func row(short: Bool) -> some View {
        let visible = segments.filter { !(short ? $0.short : $0.text).isEmpty || $0.icon != nil }
        return HStack(spacing: style == .main ? 3 : 4) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { item in
                if item.offset > 0 {
                    Text("・")
                        .font(textFont)
                        .foregroundStyle(style == .main ? ChatGlassChipModifier.chipForeground : Color.secondary)
                        .accessibilityHidden(true)
                }
                Button(action: action) { label(item.element, short: short) }
                    .buttonStyle(ChatGlassChipButtonStyle())
                    .accessibilityLabel(item.element.accessibilityLabel)
                    .accessibilityHint("打開模式選擇")
                    .accessibilityIdentifier(item.element.identifier)
            }
            Image(systemName: "chevron.down")
                .font(style == .main
                    ? .system(size: 8, weight: .black)
                    : .system(size: GlobalDMChatLayout.captionSize, weight: .semibold))
                .foregroundStyle(style == .main ? ChatGlassChipModifier.chipForeground : Color.secondary)
                .accessibilityHidden(true)
        }
        .fixedSize()
        .modifier(ChatComposerModeChipSurface(style: style, selected: selected))
    }

    private func label(_ segment: TatwoComposerMode.Segment, short: Bool) -> some View {
        let text = short ? segment.short : segment.text
        return HStack(spacing: 3) {
            if let icon = segment.icon {
                Image(systemName: icon)
                    .font(style == .main
                        ? .system(size: 10, weight: .semibold)
                        : .system(size: GlobalDMChatLayout.captionSize, weight: .semibold))
            }
            if !text.isEmpty {
                Text(text)
                    .font(segment.id == "model" ? modelFont : textFont)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(color(segment))
        .contentShape(Rectangle())
    }

    private var modelFont: Font {
        style == .main ? .caption2.weight(.black) : .system(size: GlobalDMChatLayout.footnoteSize, weight: .medium)
    }

    private var textFont: Font {
        style == .main ? .caption2.weight(.semibold) : .system(size: GlobalDMChatLayout.footnoteSize)
    }

    /// 模型＝主色；記憶＝次要色；ultrawork 開著＝強調色、關著或現在不能選＝淡。
    private func color(_ segment: TatwoComposerMode.Segment) -> Color {
        if style == .main { return ChatGlassChipModifier.chipForeground }
        if segment.emphasized { return LiquidGlassTokens.brandAccent }
        if segment.dimmed { return Color.secondary.opacity(0.72) }
        return segment.id == "model" ? Color.primary : Color.secondary
    }
}

/// 模式選擇 chip 的底：主視窗＝同模型 chip 的玻璃 chip（開著卡＝選取樣子）；私訊框＝同記憶、模型 chip 的玻璃膠囊（開著卡加一圈強調色細框）。
private struct ChatComposerModeChipSurface: ViewModifier {
    let style: ChatComposerModeChip.Style
    let selected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        switch style {
        case .main:
            content
                .padding(.horizontal, 8)
                .frame(height: 24)
                .chatGlassChip(isSelected: selected)
        case .dmPhone:
            content
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .frame(height: GlobalDMChatLayout.chipHeight)
                .background(GlobalDMGlassCapsule())
                .overlay {
                    if selected {
                        Capsule().strokeBorder(LiquidGlassTokens.brandAccent.opacity(0.55), lineWidth: 1)
                    }
                }
        }
    }
}

struct ChatComposerSendButton: View {
    let enabled: Bool
    /// W179 UI：私訊框自己用 Return 送出；多個私訊框同時開著時 ⌘↩ 不該被其中一個搶走。Coder 照舊。
    var usesCommandReturn = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(enabled ? .white : .secondary)
                .frame(width: 28, height: 28)
        }
        .keyboardShortcut(usesCommandReturn ? KeyboardShortcut(.return, modifiers: [.command]) : nil)
        .disabled(!enabled)
        .buttonStyle(.plain)
        .background {
            Circle().fill(enabled
                ? AnyShapeStyle(LiquidGlassTokens.ultraworkGradient)
                : AnyShapeStyle(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.chipFillOpacity)))
        }
        .overlay {
            Circle().strokeBorder(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.strokeOpacity))
        }
        .shadow(
            color: LiquidGlassTokens.brandAccent.opacity(enabled ? LiquidGlassTokens.shadowOpacity : .zero),
            radius: LiquidGlassTokens.shadowRadius,
            x: LiquidGlassTokens.shadowOffsetX,
            y: LiquidGlassTokens.shadowOffsetY)
    }
}

// MARK: - W179 UI：TATWO 與私訊框共用的輸入框小元件（外觀逐字照 Coder；Coder 自己那份不動）

/// 停止鈕：同 Coder 輸入框的停止鈕（ChatPage+Composer.swift 的 composerStopButton）。
struct ChatComposerStopButton: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let action: () -> Void

    /// 極光的 brandAccent 是紫色、沒有停止的意思，改用系統紅；fable5 照舊用 brandAccent。
    private var tint: Color {
        TatwoActivePalette.current.usesGlass
            ? Color(nsColor: .systemRed)
            : LiquidGlassTokens.brandAccent
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.fill")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .background {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [tint, tint.opacity(0.78)],
                        startPoint: .top,
                        endPoint: .bottom))
        }
        .overlay {
            Circle()
                .strokeBorder(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.strokeOpacity))
        }
        .shadow(
            color: tint.opacity(LiquidGlassTokens.shadowOpacity),
            radius: LiquidGlassTokens.shadowRadius,
            x: LiquidGlassTokens.shadowOffsetX,
            y: LiquidGlassTokens.shadowOffsetY)
        .help("停止")
    }
}

/// 輸入框下方狀態抽屜的語氣：沒字（quiet）、一般說明（info）、提醒（hint）、進行中（working）、要注意（warning）。
enum ChatComposerStatusTone: Equatable, Sendable {
    case quiet, info, hint, working, warning
}

/// 微倒梯形（頂寬、底稍窄）：上緣切平，只圓下緣兩角。幾何同 Coder 輸入框下的狀態抽屜。
struct ChatComposerStatusDrawerShape: Shape {
    var sideSlope: CGFloat = 5
    var cornerRadius: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        let pts = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX - sideSlope, y: rect.maxY),
            CGPoint(x: rect.minX + sideSlope, y: rect.maxY),
        ]
        func unit(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
            let dx = to.x - from.x, dy = to.y - from.y
            let len = Swift.max(0.0001, (dx * dx + dy * dy).squareRoot())
            return CGPoint(x: dx / len, y: dy / len)
        }
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = a.x - b.x, dy = a.y - b.y
            return (dx * dx + dy * dy).squareRoot()
        }
        var path = Path()
        let n = pts.count
        for i in 0..<n {
            let curr = pts[i]
            let prev = pts[(i - 1 + n) % n]
            let next = pts[(i + 1) % n]
            let r = (i <= 1) ? 0 : Swift.min(cornerRadius, dist(prev, curr) / 2, dist(next, curr) / 2)
            let toPrev = unit(curr, prev), toNext = unit(curr, next)
            let p1 = CGPoint(x: curr.x + toPrev.x * r, y: curr.y + toPrev.y * r)
            let p2 = CGPoint(x: curr.x + toNext.x * r, y: curr.y + toNext.y * r)
            if i == 0 { path.move(to: p1) } else { path.addLine(to: p1) }
            if r > 0 { path.addQuadCurve(to: p2, control: curr) }
        }
        path.closeSubpath()
        return path
    }
}

/// 輸入框下方的狀態抽屜（外觀同 Coder 的 composerStatusBar）：只顯示一行字，不接點擊。
/// 呼叫端加 `.zIndex(-1).padding(.top, -13)`，讓抽屜的平頂塞進輸入框底下。
struct ChatComposerStatusDrawer: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let text: String?
    let tone: ChatComposerStatusTone

    private var dotColor: Color {
        switch tone {
        case .hint: LiquidGlassTokens.brandAccent
        case .warning: Color.orange
        case .quiet, .info, .working: Color.secondary.opacity(0.72)
        }
    }

    /// 同 Coder：只有提醒（hint）用深色粗字；「工作中」照中性字色，要注意（同 workContextUnbound）用 secondary。
    private var textColor: Color {
        switch tone {
        case .hint: Color.primary.opacity(0.9)
        case .warning: Color.secondary
        case .working, .info, .quiet: Color.secondary.opacity(0.88)
        }
    }

    var body: some View {
        let shape = ChatComposerStatusDrawerShape(sideSlope: 5, cornerRadius: 16)
        HStack(spacing: 7) {
            if tone == .working {
                ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 10, height: 10)
            } else {
                Circle().fill(dotColor).frame(width: 5, height: 5)
            }
            Text(text ?? "")
                .font(.system(size: 11, weight: tone == .hint ? .semibold : .medium))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(tone == .quiet ? 0 : 1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
        .padding(.top, 5)
        .background {
            if TatwoActivePalette.current.usesGlass {
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(LiquidGlassTokens.ultraworkGradient)
                        .opacity(LiquidGlassTokens.glassIdentityFillOpacity * 1.6))
                    .overlay(shape.fill(Color.white.opacity(0.12)))
            } else {
                shape.fill(Color.primary.opacity(0.075))
            }
        }
        .overlay {
            if TatwoActivePalette.current.usesGlass {
                shape.stroke(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.strokeOpacity), lineWidth: 1)
            } else {
                shape.stroke(Color.primary.opacity(0.16), lineWidth: 1)
            }
        }
        .padding(.horizontal, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text ?? "")
        .help(text ?? "")
    }
}
