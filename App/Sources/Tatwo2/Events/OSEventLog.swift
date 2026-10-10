import Foundation

struct OSEvent: Codable, Equatable, Sendable {
    var v = 1
    var id = UUID().uuidString.lowercased()
    var at: String
    var project: String
    var thread: String?
    var actor: String
    var kind: String
    var purpose: String?
    var used: [String]?
    var result: String?
    var size: Int?
    var note: String?
    var origin: String?
    var surface: String?
    var turn: String?
    var workspace: String?
    var tokens: Int?
    var estimated: Bool?
    var device: String?
}

final class OSEventLog: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var logs: [String: OSEventLog] = [:]
    static func atRoot(_ root: URL) -> OSEventLog {
        registryLock.lock(); defer { registryLock.unlock() }
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        if let log = logs[key] { return log }
        let log = OSEventLog(root: root); logs[key] = log; return log
    }
    static func flushAll() {
        let group = DispatchGroup(); group.enter()
        DispatchQueue.global(qos: .utility).async {
            registryLock.lock(); let pending = Array(logs.values); registryLock.unlock()
            for log in pending { group.enter(); DispatchQueue.global(qos: .utility).async { defer { group.leave() }; try? log.flush() } }
            group.leave()
        }
        _ = group.wait(timeout: .now() + 1)
    }
    static var liveRoot: URL {
        ProcessInfo.processInfo.environment["TATWO2_LIVE_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("tatwo2/live")
    }
    static func stamp(_ date: Date) -> String { date.ISO8601Format(.init(includingFractionalSeconds: true)) }
    let root: URL
    private let queue = DispatchQueue(label: "ai.tatwo.os-events", qos: .utility)
    private let clock: OSClock
    private let encoder = JSONEncoder()
    private var handles: [URL: FileHandle] = [:]
    private var error: Error?
    private let device = (try? DeviceIdentityStore.readLocal())?.deviceID.lowercased()
    private var recordedIDs: Set<String> = []
    init(root: URL, clock: OSClock = .shared) {
        self.root = root; self.clock = clock
        clock.schedule(source: "events-month-" + root.path, at: OSClock.nextMonth(after: clock.currentTime), next: OSClock.nextMonth) { [weak self] in
            self?.queue.async { [weak self] in self?.closeMonth() }
        }
    }
    deinit { clock.cancel("events-month-" + root.path); for handle in handles.values { try? handle.close() } }
    var openFileCount: Int { queue.sync { handles.count } }
    private func closeMonth() { for handle in handles.values { try? handle.close() }; handles.removeAll() }
    func file(project: UUID?, at: Date) -> URL {
        root.appendingPathComponent("events/" + (project?.uuidString.lowercased() ?? "一般"))
            .appendingPathComponent(String(Self.stamp(at).prefix(7)) + ".jsonl")
    }
    func append(project: UUID?, thread: UUID? = nil, actor: String, kind: String, at: Date = Date(), purpose: String? = nil,
                used: [String]? = nil, result: String? = nil, size: Int? = nil, sizeText: String? = nil, note: String? = nil, id: String? = nil, origin: String? = nil, surface: String? = nil, turn: String? = nil, workspace: UUID? = nil, tokens: Int? = nil, estimated: Bool? = nil) {
        queue.async { [self] in
            if let id, recordedIDs.contains(id) { return }
            let safe = note.map { text -> String in
                let masked = HandsRedactor.redact(HandsSecretLines.maskText(text))
                return String((TatwoMemoryStore.containsSecret(masked) ? "[已遮蔽：疑似秘密]" : masked).split(whereSeparator: \.isNewline).joined(separator: " ").prefix(120))
            }
            var row = OSEvent(at: Self.stamp(at), project: project?.uuidString.lowercased() ?? "一般", thread: thread?.uuidString.lowercased(),
                              actor: actor, kind: kind, purpose: purpose, used: used, result: result, size: size ?? sizeText?.count, note: safe,
                              origin: origin, surface: surface, turn: turn, workspace: workspace?.uuidString.lowercased(), tokens: tokens, estimated: estimated, device: device)
            if let id { row.id = id }
            do { try write(row, to: file(project: project, at: at)); if let id { recordedIDs.insert(id) } } catch { self.error = error; fputs("OS events write failed\n", stderr) }
        }
    }
    private func write(_ row: OSEvent, to url: URL) throws {
        let handle: FileHandle
        if let existing = handles[url] { handle = existing } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            handle = try FileHandle(forUpdating: url); handles[url] = handle
        }
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([10]) { try handle.seekToEnd(); try handle.write(contentsOf: Data([10])) }
        }
        try handle.seekToEnd(); var data = try encoder.encode(row); data.append(10); try handle.write(contentsOf: data)
    }
    func flush() throws { try queue.sync { for handle in handles.values { try handle.synchronize() }; if let error { throw error } } }
    func revision(project: UUID) throws -> String {
        try queue.sync {
            let folder = file(project: project, at: Date()).deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: folder.path) else { return "" }
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]).filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path }.map {
                let value = try $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return "\($0.lastPathComponent):\(value.fileSize ?? 0):\(value.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            }.joined(separator: ";")
        }
    }
    func query(project: UUID?, from: Date, through: Date, kinds: Set<String> = []) throws -> [OSEvent] {
        try queue.sync {
            let folder = file(project: project, at: from).deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
            let lo = Self.stamp(from), hi = Self.stamp(through), decoder = JSONDecoder()
            var found: [OSEvent] = []
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                let month = String(url.lastPathComponent.prefix(7))
                guard url.pathExtension == "jsonl", month >= String(lo.prefix(7)), month <= String(hi.prefix(7)) else { continue }
                let data = try Data(contentsOf: url)
                var rows: [OSEvent] = [], damaged: [String] = [], offset = 0
                for line in data.split(separator: 10, omittingEmptySubsequences: false) {
                    defer { offset += line.count + 1 }; if line.isEmpty { continue }
                    if let row = try? decoder.decode(OSEvent.self, from: Data(line)) { rows.append(row) }
                    else { damaged.append("\(month):\(offset)") }
                }
                let time = clock.currentTime
                let recorded = Set(rows.filter { $0.kind == "log_recovery" }.map(\.id))
                for marker in damaged {
                    let id = "recovery:\(project?.uuidString.lowercased() ?? "一般"):\(marker)"
                    guard !recorded.contains(id) else { continue }
                    let row = OSEvent(id: id, at: Self.stamp(time), project: project?.uuidString.lowercased() ?? "一般",
                                      actor: "系統", kind: "log_recovery", note: "略過損壞的事件行", device: device)
                    try? write(row, to: url)
                }
                found += rows.filter { $0.project == (project?.uuidString.lowercased() ?? "一般") && $0.at >= lo && $0.at <= hi && (kinds.isEmpty || kinds.contains($0.kind)) }
            }
            return found
        }
    }
}
