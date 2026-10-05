import AppKit

/// W183 R8b 審查（GPT-6、Claude）：「不給擷取」以視窗為單位計數——連線卡片（HandsConnectPresenter）與 Browser 的敏感分頁（DMBrowser）
/// 可能同時保護同一個私訊框視窗；各自記原值、各自還原會把還在保護的視窗放開（或卡在不給擷取）。第一個持有者記下原本的設定，
/// 最後一個放手才還原。
/// W184 D（GPT-6 審查 #1：配對碼還在退場動畫裡，保護已經放掉）：最後一個持有者放手之後，視窗再擋 `linger` 這麼久才還原——
/// 退場動畫的尾巴、合成器還沒換掉的最後一幀都還在保護裡；這段時間又有人持有＝不還原。還原用 run loop 上的計時器（common 模式：
/// 巢狀的 run loop 也輪得到）。持有者本身照舊馬上放手（holders 只數還拿著的）。
@MainActor
final class WindowCaptureShield {
    static let shared = WindowCaptureShield()
    /// 最後一個放手之後再擋多久（比私訊框裡最長的退場動畫 0.36 秒的 sheet 還久一點）。
    static let linger: TimeInterval = 0.45

    @MainActor private final class Entry {
        weak var window: NSWindow?
        let original: NSWindow.SharingType
        var holders: Set<ObjectIdentifier> = []
        /// 最後一個放手之後、還原之前的那一小段。
        var restore: Timer?
        init(window: NSWindow) {
            self.window = window
            original = window.sharingType
        }
    }

    private var entries: [Entry] = []
    private var holding: [ObjectIdentifier: Entry] = [:]

    /// holder 要保護這個視窗（nil＝不保護了）。一個持有者一次只保護一個視窗；換視窗＝先放開舊的（舊的照樣再擋 linger）。
    func hold(_ holder: AnyObject, window: NSWindow?) {
        let key = ObjectIdentifier(holder)
        if let current = holding[key] {
            if let window, current.window === window {
                window.sharingType = .none   // 還在保護：再設一次（別處改過也拉回來）
                return
            }
            drop(key, current)
        }
        guard let window else { return }
        entries.removeAll { $0.window == nil }
        let entry: Entry
        if let existing = entries.first(where: { $0.window === window }) {
            entry = existing
        } else {
            entry = Entry(window: window)
            entries.append(entry)
        }
        entry.restore?.invalidate()   // 還在最後一小段又有人持有：不還原
        entry.restore = nil
        entry.holders.insert(key)
        holding[key] = entry
        window.sharingType = .none
    }

    func release(_ holder: AnyObject) { hold(holder, window: nil) }

    /// 這個持有者現在保護的視窗（自測看）。
    func window(heldBy holder: AnyObject) -> NSWindow? { holding[ObjectIdentifier(holder)]?.window }

    /// 這個視窗現在有幾個持有者（自測看；最後一小段不算持有者）。
    func holders(of window: NSWindow) -> Int { entries.first { $0.window === window }?.holders.count ?? 0 }

    /// 這個視窗現在不給擷取：有持有者，或最後一個放手之後還在 linger 那一小段（自測看）。
    func isShielding(_ window: NSWindow) -> Bool { entries.contains { $0.window === window } }

    private func drop(_ key: ObjectIdentifier, _ entry: Entry) {
        holding[key] = nil
        entry.holders.remove(key)
        guard entry.holders.isEmpty, entry.restore == nil else { return }
        let timer = Timer(timeInterval: Self.linger, repeats: false) { [weak self, weak entry] _ in
            MainActor.assumeIsolated {
                guard let self, let entry, entry.holders.isEmpty else { return }
                entry.restore = nil
                entry.window?.sharingType = entry.original
                self.entries.removeAll { $0 === entry }
            }
        }
        entry.restore = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
