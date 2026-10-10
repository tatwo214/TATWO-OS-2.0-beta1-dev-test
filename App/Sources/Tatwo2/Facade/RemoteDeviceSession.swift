import Combine
import Foundation
import CryptoKit
import Darwin

struct RemoteThreadRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let statusLine: String
    let isRunning: Bool
}

struct RemoteProjectRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let threads: [RemoteThreadRow]
}

struct RemoteSidebarSection: Identifiable, Equatable, Sendable {
    var id: String { deviceID }
    let deviceID: String
    let deviceName: String
    let isOnline: Bool
    let lastSeenAt: Date
    let projects: [RemoteProjectRow]
    /// W182 R4：離線但有離線副本時＝最後同步的時間（側欄照樣列出專案與串、整區變淡）；在線或沒有副本是 nil。
    var offlineSyncedAt: Date? = nil
}

struct RemoteThreadTransferMessage: Codable, Equatable, Sendable {
    let role: String
    let text: String
    let createdAt: Date

    init(role: String, text: String, createdAt: Date) {
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }

    init(_ message: ChatMessage) {
        role = message.role.storageValue
        text = message.text
        createdAt = message.createdAt
    }

    var chatMessage: ChatMessage {
        let parsedRole: ChatMessageRole
        switch role {
        case "user": parsedRole = .user
        case "system": parsedRole = .system
        default: parsedRole = .assistant
        }
        return ChatMessage(role: parsedRole, text: text, createdAt: createdAt)
    }
}

struct RemoteThreadTransferFile: Codable, Equatable, Sendable {
    let relativePath: String
    let base64: String
    // nil is a legacy/unproven packet, never permission to overwrite. "missing" is explicit.
    var baseSHA256: String? = nil
}

enum RemoteThreadTransfer {
    static let missing = "missing"
    private static let transactionLock = NSLock()
    enum TransferError: Error, LocalizedError {
        case unsafeRelativePath(String)
        case unreadableFile(String)
        case invalidBase64(String)
        case conflicts([String])
        case recoveryRequired(String)

        var errorDescription: String? {
            switch self {
            case .unsafeRelativePath(let path): "unsafe_relative_path: \(path)"
            case .unreadableFile(let path): "unreadable_file: \(path)"
            case .invalidBase64(let path): "invalid_base64: \(path)"
            case .conflicts(let paths): "conflicts: " + paths.joined(separator: ", ")
            case .recoveryRequired(let detail): "recovery_required: \(detail)"
            }
        }
    }

    struct Candidate {
        let path: String
        let automatic: Bool
        let observedSHA256: String?
    }

