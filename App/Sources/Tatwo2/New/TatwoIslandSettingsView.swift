import SwiftUI
import AppKit

/// Settings › Tatwo Island（W105，使用者 2026-09-19：「island開關、尺寸調節(黑劉海跟玻璃尺寸分開調)、
/// 風格(跟computer use一樣呈現給用戶選)」）。版面刻意與 ComputerUseSettingsView 同構：
/// 一張總開關卡片（點空白處展開細項），底下一排風格磚塊＋即時預覽。
struct TatwoIslandSettingsView: View {
    @ObservedObject private var settings = TatwoIslandSettings.shared
    let onClose: () -> Void
    @State private var expanded = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                masterCard
                Text("Island 風格")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, -6)
                styleCard
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tatwo Island").font(.title3.bold())
                Text("螢幕頂端的瀏海容器：通知、同意卡與 AI 動態都從這裡出現")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("完成") { onClose() }
                .buttonStyle(.borderedProminent)
                .tint(LiquidGlassTokens.brandAccent)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - 總開關與兩組尺寸

    private var masterCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text("啟用 Tatwo Island").font(.system(size: 13, weight: .semibold))
                    Text("關閉後瀏海容器完全不顯示，通知改用視窗提示；重新打開不必重開 App")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $settings.enabled)
                    .toggleStyle(.switch)
                    .tint(LiquidGlassTokens.brandAccent)
                    .labelsHidden()
                    .accessibilityLabel("啟用 Tatwo Island")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(expanded ? "收起" : "展開尺寸調整")

            if expanded {
                Divider()
                Group {
                    // 黑瀏海＝收合時看到的實心黑；玻璃＝展開後的液態玻璃本體。兩組分開調。
                    sizeRow(
                        "黑瀏海尺寸",
                        "收合時那塊黑色瀏海的大小",
                        value: $settings.notchScale,
                        base: TatwoIslandShellMetrics.baseCollapsedSize
                    )
                    Divider().padding(.leading, 32)
                    sizeRow(
                        "玻璃尺寸",
                        "展開後液態玻璃容器的大小",
                        value: $settings.glassScale,
                        base: TatwoIslandShellMetrics.baseExpandedSize
                    )
                    Divider().padding(.leading, 32)
                    resetRow
                }
                .opacity(settings.enabled ? 1 : 0.42)
                .disabled(!settings.enabled)
            }
        }
        .background(cardBackground)
    }

    private func sizeRow(
        _ title: String,
        _ detail: String,
        value: Binding<Double>,
        base: NSSize
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                Text(measurement(base: base, scale: value.wrappedValue))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Slider(value: value, in: TatwoIslandSettings.scaleRange)
                .frame(width: 170)
                .tint(LiquidGlassTokens.brandAccent)
                .accessibilityLabel(title)
            Text(percent(value.wrappedValue))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.leading, 32)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
    }

    private var resetRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("回到出廠尺寸").font(.system(size: 13, weight: .semibold))
                Text("兩組尺寸都回到 100%").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("重設") { settings.resetSizes() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.leading, 32)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
    }

    private func percent(_ scale: Double) -> String {
        "\(Int((scale * 100).rounded()))%"
    }

    private func measurement(base: NSSize, scale: Double) -> String {
        let width = Int((base.width * CGFloat(scale)).rounded())
        let height = Int((base.height * CGFloat(scale)).rounded())
        return "\(width) × \(height) pt"
    }

    // MARK: - 風格（呈現方式同 Computer Use 的箭頭風格磚塊）

    private var styleCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(TatwoIslandSettings.Style.allCases) { style in
                    let selected = settings.style == style
                    Button { settings.style = style } label: {
                        IslandStyleSwatch(style: style)
                            .frame(maxWidth: .infinity)
                            .frame(height: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(
                                        selected ? LiquidGlassTokens.brandAccent.opacity(0.55) : .clear,
                                        lineWidth: 2)
                            }
                    }
                    .buttonStyle(.plain)
                    .help(style.detail)
                    .accessibilityLabel(style.title)
                    .accessibilityHint(style.detail)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            HStack(spacing: 8) {
                ForEach(TatwoIslandSettings.Style.allCases) { style in
                    Text(style.title)
                        .font(.system(size: 11, weight: settings.style == style ? .semibold : .regular))
                        .foregroundStyle(settings.style == style ? Color.primary : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            IslandStylePreview(
                style: settings.style,
                notchScale: settings.notchScale,
                glassScale: settings.glassScale
            )
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(12)
        .background(cardBackground)
        .opacity(settings.enabled ? 1 : 0.42)
        .disabled(!settings.enabled)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.secondary.opacity(0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

private func islandHexColor(_ value: UInt32, _ alpha: Double = 1) -> Color {
    Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
          blue: Double(value & 0xFF) / 255, opacity: alpha)
}

/// 與 Computer Use 磚塊同一塊紙色＋紙紋底，讓兩頁看起來是同一套設定。
private struct IslandSwatchGround: View {
    var body: some View {
        Rectangle()
            .fill(islandHexColor(0xF2ECE2))
            .overlay {
                Rectangle()
                    .fill(ImagePaint(image: Image(nsImage: TatwoPaperGrain.tile), scale: 0.5))
                    .opacity(0.08)
                    .blendMode(.multiply)
                    .allowsHitTesting(false)
            }
    }
}

/// 三種風格只畫造型本身（同 Computer Use 的箭頭磚塊做法）。
private struct IslandStyleSwatch: View {
    let style: TatwoIslandSettings.Style

    var body: some View {
        ZStack(alignment: .top) {
            IslandSwatchGround()
            IslandShapeGlyph(style: style, width: 92, height: 24)
                .padding(.top, 18)
        }
    }
}

/// 一顆縮小的 Island：黑瀏海與玻璃兩層依風格開關，造型直接用 Island 本體的 Shape。
private struct IslandShapeGlyph: View {
    let style: TatwoIslandSettings.Style
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let shape = TatwoIslandShellShape(
            topReverseCornerRadius: height * 0.30,
            bottomCornerRadius: height * 0.52
        )
        ZStack {
            if style != .solid {
                glass(shape)
            }
            if style != .glass {
                shape.fill(.black)
            }
            if style == .glass {
                // 純玻璃在淺色磚塊上幾乎透明，補一道細邊讓造型看得出來。
                shape.stroke(Color.primary.opacity(0.28), lineWidth: 1)
            }
        }
        .frame(width: width, height: height)
    }

    @ViewBuilder
    private func glass(_ shape: TatwoIslandShellShape) -> some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(Color.white.opacity(0.35))
        }
    }
}

/// 即時預覽：一塊迷你桌面，Island 依目前風格與兩組尺寸倍率等比縮放後貼在頂端。
private struct IslandStylePreview: View {
    let style: TatwoIslandSettings.Style
    let notchScale: Double
    let glassScale: Double
    @State private var showExpanded = false

    var body: some View {
        ZStack(alignment: .top) {
            IslandSwatchGround()
            IslandShapeGlyph(style: style, width: width, height: height)
                .animation(.smooth(duration: 0.24), value: showExpanded)
                .animation(.smooth(duration: 0.24), value: width)
        }
        .overlay(alignment: .bottom) {
            Picker("", selection: $showExpanded) {
                Text("收合").tag(false)
                Text("展開").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
            .padding(.bottom, 10)
            .accessibilityLabel("預覽狀態")
        }
    }

    /// 預覽縮小比例：讓出廠尺寸的展開態剛好佔滿預覽寬度的大半。
    private var previewRatio: CGFloat { 0.34 }

    private var width: CGFloat {
        showExpanded
            ? TatwoIslandShellMetrics.baseExpandedSize.width * CGFloat(glassScale) * previewRatio
            : TatwoIslandShellMetrics.baseCollapsedSize.width * CGFloat(notchScale) * previewRatio * 1.6
    }

    private var height: CGFloat {
        showExpanded
            ? TatwoIslandShellMetrics.baseExpandedSize.height * CGFloat(glassScale) * previewRatio * 0.5
            : TatwoIslandShellMetrics.baseCollapsedSize.height * CGFloat(notchScale) * previewRatio * 1.6
    }
}
