import AppKit

/// 只由使用者按「複製」觸發；不代填、不讀回剪貼簿、不記錄碼。
@MainActor
final class HandsPairingClipboard {
    private let pasteboard: NSPasteboard
    private var ownedChange: Int?
    private var expiryTask: Task<Void, Never>?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    static func mayCopy(_ shown: HandsConnectPairingView, current: HandsConnectPairingView?,
                        visible: Bool, now: Date) -> Bool {
        guard visible, current == shown, shown.expiresAt > now, shown.attemptsLeft > 0,
              let code = shown.pairingCode, code.utf8.count == 8 else { return false }
        return code.allSatisfy { HandsAuth.codeAlphabet.contains($0) }
    }

    func copy(_ shown: HandsConnectPairingView, current: HandsConnectPairingView?,
              visible: Bool, now: Date = Date()) -> Bool {
        guard Self.mayCopy(shown, current: current, visible: visible, now: now),
              let code = shown.pairingCode else { return false }
        clear()
        let change = pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard pasteboard.setString(code, forType: .string),
              pasteboard.changeCount == change else { return false }
        ownedChange = change
        let seconds = min(60, shown.expiresAt.timeIntervalSince(now))
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            guard let self, self.ownedChange == change else { return }
            self.clear()
        }
        return true
    }

    /// 不清掉使用者後來複製的其他內容，也不把舊剪貼簿保存起來。
    func clear() {
        expiryTask?.cancel()
        expiryTask = nil
        if let ownedChange, pasteboard.changeCount == ownedChange {
            pasteboard.clearContents()
        }
        ownedChange = nil
    }
}
