import AppKit
import SwiftUI

/// W114（使用者 2026-09-20：「"空間"長期沒有水平對齊紅綠燈 喬很多次 dia就對齊很好」）。
/// 之前每次都用算出來的常數（上邊距 16＋半徑 7＝23），實機量到關閉鈕的中心是 21，各版 macOS 也不一樣。
/// 改成直接量：關閉鈕在視窗裡的中心線，以及自己在視窗裡的位置，相減就是要補的量。不管容器怎麼出現都對得上。
struct TrafficLightAlignedTitle<Content: View>: View {
    let height: CGFloat
    /// 文字在按鈕框裡視覺上略偏下，補回來（自測 .011：文字中心比框中心低約 1 pt）。
    var opticalLift: CGFloat = 1
    @ViewBuilder var content: Content
    @State private var lightCenterY: CGFloat = WindowChromeMetrics.trafficLightTopInset + WindowChromeMetrics.nativeTrafficLightDiameter / 2

    var body: some View {
        GeometryReader { proxy in
            content
                .frame(height: height)
                .offset(y: lightCenterY - height / 2 - opticalLift - proxy.frame(in: .global).minY)
        }
        .frame(height: height)
        .background(TrafficLightCenterReader(centerY: $lightCenterY))
    }
}

private struct TrafficLightCenterReader: NSViewRepresentable {
    @Binding var centerY: CGFloat
    /// 只量位置，不吃任何滑鼠事件。
    final class PassthroughView: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
    func makeNSView(context: Context) -> NSView { PassthroughView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window, let button = window.standardWindowButton(.closeButton) else { return }
            let frame = button.convert(button.bounds, to: nil)          // 視窗座標，原點在視窗左下
            let measured = window.frame.height - frame.midY              // 內容鋪滿整個視窗（fullSizeContentView），視窗頂＝SwiftUI 的 global 0
            if measured > 4, measured < 60, abs(measured - centerY) > 0.25 { centerY = measured }
        }
    }
}
