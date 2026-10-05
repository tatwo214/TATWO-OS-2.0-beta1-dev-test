#if DEBUG
import AppKit
import SwiftUI

extension HandsConnectAcceptance {
    @MainActor static func pairingClipboardChecks(_ check: Checker) async {
        // 全部使用合成碼與獨立剪貼簿；不讀寫使用者的 general pasteboard。
        let board = NSPasteboard(name: .init("tatwo-pairing-copy-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let clipboard = HandsPairingClipboard(pasteboard: board)
        defer { clipboard.clear() }
        let now = Date()
        func view(_ code: String? = "AB23CD45", expires: Date? = nil,
                  attempts: Int = 5, display: String = "test-transaction") -> HandsConnectPairingView {
            .init(displayCode: display, expiresAt: expires ?? now.addingTimeInterval(60),
                  attemptsLeft: attempts, callbackHost: "example.test", pairingCode: code, popup: false)
        }
        let shown = view()
        check(clipboard.copy(shown, current: shown, visible: true, now: now)
              && board.string(forType: .string) == "AB23CD45",
              "複製配對碼：字母數字八碼原樣複製，不含分隔空白（合成碼）")
        clipboard.clear()
        check(board.string(forType: .string) == nil, "複製配對碼：流程清除會移除自己寫入的碼")
        board.setString("user-later-content", forType: .string)
        let before = board.changeCount
        for (label, candidate, current, visible) in [
            ("hidden", shown, Optional(shown), false),
            ("stale", shown, Optional(view(display: "new-transaction")), true),
            ("finished", shown, nil, true),
            ("expired", view(expires: now), Optional(view(expires: now)), true),
            ("missing", view(nil), Optional(view(nil)), true),
            ("attempts", view(attempts: 0), Optional(view(attempts: 0)), true),
            ("malformed", view("1234 5678"), Optional(view("1234 5678")), true),
            ("disallowed", view("01234567"), Optional(view("01234567")), true),
            ("unicode", view("１２３４５６７８"), Optional(view("１２３４５６７８")), true)
        ] {
            check(!clipboard.copy(candidate, current: current, visible: visible, now: now)
                  && board.changeCount == before, "複製配對碼：\(label) 拒絕且不碰剪貼簿")
        }
        _ = clipboard.copy(shown, current: shown, visible: true, now: now)
        board.clearContents()
        board.setString("new-user-copy", forType: .string)
        clipboard.clear()
        check(board.string(forType: .string) == "new-user-copy", "複製配對碼：不清掉使用者後來複製的內容")
        let short = view(expires: Date().addingTimeInterval(0.05))
        _ = clipboard.copy(short, current: short, visible: true)
        try? await Task.sleep(for: .milliseconds(100))
        check(board.string(forType: .string) == nil, "複製配對碼：到期自動清除")
        // 只拍合成測試卡；沿用遮碼機制，不擷取任何真實配對畫面。
        let capture = DMSecretCodeView.holdForCapture()
        defer { DMSecretCodeView.releaseCapture(capture) }
        let fixture = HandsConnectFloatCardView(
            card: .pairing(shown),
            context: .init(phase: .waitingPairing, revealsCode: true),
            actions: .init())
        if let root = ProcessInfo.processInfo.environment["TATWO_STAGING_ROOT"],
           let rendered = GlobalDMChatAcceptance.renderSync(fixture, size: .init(width: 390, height: 300)) {
            defer { rendered.close() }
            let url = URL(fileURLWithPath: root).appendingPathComponent("pairing-copy-fixture.png")
            let png = rendered.bitmap.representation(using: .png, properties: [:])
            check(png != nil && (try? png?.write(to: url)) != nil,
                  "複製配對碼：原生卡片畫面證據（合成資料、配對碼遮蔽）")
        } else {
            check(false, "複製配對碼：原生卡片畫面無法建立")
        }
    }
}
#endif
