import AppKit
import ApplicationServices
import os

/// W184 CU：觀察要截哪一個視窗（AX 讀的那個視窗 → 視窗伺服器裡的視窗），規則要有確定的結果。
///
/// 09-30 mini（.032）：以 TATWO 自己為目標、開著主視窗＋停靠在主視窗裡的私訊框＋Island（可能還有換形態的外殼）時，
/// computer_start／computer_observe 三次都回 computer_window_not_uniquely_identified。舊規則只比位置大小＋標題、
/// 再找「在螢幕上的前後順序」；AX 挑到的視窗跟別的自家視窗同位置、同標題又都不在螢幕上（收起來的外殼、alpha 0 的輔助視窗）
/// 就判斷不了，代理也沒有辦法指定要哪一個。
///
/// 09-30 mini 實機（讀 AX 與視窗伺服器，唯讀）：同一個視窗兩邊的位置不一樣——私訊框 AX 說 y=227、視窗伺服器
///（ScreenCaptureKit 用的）說 y=1247；主視窗 48 對 1068，大小都一樣、整整差 1020。舊規則拿「AX 的位置大小」去比，
/// 一個都對不上＝每次都 not_uniquely_identified。所以同一個視窗只比大小（位置可能是兩套座標）。
///
/// W184 CU 第二輪（GPT-6 審查 #1、#5）：「可以用」（看得見、接得到滑鼠、沒擋擷取）是每一條選取分支的共同前置條件——
/// 代理指定的、知道編號的、AX 那邊挑的都一樣；知道編號不是例外。
///
/// W184 CU 第三輪（GPT-6 複核）：
/// - 擋擷取是三態（shareable／protected／unknown）：視窗伺服器的 kCGWindowSharingState 缺、不是整數、不認得＝unknown＝
///   當成受保護（不可以用、不給標題）。自家視窗再看 WindowCaptureShield（持有＋放手後的 linger）：它在擋＝強制否決；
///   不在主執行緒問不到＝unknown。不再看 AppKit 的 sharingType getter（這個 macOS 上設過 .none 就卡住）。
/// - 標題、位置送不送出去是同一條輸出過濾（`disclosed`）：成功回應的 windows、錯誤的候選清單、錯誤裡 AX 讀的那個視窗都走它；
///   確定沒擋擷取才給，擋擷取或讀不到＝只有 windowID 與 protected。
/// - 沒有 AX↔視窗編號的對應（私有 API `_AXUIElementGetWindow` 拿不到）＝沒有可信的身分對應：一律拒絕，
///   代理指定的、沒指定的、要截圖的、不截圖的都一樣（readState 讀樹之前就拒絕；choose 也拒絕）。位置大小相等從不算數。
///
/// 規則（照順序，第一條成立就是它）：
/// 1. 沒有 AX 視窗編號＝拒絕（`*_unverifiable_without_ax_window_id`）。
/// 2. 代理用 computer_observe 的 windowID 指定（上一次錯誤附的候選清單裡的）：那個視窗要在清單裡、可以用、而且就是 AX 讀的
///    那個視窗（編號一樣），不然就是錯誤——截圖一定要跟無障礙樹是同一個視窗。
/// 3. AX 視窗的編號：同一個視窗（大小一樣就好，位置可能是兩套座標）而且可以用，才是它；不可以用＝拒絕（不會改拿別的）。
/// 4. 判斷不了：錯誤附候選清單（可以送出的給 windowID、標題、大小、位置、看不看得見；其餘只有 windowID＋protected），
///    代理用 computer_observe 的 windowID 指定。
enum ComputerUseWindowPick {
    /// 擋擷取的狀態。unknown＝讀不到＝當成受保護。
    enum Protection: String, Equatable, Sendable { case shareable, protected, unknown }

