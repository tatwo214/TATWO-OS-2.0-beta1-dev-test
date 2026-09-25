import AppKit
import SwiftUI

/// Shared tab label and selection treatment; callers retain their own menus and drag actions.
struct BrowserTabRow: View {
    enum Variant { case workspace, session }
    var variant: Variant = .session
    let title: String
    let tabID: String
    var host: String? = nil
    var favicon: Data? = nil
    let selected: Bool
    @ObservedObject private var audible = BrowserAudibleTabs.shared
    var sleeping = false
    var loading = false
    var leadingInset = BrowserSidebarMetrics.childLeadingInset
    var workspaceIconFill: Color = .secondary
    var workspaceIconForeground: Color = .white
    let onSelect: () -> Void

    private var iconSize: CGFloat { variant == .workspace ? BrowserSidebarMetrics.workspaceFaviconSize : BrowserSidebarMetrics.rowIconWidth }

    var body: some View {
        // W115（使用者 2026-09-20：「新分頁還是無法拖拽上去進書籤跟珍藏 也無法拖出」）：這一列原本是 Button，
        // macOS 上 Button 會把 mouse-down 吃掉，外層的 onDrag 永遠起不來。改成一般的列＋點擊手勢，拖曳才拿得到事件；
        // 輔助使用仍然是按鈕（特徵與動作都補上）。
        Group {
            HStack(spacing: BrowserSidebarMetrics.rowSpacing) {
                Group {
                    if loading {
                        ProgressView().controlSize(.mini).accessibilityLabel("載入中")
                    } else if let favicon, let image = NSImage(data: favicon) {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else { Image(systemName: "globe").foregroundStyle(.secondary) }
                }
                .font(.system(size: BrowserSidebarMetrics.faviconFontSize, weight: .bold))
                .foregroundStyle(variant == .workspace ? workspaceIconForeground : .primary)
                .frame(width: iconSize, height: iconSize)
                .background(variant == .workspace ? workspaceIconFill : .clear,
                    in: RoundedRectangle(cornerRadius: BrowserSidebarMetrics.faviconCornerRadius))
                VStack(alignment: .leading, spacing: BrowserSidebarMetrics.childGap) {
                    Text(title).font(.system(size: variant == .workspace ? BrowserSidebarMetrics.workspaceRowFontSize : BrowserSidebarMetrics.rowFontSize)).lineLimit(1)
                    if variant == .session, let host {
                        Text(host).font(.system(size: BrowserSidebarMetrics.metaFontSize))
                            .foregroundStyle(selected ? LiquidGlassTokens.browserMutedInk : Color.secondary).lineLimit(1)
                    }
                }
                if audible.ids.contains(tabID) || host.map(audible.playingElsewhere.contains) == true { BrowserAudioNote() }
                if sleeping {
                    Text("睡眠中").font(.system(size: BrowserSidebarMetrics.sleepingFontSize))
                        .foregroundStyle(selected ? LiquidGlassTokens.browserMutedInk : Color.secondary).lineLimit(BrowserSidebarMetrics.singleLine)
                }
                Spacer(minLength: BrowserSidebarMetrics.zero)
                if variant == .workspace, selected, let host, !host.isEmpty {
                    Text(host).font(.system(size: BrowserSidebarMetrics.selectedHostFontSize))
                        .foregroundStyle(selected ? LiquidGlassTokens.browserMutedInk : Color.secondary).lineLimit(BrowserSidebarMetrics.singleLine)
                        .truncationMode(.tail)
                }
            }
            .padding(.vertical, BrowserSidebarMetrics.rowVerticalPadding)
            .padding(.trailing, variant == .workspace ? BrowserSidebarMetrics.zero : BrowserSidebarMetrics.rowHorizontalPadding)
            .padding(.leading, variant == .workspace ? BrowserSidebarMetrics.rowHorizontalPadding : leadingInset)
            .frame(minHeight: variant == .workspace ? BrowserSidebarMetrics.workspaceRowMinHeight : BrowserSidebarMetrics.zero)
            .contentShape(Rectangle())
            .background(selected && variant == .session ? LiquidGlassTokens.browserFieldFill : .clear,
                in: RoundedRectangle(cornerRadius: BrowserSidebarMetrics.rowCornerRadius))
        }
        .onTapGesture(perform: onSelect)
        .foregroundStyle(selected ? LiquidGlassTokens.browserInk : Color.primary)
        .opacity(sleeping ? BrowserSidebarMetrics.sleepingOpacity : BrowserSidebarMetrics.visibleOpacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityIdentifier("browser.tab.\(tabID)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onSelect() }
    }
}

/// Bot ownership is visible in Session space, without introducing a bot browser surface.
struct BrowserBotTabRows: View {
    let tabs: [BrowserTab]
    var body: some View {
        ForEach(tabs) { tab in
            BrowserTabRow(title: tab.title, tabID: tab.id.uuidString, host: tab.url?.host ?? "about:blank",
                favicon: tab.faviconPNG, selected: false, sleeping: tab.isSleeping, onSelect: {})
                .disabled(true)
        }
    }
}

/// 小音符：輕輕上下跳；系統開了「減少動態效果」就只顯示不動。
struct BrowserAudioNote: View {
    var size: CGFloat = 9
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Image(systemName: "music.note")
            .font(.system(size: size, weight: .bold))
            .symbolEffect(.bounce.up.byLayer, options: reduceMotion ? .nonRepeating : .repeating.speed(0.55))
            .foregroundStyle(LiquidGlassTokens.browserInk.opacity(0.8))
            .accessibilityLabel("正在播放聲音")
    }
}
