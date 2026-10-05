import Foundation

final class OSClock: @unchecked Sendable {
    static let shared = OSClock()
    typealias Arm = (Date?, @escaping () -> Void) -> Void
    private struct Work {
        let source: String
        var at: Date?
        var condition: String?
        var next: ((Date) -> Date)?
        var repeating = false
        let action: () -> Void
    }
    private let lock = NSRecursiveLock()
    private let now: () -> Date
    private let arm: Arm?
    private var timer: DispatchSourceTimer?
    private var jobs: [String: Work] = [:]
    private var generation = 0
    private var wakeCount = 0
    var wakeups: Int { lock.lock(); defer { lock.unlock() }; return wakeCount }
    init(now: @escaping () -> Date = Date.init, arm: Arm? = nil) { self.now = now; self.arm = arm }
    var currentTime: Date { now() }
    deinit { timer?.cancel() }
    func schedule(source: String, at: Date, next: ((Date) -> Date)? = nil, action: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        jobs[source] = Work(source: source, at: at, next: next, action: action); rearm()
    }
    func when(source: String, condition: String, repeating: Bool = false, action: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        jobs[source] = Work(source: source, condition: condition, repeating: repeating, action: action); rearm()
    }
    func cancel(_ source: String) { lock.lock(); defer { lock.unlock() }; jobs[source] = nil; rearm() }
    func signal(_ condition: String) {
        lock.lock()
        let time = now()
        for key in jobs.keys.sorted() where jobs[key]?.condition == condition { jobs[key]?.at = time }
        lock.unlock(); runDue()
    }
    private func runDue(ticket: Int? = nil) {
        lock.lock()
        if let ticket, generation != ticket { lock.unlock(); return }
        let time = now()
        let due = jobs.values.filter { $0.at.map { $0 <= time } ?? false }.sorted {
            $0.at == $1.at ? $0.source < $1.source : $0.at! < $1.at!
        }
        wakeCount += 1
        for job in due {
            guard jobs[job.source]?.at == job.at else { continue }
            jobs[job.source] = nil
            if let next = job.next {
                var repeated = job; repeated.at = max(next(job.at!), time.addingTimeInterval(0.001)); jobs[job.source] = repeated
            } else if job.repeating { var repeated = job; repeated.at = nil; jobs[job.source] = repeated }
        }
        rearm(); lock.unlock()
        for job in due { job.action() }
    }
    private func rearm() {
        generation += 1; let ticket = generation
        let deadline = jobs.values.compactMap(\.at).min()
        let callback: () -> Void = { [weak self] in
            self?.runDue(ticket: ticket)
        }
        if let arm { arm(deadline, callback); return }
        timer?.cancel(); timer = nil
        guard let deadline else { return }
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        source.schedule(wallDeadline: .now() + max(0, deadline.timeIntervalSince(now())), leeway: .milliseconds(10))
        source.setEventHandler(handler: callback); timer = source; source.resume()
    }
    static func nextMonth(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(byAdding: .month, value: 1, to: calendar.dateInterval(of: .month, for: date)!.start)!
    }
}
