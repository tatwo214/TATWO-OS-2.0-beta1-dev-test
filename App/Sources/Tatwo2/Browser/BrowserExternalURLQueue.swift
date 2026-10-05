import Foundation

extension Notification.Name {
    static let tatwoBrowserOpenExternalURLs = Notification.Name("tatwo.browser.openExternalURLs")
}

/// Notifications wake mounted views; this inbox retains deliveries while no view exists.
/// Main-actor ownership makes each accepted batch drain once, including reentrant deliveries.
@MainActor
final class BrowserExternalURLQueue {
    /// W183 R3b：sensitive＝一次性的授權網址（例如 Cloudflare 的授權頁）：開成只在記憶體的分頁
    /// （BrowserTabRegistry.openTab(sensitive:)：不進 tabs.json、最近關閉、空間封存）。
    struct Item: Equatable {
        let url: URL
        let sensitive: Bool
    }

    static let shared = BrowserExternalURLQueue()
    private var pending: [Item] = []
    private let notifications: NotificationCenter
    var hasPendingURLs: Bool { !pending.isEmpty }

    init(notifications: NotificationCenter = .default) { self.notifications = notifications }

    static func accepts(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": return !(url.host ?? "").isEmpty
        // 2.0.7: local files are not accepted (the human policy only loads http/https).
        default: return false
        }
    }

    @discardableResult
    func enqueue(_ urls: [URL]) -> Bool { enqueue(urls, sensitive: false) }

    @discardableResult
    func enqueue(_ urls: [URL], sensitive: Bool) -> Bool {
        let accepted = urls.filter(Self.accepts)
        guard !accepted.isEmpty else { return false }
        pending.append(contentsOf: accepted.map { Item(url: $0, sensitive: sensitive) })
        notifications.post(name: .tatwoBrowserOpenExternalURLs, object: self)
        return true
    }

    func consume(whenMounted mounted: Bool, open: ([URL]) -> Void) {
        consumeItems(whenMounted: mounted) { open($0.map(\.url)) }
    }

    /// W183 R3b：分頁要知道哪些是敏感的（BrowserWorkSpaceLifecycle 用這個）。
    func consumeItems(whenMounted mounted: Bool, open: ([Item]) -> Void) {
        guard mounted, !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        open(batch)
    }
}
