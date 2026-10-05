import AppKit
import ApplicationServices

enum ComputerUsePointer {
    enum Kind: String, Sendable {
        case click, scroll, drag
        case doubleClick = "double_click"
        case rightClick = "right_click"
    }
    enum Location: Sendable {
        case element(Int)
        case point(Double, Double)
    }
    struct Request: Sendable {
        let kind: Kind
        let from: Location
        let to: Location?
        let dx: Int32
        let dy: Int32
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    static func index(_ value: Any?) throws -> Int {
        guard let number = number(value), number >= 0, number <= Double(Int32.max), number.rounded() == number else {
            throw ComputerUseFailure("computer_invalid_element_index")
        }
        return Int(number)
    }
    static func request(action: String, params: [String: Any]) throws -> Request {
        guard let kind = Kind(rawValue: action) else { throw ComputerUseFailure("computer_invalid_action") }
        var fields: Set<String> = ["sessionID", "observationID", "callerThreadID", "action", "element", "x", "y", "image"]
        if kind == .scroll { fields.formUnion(["dx", "dy"]) }
        if kind == .drag { fields.formUnion(["toElement", "toX", "toY"]) }
        guard Set(params.keys).isSubset(of: fields) else { throw ComputerUseFailure("computer_invalid_pointer_arguments") }
        func location(_ element: String, _ x: String, _ y: String) throws -> Location {
            if let value = params[element] {
                guard params[x] == nil, params[y] == nil else { throw ComputerUseFailure("computer_invalid_pointer_arguments") }
                return .element(try index(value))
            }
            guard let x = number(params[x]), let y = number(params[y]), x >= 0, y >= 0, x < 2048, y < 2048 else {
                throw ComputerUseFailure("computer_invalid_pointer_arguments")
            }
            return .point(x, y)
        }
        func delta(_ key: String) throws -> Int32 {
            guard let value = number(params[key]), value.rounded() == value, abs(value) <= 1200 else {
                throw ComputerUseFailure("computer_invalid_pointer_arguments")
            }
            return Int32(value)
        }
        let dx: Int32 = kind == .scroll ? try delta("dx") : 0
        let dy: Int32 = kind == .scroll ? try delta("dy") : 0
        if kind == .scroll && dx == 0 && dy == 0 { throw ComputerUseFailure("computer_invalid_pointer_arguments") }
        return Request(kind: kind, from: try location("element", "x", "y"),
                       to: kind == .drag ? try location("toElement", "toX", "toY") : nil, dx: dx, dy: dy)
    }

    static func screenPoint(x: Double, y: Double, imageWidth: Int, imageHeight: Int, frame: CGRect) throws -> CGPoint {
        guard (1...2048).contains(imageWidth), (1...2048).contains(imageHeight),
              x.isFinite, y.isFinite, x >= 0, y >= 0, x < Double(imageWidth), y < Double(imageHeight),
              frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { throw ComputerUseFailure("computer_pointer_outside_observation") }
        let scale = frame.width / Double(imageWidth)
        let point = CGPoint(x: frame.minX + x * scale, y: frame.minY + y * scale)
        guard frame.contains(point) else { throw ComputerUseFailure("computer_pointer_outside_observation") }
        return point
    }
    static func imageFrame(_ rect: CGRect, windowFrame: CGRect, imageWidth: Int) -> CGRect {
        let scale = Double(imageWidth) / windowFrame.width
        return CGRect(x: (rect.minX - windowFrame.minX) * scale, y: (rect.minY - windowFrame.minY) * scale,
                      width: rect.width * scale, height: rect.height * scale)
    }

    enum DragEvent: Equatable { case down, moved, up }
    /// The production sender and tests share this choreography. Up is cleanup,
    /// deliberately outside the revoked gate; it must run even if dispatch throws.
    static func drag(from: CGPoint, to: CGPoint, check: () throws -> Void,
                     send: (DragEvent, CGPoint) throws -> Void, release: (CGPoint) -> Void,
                     wait: () throws -> Void = { Thread.sleep(forTimeInterval: 0.025) }) throws {
        var point = from
        var mayBeDown = false
        defer { if mayBeDown { release(point) } }
        try check()
        mayBeDown = true
        try send(.down, point)
        for step in 1...12 {
            try wait()
            try check()
            let next = CGPoint(x: from.x + (to.x - from.x) * Double(step) / 12,
                               y: from.y + (to.y - from.y) * Double(step) / 12)
            try send(.moved, next)
            point = next // A rejected dispatch must not move the cleanup/drop location.

        }
    }

