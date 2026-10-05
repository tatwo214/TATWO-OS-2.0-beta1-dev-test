#if DEBUG
import AppKit
import SwiftUI

// W183 R12（主導 1：「卡片永遠不蓋網頁…任何形態、任何大小（外直 0.7 倍也算），要按的東西都看得到」）：兩頁的時候卡片在左頁（w184forms 驗）；
// 單欄（外直、內直、使用者自己換掉兩頁）的時候，連線卡片擺在網頁下面：網頁的下緣停在卡片上緣。最高的卡（說明改了的全文、手動步驟）＋
// 最小的框（外直 ×0.7）都驗。讀畫面的檢查讀不到＝FAIL（不 skip）。

extension DMBrowserPhoneAcceptance {
    @MainActor static func r12YieldChecks(_ check: Checker) async {
        let phone = Phone("r12-yield")
        phone.store.showBrowser()
        _ = phone.browser.openPod(purpose: .chatgptDeveloper)
        phone.browser.podFrame(HandsPodFrame(url: URL(string: "https://chatgpt.com/plugins"), generation: 1, loading: false, httpStatus: 200))
        let url = "https://\(HandsConnectAcceptance.publicHost)/mcp"
        let cards: [(String, HandsConnectCard)] = [
            ("tick-missed", .waitingUser(HandsConnectFlow.tickMissedCardText, continuable: true)),
            ("consent", .consent(GlobalDMFormsAcceptance.r12OfferConsent)),
            ("manual", .manual(url: url, steps: HandsConnectFlow.manualSteps(url))),
        ]
        let sizes = [CGSize(width: 466, height: 610),
                     CGSize(width: (466 * 0.7).rounded(), height: ((GlobalDMForm.outerPortrait.size.height - DMPhone.headerHeight) * 0.7).rounded())]
        for (name, card) in cards {
            phone.box.card = card
            phone.presenter.show()
            for size in sizes {
                guard let rendered = GlobalDMChatAcceptance.renderSync(phone.pane(probes: true), size: size) else {
                    check(false, "R12 yield \(name) \(Int(size.width))×\(Int(size.height)): could not render (screen checks must not be skipped)")
                    continue
                }
                let page = probeFrame("page.frame", in: rendered.host)
                let frame = probeFrame("card.frame", in: rendered.host)
                let apart = page.flatMap { p in frame.map { !p.insetBy(dx: 0.5, dy: 0.5).intersects($0.insetBy(dx: 0.5, dy: 0.5)) } } ?? false
                let above = page.flatMap { p in frame.map { p.minY >= $0.maxY - 1 } } ?? false   // 視窗座標：y 往上
                check(apart && above && (page?.height ?? 0) > 40,
                      "R12 one column (\(name), \(Int(size.width))×\(Int(size.height))): the connect card sits below the web page and the page stops above it (no overlap; the page is still there)",
                      "page=\(String(describing: page)) card=\(String(describing: frame))")
                rendered.close()
            }
        }
        phone.presenter.hide()
        phone.browser.closeAll()
    }
}
#endif
