import AppKit
import Combine

/// One queue owns presentation, deadlines and the Island's open lease.
@MainActor
final class IslandNotice: ObservableObject {
    static let shared = IslandNotice()

    enum Decision: Equatable, Sendable { case allow, cancel, timeout }
    enum Kind: Equatable, Sendable { case ask, confirm, info }
    struct Request: Identifiable, Equatable, Sendable {
        let id: UUID
        let kind: Kind
        let title: String
        let detail: String
        let allowLabel: String
        let cancelLabel: String
        var deadline: Date
        /// W178：要使用者看完整內容才能按允許（AI 代跑的指令）。Island 那一行放不下時，允許鍵換成「查看」，
        /// 按了才開視窗顯示完整內容，在那裡決定；絕不讓人對著被截掉的內容按允許。
        var fullTextRequired = false

        /// Island 那一行顯示的內容：最多兩行（指令＋位置）接成一行；指令本身有換行就沒有一行版，一定要開「查看」。
        var summaryLine: String? {
            let lines = detail.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count <= 2, !lines.contains(where: \.isEmpty) else { return nil }
            return lines.joined(separator: " · ")
        }
    }
    /// Returns a dismissal action; injected fixtures never create AppKit windows.
    typealias Fallback = @MainActor (Request, NSWindow?, @escaping (Decision) -> Void) -> (() -> Void)?
    /// 「查看」開的完整內容視窗；回傳關閉動作。測試可換成不開視窗的版本。
    typealias FullView = @MainActor (Request, @escaping (Decision) -> Void) -> (() -> Void)?

    @Published private(set) var current: Request?
    var hostAvailable = false {
        didSet {
            guard !hostAvailable, current != nil, let active else { return }
            current = nil
            // 「查看」視窗已經開著：就在那裡決定，不再疊開一個備援視窗（Island 的展開鎖照樣放掉）。
            guard active.dismiss == nil else { holdOpen(false); return }
            presentFallback(active)
        }
    }
    private let fallback: Fallback
    private let fullView: FullView
    private let holdOpen: (Bool) -> Void
    private let log: (String) -> Void
    private var queue: [Entry] = []
    private var active: Entry?
    private var blocking = false

    private final class Entry {
        var request: Request
        let duration: TimeInterval
        weak var window: NSWindow?
        let completion: (Decision) -> Void
        var timer: Timer?
        var dismiss: (() -> Void)?
        init(_ request: Request, window: NSWindow?, completion: @escaping (Decision) -> Void) {
            self.request = request
            self.duration = max(0, request.deadline.timeIntervalSinceNow)
            self.window = window
            self.completion = completion
        }
    }

    init(fallback: @escaping Fallback = IslandNotice.alertFallback,
         holdOpen: ((Bool) -> Void)? = nil,
         log: @escaping (String) -> Void = { NSLog("IslandNotice: %@", $0) },
         fullView: @escaping FullView = IslandNotice.fullTextSheet) {
        self.fallback = fallback
        self.fullView = fullView
        // Default resolved inside the @MainActor init: a default-argument closure is
        // nonisolated and cannot touch the main-actor Island shell.
        self.holdOpen = holdOpen ?? { IslandExceptionsNavigation.shell?.holdOpen($0) }
        self.log = log
    }

    func ask(title: String, detail: String, allowLabel: String, timeout: TimeInterval,
             requestID: UUID = UUID(), fullTextRequired: Bool = false) async -> Decision {
        var request = makeRequest(id: requestID, kind: .ask, title: title, detail: detail,
                                  allow: allowLabel, cancel: "取消", timeout: timeout)
        request.fullTextRequired = fullTextRequired
        return await wait(request)
    }

    /// Island 上按「查看」：開視窗顯示完整內容與允許／取消（只對目前顯示中的那一則；已開著就不重開）。
    func showFullText(id: UUID) {
        guard let entry = active, entry.request.id == id, entry.request.kind != .info, entry.dismiss == nil else { return }
        let dismiss = fullView(entry.request) { [weak self] decision in
            self?.resolve(decision, id: id)
        }
        if active === entry { entry.dismiss = dismiss } else { dismiss?() }
    }

