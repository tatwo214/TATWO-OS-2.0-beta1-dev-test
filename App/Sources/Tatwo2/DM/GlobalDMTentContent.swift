import SwiftUI

// W184 AB → 房 E（spec E：倒放＝影片子畫面；主導 09-29：倒放沒有頂列，整塊都是這個）：
// 倒放（678×466、圓角 52）整塊就是 GlobalDMTentContent。
// W184 E：內容是 GlobalDMTentPane——Browser 分頁正在播的影片（DMTentVideo 借來的 CEF 畫面，不重新載入）、滑鼠移入才浮出的控制、
// 沒有影片的一句話＋一顆鈕、有事時蓋上來的三種卡。離開倒放：⌘⌥Tab（或卡上的鈕呼叫 GlobalDMDeskController.shared.setForm(_:animated:)）；
// ⌥⌘ 開關、Esc 收框照舊（收框＝影片還回主視窗的分頁）。
// 原生網頁畫面（影片的 CEF）放在 DMTentVideoContainer（實作 GlobalDMNativePageHost）：進倒放等轉換動畫走完才掛上，離開倒放在動畫開始前先還回。
struct GlobalDMTentContent: View {
    @ObservedObject var store: GlobalDMStore

    var body: some View {
        Group {
            if let model = store.model {
                GlobalDMTentPane(store: store, model: model, video: .shared)
            } else {
                // 私訊框還在準備（整支手機的外框在 model 接上前本來就不畫這裡；保險起見一句話）。
                Text(DMTentEmpty.text(playingElsewhere: false))
                    .font(.system(size: DMPhone.TextSize.body, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo.dm.tent")
    }
}
