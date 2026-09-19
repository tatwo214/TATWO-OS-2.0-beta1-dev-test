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
                Text("預覽")
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
                    // 只調左右寬度；高度永遠等於這台螢幕的實體瀏海，寬度下限也不會小於它（不露餡）。
                    sizeRow(
                        "黑瀏海寬度",
                        TatwoIslandShellMetrics.hardwareNotch == nil
                            ? "收合時黑色瀏海往左右延伸多寬"
                            : "往左右延伸多寬；高度固定跟這台的實體瀏海一致",
                        value: $settings.notchScale,
                        base: TatwoIslandShellMetrics.baseCollapsedSize,
                        widthOnly: true
                    )
                    Divider().padding(.leading, 32)
                    sizeRow(
                        "玻璃尺寸",
                        "展開後液態玻璃容器的大小",
                        value: $settings.glassScale,
                        base: TatwoIslandShellMetrics.baseExpandedSize,
                        holdsIslandOpen: true   // 玻璃只有展開才看得到：拖的時候讓真的 Island 保持展開
                    )
                    Divider().padding(.leading, 32)
                    opacityRow
                    Divider().padding(.leading, 32)
                    resetRow
                }
                .opacity(settings.enabled ? 1 : 0.42)
                .disabled(!settings.enabled)
            }
        }
        .background(cardBackground)
        .onDisappear { settings.previewExpanded = false }   // 拖到一半關掉設定也要放手
    }

    private func sizeRow(
        _ title: String,
        _ detail: String,
        value: Binding<Double>,
        base: NSSize,
        holdsIslandOpen: Bool = false,
        widthOnly: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                Text(widthOnly ? notchMeasurement : measurement(base: base, scale: value.wrappedValue))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Slider(value: value, in: widthOnly ? notchRange : TatwoIslandSettings.scaleRange) { editing in
                if holdsIslandOpen { settings.previewExpanded = editing }
            }
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
                Text("寬度、玻璃尺寸與透明度都回到 100%").font(.system(size: 11.5)).foregroundStyle(.secondary)
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

    /// 黑瀏海寬度的下限：不小於實體瀏海（每側再多一點），所以滑到最左也不會露餡。
    private var notchRange: ClosedRange<Double> {
        let floor = Double(TatwoIslandShellMetrics.minimumCollapsedWidth / TatwoIslandShellMetrics.baseCollapsedSize.width)
        return min(max(floor, TatwoIslandSettings.scaleRange.lowerBound), 1)...TatwoIslandSettings.scaleRange.upperBound
    }
    private var notchMeasurement: String {
        _ = settings.notchScale
        let size = TatwoIslandShellMetrics.collapsedSize
        return "\(Int(size.width.rounded())) × \(Int(size.height.rounded())) pt"
    }

    private var opacityRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("玻璃透明度").font(.system(size: 13, weight: .semibold))
                Text("展開後那片玻璃有多實；100% 是原本的樣子").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Slider(value: $settings.glassOpacity, in: TatwoIslandSettings.glassOpacityRange) { editing in
                settings.previewExpanded = editing
            }
            .frame(width: 170)
            .tint(LiquidGlassTokens.brandAccent)
            .accessibilityLabel("玻璃透明度")
            Text(percent(settings.glassOpacity))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.leading, 32)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
    }

    private func measurement(base: NSSize, scale: Double) -> String {
        let width = Int((base.width * CGFloat(scale)).rounded())
        let height = Int((base.height * CGFloat(scale)).rounded())
        return "\(width) × \(height) pt"
    }

    // MARK: - 預覽（使用者 2026-09-19：「實心黑跟純玻璃取消 先針對原版做好優化」→ 只留原版，這裡只做預覽）

    private var styleCard: some View {
        VStack(spacing: 12) {
            IslandStylePreview(
                glassOpacity: settings.glassOpacity,
                forceExpanded: settings.previewExpanded,
                notchScale: settings.notchScale,
                glassScale: settings.glassScale
            )
            .frame(height: 170)
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


/// 一顆縮小的 Island（原版）：收合＝黑瀏海；展開＝玻璃，黑瀏海在玻璃底下霧化成一團深色。
private struct IslandShapeGlyph: View {
    let expanded: Bool
    var glassOpacity: Double = 1
    let width: CGFloat
    let height: CGFloat
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    var body: some View {
        let shape = TatwoIslandShellShape(
            topReverseCornerRadius: min(height * 0.30, 9),
            bottomCornerRadius: min(height * 0.52, 12)
        )
        ZStack(alignment: .top) {
            if expanded {
                // 原設計：黑瀏海在玻璃「底下」被霧化成一團深色；玻璃上面不放任何黑塊。
                let notch = TatwoIslandShellShape(topReverseCornerRadius: notchHeight * 0.30, bottomCornerRadius: notchHeight * 0.52)
                notch.fill(.black).frame(width: notchWidth, height: notchHeight).blur(radius: 7).opacity(0.55)
                glass(shape).opacity(glassOpacity)
                shape.stroke(Color.primary.opacity(0.14), lineWidth: 1)
            } else {
                shape.fill(.black)
            }
        }
        .frame(width: width, height: height, alignment: .top)
        .clipShape(shape)
    }

    @ViewBuilder
    private func glass(_ shape: TatwoIslandShellShape) -> some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }
}

/// 即時預覽：一塊迷你桌面，Island 依目前風格與兩組尺寸倍率等比縮放後貼在頂端。
private struct IslandStylePreview: View {
    var glassOpacity: Double = 1
    var forceExpanded = false
    let notchScale: Double
    let glassScale: Double
    @State private var showExpanded = false
    private var isExpanded: Bool { showExpanded || forceExpanded }

    var body: some View {
        ZStack(alignment: .top) {
            IslandSwatchGround()
            IslandShapeGlyph(expanded: isExpanded, glassOpacity: glassOpacity, width: width, height: height,
                             notchWidth: collapsedWidth, notchHeight: collapsedHeight)
                .animation(.smooth(duration: 0.24), value: isExpanded)
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
    private var previewRatio: CGFloat { 0.5 }

    // 收合與展開用同一個縮小比例，兩條滑桿的效果才看得出相對大小。
    private var collapsedWidth: CGFloat { _ = notchScale; return TatwoIslandShellMetrics.collapsedSize.width * previewRatio }
    private var collapsedHeight: CGFloat { TatwoIslandShellMetrics.collapsedSize.height * previewRatio }
    private var width: CGFloat {
        isExpanded ? TatwoIslandShellMetrics.baseExpandedSize.width * CGFloat(glassScale) * previewRatio : collapsedWidth
    }
    private var height: CGFloat {
        isExpanded ? TatwoIslandShellMetrics.baseExpandedSize.height * CGFloat(glassScale) * previewRatio : collapsedHeight
    }
}
