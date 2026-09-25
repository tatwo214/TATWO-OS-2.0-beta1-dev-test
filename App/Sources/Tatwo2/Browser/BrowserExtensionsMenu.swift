import AppKit
import SwiftUI

/// 工具列拼圖鈕按下去展開的選單（W122，使用者 2026-09-21：「展開我所擁有的擴充工具 以及顯示『管理擴充功能』跟『擴充商店』」
/// 「展開的擴充功能要有訂選的符號 點擊可釘選在工具列」）。不是對話框，是掛在按鈕上的選單。
struct BrowserExtensionsMenu: View {
    @AppStorage("tatwo.browser.chromeStyleSpike") private var enabled = false
    @State private var enabledAtLaunch = UserDefaults.standard.bool(forKey: "tatwo.browser.chromeStyleSpike")
    @State private var items: [BrowserExtensionInventory.Item] = []
    @State private var pinned: [String] = BrowserExtensionInventory.Pins.ids()
    @ObservedObject private var surface = BrowserChromeStyleEmbedState.shared   // W136：開著時給一個明確的關閉項
    /// W139（使用者 2026-09-21：「新增在左列新分頁很難嗎」）：商店是一般網頁，開在左列的新分頁。
    /// `chrome://extensions` 不行——瀏覽器核心的白名單不收它，嵌入的分頁載不起來，只能用擴充視窗開。
    let openTab: (String) -> Void
    let openManager: (String) -> Void
    let dismiss: () -> Void

    private var live: Bool { enabled && enabledAtLaunch }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !live {
                row("啟用擴充功能", systemImage: "puzzlepiece.extension") {
                    enabled = true
                }
                Text(enabled ? "重新啟動 TATWO OS 後生效。" : "擴充功能會在每一個分頁執行，可以讀取與修改網頁內容。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.bottom, 4).fixedSize(horizontal: false, vertical: true)
            } else if items.isEmpty {
                Text("還沒有安裝擴充功能").font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
            } else {
                ForEach(items) { item in extensionRow(item) }
            }
            Divider().padding(.vertical, 4)
            row("進階管理（瀏覽器內建頁）", systemImage: "slider.horizontal.3") { openManager("chrome://extensions"); dismiss() }
                .disabled(!live)
            if surface.url != nil {
                row("關閉擴充功能視窗", systemImage: "xmark.circle") { surface.close(); dismiss() }
            }
            row("擴充商店", systemImage: "bag") { openTab("https://chromewebstore.google.com/"); dismiss() }
                .disabled(!live)
        }
        .padding(6)
        .frame(width: 200)
        .onAppear { items = live ? BrowserExtensionInventory.cached(reload: true) : [] }
    }

    private func extensionRow(_ item: BrowserExtensionInventory.Item) -> some View {
        HStack(spacing: 8) {
            icon(item).frame(width: 18, height: 18)
            Text(item.name).lineLimit(1)
            Spacer(minLength: 4)
            Button {
                BrowserExtensionInventory.Pins.toggle(item.id)
                pinned = BrowserExtensionInventory.Pins.ids()
            } label: {
                Image(systemName: pinned.contains(item.id) ? "pin.fill" : "pin")
                    .foregroundStyle(pinned.contains(item.id) ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(pinned.contains(item.id) ? "取消釘選" : "釘選在工具列")
            .accessibilityLabel(pinned.contains(item.id) ? "取消釘選 \(item.name)" : "釘選 \(item.name)")
            .accessibilityIdentifier("browser.extension.pin.\(item.id)")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { openExtensionPage(item); dismiss() }
        .accessibilityIdentifier("browser.extension.\(item.id)")
    }

    /// W141（.044 實測）：`chrome-extension://` 在嵌入的分頁一樣載不起來，開出來是 `about:blank`。
    /// 嵌入模式的分頁只吃 http(s)；所有帶 Chrome 自己介面的頁面（管理頁、擴充的彈出視窗與設定頁）都得用擴充視窗。
    private func openExtensionPage(_ item: BrowserExtensionInventory.Item) { openManager(item.actionURL) }

    @ViewBuilder private func icon(_ item: BrowserExtensionInventory.Item) -> some View {
        if let path = item.iconPath, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary)
        }
    }

    private func row(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).frame(width: 18)
                Text(title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 釘在工具列的擴充圖示（點一下開它自己的頁面）。
struct BrowserPinnedExtensionButtons: View {
    let size: CGFloat
    /// W140：點釘選的擴充＝開它自己的頁面，開在分頁。
    let openPage: (String) -> Void
    @State private var items: [BrowserExtensionInventory.Item] = []
    @State private var pinned: [String] = BrowserExtensionInventory.Pins.ids()

    var body: some View {
        // W132（.035 自測：選單一關圖示就不見）：狀態改掛在外層，工具列重畫時一定重新讀。
        Group { content }
            .onAppear { refresh() }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in refresh() }
    }

    @ViewBuilder private var content: some View {
        ForEach(items.filter { pinned.contains($0.id) }) { item in
            Button { openPage(item.actionURL) } label: {
                Group {
                    if let path = item.iconPath, let image = NSImage(contentsOfFile: path) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "puzzlepiece.extension")
                    }
                }
                .frame(width: size, height: size)
            }
            .buttonStyle(.plain).help(item.name).accessibilityLabel(item.name)
            .accessibilityIdentifier("browser.extension.pinned.\(item.id)")
        }
    }

    private func refresh() {
        pinned = BrowserExtensionInventory.Pins.ids()
        items = pinned.isEmpty ? [] : BrowserExtensionInventory.cached()
    }
}