    /// `geometry`（W184 CU 第二輪）：AX 查詢用 AX 座標（from、to 算出來的都是），合成事件與 CGEvent 用視窗伺服器座標
    /// （serverPoint），事件的視窗照確定的編號（target()），不靠座標猜。
    /// `elementGeometry`（第三輪，GPT-6 複核 #4）：用元素編號指的點，事件送到那個元素自己的視窗——開著的選單、浮出視窗
    /// 不是觀察的視窗；確認不了＝拒絕（computer_event_target_unresolved）。圖片座標的點就是觀察的視窗（截圖就是它）。
    /// 拖曳的起點、終點要在同一個視窗。
    static func input(_ request: Request, observation: ComputerUseSession.Observation,
                      grant: ComputerUseSession.Grant, gate: ComputerUseSession,
                      geometry: ComputerUseNative.EventGeometry,
                      check: () throws -> Void, element: (Int) throws -> AXUIElement,
                      elementGeometry: (AXUIElement) throws -> ComputerUseNative.EventGeometry,
                      deadline: TimeInterval, externalAI: Bool = false,
                      pointAllowed: (CGPoint) throws -> Void = { _ in }) throws {
        if externalAI { try ComputerUseExternalPolicy.requireBackgroundPointer(ComputerUseBackgroundEvents.available) }
        guard let state = observation.state, let window = state.window else {
            throw ComputerUseFailure("computer_pointer_outside_observation")
        }
        func windowGeometry() throws -> CGRect {
            guard let current = try? ComputerUseNative.frame(window, deadline: deadline),
                  ComputerUseNative.sameFrame(current, state.frame) else {
                throw ComputerUseFailure("computer_element_stale")
            }
            return current
        }
        /// 點（AX 座標）與它的事件要送去的視窗。
        func resolve(_ location: Location) throws -> (point: CGPoint, geometry: ComputerUseNative.EventGeometry) {
            let bounds = try windowGeometry()
            switch location {
            case .point(let x, let y):
                let point = try screenPoint(x: x, y: y, imageWidth: observation.imageWidth,
                                            imageHeight: observation.imageHeight, frame: bounds)
                try pointAllowed(point)
                return (point, geometry)
            case .element(let index):
                let node = try element(index)
                let rect = try ComputerUseNative.frame(node, deadline: deadline)
                return (CGPoint(x: rect.midX, y: rect.midY), try elementGeometry(node))
            }
        }
        let (from, target) = try resolve(request.from)
        guard let source = CGEventSource(stateID: .privateState) else { throw ComputerUseFailure("computer_input_unavailable") }
        /// CGEvent 的游標位置是視窗伺服器座標。
        func mouse(_ type: CGEventType, _ axPoint: CGPoint, _ button: CGMouseButton = .left, click: Int = 1) throws -> CGEvent {
            let point = target.serverPoint(axPoint)
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: point, mouseButton: button) else {
                throw ComputerUseFailure("computer_input_unavailable")
            }
            event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()))
            event.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            return event
        }
        switch request.kind {
        case .click, .doubleClick, .rightClick:
            let right = request.kind == .rightClick
            if ComputerUseBackgroundEvents.available {
                // Background: the target believes it is active for this click; cursor and front App untouched.
                try check()
                _ = try windowGeometry()
                let receiver = try target.target()
                let at = target.serverPoint(from)
                ComputerUseBackgroundEvents.activate(receiver)
                Thread.sleep(forTimeInterval: 0.06)
                for count in 1...(request.kind == .doubleClick ? 2 : 1) {
                    try check()
                    let number = ComputerUseBackgroundEvents.nextEventNumber()
                    try gate.dispatch(observationID: observation.id, for: grant) {
                        ComputerUseBackgroundEvents.mouse(receiver, right ? .rightDown : .leftDown, at: at,
                                                          click: Int32(count), eventNumber: number)
                    }
                    Thread.sleep(forTimeInterval: 0.03)
                    ComputerUseBackgroundEvents.mouse(receiver, right ? .rightUp : .leftUp, at: at,
                                                      click: Int32(count), eventNumber: number)
                    Thread.sleep(forTimeInterval: 0.05)
                }
                ComputerUseBackgroundEvents.noteLastPoint(at)
                // A context menu stays open only while the App believes it is active; the next action or
                // Stop re-activates/deactivates anyway.
                if !right {
                    Thread.sleep(forTimeInterval: 0.12)
                    ComputerUseBackgroundEvents.deactivate(receiver)
                }
                return
            }
            for count in 1...(request.kind == .doubleClick ? 2 : 1) {
                try check()
                _ = try windowGeometry()
                let down = try mouse(right ? .rightMouseDown : .leftMouseDown, from, right ? .right : .left, click: count)
                let up = try mouse(right ? .rightMouseUp : .leftMouseUp, from, right ? .right : .left, click: count)
                try gate.dispatch(observationID: observation.id, for: grant) {
                    down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                }
            }
        case .scroll:
            try check()
            if ComputerUseBackgroundEvents.available {
                // Background wheel through synthetic app focus (CU02-F2: the old cursor-borrowing path raised
                // Finder and the user's mouse move then read as a takeover).
                _ = try windowGeometry()
                let receiver = try target.target()
                let at = target.serverPoint(from)
                ComputerUseBackgroundEvents.activate(receiver)
                Thread.sleep(forTimeInterval: 0.06)
                try gate.dispatch(observationID: observation.id, for: grant) {
                    ComputerUseBackgroundEvents.scroll(receiver, at: at, dx: request.dx, dy: request.dy)
                }
                Thread.sleep(forTimeInterval: 0.12)
                ComputerUseBackgroundEvents.deactivate(receiver)
                ComputerUseBackgroundEvents.noteLastPoint(at)
                return
            }
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                      wheelCount: 2, wheel1: -request.dy, wheel2: -request.dx, wheel3: 0) else {
                throw ComputerUseFailure("computer_input_unavailable")
            }
            event.location = target.serverPoint(from)
            event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()))
            try gate.dispatch(observationID: observation.id, for: grant) { event.post(tap: .cghidEventTap) }
        case .drag:
            guard let destination = request.to else { throw ComputerUseFailure("computer_invalid_pointer_arguments") }
            let (to, end) = try resolve(destination)
            // 起點、終點要在同一個視窗（事件送一個視窗、座標用同一組對應）。
            guard end.windowID == target.windowID else { throw ComputerUseFailure(ComputerUseNative.eventTargetUnresolved) }
            if ComputerUseBackgroundEvents.available {
                let receiver = try target.target()
                let number = ComputerUseBackgroundEvents.nextEventNumber()
                ComputerUseBackgroundEvents.activate(receiver)
                Thread.sleep(forTimeInterval: 0.06)
                defer {
                    Thread.sleep(forTimeInterval: 0.12)
                    ComputerUseBackgroundEvents.deactivate(receiver)
                }
                try drag(from: from, to: to, check: {
                    try check()
                    _ = try windowGeometry()
                }, send: { kind, point in
                    try gate.dispatch(observationID: observation.id, for: grant) {
                        ComputerUseBackgroundEvents.mouse(receiver, kind == .down ? .leftDown : .leftDragged,
                                                          at: target.serverPoint(point), eventNumber: number)
                    }
                }, release: { point in
                    ComputerUseBackgroundEvents.mouse(receiver, .leftUp, at: target.serverPoint(point), eventNumber: number)
                })
                ComputerUseBackgroundEvents.noteLastPoint(target.serverPoint(to))
                return
            }
            // Allocate cleanup before down; allocation failure can never strand a button.
            let up = try mouse(.leftMouseUp, from)
            try drag(from: from, to: to, check: {
                try check()
                _ = try windowGeometry()
            }, send: { kind, point in
                let event = try mouse(kind == .down ? .leftMouseDown : .leftMouseDragged, point)
                try gate.dispatch(observationID: observation.id, for: grant) { event.post(tap: .cghidEventTap) }
            }, release: { point in
                up.location = target.serverPoint(point)
                up.post(tap: .cghidEventTap)
            })
        }
    }
}
