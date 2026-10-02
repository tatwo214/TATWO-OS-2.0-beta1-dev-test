import SwiftUI

/// Existing OS palette + geometry, not a second theme system or new glass effect.
struct CLIWorkbenchAppearance {
    let canvas: Color
    let surface: Color
    let border: Color
    let accent: Color
    let ink: Color
    let secondaryInk: Color
    let cornerRadius: CGFloat

    static func osTheme(_ palette: TatwoThemePalette) -> Self {
        Self(canvas: palette.canvasBase, surface: palette.surfaceFill,
             border: palette.usesGlass ? Color.gray.opacity(LiquidGlassTokens.strokeOpacity) : palette.surfaceBorder,
             accent: palette.brandAccent,
             ink: Color(nsColor: .labelColor),
             secondaryInk: TatwoThemeColor.adaptive(.init(srgbRed: 0.36, green: 0.36, blue: 0.36, alpha: 1), .init(srgbRed: 0.75, green: 0.75, blue: 0.75, alpha: 1)),
             cornerRadius: LiquidGlassTokens.radiusChip)
    }
}