    func confirm(title: String, detail: String, confirmLabel: String = "確認",
                 cancelLabel: String = "取消", timeout: TimeInterval = 20) async -> Bool {
        await wait(makeRequest(kind: .confirm, title: title, detail: detail,
                               allow: confirmLabel, cancel: cancelLabel, timeout: timeout)) == .allow
    }

    func info(title: String, detail: String, duration: TimeInterval = 7) {
        guard hostAvailable else { log("info skipped: Island host unavailable"); return }
        enqueue(makeRequest(kind: .info, title: title, detail: detail,
                            allow: "", cancel: "", timeout: duration), completion: { _ in })
    }

    /// Use the same callback-backed async operation, not a main-actor Task: a nested
    /// run loop cannot reliably drain Swift's main-executor jobs while its caller waits.
    func confirmBlocking(title: String, detail: String, confirmLabel: String = "確認",
                         cancelLabel: String = "取消", timeout: TimeInterval = 20,
                         window: NSWindow? = nil) -> Bool {
        guard !blocking else { return false } // nested close/Esc must never approve another action
        blocking = true
        defer { blocking = false }
        let request = makeRequest(kind: .confirm, title: title, detail: detail,
                                  allow: confirmLabel, cancel: cancelLabel, timeout: min(timeout, 20))
        var result: Decision?
        enqueue(request, window: window) { result = $0 }
        while result == nil, request.deadline > Date() {
            autoreleasepool {
                // AppKit's outer run() is suspended here. Dispatch native events as well
                // as timers so the Island buttons and fallback sheet remain clickable.
                if let app = NSApp,
                   let event = app.nextEvent(matching: .any, until: .distantPast,
                                             inMode: .default, dequeue: true) {
                    app.sendEvent(event)
                }
                RunLoop.main.run(until: min(request.deadline, Date().addingTimeInterval(0.01)))
            }
        }
        if result == nil { resolve(.timeout, id: request.id) }
        return result == .allow
    }

    func resolve(_ decision: Decision, id: UUID) {
        if let entry = active, entry.request.id == id {
            // A late click (or stale sheet callback) must not approve an expired request.
            let outcome: Decision = entry.request.deadline <= Date() ? .timeout : decision
            entry.timer?.invalidate()
            active = nil
            current = nil
            entry.dismiss?()
            entry.completion(outcome)
            presentNext()
        } else if decision != .allow, let index = queue.firstIndex(where: { $0.request.id == id }) {
            let entry = queue.remove(at: index)
            entry.timer?.invalidate()
            entry.completion(decision)
        }
    }

    private func makeRequest(id: UUID = UUID(), kind: Kind, title: String, detail: String,
                             allow: String, cancel: String, timeout: TimeInterval) -> Request {
        Request(id: id, kind: kind, title: title, detail: detail, allowLabel: allow,
                cancelLabel: cancel, deadline: Date().addingTimeInterval(timeout.isFinite ? max(0, timeout) : 20))
    }

