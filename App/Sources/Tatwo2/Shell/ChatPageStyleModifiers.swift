// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageStyleModifiers.swift；改動 1 行（原因：run A 照搬，僅移除舊水電 import／呼叫並接同名 Facade）
import SwiftUI
import AppKit

// Chat styling helpers (liquid-glass section/card/hover modifiers + slider visual
// suppression shape) pure-moved out of ChatPage.swift for structure health. Top-level
// declarations widened private→internal (same-module, behavior-neutral); nested
// property access levels unchanged. No ChatPageModel state dependency.

struct ChatMenuRowHoverModifier: ViewModifier {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let isSelected: Bool
    let tint: Color
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(
                    cornerRadius: LiquidGlassTokens.radiusChip,
                    style: LiquidGlassTokens.shapeStyle
                )
                .fill(
                    tint.opacity(
                        isSelected
                            ? LiquidGlassTokens.chipFillOpacity
                            : (isHovering ? LiquidGlassTokens.subtleFillOpacity : .zero)
                    )
                )
            }
            .shadow(
                color: tint.opacity(isHovering ? LiquidGlassTokens.shadowOpacity : .zero),
                radius: isHovering ? LiquidGlassTokens.shadowRadius : .zero,
                x: LiquidGlassTokens.shadowOffsetX,
                y: isHovering ? LiquidGlassTokens.shadowOffsetY : .zero
            )
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.10)) {
                    isHovering = hovering
                }
            }
    }
}

struct ChatLiquidSectionModifier: ViewModifier {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let cornerRadius: CGFloat
    let fillOpacity: Double
    let strokeOpacity: Double
    let accentOpacity: Double
    let shadowOpacity: Double

    // 極光 P4 隔離（2026-08-20）：本修飾器原本無主題分支硬上
    // ultraThinMaterial——玻璃反向漏進 fable5。比照 ChatGlassChipModifier
    // 的雙分支語法：極光走玻璃、fable5 走不透明暖紙。
    @ViewBuilder
    func body(content: Content) -> some View {
        if TatwoActivePalette.current.usesGlass {
            glassBody(content)
        } else {
            matteBody(content)
        }
    }

    private func matteBody(_ content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: LiquidGlassTokens.shapeStyle)
                    .fill(TatwoActivePalette.current.surfaceFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: LiquidGlassTokens.shapeStyle)
                    .strokeBorder(
                        TatwoActivePalette.current.surfaceBorder.opacity(0.75),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .shadow(
                color: Color.black.opacity(shadowOpacity * 0.6),
                radius: LiquidGlassTokens.shadowRadius,
                x: LiquidGlassTokens.shadowOffsetX,
                y: LiquidGlassTokens.shadowOffsetY
            )
    }

    private func glassBody(_ content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: LiquidGlassTokens.shapeStyle)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: LiquidGlassTokens.shapeStyle)
                            .fill(LiquidGlassTokens.tint.opacity(fillOpacity))
                            .allowsHitTesting(false)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: LiquidGlassTokens.shapeStyle)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        LiquidGlassTokens.tint.opacity(fillOpacity),
                                        LiquidGlassTokens.accentPink.opacity(accentOpacity),
                                        LiquidGlassTokens.accentViolet.opacity(accentOpacity),
                                        LiquidGlassTokens.accentBlue.opacity(accentOpacity),
                                        LiquidGlassTokens.tint.opacity(fillOpacity)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .allowsHitTesting(false)
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: LiquidGlassTokens.shapeStyle)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                LiquidGlassTokens.tint.opacity(strokeOpacity),
                                LiquidGlassTokens.brandAccent.opacity(accentOpacity),
                                LiquidGlassTokens.tint.opacity(strokeOpacity)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .shadow(
                color: Color.black.opacity(shadowOpacity),
                radius: LiquidGlassTokens.shadowRadius,
                x: LiquidGlassTokens.shadowOffsetX,
                y: LiquidGlassTokens.shadowOffsetY
            )
    }
}

// 舊 SwiftUI 玻璃卡近似修飾器已移除：ultrawork/model picker 改用真 dashboard WebGL liquidGlassPanelSurface（零 caller 死碼，sol Verifier 抓）。

/// Keep native disabled hit testing, without the system plain style's extra text wash (the chip itself fades when disabled).
struct ChatGlassChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.90 : 1)
    }
}

