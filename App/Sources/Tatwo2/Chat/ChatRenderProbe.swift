#if DEBUG
import Foundation

/// Opt-in counters; never publish observable state or retain conversation contents.
@MainActor enum ChatRenderProbe {
    static var enabled = ProcessInfo.processInfo.environment["TATWO2_SELFTEST"] == "w202perf"
    static weak var browserStore: BrowserWorkSpaceStore?
    private(set) static var counts: [String: Int] = [:]
    static func record(_ name: String) {
        guard enabled else { return }
        counts[name, default: 0] += 1
    }
    static func reset() { counts.removeAll(keepingCapacity: true) }
}
#endif
