import Foundation

/// Client-side selections are scoped to the device that owns the conversation.
/// Remote ready entries remain durable until the next explicit send to that host.
@MainActor final class PendingModelSelections {
    struct Entry: Codable, Equatable {
        var deviceID: String
        var threadID: UUID
        var routeID: String
        var pending: Bool
    }
    private let file: URL
    private var entries: [String: Entry] = [:]
    private var loadError: Error?
    init(root: URL) {
        file = root.appendingPathComponent("pending-model-selections.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { entries = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: file)) }
            catch { loadError = error } // Preserve an unreadable original; never overwrite it with an empty queue.
        }
    }
    private func key(_ deviceID: String, _ threadID: UUID) -> String { deviceID + ":" + threadID.uuidString }
    func entry(deviceID: String, threadID: UUID?) -> Entry? {
        threadID.flatMap { entries[key(deviceID, $0)] }
    }
    var queued: [Entry] { entries.values.filter(\.pending) }
    func set(deviceID: String, threadID: UUID, routeID: String?, pending: Bool) throws {
        if let loadError { throw loadError }
        var next = entries
        let key = key(deviceID, threadID)
        next[key] = routeID.map { Entry(deviceID: deviceID, threadID: threadID, routeID: $0, pending: pending) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        entries = next
    }
}