    /// Read every turn, not only latest.json. A git observation is NOT a thread edit.
    static func candidates(threadID: UUID, artifactsRoot: URL, workdir: String) throws -> [Candidate] {
        let folder = artifactsRoot.appendingPathComponent(threadID.uuidString)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "latest.json" }
        var indexes: [TurnArtifactIndex] = []
        for url in urls {
            let data = try Data(contentsOf: url)
            guard data.count <= TurnArtifacts.maxIndexBytes else { throw TransferError.unreadableFile("artifact index") }
            let index = try JSONDecoder().decode(TurnArtifactIndex.self, from: data)
            guard index.threadID == threadID, index.artifacts.count <= TurnArtifacts.maxPaths else {
                throw TransferError.unreadableFile("artifact index")
            }
            indexes.append(index)
        }
        var rows: [String: TurnArtifact] = [:]
        for index in indexes.sorted(by: { $0.endedAt < $1.endedAt }) {
            for row in index.artifacts where !row.outside {
                // Keep the last structured edit even when later turns merely observe it.
                if row.claimed || rows[row.path]?.claimed != true { rows[row.path] = row }
            }
        }
        return try rows.keys.sorted().map { path in
            let row = rows[path]!
            let current = try snapshot(path, in: workdir)
            let observed = current.map { digest($0.data) }
            return Candidate(path: path, automatic: row.claimed && row.exists && current != nil
                && row.sha256 == observed, observedSHA256: observed)
        }
    }

    /// Compatibility for pull_thread: without thread provenance, transfer messages only.
    /// Never fall back to a whole-worktree git status inventory.
    static func changedFiles(in workdir: String) -> [RemoteThreadTransferFile] { [] }

    static func changedFiles(in workdir: String, paths: [String], baselines: [String: String],
                             observedHashes: [String: String]? = nil) throws -> [RemoteThreadTransferFile] {
        try paths.sorted().map { path in
            guard let base = baselines[path], let current = try snapshot(path, in: workdir) else {
                throw TransferError.unreadableFile(path)
            }
            if let observedHashes, observedHashes[path] != digest(current.data) {
                throw TransferError.conflicts([path + " (source changed after selection)"])
            }
            return RemoteThreadTransferFile(relativePath: path, base64: current.data.base64EncodedString(), baseSHA256: base)
        }
    }

    /// Sender's common ancestor must agree with the peer's original, not simply bless any
    /// same-name file currently on the peer. No HEAD / unknown ancestry fails closed.
    static func sourceBaselines(in workdir: String, paths: [String]) throws -> [String: String] {
        func git(_ args: [String]) throws -> (Int32, Data) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["--literal-pathspecs", "-C", workdir] + args
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return (p.terminationStatus, data)
        }
        let (status, headData) = try git(["rev-parse", "--verify", "HEAD"])
        guard status == 0 else { throw TransferError.unreadableFile("git HEAD baseline") }
        let head = String(decoding: headData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let (prefixStatus, prefixData) = try git(["rev-parse", "--show-prefix"])
        guard prefixStatus == 0 else { throw TransferError.unreadableFile("git path baseline") }
        let prefix = String(decoding: prefixData.dropLast(prefixData.last == 10 ? 1 : 0), as: UTF8.self)
        var result: [String: String] = [:]
        for path in paths {
            _ = try validatedRelativePath(path)
            let fullPath = prefix + path
            let (found, data) = try git(["show", "\(head):\(fullPath)"])
            if found == 0 { result[path] = digest(data) }
            else {
                let (listed, names) = try git(["ls-tree", "-z", "--full-tree", head, "--", fullPath])
                guard listed == 0, names.isEmpty else { throw TransferError.unreadableFile(path) }
                result[path] = missing
            }
        }
        return result
    }

    static func baselines(paths: [String], in workdir: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for path in paths { result[path] = try snapshot(path, in: workdir).map { digest($0.data) } ?? missing }
        return result
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Snapshot { let data: Data; let mode: mode_t }

    /// No symlink component is followed, including dangling links and the final leaf.
    /// Keep directory descriptors pinned for writes and rollback (not string-only checks).
    private static func parent(_ path: String, root: String) throws -> (Int32, String)? {
        let parts = try validatedRelativePath(path).split(separator: "/").map(String.init)
        let canonical = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        var fd = Darwin.open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TransferError.unreadableFile(path) }
        for part in parts.dropLast() {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno; Darwin.close(fd)
            if next < 0 {
                if code == ENOENT { return nil }
                throw TransferError.unsafeRelativePath(path)
            }
            fd = next
        }
        return (fd, parts.last!)
    }

    private static func read(_ name: String, at fd: Int32) throws -> Snapshot? {
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0 {
            if errno == ENOENT { return nil }
            throw TransferError.unsafeRelativePath(name)
        }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw TransferError.unsafeRelativePath(name) }
        return Snapshot(data: try handle.readToEnd() ?? Data(), mode: info.st_mode & 0o777)
    }

    private static func snapshot(_ path: String, in root: String) throws -> Snapshot? {
        guard let (fd, name) = try parent(path, root: root) else { return nil }
        defer { Darwin.close(fd) }
        return try read(name, at: fd)
    }

    private static func install(_ data: Data, name: String, fd: Int32, mode: mode_t, leftovers: inout [(Int32, String)]) throws {
        let stage = ".w72-" + UUID().uuidString
        let file = openat(fd, stage, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard file >= 0 else { throw TransferError.unreadableFile(name) }
        leftovers.append((fd, stage))
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        guard fchmod(file, mode) == 0, fsync(file) == 0, renameat(fd, stage, fd, name) == 0 else {
            throw TransferError.unreadableFile(name)
        }
        leftovers.removeLast()
    }

    /// Originals are copied outside the project before the first write. Successful or
    /// rolled-back receipts go to macOS Trash, never permanent deletion.
    static func write(_ files: [RemoteThreadTransferFile], to workdir: String,
                      backupDirectory: URL? = nil, beforeWrite: ((Int) throws -> Void)? = nil,
                      retire: ((URL) -> Void)? = nil) throws {
        guard !files.isEmpty else { return }
        transactionLock.lock(); defer { transactionLock.unlock() }
        let fm = FileManager.default
        var seen = Set<String>(), conflicts: [String] = []
        var prepared: [(RemoteThreadTransferFile, Data, Snapshot?)] = []
        for file in files {
            let path = try validatedRelativePath(file.relativePath)
            guard seen.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw TransferError.unsafeRelativePath(path) }
            guard let data = Data(base64Encoded: file.base64) else { throw TransferError.invalidBase64(path) }
            let original = try snapshot(path, in: workdir)
            if file.baseSHA256 == nil || file.baseSHA256 != (original.map { digest($0.data) } ?? missing) { conflicts.append(path) }
            prepared.append((file, data, original))
        }
        guard conflicts.isEmpty else { throw TransferError.conflicts(conflicts) }
        let backup = (backupDirectory ?? fm.temporaryDirectory).resolvingSymlinksInPath()
            .appendingPathComponent("w72-transfer-" + UUID().uuidString)
        let root = URL(fileURLWithPath: workdir).resolvingSymlinksInPath().standardizedFileURL
        guard root.path != "/", !backup.path.hasPrefix(root.path + "/") else { throw TransferError.unsafeRelativePath("backup inside project") }
        try fm.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var manifest = "# W72 transfer recovery\n\nOriginal source: receiving project \(root.lastPathComponent) (relative paths below).\nRestore: copy N.original to its listed relative path; absent entries had no original.\nDo not permanently remove without independent approval.\n\n"
        for (i, entry) in prepared.enumerated() {
            if let original = entry.2 { try original.data.write(to: backup.appendingPathComponent("\(i).original")) }
            manifest += "- \(i).original → \(entry.0.relativePath): \(entry.0.baseSHA256 ?? "unproven"); mode \(String(entry.2?.mode ?? 0o644, radix: 8))\n"
        }
        let manifestURL = backup.appendingPathComponent("MANIFEST.md")
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        var written: [(Int32, String, Int)] = [], opened: [Int32] = []
        var created: [(Int32, String)] = [], leftovers: [(Int32, String)] = []
        defer { for fd in opened { Darwin.close(fd) } }
        func makeParent(_ path: String) throws -> (Int32, String) {
            let parts = path.split(separator: "/").map(String.init)
            var fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw TransferError.unreadableFile(path) }
            opened.append(fd)
            for part in parts.dropLast() {
                var next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT {
                    guard mkdirat(fd, part, 0o755) == 0 else { throw TransferError.unreadableFile(path) }
                    created.append((fd, part))
                    next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw TransferError.unsafeRelativePath(path) }
                opened.append(next); fd = next
            }
            return (fd, parts.last!)
        }
        // Move newly created files/empty directories out rather than deleting work products.
        func archive(_ fd: Int32, _ name: String) throws {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(fd, F_GETPATH, &path) == 0 else { throw TransferError.unreadableFile(name) }
            let source = URL(fileURLWithPath: String(cString: path)).appendingPathComponent(name)
            try fm.moveItem(at: source, to: backup.appendingPathComponent("discard-" + UUID().uuidString))
        }
        do {
            for (i, entry) in prepared.enumerated() {
                try beforeWrite?(i)
                let (fd, name) = try makeParent(entry.0.relativePath)
                let now = try read(name, at: fd)
                guard (now.map { digest($0.data) } ?? missing) == entry.0.baseSHA256 else {
                    throw TransferError.conflicts([entry.0.relativePath])
                }
                try install(entry.1, name: name, fd: fd, mode: entry.2?.mode ?? 0o644, leftovers: &leftovers)
                written.append((fd, name, i))
            }
        } catch {
            var recoveryFailures: [String] = []
            for (fd, name, i) in written.reversed() {
                do {
                    // Rollback is also a write: never clobber a third-party edit made
                    // after our installation. Continue recovering independent files.
                    guard try read(name, at: fd).map({ digest($0.data) }) == digest(prepared[i].1) else {
                        throw TransferError.conflicts([prepared[i].0.relativePath])
                    }
                    if let original = prepared[i].2 {
                        try install(try Data(contentsOf: backup.appendingPathComponent("\(i).original")), name: name, fd: fd, mode: original.mode, leftovers: &leftovers)
                    } else { try archive(fd, name) }
                } catch { recoveryFailures.append(prepared[i].0.relativePath) }
            }
            for (fd, name) in leftovers {
                do { try archive(fd, name) } catch { recoveryFailures.append(name) }
            }
            for (fd, name) in created.reversed() {
                // An unexpected file in a newly created directory belongs to someone
                // else. Keep that directory rather than moving their work to Trash.
                do {
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw TransferError.unreadableFile(name) }
                    defer { Darwin.close(child) }
                    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                    guard fcntl(child, F_GETPATH, &path) == 0,
                          try fm.contentsOfDirectory(atPath: String(cString: path)).isEmpty else {
                        throw TransferError.conflicts([name])
                    }
                    try archive(fd, name)
                } catch { recoveryFailures.append(name) }
            }
            if !recoveryFailures.isEmpty {
                manifest += "\nNOT safe to remove: manual recovery required for " + recoveryFailures.joined(separator: ", ") + "\n"
                try? manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
                throw TransferError.recoveryRequired(backup.lastPathComponent)
            }
            manifest += "\nVerified reason safe to remove: transaction failed; original bytes restored.\n"
            try? manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
            if let retire { retire(backup) } else { retireBackup(backup) }
            throw error
        }
        manifest += "\nVerified reason safe to remove: every selected file passed baseline checks and installation completed.\n"
        // Receipt/Trash failure must not turn a completed transaction into a false failure.
        try? manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        if let retire { retire(backup) } else { retireBackup(backup) }
    }

    private static func retireBackup(_ backup: URL) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/trash")
        p.arguments = [backup.path]; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        // Failure retains the recovery folder, never removes it permanently.
        if (try? p.run()) != nil { p.waitUntilExit() }
    }

    static func validatedRelativePath(_ path: String) throws -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\0"), !path.hasPrefix("/"),
              !components.contains(".."), !components.contains("."), !components.contains(where: { $0.lowercased() == ".git" }), !components.contains("") else {
            throw TransferError.unsafeRelativePath(path)
        }
        return path
    }
}

