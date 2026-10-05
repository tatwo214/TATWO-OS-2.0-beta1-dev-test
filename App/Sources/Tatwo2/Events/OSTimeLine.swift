import Foundation

enum OSTimeLine {
    struct Line {
        let nowIndex: Int
        let lastIndex: Int?
        let between: Int
        let elapsed: TimeInterval?
        let text: String
    }
    static func describe(rows: [OSEvent], participant: String) -> Line {
        let current = rows.count, last = rows.indices.dropLast().last { rows[$0].actor == participant }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let elapsed = last.flatMap { i in formatter.date(from: rows[i].at).flatMap { prior in rows.last.flatMap { formatter.date(from: $0.at)?.timeIntervalSince(prior) } } }
        let between = last.map { max(0, current - $0 - 2) } ?? current
        let text = "現在第\(current)筆，\(rows.last?.at ?? "—")；\(participant)上次\(last.map { "第\($0 + 1)筆，\(rows[$0].at)" } ?? "—")；中間\(between)筆，\(elapsed.map { "\(Int($0))秒" } ?? "—")"
        return Line(nowIndex: current, lastIndex: last.map { $0 + 1 }, between: between, elapsed: elapsed, text: text)
    }
}
