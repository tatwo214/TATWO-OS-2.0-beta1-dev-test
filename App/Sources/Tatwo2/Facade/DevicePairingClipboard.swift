import AppKit
import Combine

/// 只由畫面的複製鈕寫入。全部複製允許跨裝置貼上；碼到期或畫面離開時只清除自己那次寫入。
@MainActor
final class DevicePairingClipboard: ObservableObject {
    enum Item { case address, all }

    @Published private(set) var copied: Item?
    private let pasteboard: NSPasteboard
    private var ownedChange: Int?
    private var expiryTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    @discardableResult
    func copy(_ item: Item, address: String, code: String, expiresAt: Date, now: Date = Date()) -> Bool {
        guard expiresAt > now, DevicePairingInput.parseAddress(address) != nil,
              code.count == 6, DevicePairingInput.normalizedCode(code) == code else { return false }
        clear()
        // 不使用 currentHostOnly：使用者明確要求同一 Apple ID 的另一台可貼上。
        let change = pasteboard.prepareForNewContents(with: [])
        let text = item == .address ? address : DevicePairingInput.copyLine(address: address, code: code)
        guard pasteboard.setString(text, forType: .string), pasteboard.changeCount == change else { return false }
        copied = item
        feedbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self?.copied = nil
        }
        if item == .all {
            ownedChange = change
            expiryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(expiresAt.timeIntervalSince(now))) } catch { return }
                self?.clear()
            }
        }
        return true
    }

    func clear() {
        expiryTask?.cancel()
        expiryTask = nil
        feedbackTask?.cancel()
        feedbackTask = nil
        copied = nil
        if let ownedChange, pasteboard.changeCount == ownedChange {
            pasteboard.clearContents()
        }
        ownedChange = nil
    }
}