/// W100：跨執行緒把連線結果帶回主執行緒的小盒子（只在 `connectNow()` 的 semaphore 期間被一邊寫一邊讀）。
private final class RemoteConnectBox: @unchecked Sendable {
    var value: Result<[String: Any], Error>?
}

@MainActor
final class RemoteDeviceSession: ObservableObject {
    enum State: Equatable, Sendable {
        case offline
        case connecting
        case online(Int64)
    }

    let device: DeviceRecord
    let link: RemoteHostLink
    @Published private(set) var engine: RemoteLiveEngine?
    @Published private(set) var state: State = .offline
    @Published private(set) var lastSeenAt: Date
    @Published private(set) var connectionProblem: String?

    /// Settings shows fixed actionable categories, never raw SSH diagnostics.
    static func actionableConnectionProblem(_ error: Error) -> String? {
        if case SSHHostPinError.hostKeyNotPaired = error { return "主機金鑰未確認，請重新配對" }
        if case SSHHostPinError.pinFileUnwritable = error { return "主機金鑰無法保存，請檢查設備設定" }
        let code = String(describing: error).lowercased() + " " + error.localizedDescription.lowercased()
        if ["host key verification failed", "remote host identification has changed", "ssh_host_key_mismatch", "paired_host_key_not_found"].contains(where: code.contains) {
            return "主機金鑰不符，請重新確認設備配對"
        }
        if ["permission denied", "authentication_failed", "authentication failed", "publickey"].contains(where: code.contains) {
            return "認證失敗，請檢查設備登入與配對"
        }
        return nil
    }
    #if DEBUG
    func w203ConnectionProblemForTest(_ error: Error) {
        markOffline(error: error)
        retryTask?.cancel(); retryTask = nil
    }
    #endif