    private func wait(_ request: Request) async -> Decision {
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return .cancel }
            return await withCheckedContinuation { continuation in
                enqueue(request) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            Task { @MainActor in self.resolve(.cancel, id: request.id) }
        }
    }

    private func enqueue(_ request: Request, window: NSWindow? = nil,
                         completion: @escaping (Decision) -> Void) {
        let entry = Entry(request, window: window, completion: completion)
        queue.append(entry)
        if request.kind != .info { scheduleTimeout(entry) }
        presentNext()
    }

    private func scheduleTimeout(_ entry: Entry) {
        let request = entry.request
        let timer = Timer(fire: request.deadline, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.resolve(.timeout, id: request.id) }
        }
        entry.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func presentNext() {
        guard active == nil else { return }
        guard !queue.isEmpty else { holdOpen(false); return }
        let entry = queue.removeFirst()
        active = entry
        // info.duration is reading time, not a request deadline: do not silently
        // discard a heads-up while it waits behind an interactive confirmation.
        if entry.request.kind == .info {
            entry.request.deadline = Date().addingTimeInterval(entry.duration)
            scheduleTimeout(entry)
        }
        let request = entry.request
        guard request.deadline > Date() else { resolve(.timeout, id: request.id); return }
        if hostAvailable {
            current = request
            holdOpen(true)
        } else {
            presentFallback(entry)
        }
    }

    private func presentFallback(_ entry: Entry) {
        holdOpen(false)
        let request = entry.request
        if request.kind == .info {
            log("info skipped: Island host unavailable")
            resolve(.cancel, id: request.id)
            return
        }
        let dismiss = fallback(request, entry.window) { [weak self] decision in
            self?.resolve(decision, id: request.id)
        }
        // An injected fallback may complete synchronously.
        if active === entry { entry.dismiss = dismiss } else { dismiss?() }
    }

    static func alertFallback(_ request: Request, window: NSWindow?,
                              completion: @escaping (Decision) -> Void) -> (() -> Void)? {
        guard let app = NSApp else { completion(.cancel); return nil }
        let parent = window.flatMap { $0.canBecomeMain ? $0 : nil }
            ?? app.keyWindow.flatMap { $0.canBecomeMain ? $0 : nil }
            ?? app.mainWindow
            ?? app.windows.filter { $0.isVisible && $0.canBecomeMain && $0.sheetParent == nil }
                .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let parent, parent.attachedSheet == nil else {
            NSLog("IslandNotice: no available sheet host; cancelled")
            completion(.cancel)
            return nil
        }
        parent.orderFront(nil)
        let alert: NSAlert
        if request.fullTextRequired {
            // W178：要看完整內容才能允許的請求，備援也用「查看」視窗（可捲動、看不見的字元顯示出來、允許鍵不接 Return）。
            alert = fullTextAlert(request)
        } else {
            alert = NSAlert()
            alert.messageText = request.title
            alert.informativeText = request.detail
            alert.addButton(withTitle: request.allowLabel)
            alert.addButton(withTitle: request.cancelLabel)
        }
        alert.beginSheetModal(for: parent) { response in
            completion(response == .alertFirstButtonReturn ? .allow : .cancel)
        }
        return {
            if alert.window.sheetParent != nil { parent.endSheet(alert.window, returnCode: .abort) }
        }
    }

    /// 「查看」視窗：完整內容用等寬字、可捲動、可選取；看不見的字元（控制、格式、雙向排版）一律顯示成 \u{…}，
    /// 畫面上看到的就是實際的內容。使用者自己按了查看才開，所以會把 App 叫到前面；
    /// 允許鍵不接 Return（避免順手按到），Esc＝取消。
    static func fullTextSheet(_ request: Request, completion: @escaping (Decision) -> Void) -> (() -> Void)? {
        guard let app = NSApp else { completion(.cancel); return nil }
        let parent = app.keyWindow.flatMap { $0.canBecomeMain ? $0 : nil }
            ?? app.mainWindow
            ?? app.windows.filter { $0.canBecomeMain && $0.sheetParent == nil }
                .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let parent, parent.attachedSheet == nil else {
            NSLog("IslandNotice: no available sheet host for full text; cancelled")
            completion(.cancel)
            return nil
        }
        app.activate(ignoringOtherApps: true)
        if parent.isMiniaturized { parent.deminiaturize(nil) }
        parent.makeKeyAndOrderFront(nil)
        let alert = fullTextAlert(request)
        alert.beginSheetModal(for: parent) { response in
            completion(response == .alertFirstButtonReturn ? .allow : .cancel)
        }
        return {
            if alert.window.sheetParent != nil { parent.endSheet(alert.window, returnCode: .abort) }
        }
    }

    /// 「查看」視窗的內容（不顯示；畫面自測也用這一個）。
    static func fullTextAlert(_ request: Request) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = request.title
        alert.informativeText = "以下是完整內容，看清楚再決定。"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 200))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = visibleText(request.detail)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        alert.accessoryView = scroll
        let allow = alert.addButton(withTitle: request.allowLabel)
        allow.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: request.cancelLabel)
        cancel.keyEquivalent = "\u{1b}"
        return alert
    }

    /// 看不見或會改變顯示順序的字元換成可見的 \u{…}；換行與 Tab 保留。
    nonisolated static func visibleText(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control where scalar != "\n" && scalar != "\t",
                 .format, .lineSeparator, .paragraphSeparator:
                result += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