struct ChatGlassChipModifier: ViewModifier {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let isSelected: Bool
    let tint: Color
    var readable = false
    @Environment(\.colorScheme) private var colorScheme
    /// 停用只在這裡淡化一次（字、分隔點、箭頭一起），仍可讀但看得出不能按。
    @Environment(\.isEnabled) private var isEnabled
    /// Dynamic colors retained by native controls use the same ink calculation as SwiftUI's environment.
    static var chipForeground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            foreground(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        })
    }
    static var chipDestructiveForeground: Color {
        return Color(nsColor: NSColor(name: nil) { appearance in
            TatwoActivePalette.current.usesGlass && appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 1, green: 0.60, blue: 0.57, alpha: 1)
                : NSColor(srgbRed: 0.60, green: 0.04, blue: 0.02, alpha: 1)
        })
    }
    private static func foreground(dark: Bool) -> NSColor {
        TatwoActivePalette.current.usesGlass && dark ? .white : .black.withAlphaComponent(0.85)
    }
    private var ink: Color { readable ? .black.opacity(0.85) : Color(nsColor: Self.foreground(dark: colorScheme == .dark)) }

    @ViewBuilder
    func body(content: Content) -> some View {
        let label = content.opacity(isEnabled ? 1 : 0.7).foregroundStyle(ink, ink, ink)
        if TatwoActivePalette.current.usesGlass {
            glassBody(label)
        } else {
            matteBody(label)
        }
    }

    // Glass keeps material and a visible rim. Ordinary light chips retain the original white veil;
    // dark chips bound the background luminance with a dark veil and use light ink.
    // Recovery chips retain the pale surface with dark ink in either appearance.
    private func glassBody(_ content: some View) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: LiquidGlassTokens.shapeStyle)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: LiquidGlassTokens.shapeStyle)
                            .fill(readable ? Color.white.opacity(0.70)
                                  : (colorScheme == .dark ? Color.black.opacity(0.70) : Color.white.opacity(0.26)))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: LiquidGlassTokens.shapeStyle)
                            .fill(LiquidGlassTokens.tint.opacity(isSelected ? 0.15 : LiquidGlassTokens.chipFillOpacity))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: LiquidGlassTokens.shapeStyle)
                    .strokeBorder(isSelected ? LiquidGlassTokens.brandAccent.opacity(0.9)
                                  : (colorScheme == .light || readable ? Color.black.opacity(0.25) : LiquidGlassTokens.tint.opacity(0.40)),
                                  lineWidth: isSelected ? 1.5 : 1)
            }
    }

    // 扁平牛皮紙 chip（fable5）：不透明暖紙實底；選中用赤陶錨色淡填 + 暖邊。無 material/blur。
    private func matteBody(_ content: some View) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: LiquidGlassTokens.shapeStyle)
                    .fill(TatwoActivePalette.current.surfaceFill)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: LiquidGlassTokens.shapeStyle)
                                .fill(LiquidGlassTokens.brandAccent.opacity(0.15))
                        }
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: LiquidGlassTokens.shapeStyle)
                    .strokeBorder(
                        isSelected
                            ? LiquidGlassTokens.brandAccent.opacity(0.9)
                            : TatwoActivePalette.current.surfaceBorder.opacity(0.75),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
    }
}

extension View {
    func chatMenuRowHover(
        isSelected: Bool = false,
        tint: Color = LiquidGlassTokens.brandAccent
    ) -> some View {
        modifier(ChatMenuRowHoverModifier(isSelected: isSelected, tint: tint))
    }

    func chatGlassChip(
        isSelected: Bool = false,
        tint: Color = LiquidGlassTokens.brandAccent,
        readable: Bool = false
    ) -> some View {
        modifier(ChatGlassChipModifier(isSelected: isSelected, tint: tint, readable: readable))
    }

    func chatLiquidSection(
        cornerRadius: CGFloat,
        fillOpacity: Double = LiquidGlassTokens.tintOpacity,
        strokeOpacity: Double = LiquidGlassTokens.strokeOpacity,
        accentOpacity: Double = 0.0,
        shadowOpacity: Double = LiquidGlassTokens.shadowOpacity
    ) -> some View {
        modifier(ChatLiquidSectionModifier(
            cornerRadius: cornerRadius,
            fillOpacity: fillOpacity,
            strokeOpacity: strokeOpacity,
            accentOpacity: accentOpacity,
            shadowOpacity: shadowOpacity
        ))
    }

    @ViewBuilder
    func sliderArchProbeAccessibilityIdentifier(
        _ identifier: String,
        enabled: Bool
    ) -> some View {
        if enabled {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}

struct ChatSliderVisualSuppressionShape: Shape {
    func path(in _: CGRect) -> Path {
        Path()
    }
}

struct ChatChipTextField: View {
    let title: String
    @Binding var text: String
    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(title).foregroundStyle(ChatGlassChipModifier.chipForeground)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            TextField("", text: $text)
                .foregroundStyle(ChatGlassChipModifier.chipForeground)
                .textFieldStyle(.plain)
                .accessibilityLabel(title)
        }
    }
}
