import SwiftUI
import AppKit

/// Replace this file and the original avatar catalog to change the pet appearance.
struct PetSkin {
    static let avatarOpacity = 0.12, faintOpacity = 0.5
    let compactGap: CGFloat = 6, chipX: CGFloat = 14, chipY: CGFloat = 8, iconSize: CGFloat = 32
    let composerMin: CGFloat = 28, composerMax: CGFloat = 140, messageSize: CGFloat = 14
    let avatarColumns = 4, dash: [CGFloat] = [6, 4], avatarGridWidth: CGFloat = 300
    let customHeight: CGFloat = 80
    var dropFill: Color { accent.opacity(0.12) }
    var dashedBorder: Color { accent.opacity(0.35) }
    let selectedTab = Font.system(size: 14, weight: .semibold)
    var faint: Color { muted.opacity(Self.faintOpacity) }
    let canvas: Color, card: Color, ink: Color, muted: Color, accent: Color, border: Color, shadow: Color
    let gap: CGFloat = 12, inset: CGFloat = 18, column: CGFloat = 360, avatar: CGFloat = 48, portrait: CGFloat = 128, actionWidth: CGFloat = 24
    let sheetWidth: CGFloat = 640, sheetHeight: CGFloat = 560, inputHeight: CGFloat = 80, zero: CGFloat = 0
    let radius: CGFloat, avatarRadius: CGFloat
    let shadowRadius: CGFloat = 2, shadowY: CGFloat = 3, stroke: CGFloat = 1
    let body = Font.system(size: 14), title = Font.system(size: 22, weight: .semibold), detail = Font.system(size: 12)
    let heading = Font.system(size: 16, weight: .semibold)
    init(palette: TatwoThemePalette = TatwoActivePalette.current, dark: Bool) {
        accent = palette.brandAccent; border = palette.surfaceBorder.opacity(dark ? 0.3 : 0.6)
        canvas = dark ? palette.brandAccent.opacity(0.12).blend(with: .black) : palette.canvasBase
        card = dark ? palette.accentViolet.opacity(0.12).blend(with: Color(white: 0.12)) : palette.surfaceFill
        ink = dark ? .white : Color(white: 0.12); muted = ink.opacity(0.65); shadow = .black.opacity(dark ? 0.25 : 0.08)
        radius = 20 * palette.radiusScale; avatarRadius = palette.usesGlass ? 24 : 8
    }
}

private extension Color {
    func blend(with base: Color) -> Color {
        let front = NSColor(self).usingColorSpace(.sRGB)!, back = NSColor(base).usingColorSpace(.sRGB)!, a = front.alphaComponent
        return Color(red: front.redComponent * a + back.redComponent * (1-a), green: front.greenComponent * a + back.greenComponent * (1-a), blue: front.blueComponent * a + back.blueComponent * (1-a))
    }
}
extension View {
    func petDropHighlight(_ skin: PetSkin, active: Bool) -> some View {
        overlay(RoundedRectangle(cornerRadius: skin.radius).fill(active ? skin.dropFill : skin.dropFill.opacity(skin.zero)).allowsHitTesting(false))
            .overlay(RoundedRectangle(cornerRadius: skin.radius).stroke(active ? skin.accent : skin.border.opacity(skin.zero), lineWidth: skin.stroke).allowsHitTesting(false))
    }
    func petCard(_ skin: PetSkin) -> some View {
        padding(skin.inset).background(skin.card, in: RoundedRectangle(cornerRadius: skin.radius))
            .overlay(RoundedRectangle(cornerRadius: skin.radius).stroke(skin.border, lineWidth: skin.stroke))
            .shadow(color: skin.shadow, radius: skin.shadowRadius, x: skin.zero, y: skin.shadowY)
    }
}
