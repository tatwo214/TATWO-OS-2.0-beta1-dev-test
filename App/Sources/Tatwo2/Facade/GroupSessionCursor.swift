import Foundation

/// Group pointers and read_session must count the same visible, ordered transcript rows.
enum GroupSessionCursor {
    private static func visible(_ row: ChatMessage) -> Bool {
        !(row.status?.hasPrefix(TatwoMemoryUsageNote.status) ?? false)
            && !(row.role == .system && [CoderImport.summaryStatus, "info|支線摘要"].contains(row.status ?? ""))
    }
    static func count(_ rows: [ChatMessage]) -> Int { rows.lazy.filter(visible).count }
    static func offset(_ row: ChatMessage, in rows: [ChatMessage]) -> Int? {
        let rows = rows.filter(visible)
        guard let position = rows.firstIndex(where: { $0.id == row.id }) else { return nil }
        return rows.enumerated().filter { $0.element.createdAt < row.createdAt || $0.element.createdAt == row.createdAt && $0.offset < position }.count
    }
    static func rows(_ rows: [ChatMessage]) -> [ChatMessage] {
        rows.filter(visible)
            .enumerated().sorted { $0.element.createdAt == $1.element.createdAt ? $0.offset < $1.offset : $0.element.createdAt < $1.element.createdAt }.map(\.element)
    }
}
