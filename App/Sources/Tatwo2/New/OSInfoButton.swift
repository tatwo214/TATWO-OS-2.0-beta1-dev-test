// W183 R3：共用的 ⓘ 說明鈕（使用者 09-27「用[ⓘ]這個說明開關功能」）。
// 側欄「分頁設計說明」那顆在 2.0 打開的是空殼（Tatwo2PlumbingStubs 回 EmptyView），真正的卡片只在 1.0；
// 設定浮層固定 780×560 又包在捲動區裡，自己疊上去的卡會被裁掉——所以這裡用系統的 .popover（照 ChatPage+Sidebar 的先例），
// 卡片外觀照 1.0 的說明卡（寬 300、段落短）。
import SwiftUI

struct OSInfoButton: View {
    let title: String
    let paragraphs: [String]
    var accessibilityID = "os-info-button"
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel("說明：\(title)")
        .accessibilityIdentifier(accessibilityID)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold))
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, text in
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(width: 300, alignment: .leading)
            .accessibilityIdentifier(accessibilityID + ".card")
        }
    }
}
