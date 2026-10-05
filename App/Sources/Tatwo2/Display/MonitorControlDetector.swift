import AppKit
import Combine

@MainActor final class MonitorControlDetector: ObservableObject {
    static let bundleIdentifier = "app.monitorcontrol.MonitorControl"
    @Published private(set) var isRunning = false
    private var tokens: [NSObjectProtocol] = []
    static func running(in identifiers: [String]) -> Bool { identifiers.contains(bundleIdentifier) }
    init(observe: Bool = true, identifiers: [String] = []) {
        isRunning = Self.running(in: identifiers)
        guard observe else { return }
        refresh()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
    }
    func refresh() {
        isRunning = Self.running(in: NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
    deinit { for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) } }
}
