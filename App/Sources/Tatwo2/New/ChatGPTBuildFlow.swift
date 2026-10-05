// W183 R8a：ChatGPT build 的節點流程（像 n8n：圖示節點＋連線、點狀底；對照稿 w183-r8-mock-Main）。原生 SwiftUI 畫，不是網頁。
// 使用者 09-28：「我還寧願你做得像n8n那種icon流程可視化，也不要對一個沒有說明書的開發者塞一堆文字說明」。
// - 節點＝圓角方塊（圖示＋名稱＋小字），右上角標記：完成綠勾／等你橘「!」／進行中轉圈／沒選灰／出錯紅。
// - 連線用曲線：完成＝品牌色實線、其他＝灰虛線。GPT →（每台設備一個節點；只有一台就只畫「主」）→ Cloudflare → ChatGPT Dev。
// - 節點點得到、鍵盤聚焦得到（空白鍵／Return 打開面板），VoiceOver 念「名稱：狀態」。
// 節點、連線、位置都在 Facade/HandsBuildModel.swift（HandsBuildGraph、HandsBuildLayout；自測驗）；這裡只畫。
import SwiftUI

/// 對照稿的顏色（淺色照稿；深色換成同一個意思的深底）。品牌色用 LiquidGlassTokens.brandAccent（跟其他設定頁一樣）。
enum ChatGPTBuildPalette {
    static let done = Color(red: 62 / 255, green: 154 / 255, blue: 91 / 255)
    static let waiting = Color(red: 217 / 255, green: 138 / 255, blue: 58 / 255)
    static let idle = Color(red: 201 / 255, green: 192 / 255, blue: 179 / 255)
    static let failed = Color(red: 196 / 255, green: 68 / 255, blue: 58 / 255)
    static let cloud = Color(red: 198 / 255, green: 106 / 255, blue: 43 / 255)
    static var accent: Color { LiquidGlassTokens.brandAccent }

    static func color(_ state: HandsBuildNodeState) -> Color {
        switch state {
        case .done: done
        case .waiting: waiting
        case .working: accent
        case .off: idle
        case .failed: failed
        }
    }

    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.04) : Color(red: 251 / 255, green: 248 / 255, blue: 243 / 255)
    }
    static func dot(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color(red: 226 / 255, green: 216 / 255, blue: 201 / 255)
    }
    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color(red: 227 / 255, green: 218 / 255, blue: 204 / 255)
    }
    static func nodeFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.19) : Color.white
    }
    static func nodeBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.14) : Color(red: 221 / 255, green: 212 / 255, blue: 198 / 255)
    }
    static func fieldBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.20) : Color(red: 207 / 255, green: 198 / 255, blue: 184 / 255)
    }
    static func suffixFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.06) : Color(red: 241 / 255, green: 236 / 255, blue: 227 / 255)
    }
}

struct ChatGPTBuildFlow: View {
    let graph: HandsBuildGraph
    /// 現在開著哪個面板（那個節點描品牌色框）；看工程細節時＝nil。
    let selected: HandsBuildPanel?
    /// 開關關著：整片淡一點（對照稿 0.45）。
    let dimmed: Bool
    let onPick: (HandsBuildPanel) -> Void
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: String?

