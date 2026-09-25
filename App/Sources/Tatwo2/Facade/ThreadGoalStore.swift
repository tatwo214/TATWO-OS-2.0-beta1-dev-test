import Foundation

/// W170：每條討論串一份目標清單，存在 live 根目錄 goals/<討論串>.json。
/// 畫面、/goal、/plan、/plg、引擎工具都走這一個地方；檔案寫入是整份原子替換。
final class ThreadGoalStore: ObservableObject, @unchecked Sendable {
    static let shared = ThreadGoalStore()
    @MainActor @Published private(set) var revision = 0
    private let lock = NSLock()
    private let root: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let live = environment["TATWO2_LIVE_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/tatwo2/live")
        root = live.appendingPathComponent("goals", isDirectory: true)
    }

    private func url(_ thread: UUID) -> URL { root.appendingPathComponent(thread.uuidString.lowercased() + ".json") }

    func list(_ thread: UUID) -> ThreadGoalList {
        lock.lock(); defer { lock.unlock() }
        return read(thread)
    }

    /// 在同一把鎖裡讀、改、寫，失敗就不寫。
    @discardableResult
    func update<T>(_ thread: UUID, _ change: (inout ThreadGoalList) throws -> T) throws -> T {
        lock.lock()
        var list = read(thread)
        let result: T
        do { result = try change(&list); try write(list, thread) }
        catch { lock.unlock(); throw error }
        lock.unlock()
        Task { @MainActor in self.revision += 1 }
        return result
    }

    /// 專案總覽：多條討論串還沒完成的目標。
    func openGoals(threads: [UUID]) -> [(UUID, [ThreadGoal])] {
        threads.compactMap { thread in
            let open = list(thread).goals.filter { $0.status != .done }
            return open.isEmpty ? nil : (thread, open)
        }
    }

    private func read(_ thread: UUID) -> ThreadGoalList {
        guard let data = try? Data(contentsOf: url(thread)) else { return ThreadGoalList() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ThreadGoalList.self, from: data)) ?? ThreadGoalList()
    }

    private func write(_ list: ThreadGoalList, _ thread: UUID) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: url(thread), options: .atomic)
    }
}
