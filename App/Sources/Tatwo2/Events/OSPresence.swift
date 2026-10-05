import AppKit
import SwiftUI

@MainActor final class OSPresence {
    static var shared = OSPresence()
    private let now: () -> Date
    private let active: @MainActor () -> Bool
    private let foreground: (UUID, String) -> Bool
    private var selected: (UUID, UUID?, OSEventLog)?
    private var last: [String: Date] = [:]
    private var monitor: Any?
    private var observer: NSObjectProtocol?
    private var page = TatwoPage.initialSelection.rawValue
    private struct WeakProbe { weak var view: OSPresenceDMProbe.View? }
    private var probes: [WeakProbe] = []
    init(now: @escaping () -> Date = Date.init, active: @escaping @MainActor () -> Bool = { NSApp?.isActive ?? false }, foreground: ((UUID, String) -> Bool)? = nil) {
        self.now = now; self.active = active
        self.foreground = foreground ?? { thread, surface in Self.shared.visible(thread, surface: surface) }
    }
    func install() {
        guard monitor == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .tatwoWorkOSPageDidChange, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.page = note.object as? String ?? "" }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.record(event: event); return event
        }
    }
    func add(_ view: OSPresenceDMProbe.View) { probes.removeAll { $0.view == nil || $0.view === view }; probes.append(WeakProbe(view: view)) }
    private func dm(_ store: GlobalDMStore) -> (UUID, UUID?, OSEventLog)? {
        guard !store.isBrowsing, !HandsConnectPresenter.shared.covers(store), let engine = store.model?.localLiveForBridge else { return nil }
        let thread: UUID?
        switch store.target { case .thread(let id): thread = id; case .assistant: thread = store.model?.assistantThreadID; case .chatGPT: thread = nil }
        guard let thread, let row = engine.threadRecord(thread) else { return nil }
        return (thread, row.projectID ?? engine.doc.generalProjectID, OSEventLog.atRoot(engine.store.url.deletingLastPathComponent()))
    }
    static func coderVisible(_ thread: UUID, selected: UUID?, page: String, mode: ChatRunMode?, key: Bool, main: Bool) -> Bool {
        main && key && page == TatwoPage.chat.rawValue && mode == .chat && selected == thread
    }
    private func visible(_ thread: UUID, surface: String) -> Bool {
        guard let window = NSApp?.keyWindow, window.isKeyWindow, window.attachedSheet == nil else { return false }
        if surface == "dm" { return probes.contains { $0.view?.window === window && $0.view?.store.flatMap { dm($0)?.0 } == thread && $0.view?.isHiddenOrHasHiddenAncestor == false } }
        let model = CLISessionsTermination.model
        return Self.coderVisible(thread, selected: model?.selectedThreadID, page: page, mode: model?.mode, key: window.isKeyWindow, main: window is TatwoWorkOSWindow)
    }
    func record(event: NSEvent) {
        guard active(), let window = event.window, window.isKeyWindow, window.attachedSheet == nil else { return }
        let point = event.type == .keyDown ? (window.firstResponder as? NSView).map { $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) } : event.locationInWindow
        for probe in probes.compactMap(\.view) where probe.window === window && !probe.isHiddenOrHasHiddenAncestor {
            if let point, probe.bounds.contains(probe.convert(point, from: nil)), let store = probe.store, let context = dm(store) {
                record(thread: context.0, project: context.1, log: context.2, surface: "dm"); return
            }
        }
        if window is TatwoWorkOSWindow { record() }
    }
    func select(_ thread: UUID?, engine: (any LiveEngineAPI)?) {
        guard let thread, let engine else { selected = nil; return }
        select(thread, project: engine.threadRecord(thread)?.projectID ?? engine.doc.generalProjectID, log: OSEventLog.atRoot((engine as? ChatLiveEngine)?.store.url.deletingLastPathComponent() ?? OSEventLog.liveRoot))
    }
    func select(_ thread: UUID, project: UUID?, log: OSEventLog) { selected = (thread, project, log); record() }
    func record(thread: UUID? = nil, project: UUID? = nil, log: OSEventLog? = nil, surface: String? = nil) {
        guard active(), let context = thread.flatMap({ id in log.map { (id, project, $0) } }) ?? selected else { return }
        let surface = surface ?? (visible(context.0, surface: "dm") ? "dm" : "coder")
        guard foreground(context.0, surface) else { return }
        let time = now(), key = context.2.root.path + ":" + context.0.uuidString
        guard last[key].map({ time.timeIntervalSince($0) >= 60 }) ?? true else { return }
        last[key] = time; context.2.append(project: context.1, thread: context.0, actor: "你", kind: "presence", at: time, surface: surface)
    }
}

struct OSPresenceDMProbe: NSViewRepresentable {
    final class View: NSView {
        weak var store: GlobalDMStore?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); OSPresence.shared.add(self) }
    }
    let store: GlobalDMStore
    func makeNSView(context: Context) -> View { let view = View(); view.store = store; return view }
    func updateNSView(_ view: View, context: Context) { view.store = store }
}
