import AppKit

/// /goal 101：自測用的唯讀探針＋真實滑鼠事件。
/// Computer Use 的點擊會先轉成 AXPress，繞過 AppKit 的 hitTest；使用者回報的「按鈕點了沒反應」
/// 只有走 `NSApp.postEvent` 的真實 mouse-down／up 才重現得出來。只在本機 os.sock、權限「全權」時可用。
/// 座標一律是螢幕左上原點（跟輔助功能回報的 frame 同一套）。
@MainActor
enum UIProbe {
    static func run(_ params: [String: Any]) -> [String: Any] {
        let action = params["action"] as? String ?? "hit"
        if action == "find" { return find(label: params["label"] as? String ?? "") }
        guard let x = (params["x"] as? NSNumber)?.doubleValue, let y = (params["y"] as? NSNumber)?.doubleValue else {
            return ["error": "x_y_required"]
        }
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let screenPoint = NSPoint(x: x, y: screenHeight - y)
        guard let window = NSApp.orderedWindows.first(where: { $0.isVisible && $0.frame.contains(screenPoint) }) else {
            return ["error": "no_window_at_point"]
        }
        let point = window.convertPoint(fromScreen: screenPoint)
        let root = window.contentView?.superview ?? window.contentView
        var chain: [String] = []
        var view = root?.hitTest(point)
        while let current = view, chain.count < 14 {
            let frame = current.convert(current.bounds, to: nil)
            chain.append("\(type(of: current)) [\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))] canMoveWindow=\(current.mouseDownCanMoveWindow)")
            view = current.superview
        }
        var result: [String: Any] = ["window": "\(type(of: window)) \(window.title)", "chain": chain]
        guard action == "click" else { return result }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for (type, delay) in [(NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseUp, 0.08)] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 + delay) {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { return }
                NSApp.postEvent(event, atStart: false)
            }
        }
        result["posted"] = true
        return result
    }

    private static func find(label: String) -> [String: Any] {
        guard !label.isEmpty else { return ["error": "label_required"] }
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        var matches: [[String: Any]] = []
        var visited = 0
        func walk(_ element: Any, depth: Int) {
            guard visited < 6000, depth < 60, let object = element as? NSAccessibilityProtocol else { return }
            visited += 1
            let text = object.accessibilityLabel() ?? ""
            let title = object.accessibilityTitle() ?? ""
            let frame = object.accessibilityFrame()
            if text.contains(label) || title.contains(label), frame.width > 0 {
                matches.append(["label": text.isEmpty ? title : text,
                                "x": Double(frame.midX), "y": Double(screenHeight - frame.midY),
                                "w": Double(frame.width), "h": Double(frame.height)])
            }
            for child in object.accessibilityChildren() ?? [] { walk(child, depth: depth + 1) }
        }
        for window in NSApp.orderedWindows where window.isVisible { walk(window, depth: 0) }
        return ["matches": matches, "visited": visited]
    }
}