    var onUpdate: (() -> Void)?
    var onHint: ((String) -> Void)?
    var document: TatwoNativeChatStoreDocument {
        engine?.document ?? lastDocument
    }
    /// W182 R4：這台存的離線副本（最後同步到的文件＋讀過的內容）；連不上時畫面照樣列出、可以讀。
    let offlineMirror: RemoteOfflineMirror

    private let environment: [String: String]
    private var lastDocument = TatwoNativeChatStoreDocument()
    private var retryDelay: TimeInterval = 30
    static let maxRetryDelay: TimeInterval = 60
    private var retryTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var offlineRevocation: (scope: String, token: UUID)?
    /// W100：連線一定在這條佇列上跑，主執行緒不自己呼叫 `RemoteHostLink`。
    private static let connectQueue = DispatchQueue(
        label: "ai.tatwo.tatwo2.remote-session-connect", qos: .userInitiated)

    init(
        device: DeviceRecord,
        link: RemoteHostLink,
        environment: [String: String]
    ) {
        self.device = device
        self.link = link
        self.environment = environment
        self.lastSeenAt = device.lastSeenAt
        // W182 R4：App 一開就在背景讀上次存的離線副本（讀好才叫 onUpdate；已經連上就不蓋掉）。
        self.offlineMirror = RemoteOfflineMirror(deviceID: device.id, deviceName: device.name,
                                                 cache: RemoteOfflineCache(root: RemoteOfflineCache.defaultRoot(environment: environment)))
        offlineMirror.onChange = { [weak self] in self?.offlineMirrorChanged() }
        offlineMirror.loadFromDisk()
        let scope = DeviceRegistry(environment: environment).root.path
        // 只有真的撤銷才清離線副本；close／closeAll（換群組、重新加入、撤銷前先斷線）不清也不拆掉這個監聽。
        offlineRevocation = (scope, DeviceFleetConnections.onRevoke(device.id, scope: scope) { [weak self] in
            Task { @MainActor in
                self?.retireRevokedOfflineCache()
            }
        })
        if DeviceFleetConnections.isRevoked(device.id, scope: scope) { retireRevokedOfflineCache() }
    }

