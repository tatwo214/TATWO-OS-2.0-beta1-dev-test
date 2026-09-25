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
        if action.hasPrefix("hid_") { return hid(action, params) }
        if action == "snapshot" { return snapshot() }
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
        if action == "move" {
            // W112：合成的滑鼠移動（不動真的游標），給「滑鼠到視窗最上緣才浮出」這類行為自測用。
            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { NSApp.postEvent(event, atStart: false) }
            result["posted"] = true
            return result
        }
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

    /// W115（使用者 2026-09-20：「自測工具無法跟滑鼠一樣效果嗎」）：系統層（HID）滑鼠事件——真的移動游標、真的按下與拖曳，
    /// 所以懸停、拖放、點網頁內容都跟人操作一樣。App 要有「輔助使用」權限；只在全權檔位下由 ui_probe 開放，而且只該在使用者離開時跑。
    /// 座標是螢幕座標、左上為原點（跟 Quartz 一致）。
    private static func hid(_ action: String, _ params: [String: Any]) -> [String: Any] {
        func number(_ key: String) -> Double? { (params[key] as? NSNumber)?.doubleValue }
        guard let x = number("x"), let y = number("y") else { return ["error": "x_y_required"] }
        guard AXIsProcessTrusted() else { return ["error": "accessibility_permission_required"] }
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, _ point: CGPoint) {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        let start = CGPoint(x: x, y: y)
        NSApp.activate(ignoringOtherApps: true)   // App 不在前景時，第一下點擊只會把視窗叫到前面、進不到網頁
        DispatchQueue.global(qos: .userInitiated).async {
            usleep(250_000)
            post(.mouseMoved, start)
            switch action {
            case "hid_click":
                usleep(120_000); post(.leftMouseDown, start); usleep(60_000); post(.leftMouseUp, start)
            case "hid_drag":
                guard let x2 = number("x2"), let y2 = number("y2") else { return }
                usleep(150_000); post(.leftMouseDown, start); usleep(250_000)   // 按住一下，拖曳才會被認成拖曳
                let steps = 24
                for step in 1...steps {
                    let t = Double(step) / Double(steps)
                    post(.leftMouseDragged, CGPoint(x: x + (x2 - x) * t, y: y + (y2 - y) * t)); usleep(25_000)
                }
                usleep(350_000); post(.leftMouseUp, CGPoint(x: x2, y: y2))
            default: break   // hid_move
            }
        }
        return ["posted": true, "action": action]
    }

    private static func safeString(_ object: NSAccessibilityProtocol, _ selector: Selector) -> String {
        guard let target = object as? NSObject, target.responds(to: selector),
              let value = target.perform(selector)?.takeUnretainedValue() else { return "" }
        if let string = value as? NSString { return string as String }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return ""
    }

    private static func find(label: String) -> [String: Any] {
        guard !label.isEmpty else { return ["error": "label_required"] }
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        var matches: [[String: Any]] = []
        var visited = 0
        func walk(_ element: Any, depth: Int) {
            guard visited < 6000, depth < 60, let object = element as? NSAccessibilityProtocol else { return }
            visited += 1
            // .018 實測當機（tatwo2-2026-09-20-215137.ips）：Chromium 的輔助使用節點回傳的標籤不一定是 NSString，
            // Swift 直接橋接成 String 會丟 doesNotRecognizeSelector、整個 App 倒。先當物件拿，再檢查型別。
            let text = safeString(object, #selector(NSAccessibilityProtocol.accessibilityLabel))
            let title = safeString(object, #selector(NSAccessibilityProtocol.accessibilityTitle))
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

    /// W170：主視窗畫成 PNG（App 自己畫自己，不需要螢幕錄製權限；螢幕截不到時的自測用，例如 mini 沒接螢幕）。
    /// 檔案固定寫到暫存資料夾，不接受外部路徑。
    private static func snapshot() -> [String: Any] {
        guard let window = NSApp.windows.filter({ $0.isVisible && $0.contentView != nil })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return ["error": "no_window"] }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return ["error": "encode_failed"] }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tatwo-ui-snapshot.png")
        do { try png.write(to: url, options: .atomic) } catch { return ["error": "write_failed"] }
        return ["path": url.path, "width": rep.pixelsWide, "height": rep.pixelsHigh]
    }
}