    /// kCGWindowSharingState → 三態（純函式）：0（none）＝protected；1、2（readOnly、readWrite）＝shareable；
    /// 缺、不是整數（字串、布林、NSNull）、其他數字＝unknown。
    static func protection(sharingState value: Any?) -> Protection {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue) else { return .unknown }
        switch number.intValue {
        case 0: return .protected
        case 1, 2: return .shareable
        default: return .unknown
        }
    }

    /// 一個視窗伺服器視窗現在的樣子（CGWindowList；自己的視窗再加 AppKit 與 WindowCaptureShield 看到的）。
    struct Facts: Equatable, Sendable {
        var onScreen: Bool
        var alpha: Double
        var layer: Int
        /// 視窗伺服器的擋擷取狀態（ScreenCaptureKit 真正看的）。設成 .none 當下就反映、還原也當下反映（09-30 mini 探針）。
        var server: Protection
        /// 自家視窗：WindowCaptureShield 有沒有在擋（持有或放手後的 linger）。nil＝不是自家視窗（不適用）；
        /// .unknown＝自家視窗但這次問不到（不在主執行緒）。
        var shield: Protection?
        /// 以下只有 TATWO 自己的視窗才知道（主執行緒上問 AppKit）；nil＝不知道。
        var appKitVisible: Bool? = nil
        var appKitAlpha: Double? = nil
        var ignoresMouse: Bool? = nil
        /// AppKit 的 sharingType ＝ .none。只記下來當證據、不拿來判斷：這個 macOS（27）上視窗一旦設過 .none，AppKit 的 getter
        /// 之後永遠回 .none（09-30 mini 探針）。DMBrowserAcceptance.windowSharingIsObservable 守的也是同一件事。
        var appKitProtected: Bool? = nil

        /// server 沒給＝unknown（當成受保護）：呼叫的地方要明講「確定可以分享」。
        init(onScreen: Bool, alpha: Double, layer: Int, server: Protection = .unknown, shield: Protection? = nil,
             appKitVisible: Bool? = nil, appKitAlpha: Double? = nil, ignoresMouse: Bool? = nil, appKitProtected: Bool? = nil) {
            self.onScreen = onScreen
            self.alpha = alpha
            self.layer = layer
            self.server = server
            self.shield = shield
            self.appKitVisible = appKitVisible
            self.appKitAlpha = appKitAlpha
            self.ignoresMouse = ignoresMouse
            self.appKitProtected = appKitProtected
        }

        /// 擋擷取：視窗伺服器不是確定可以分享（protected 或 unknown），或自家的 WindowCaptureShield 在擋／問不到。
        var captureProtected: Bool { server != .shareable || (shield != nil && shield != .shareable) }
        /// 看得見：在螢幕上、不透明（自己的視窗：AppKit 也說看得見、不透明）。
        var visible: Bool { onScreen && alpha > 0.01 && appKitVisible != false && (appKitAlpha ?? 1) > 0.01 }
        /// 可以用（每一條選取分支的共同前置條件）：看得見、接得到滑鼠（Computer Use 指標那種浮層不算）、沒有擋擷取。
        var usable: Bool { visible && ignoresMouse != true && !captureProtected }
        /// 標題、位置可以送出去：確定沒擋擷取。
        var disclosable: Bool { !captureProtected }
    }

    /// 統一的輸出過濾（成功回應的 windows、錯誤的候選清單、錯誤裡 AX 讀的那個視窗都走這裡）：確定沒擋擷取才給完整的一列；
    /// 擋擷取、讀不到狀態、不知道是哪個視窗＝只有 windowID（知道的話）與 protected。
    static func disclosed(windowID: CGWindowID?, facts: Facts?, _ full: () -> [String: Any]) -> [String: Any] {
        guard let facts, facts.disclosable else {
            var row: [String: Any] = ["protected": true]
            if let windowID { row["windowID"] = Int(windowID) }
            return row
        }
        return full()
    }

    struct Candidate: Equatable, Sendable {
        let windowID: CGWindowID
        let title: String
        /// 視窗伺服器座標、左上原點（CGWindowList、SCWindow 同一套）。
        let frame: CGRect
        var facts: Facts
    }

    enum Outcome: Equatable {
        case window(CGWindowID, rule: String)
        /// 同一個視窗但大小對不上（剛好在變）：當成擷取途中視窗變了，由 observeWithRetry 重試。
        case moving
        case unresolved(reason: String, candidates: [Candidate])
    }

    /// 這個 App 每個視窗伺服器視窗的可見度與擋擷取狀態。自己的視窗而且在主執行緒上：再問 AppKit（isVisible、alphaValue、
    /// ignoresMouseEvents、sharingType 當證據）與 WindowCaptureShield；不在主執行緒＝shield unknown（當成受保護）。
    static func facts(pid: pid_t) -> [CGWindowID: Facts] {
        var result: [CGWindowID: Facts] = [:]
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list where (info[kCGWindowOwnerPID as String] as? Int32) == pid {
            guard let number = info[kCGWindowNumber as String] as? Int, number > 0 else { continue }
            var sharing = info[kCGWindowSharingState as String]
            #if DEBUG
            if ComputerUseSelfTestHooks.sharingUnknown(CGWindowID(number)) { sharing = nil }   // 自測：模擬讀不到
            #endif
            result[CGWindowID(number)] = Facts(onScreen: (info[kCGWindowIsOnscreen as String] as? Bool) ?? false,
                                               alpha: (info[kCGWindowAlpha as String] as? Double) ?? 1,
                                               layer: (info[kCGWindowLayer as String] as? Int) ?? 0,
                                               server: protection(sharingState: sharing))
        }
        guard pid == getpid() else { return result }
        guard Thread.isMainThread else {
            for id in Array(result.keys) { result[id]?.shield = .unknown }
            return result
        }
        MainActor.assumeIsolated {
            for id in Array(result.keys) {
                // 不是 NSWindow 的（系統替這個行程開的）WindowCaptureShield 也擋不了它：不適用＝shareable。
                guard let window = NSApp.window(withWindowNumber: Int(id)) else { result[id]?.shield = .shareable; continue }
                result[id]?.appKitVisible = window.isVisible
                result[id]?.appKitAlpha = Double(window.alphaValue)
                result[id]?.ignoresMouse = window.ignoresMouseEvents
                result[id]?.appKitProtected = window.sharingType == .none
                result[id]?.shield = WindowCaptureShield.shared.isShielding(window) ? .protected : .shareable
            }
        }
        return result
    }

    /// 這個 App 的視窗伺服器視窗（編號、名稱、位置大小、可見度）：讀樹那一步判斷不了時附在錯誤裡的候選。
    static func candidates(pid: pid_t) -> [Candidate] {
        let facts = facts(pid: pid)
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  let number = info[kCGWindowNumber as String] as? Int, number > 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict), let fact = facts[CGWindowID(number)] else { return nil }
            return Candidate(windowID: CGWindowID(number), title: info[kCGWindowName as String] as? String ?? "", frame: bounds, facts: fact)
        }
    }

    /// 這個視窗現在的位置大小（視窗伺服器座標）；不在清單裡（或不是 owner 這個行程的）＝nil。
    static func serverFrame(windowID: CGWindowID, owner: pid_t? = nil) -> CGRect? {
        for info in CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        where (info[kCGWindowNumber as String] as? Int) == Int(windowID) {
            if let owner, (info[kCGWindowOwnerPID as String] as? Int32) != owner { return nil }
            return (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        }
        return nil
    }

    /// 這個視窗現在還可以用（讀樹、擷取、回傳前各看一次）。
    static func stillUsable(windowID: CGWindowID, pid: pid_t) -> Bool {
        facts(pid: pid)[windowID]?.usable == true
    }

    /// 這個行程在螢幕上的選單視窗（kCGPopUpMenuWindowLevel）：編號與視窗伺服器的位置大小。
    static func popUpMenuWindows(pid: pid_t) -> [(CGWindowID, CGRect)] {
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid, (info[kCGWindowLayer as String] as? Int) == level,
                  let number = info[kCGWindowNumber as String] as? Int, number > 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return nil }
            return (CGWindowID(number), bounds)
        }
    }

    /// 開著的選單是哪一個視窗（純函式）：AXMenu 的位置大小（AX 座標）平移「AX → 視窗伺服器」的座標差之後，跟選單視窗的
    /// 位置大小一模一樣的，剛好一個才算。`_AXUIElementGetWindow` 對選單回的是叫出它的那個視窗（09-30 mini 探針），不能用。
    static func menuWindow(axMenuFrame: CGRect, offset: CGVector, windows: [(CGWindowID, CGRect)]) -> (CGWindowID, CGRect)? {
        let expected = axMenuFrame.offsetBy(dx: offset.dx, dy: offset.dy)
        let matches = windows.filter { ComputerUseNative.sameFrame($0.1, expected) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// AX 那邊一個視窗的狀態：可以用、不可以用、確認不了（沒有視窗編號＝沒有可信的身分對應）。
    enum AXStatus: Equatable, Sendable { case usable, unusable, unverifiable }
    enum AXPick<T> { case window(T), none, unverifiable }

    /// AX 這邊要讀哪一個視窗（代理沒有指定時）：焦點視窗 → 主視窗 → 其他，第一個可以用的；途中碰到確認不了的＝拒絕
    /// （不跳過它改讀別的，也不當成可以用）；都不可以用＝沒有視窗。代理指定的視窗由 readState 另外處理。
    static func axWindow<T>(focused: T?, main: T?, all: [T], status: (T) -> AXStatus) -> AXPick<T> {
        for node in [focused, main].compactMap({ $0 }) + all {
            switch status(node) {
            case .usable: return .window(node)
            case .unverifiable: return .unverifiable
            case .unusable: continue
            }
        }
        return .none
    }

    static func choose(_ all: [Candidate], focusedID: CGWindowID?, focusedFrame: CGRect, requested: CGWindowID? = nil) -> Outcome {
        let sameFrame = all.filter { ComputerUseNative.sameFrame($0.frame, focusedFrame) }
        // 1. 沒有 AX 視窗的編號＝沒有可信的身分對應：一律拒絕（位置大小相等不算數）。
        guard let focusedID else {
            return .unresolved(reason: requested == nil ? "observed_window_unverifiable_without_ax_window_id"
                                                        : "requested_window_unverifiable_without_ax_window_id",
                               candidates: listed(all, sameFrame))
        }
        // 2. 代理指定的：要在清單裡、可以用、而且就是 AX 讀的那個。
        if let requested {
            guard let chosen = all.first(where: { $0.windowID == requested }) else {
                return .unresolved(reason: "requested_window_not_capturable", candidates: listed(all, sameFrame))
            }
            guard chosen.facts.usable else {
                return .unresolved(reason: "requested_window_not_usable", candidates: listed(all, sameFrame))
            }
            guard focusedID == requested else {
                return .unresolved(reason: "requested_window_is_not_the_observed_window", candidates: listed(all, sameFrame))
            }
            return sameSize(chosen.frame, focusedFrame) ? .window(requested, rule: "requested") : .moving
        }
        // 3. AX 視窗的編號：同一個視窗（只比大小：兩邊的位置可能是兩套座標）而且可以用；不可以用＝拒絕，不換別的。
        guard let same = all.first(where: { $0.windowID == focusedID }) else {
            return .unresolved(reason: "observed_window_not_capturable", candidates: listed(all, sameFrame))
        }
        guard same.facts.usable else {
            return .unresolved(reason: "observed_window_not_usable", candidates: listed(all, sameFrame))
        }
        return sameSize(same.frame, focusedFrame) ? .window(focusedID, rule: "same_window") : .moving
    }

    /// 大小一樣（差不到 1 點）。
    static func sameSize(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.width - rhs.width) < 1 && abs(lhs.height - rhs.height) < 1
    }

    /// 錯誤附的候選：同位置大小的全列；再加其他看得見的（最多 12 個）。
    static func listed(_ all: [Candidate], _ sameFrame: [Candidate]) -> [Candidate] {
        var list = sameFrame
        for candidate in all where candidate.facts.visible && !list.contains(where: { $0.windowID == candidate.windowID }) {
            list.append(candidate)
        }
        return Array(list.prefix(12))
    }

    /// computer_window_not_uniquely_identified 後面接 JSON：為什麼、AX 讀的那個視窗、候選清單、下一步。
    /// 候選與 AX 讀的那個視窗都經過 `disclosed`（擋擷取、讀不到、不知道是哪個＝只有 windowID 與 protected）。
    static func failureCode(reason: String, candidates: [Candidate], focusedTitle: String, focusedFrame: CGRect,
                            focusedID: CGWindowID?, focusedFacts: Facts?) -> String {
        func size(_ rect: CGRect) -> String { "\(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))" }
        let focused = disclosed(windowID: focusedID, facts: focusedID == nil ? nil : focusedFacts) {
            var row: [String: Any] = ["title": String(focusedTitle.prefix(80)), "size": size(focusedFrame),
                                      "x": Int(focusedFrame.minX.rounded()), "y": Int(focusedFrame.minY.rounded())]
            if let focusedID { row["windowID"] = Int(focusedID) }
            return row
        }
        let rows: [[String: Any]] = candidates.map { candidate in
            disclosed(windowID: candidate.windowID, facts: candidate.facts) {
                var row: [String: Any] = ["windowID": Int(candidate.windowID), "title": String(candidate.title.prefix(80)),
                                          "size": size(candidate.frame), "x": Int(candidate.frame.minX.rounded()),
                                          "y": Int(candidate.frame.minY.rounded()), "visible": candidate.facts.visible,
                                          "sameFrameAsObserved": ComputerUseNative.sameFrame(candidate.frame, focusedFrame)]
                if candidate.facts.layer != 0 { row["layer"] = candidate.facts.layer }
                if candidate.facts.ignoresMouse == true { row["ignoresMouse"] = true }
                return row
            }
        }
        let payload: [String: Any] = ["reason": reason, "observedWindow": focused, "candidates": rows,
                                      "next": "call computer_observe again with windowID set to one candidate's windowID (the window you want to see)"]
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "computer_window_not_uniquely_identified:" + json
    }

    nonisolated static let failurePrefix = "computer_window_not_uniquely_identified:"

    /// 讀樹那一步就判斷不了（代理指定的視窗不在 AX 樹裡、不可以用、沒有視窗編號）：同一種錯誤、同一份候選清單。
    static func failure(reason: String, pid: pid_t, focusedTitle: String = "", focusedFrame: CGRect = .zero,
                        focusedID: CGWindowID? = nil) -> ComputerUseFailure {
        let all = candidates(pid: pid)
        let sameFrame = all.filter { ComputerUseNative.sameFrame($0.frame, focusedFrame) }
        return ComputerUseFailure(failureCode(reason: reason, candidates: listed(all, sameFrame), focusedTitle: focusedTitle,
                                              focusedFrame: focusedFrame, focusedID: focusedID,
                                              focusedFacts: focusedID.flatMap { id in all.first { $0.windowID == id }?.facts }))
    }

    /// 錯誤碼裡的 reason（自測、控制器看）。
    static func reason(of failure: ComputerUseFailure) -> String? {
        guard failure.code.hasPrefix(failurePrefix),
              let data = failure.code.dropFirst(failurePrefix.count).data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return payload["reason"] as? String
    }
}