    private func retireRevokedOfflineCache() {
        offlineMirror.retire { [weak self] result in
            if case .failure = result { self?.onHint?("離線副本移到垃圾桶未完成。") }
        }
        shutdown()
    }

    deinit {
        if let registration = offlineRevocation {
            DeviceFleetConnections.unregister(device.id, scope: registration.scope, token: registration.token)
        }
    }

    /// W182 R4：離線副本讀好、讀到一條內容或清掉時：沒連上就用它當側欄的文件（清掉就回到空白），重畫。
    private func offlineMirrorChanged() {
        if engine == nil {
            if let snapshot = offlineMirror.snapshot {
                if lastDocument == TatwoNativeChatStoreDocument() { lastDocument = snapshot.projection }
                lastSeenAt = max(lastSeenAt, snapshot.syncedAt)
            } else {
                lastDocument = TatwoNativeChatStoreDocument()
            }
        }
        onUpdate?()
    }

    func start() {
        guard connectTask == nil, engine == nil else { return }
        state = .connecting
        onUpdate?()
        let link = self.link
        let device = self.device
        connectTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { () throws -> [String: Any] in
                    try link.connect(device: device)
                    return try link.call(method: "get_document", params: [:])   // 第一份文件也在背景拉
                }
            }.value
            guard let self else { return }
            self.connectTask = nil
            switch result {
            case .success(let initial):
                self.installConnectedEngine(initial: initial)
            case .failure(let error):
                self.markOffline(error: error)
            }
        }
    }

    /// 同步連線：只給無介面的驗收 harness（PARALLELTEST／REMOTEUITEST）用。
    /// W100：SSH 一律在背景佇列跑（`RemoteHostLink` 禁止主執行緒進入），有介面的路徑請改用 `start()`。
    @discardableResult
    func connectNow() -> Bool {
        if engine != nil { return true }
        connectTask?.cancel()
        connectTask = nil
        retryTask?.cancel()
        retryTask = nil
        state = .connecting
        onUpdate?()
        let link = self.link
        let device = self.device
        let box = RemoteConnectBox()
        let done = DispatchSemaphore(value: 0)
        Self.connectQueue.async {
            box.value = Result { () throws -> [String: Any] in
                try link.connect(device: device)
                return try link.call(method: "get_document", params: [:])
            }
            done.signal()
        }
        done.wait()
        switch box.value {
        case .success(let initial)?:
            installConnectedEngine(initial: initial)
            return true
        case .failure(let error)?:
            markOffline(error: error)
            return false
        case nil:
            markOffline(error: RemoteHostLinkError.invalidResponse)
            return false
        }
    }

    func shutdown() {
        retryTask?.cancel()
        connectTask?.cancel()
        retryTask = nil
        connectTask = nil
        offlineMirror.flushPendingDocument()   // W182 R4：還沒寫的最後一份補寫（移除的那台已停記，不會寫）
        engine?.shutdownAll()
        engine = nil
        link.disconnect()
        state = .offline
    }

    private func installConnectedEngine(initial: [String: Any]? = nil) {
        do {
            let cacheRoot = remoteCacheRoot()
            let remote = try RemoteLiveEngine(
                link: link,
                store: ChatLiveStore(root: cacheRoot),
                initial: initial)
            EngineModelCatalog.replace(remote.engineModelCatalogs, deviceID: device.id)
            remote.onHint = { [weak self] message in self?.onHint?(message) }
            remote.onTranscriptFetched = { [weak self, weak remote] threadID, records in   // W182 R4：讀過的內容存進離線副本
                guard let self, let remote, self.engine === remote else { return }   // 斷線、移除後晚到的不記
                self.offlineMirror.record(transcript: records, threadID: threadID)
            }
            remote.onChange = { [weak self, weak remote] in
                guard let self, let remote, self.engine === remote else { return }
                self.offlineMirror.record(document: remote.doc, revision: remote.currentRevision)   // W182 R4
                EngineModelCatalog.replace(remote.engineModelCatalogs, deviceID: self.device.id)
                self.lastDocument = remote.document
                self.state = .online(remote.currentRevision)
                self.lastSeenAt = Date()
                self.onUpdate?()
            }
            remote.onConnectionStateChange = { [weak self, weak remote] result in
                guard let self, let remote, self.engine === remote else { return }
                switch result {
                case .success(let revision):
                    self.offlineMirror.record(document: remote.doc, revision: revision)   // W182 R4：換版或每分鐘存一次
                    EngineModelCatalog.replace(remote.engineModelCatalogs, deviceID: self.device.id)
                    self.lastDocument = remote.document
                    self.state = .online(revision)
                    self.lastSeenAt = Date()
                    self.retryDelay = 30
                    self.onUpdate?()
                case .failure(let error):
                    self.offlineMirror.flushPendingDocument()   // W182 R4：忙的時候還沒寫的最後一份補寫
                    EngineModelCatalog.replace(remote.engineModelCatalogs, deviceID: self.device.id)
                    self.lastDocument = remote.document
                    remote.shutdownAll()
                    self.engine = nil
                    self.markOffline(error: error)
                }
            }
            engine = remote
            offlineMirror.record(document: remote.doc, revision: remote.currentRevision, force: true)   // W182 R4：連上就換成最新的快照
            lastDocument = remote.document
            state = .online(remote.currentRevision)
            connectionProblem = nil
            lastSeenAt = Date()
            retryDelay = 30
            onUpdate?()
        } catch {
            markOffline(error: error)
        }
    }

    private func markOffline(error: Error) {
        engine = nil
        link.disconnect()
        state = .offline
        connectionProblem = Self.actionableConnectionProblem(error)
        // W201：斷線由原本的重試處理；需要那台的動作在自己的位置說明，不主動報備。
        onUpdate?()
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        let delay = retryDelay
        // W182 演練（09-27）：上限原本 5 分鐘，主設備開回來後這台最久要等 5 分鐘才連上、補回；改成最多 1 分鐘（連不上的 SSH 很便宜）。
        retryDelay = min(retryDelay * 2, Self.maxRetryDelay)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.start()
        }
    }

    #if DEBUG
    /// W201 自測：等假設備快照存好；只在隔離根目錄呼叫。
    func w201WaitForCache() async { await RemoteOfflineCache.flush() }

    /// W182 R4 自測：用給的 get_document 結果走真的「連上」路徑，再停掉輪詢（不開 SSH）。
    func w182TestConnect(initial: [String: Any]) {
        retryTask?.cancel()
        retryTask = nil
        installConnectedEngine(initial: initial)
        engine?.shutdownAll()
    }

    /// W182 R4 自測：走真的「斷線」路徑（遠端引擎回報連線失敗），再取消自動重連（不開 SSH）。
    func w182TestDisconnect() {
        engine?.onConnectionStateChange?(.failure(RemoteHostLinkError.tunnelUnavailable))
        retryTask?.cancel()
        retryTask = nil
    }
    #endif

    private func remoteCacheRoot() -> URL {
        let localRoot = environment["TATWO2_LIVE_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask)[0]
            .appendingPathComponent("tatwo2/live", isDirectory: true)
        return localRoot
            .appendingPathComponent("remote-sessions", isDirectory: true)
            .appendingPathComponent(device.id, isDirectory: true)
    }
}