    var body: some View {
        let height = HandsBuildLayout.height(devices: graph.deviceCount)
        GeometryReader { geo in
            let layout = HandsBuildLayout(width: geo.size.width, devices: graph.deviceCount)
            let frames = layout.frames(graph)
            ZStack(alignment: .topLeading) {
                background(frames: frames)
                ForEach(graph.nodes) { node in
                    if let rect = frames[node.id] {
                        nodeView(node, size: rect.size)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
        }
        .frame(height: height)
        .background(ChatGPTBuildPalette.canvas(scheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(ChatGPTBuildPalette.border(scheme), lineWidth: 1))
        .opacity(dimmed ? 0.45 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(HandsBuildCopy.title)
        .accessibilityIdentifier("tap.chatgpt.build.flow")
    }

    /// 點狀底＋連線（完成＝品牌色實線，其他＝灰虛線；虛線先畫，實線疊在上面）。
    private func background(frames: [String: CGRect]) -> some View {
        let dot = ChatGPTBuildPalette.dot(scheme)
        let accent = ChatGPTBuildPalette.accent
        let idle = ChatGPTBuildPalette.idle
        let edges: [(path: Path, done: Bool)] = graph.edges.compactMap { edge in
            guard let from = frames[edge.from], let to = frames[edge.to] else { return nil }
            return (Self.curve(from: CGPoint(x: from.maxX, y: from.midY), to: CGPoint(x: to.minX, y: to.midY)), edge.done)
        }
        return Canvas { context, size in
            var x: CGFloat = 8
            while x < size.width {
                var y: CGFloat = 8
                while y < size.height {
                    context.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(dot))
                    y += 16
                }
                x += 16
            }
            for edge in edges where !edge.done {
                context.stroke(edge.path, with: .color(idle), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 5]))
            }
            for edge in edges where edge.done {
                context.stroke(edge.path, with: .color(accent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHidden(true)
    }

    /// 對照稿的曲線：M a C (中點, a.y) (中點, b.y) b；同一高度就直線。
    static func curve(from a: CGPoint, to b: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        if abs(a.y - b.y) < 0.5 {
            path.addLine(to: b)
        } else {
            let mid = (a.x + b.x) / 2
            path.addCurve(to: b, control1: CGPoint(x: mid, y: a.y), control2: CGPoint(x: mid, y: b.y))
        }
        return path
    }

    private func nodeView(_ node: HandsBuildGraph.Node, size: CGSize) -> some View {
        let isSelected = selected == node.panel
        let accent = ChatGPTBuildPalette.accent
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(spacing: 5) {
            ChatGPTBuildNodeIcon(kind: node.kind)
                .frame(height: 26)
            Text(node.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(node.sub)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .frame(width: size.width, height: size.height)
        .background(ChatGPTBuildPalette.nodeFill(scheme), in: shape)
        .overlay(shape.strokeBorder(isSelected ? accent : ChatGPTBuildPalette.nodeBorder(scheme), lineWidth: isSelected ? 2 : 1))
        .shadow(color: isSelected ? accent.opacity(0.18) : Color.black.opacity(0.06), radius: isSelected ? 9 : 3, y: isSelected ? 6 : 2)
        .overlay(alignment: .topTrailing) {
            ChatGPTBuildBadge(state: node.state)
                .offset(x: 8, y: -8)
        }
        .overlay {
            if focused == node.id {
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .strokeBorder(accent.opacity(0.75), lineWidth: 2)
                    .padding(-4)
            }
        }
        .contentShape(shape)
        .onTapGesture { onPick(node.panel) }
        .focusable(interactions: .activate)
        .focused($focused, equals: node.id)
        .focusEffectDisabled()
        .onKeyPress(keys: [.space, .return]) { _ in
            onPick(node.panel)
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(node.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction { onPick(node.panel) }
        .accessibilityIdentifier("tap.chatgpt.build.node.\(node.id)")
        .help(node.accessibilityLabel)
    }
}

/// 節點的圖示（對照稿：ChatGPT 標誌、螢幕、橘色雲、程式碼）。
struct ChatGPTBuildNodeIcon: View {
    let kind: HandsBuildGraph.Kind

    var body: some View {
        switch kind {
        case .gpt:
            ChatGPTLogo(size: 24)
        case .device:
            Image(systemName: "display")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.primary)
        case .cloudflare:
            Image(systemName: "cloud")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(ChatGPTBuildPalette.cloud)
        case .dev:
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
        }
    }
}

/// 右上角標記：完成綠勾、等你橘「!」、進行中轉圈、沒選灰、出錯紅。
struct ChatGPTBuildBadge: View {
    let state: HandsBuildNodeState

    var body: some View {
        ZStack {
            Circle().fill(ChatGPTBuildPalette.color(state))
            switch state {
            case .done:
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            case .waiting:
                Text("!").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            case .failed:
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            case .working:
                ChatGPTBuildSpinner().frame(width: 11, height: 11)
            case .off:
                EmptyView()
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

/// 進行中的轉圈（白色弧線；只在有節點進行中時畫）。
struct ChatGPTBuildSpinner: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            Circle()
                .trim(from: 0.1, to: 0.75)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(turn * 360))
        }
    }
}

/// 與登入頁 OpenAI、私訊框共用同一個單色資產。
struct ChatGPTLogo: View {
    var size: CGFloat = 20
    var body: some View {
        if let logo = ProviderSVGIconLoader.image(for: "codex-gpt") {
            Image(nsImage: logo).resizable().renderingMode(.template).scaledToFit()
                .frame(width: size, height: size)
        }
    }
}
