import SwiftUI

// W183 R9：原生 ChatGPT Space「外掛」頁右上角的「新增 ▾」（照網頁版的位置與三項；照專案 UI 規則：玻璃 chip、不要藍按鈕）。
// 邏輯在 Facade/ChatGPTPluginNewMenu.swift：三項都把真的網頁開在私訊框 Browser 的「ChatGPT Dev」分頁（只開，不填、不勾、不按 Create）。
// W183 R9 審查（Claude #4、#8）：選單內容是自己的一張（ChatGPTPluginNewMenuList：三項＋MCP 那一項下面一行提示），用玻璃 chip 打開的
// popover 顯示——自測照這一張畫出來（PNG）、用 accessibilityIdentifier「chatgpt.plugins.new.<item>」真的按三項；
// 那一句話（打開了、為什麼沒打開）放在標題列下面（ChatGPTPluginNewMenuMessage），不撐高標題列。

struct ChatGPTPluginNewMenuButton: View {
    @ObservedObject var menu: ChatGPTPluginNewMenu
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                if menu.working != nil || menu.holding != nil { ProgressView().controlSize(.mini) }
                Text("新增").font(.system(size: 12.5, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .chatGlassChip()
        .fixedSize()
        .disabled(menu.working != nil)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ChatGPTPluginNewMenuList(menu: menu) { open = false }
        }
        .help("在私訊框 Browser 的 ChatGPT Dev 分頁打開網頁版的「新增」")
        .accessibilityLabel("新增外掛")
        .accessibilityIdentifier("chatgpt.plugins.new")
    }
}

/// 「新增 ▾」打開後的那一張：三項（跟網頁版同字、同順序）＋「建立 MCP 應用程式」下面一行提示（不能按）。
struct ChatGPTPluginNewMenuList: View {
    @ObservedObject var menu: ChatGPTPluginNewMenu
    var dismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(ChatGPTPluginNewItem.allCases) { item in
                Button {
                    dismiss()
                    menu.open(item)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.systemImage).font(.system(size: 12)).frame(width: 16)
                        Text(item.title).font(.system(size: 13))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .chatMenuRowHover()
                .disabled(menu.working != nil)
                .accessibilityLabel(item.title)
                .accessibilityIdentifier("chatgpt.plugins.new.\(item.rawValue)")
                if item == .mcp {
                    // 選單裡的一行小字（不能按）：要連 TATWO 用 ChatGPT build 的［連線］。
                    Text(ChatGPTPluginNewItem.mcpHint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.leading, 25)
                        .padding(.bottom, 4)
                        .accessibilityIdentifier("chatgpt.plugins.new.hint")
                }
            }
        }
        .padding(6)
        .frame(width: 290, alignment: .leading)
    }
}

/// 外掛頁標題列下面的那一句話（打開了、或為什麼沒打開）。
struct ChatGPTPluginNewMenuMessage: View {
    @ObservedObject var menu: ChatGPTPluginNewMenu

    var body: some View {
        if let message = menu.message {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("chatgpt.plugins.new.message")
        }
    }
}
