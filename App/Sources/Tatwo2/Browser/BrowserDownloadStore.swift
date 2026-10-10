import AppKit
import Combine
import Quartz

@MainActor
final class BrowserDownloadStore: NSResponder, ObservableObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = BrowserDownloadStore()
    static let motionEvent = Notification.Name("tatwo.browser.download.motion")
    enum State: String, Codable { case starting, downloading, paused, completed, failed, cancelled
        var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
    }
    struct Item: Identifiable, Equatable, Codable {
        let id: String
        let filename: String
        var received: Int64
        var total: Int64
        var state: State
        let fileURL: URL
        let createdAt: Date
        var failure: String?
        // History records an origin only. Signed query strings, userinfo, and the
        // actual retry URL remain exclusively in the process-local Controls.
        var sourceOrigin: String?
        var done: Bool { state == .completed }
        var name: String { filename }
        var size: String { received > 0 ? ByteCountFormatter.string(fromByteCount: received, countStyle: .file) : "0 KB" }
        var time: String {
            switch state {
            case .starting: return "準備下載…"
            case .downloading: return "下載中 · \(size) / \(total > 0 ? ByteCountFormatter.string(fromByteCount: total, countStyle: .file) : "未知大小")"
            case .paused: return "已暫停 · \(size)"
            case .completed: return "已完成 · \(size)"
            case .failed: return "下載失敗 · \(size)"
            case .cancelled: return "已取消 · \(size)"
            }
        }
        var section: String {
            Calendar.current.isDateInToday(createdAt) ? "今天" : Calendar.current.isDateInYesterday(createdAt) ? "昨天" : "Earlier"
        }
        var isImage: Bool { ["png", "jpg", "jpeg", "gif", "webp"].contains(fileURL.pathExtension.lowercased()) }
    }
    struct Controls {
        let cancel: () -> Bool
        let pause: () -> Bool
        let resume: () -> Bool
        let retry: () -> Bool
    }
    @Published private(set) var downloads: [Item] = []
    @Published private(set) var feedbackID: String?
    @Published private(set) var unreadCompletions: Set<String> = []
    @Published private(set) var completionID: String?
    private(set) var feedbackDeadline = Date.distantFuture
    private var pendingProgress: [String: ([String: Any], Controls?)] = [:]
    private var progressFlush: Task<Void, Never>?
    private var lastProgress = Date.distantPast
    var active: [Item] { downloads.filter { !$0.state.isTerminal } }
    var feedback: Item? { downloads.first { $0.id == feedbackID } }
    var aggregateProgress: Double? {
        let items = active
        guard !items.isEmpty, items.allSatisfy({ $0.total > 0 }) else { return nil }
        return min(1, items.reduce(0) { $0 + Double($1.received) } / items.reduce(0) { $0 + Double(max($1.total, $1.received)) })
    }
    func markDownloadsSeen() { unreadCompletions.removeAll() }
    func deferFeedbackDismissal(_ id: String) { if feedbackID == id { feedbackDeadline = Date().addingTimeInterval(4) } }
    func dismissFeedback(_ id: String) { if feedbackID == id { feedbackID = nil } }
    private var controls: [String: Controls] = [:]
    private var fileProgress: [String: Progress] = [:]
    private var terminationObservation: AnyCancellable?
    private let storageURL: URL?
    private var lastPersisted = Date.distantPast
    private var previewURL: URL?
    private weak var previewWindow: NSWindow?
    private var hiddenIDs: Set<String> = []
    nonisolated static var defaultStorageURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/tatwo2/browser-downloads.json")
    }

    init(storageURL: URL? = BrowserDownloadStore.defaultStorageURL) {
        self.storageURL = storageURL
        super.init()
        terminationObservation = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.fileProgress.values.forEach { $0.unpublish() }; self?.fileProgress.removeAll() }
        }
        guard let storageURL, let data = try? Data(contentsOf: storageURL),
              let saved = try? JSONDecoder().decode([Item].self, from: data) else { return }
        downloads = saved.prefix(300).map { entry in
            var item = entry
            if !item.state.isTerminal {
                item.state = .failed
                item.failure = "App 已重新啟動；請回原網站重新下載。"
            }
            return item
        }
    }
    required init?(coder: NSCoder) { nil }
    deinit { fileProgress.values.forEach { $0.unpublish() } }

    private func updateFileProgress(_ item: Item, hasPath: Bool = true) {
        var progress = fileProgress[item.id]
        guard progress != nil || (item.state == .starting && hasPath) else { return }
        if progress?.userInfo[.fileURLKey] as? URL != item.fileURL {
            progress?.unpublish()
            let next = Progress(totalUnitCount: item.total > 0 ? max(item.total, item.received) : -1)
            next.kind = .file
            next.setUserInfoObject(Progress.FileOperationKind.downloading, forKey: .fileOperationKindKey)
            next.setUserInfoObject(item.fileURL, forKey: .fileURLKey)
            next.isCancellable = true; next.isPausable = false
            next.cancellationHandler = { [weak self] in
                Task { @MainActor in
                    guard let self, let current = self.downloads.first(where: { $0.id == item.id }) else { return }
                    self.cancel(current)
                }
            }
            next.completedUnitCount = item.total > 0 ? item.received : 0
            next.publish(); progress = next; fileProgress[item.id] = next
        }
        progress?.totalUnitCount = item.total > 0 ? max(item.total, item.received) : -1
        progress?.completedUnitCount = item.total > 0 ? item.received : 0
        if item.state.isTerminal { progress?.unpublish(); fileProgress[item.id] = nil }
    }

    static func safeOrigin(_ raw: String) -> String? {
        guard var parts = URLComponents(string: raw),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), parts.host != nil else { return nil }
        parts.user = nil; parts.password = nil; parts.path = ""; parts.query = nil; parts.fragment = nil
        return parts.string
    }

    func update(event: [String: Any], controls incomingControls: Controls?) {
        guard let id = event["id"] as? String, !id.isEmpty,
              let filename = event["filename"] as? String, !filename.isEmpty,
              filename == (filename as NSString).lastPathComponent, filename != ".", filename != "..",
              let rawState = event["state"] as? String, let state = State(rawValue: rawState) else { return }
        guard !hiddenIDs.contains(id) else { return }
        if state == .downloading && downloads.contains(where: { $0.id == id && $0.state == state }) && Date().timeIntervalSince(lastProgress) < 0.1 {
            pendingProgress[id] = (event, incomingControls)
            if progressFlush == nil {
                progressFlush = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self else { return }
                    let pending = pendingProgress; pendingProgress.removeAll(); progressFlush = nil
                    lastProgress = .distantPast
                    for (_, value) in pending { update(event: value.0, controls: value.1) }
                }
            }
            return
        }
        pendingProgress[id] = nil
        if state == .downloading { lastProgress = Date() }
        if let incomingControls { controls[id] = incomingControls }
        let previous = downloads.first { $0.id == id }
        // A late cancellation callback from CEF must not turn an interrupted
        // download into success or erase the visible failure reason.
        if let previous, previous.state.isTerminal, previous.state != state { return }
        let defaultURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true).appendingPathComponent(filename)
        let path = event["path"] as? String ?? ""
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : defaultURL
        let error = event["error"] as? String
        let item = Item(id: id, filename: filename,
                        received: max(previous?.received ?? 0, (event["received"] as? NSNumber)?.int64Value ?? 0),
                        total: (event["total"] as? NSNumber)?.int64Value ?? -1, state: state,
                        fileURL: url, createdAt: previous?.createdAt ?? Date(),
                        failure: error?.isEmpty == false ? error : previous?.failure,
                        sourceOrigin: Self.safeOrigin(event["sourceURL"] as? String ?? ""))
        updateFileProgress(item, hasPath: path.hasPrefix("/"))
        if let index = downloads.firstIndex(where: { $0.id == id }) { downloads[index] = item }
        else { downloads.insert(item, at: 0) }
        if previous == nil { completionID = nil; feedbackDeadline = .distantFuture; feedbackID = id; NotificationCenter.default.post(name: Self.motionEvent, object: self, userInfo: ["item": item, "start": true]) }
        persist(force: state.isTerminal || previous == nil)
        if state == .completed && previous?.state != .completed {
            unreadCompletions.insert(id); completionID = id; NotificationCenter.default.post(name: Self.motionEvent, object: self, userInfo: ["item": item])
            if feedbackID == id { feedbackDeadline = Date().addingTimeInterval(4) }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1200))
                if self?.completionID == id { self?.completionID = nil }
            }
            IslandNotice.shared.info(title: BrowserHumanInteraction.title("已下載 \(filename)"),
                                     detail: BrowserHumanInteraction.oneLine(filename))
        }
    }

    // Compatibility for callers without the richer CEF lifecycle event.
    func update(id: String, filename: String, received: Int64, total: Int64, done: Bool) {
        update(event: ["id": id, "filename": filename, "received": received, "total": total,
                       "state": done ? "completed" : "downloading"], controls: nil)
    }
    func canRetry(_ item: Item) -> Bool { (item.state == .failed || item.state == .cancelled) && controls[item.id] != nil }
    func canCancel(_ item: Item) -> Bool { !item.state.isTerminal && controls[item.id] != nil }
    func canPause(_ item: Item) -> Bool { item.state == .downloading && controls[item.id] != nil }
    func canResume(_ item: Item) -> Bool { item.state == .paused && controls[item.id] != nil }
    func cancel(_ item: Item) { perform(item) { $0.cancel() } }
    func pause(_ item: Item) { perform(item) { $0.pause() } }
    func resume(_ item: Item) { perform(item) { $0.resume() } }
    func retry(_ item: Item) { perform(item) { $0.retry() } }
    private func perform(_ item: Item, action: (Controls) -> Bool) {
        guard let controls = controls[item.id], action(controls) else {
            if let index = downloads.firstIndex(where: { $0.id == item.id }) {
                if !downloads[index].state.isTerminal { downloads[index].state = .failed }
                downloads[index].failure = "來源分頁已關閉或操作不可用；請回原網站重新下載。"
                self.controls[item.id] = nil
                updateFileProgress(downloads[index])
                persist(force: true)
            }
            return
        }
    }
    private func persist(force: Bool = false) {
        guard let storageURL, force || Date().timeIntervalSince(lastPersisted) >= 1,
              let data = try? JSONEncoder().encode(Array(downloads.prefix(300))) else { return }
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: storageURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
            lastPersisted = Date()
        } catch { /* Download success must not be changed by an unavailable history file. */ }
    }
    // Clear/hide removes terminal history entries, never files from disk.
    func clearDownloads() {
        let ids = downloads.filter { $0.state.isTerminal }.map(\.id)
        hiddenIDs.formUnion(ids)
        unreadCompletions.subtract(ids)
        for id in ids { controls[id] = nil }
        downloads.removeAll { $0.state.isTerminal }
        persist(force: true)
    }
    func hide(_ item: Item) {
        guard item.state.isTerminal else { return }
        hiddenIDs.insert(item.id)
        unreadCompletions.remove(item.id)
        controls[item.id] = nil
        downloads.removeAll { $0.id == item.id }
        persist(force: true)
    }
    func revealURL(_ item: Item) -> URL? {
        (item.done || item.state == .failed) && FileManager.default.fileExists(atPath: item.fileURL.path) ? item.fileURL : nil
    }
    func reveal(_ item: Item) {
        guard let url = revealURL(item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    func preview(_ item: Item) {
        guard item.done, FileManager.default.fileExists(atPath: item.fileURL.path),
              let panel = QLPreviewPanel.shared() else { return }
        previewURL = item.fileURL
        if previewWindow == nil, let window = NSApp.keyWindow ?? NSApp.mainWindow {
            previewWindow = window
            nextResponder = window.nextResponder
            window.nextResponder = self
        }
        panel.updateController()
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { previewURL != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        if previewWindow?.nextResponder === self { previewWindow?.nextResponder = nextResponder }
        previewWindow = nil
        nextResponder = nil
        previewURL = nil
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL as NSURL?
    }
}