#if DEBUG
/// 自測用（DEBUG 才有；正式版沒有這段）：模擬「讀不到擋擷取狀態」「私有 API 拿不到視窗編號」，記下背景事件送去哪一個視窗。
enum ComputerUseSelfTestHooks {
    struct EventRecord: Equatable, Sendable {
        let windowID: UInt32
        let type: UInt8
        /// 視窗內的座標（視窗伺服器的位置大小算的）；activate／deactivate 沒有。
        let local: CGPoint?
    }
    private struct State: Sendable {
        var unknownSharing: Set<CGWindowID> = []
        var windowIDUnavailable = false
        var recording = false
        var records: [EventRecord] = []
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())
    static func sharingUnknown(_ id: CGWindowID) -> Bool { state.withLock { $0.unknownSharing.contains(id) } }
    static func setSharingUnknown(_ ids: Set<CGWindowID>) { state.withLock { $0.unknownSharing = ids } }
    static var windowIDUnavailable: Bool {
        get { state.withLock { $0.windowIDUnavailable } }
        set { state.withLock { $0.windowIDUnavailable = newValue } }
    }
    static func startRecording() { state.withLock { $0.recording = true; $0.records = [] } }
    static func stopRecording() -> [EventRecord] {
        state.withLock { value in
            value.recording = false
            defer { value.records = [] }
            return value.records
        }
    }
    static func record(_ record: EventRecord) { state.withLock { if $0.recording { $0.records.append(record) } } }
}
#endif
