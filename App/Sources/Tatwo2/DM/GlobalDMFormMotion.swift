import AppKit
import Combine
import QuartzCore

// W184 F2（使用者 09-29 看了 v2.0.21.029：「變化特效我不喜歡 你去figma找一些專業一點的 精煉絲滑」「我不用折疊的"打開" 我要滑開」
// 「往右滑開可以 但倒不行」；對照稿第 2 版）：私訊框換形態全部用「滑」，不翻、不倒、不轉、不壓扁（舊的 3D／縮放／clip 關鍵影格全部拿掉）。
// - 框就是一個容器：框在螢幕上的矩形用阻尼比 1 的彈簧（SwiftUI .smooth(duration: 0.42)）從舊位置連續滑到新位置；哪個角固定由擺法決定
//   （現在是右下），這裡四個數各走各的彈簧，跟哪個角固定無關。
// - 框裡：對話欄貼左緣；內橫的右欄貼右緣、寬度用它最後的寬度、被對話欄蓋著（只露出對話欄右邊那一段）：進內橫＝對話欄的寬從整個框寬
//   變成左欄寬、右欄露出來，分隔線在後 70% 淡入；出內橫反過來，分隔線在前 60% 淡出。同一串對話不換頁、不淡。
// - 換內容（任何形態↔倒放）先出後進：舊的 0–0.10 秒淡出、新的 0.10–0.32 秒淡入，兩層不會同時半透明。
// - 轉換中再換形態＝從現在的位置與速度直接轉向（彈簧換目標、不重設速度；不排隊、不等）。系統「減少動態效果」＝0.12 秒淡出、換框、0.15 秒淡入。
// - 樣子全是時間的純函式（GlobalDMFormPlan.frame(at:)）：自測在指定秒數取樣。
// - 原生網頁畫面（CEF：Browser 頁、倒放影片）照 GlobalDMNativePageMask：整段轉換都藏著（含轉向），停下才顯示回來；不重載、不搬、不關。
// W184 F3（使用者真機 v2.0.21.030：「切換卡頓卡頓的」）：動作跟上面完全一樣，但不再每一格改 SwiftUI 的框（每一格整支手機重排＝20–30 格／秒）：
// 開始那一刻真的內容只排一次版、拍成幾張圖，圖層照這裡的彈簧與淡入淡出在畫面伺服器上跑（GlobalDMFormStage：CASpringAnimation 用同一條
// 彈簧，淡入淡出用這裡的函式逐格算好的關鍵影格），動畫幾何不逐格觸發排版、主執行緒不逐格工作（內容自己變才排）；停下再換回真的內容。
// W184 F3（使用者 09-29 17:10：「r角現在會變 導致輸入筐根外ｒ角不齊」）：框的圓角任何形態、任何大小、轉場中都固定 52（輸入框 40、同心）：
// 圓角那條彈簧拿掉。

/// 從哪個形態換到哪個、怎麼換：滑（彈簧）、減少動態效果（淡出、換框、淡入）、直接換（框看不到、animated＝false、沒換）。
struct GlobalDMFormTransition: Equatable, Sendable {
    enum Style: Equatable, Sendable {
        case slide
        case fade
        case instant
    }

    let from: GlobalDMForm
    let to: GlobalDMForm
    let style: Style

    static func between(_ from: GlobalDMForm, _ to: GlobalDMForm, animated: Bool = true,
                        reduceMotion: Bool = false) -> GlobalDMFormTransition {
        guard animated, from != to else { return GlobalDMFormTransition(from: from, to: to, style: .instant) }
        return GlobalDMFormTransition(from: from, to: to, style: reduceMotion ? .fade : .slide)
    }
}

// MARK: - 彈簧與淡入淡出（純計算，好測）

enum GlobalDMEase {
    /// 0…1 夾住。
    static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }

    /// smoothstep：a 之前 0、b 之後 1，中間 3t²−2t³。
    static func step(_ a: Double, _ b: Double, _ x: Double) -> Double {
        guard b > a else { return x >= b ? 1 : 0 }
        let t = clamp((x - a) / (b - a))
        return t * t * (3 - 2 * t)
    }
}

/// 阻尼比 1 的彈簧（不回彈；response 0.42＝SwiftUI .smooth(duration: 0.42)）：位置與速度都是時間的純函式。
/// 轉向＝從現在的位置與速度換目標（retarget），速度不重設。
struct GlobalDMSpring: Equatable, Sendable {
    static let omega = 2 * Double.pi / DMPhone.Slide.response
    var origin: Double
    var velocity: Double
    var target: Double

    func value(at tau: Double) -> Double {
        let t = max(0, tau), d = origin - target, c = velocity + Self.omega * d
        return target + (d + c * t) * exp(-Self.omega * t)
    }

    func speed(at tau: Double) -> Double {
        let t = max(0, tau), d = origin - target, c = velocity + Self.omega * d
        return (velocity - Self.omega * c * t) * exp(-Self.omega * t)
    }
}

/// 一層內容的透明度（先出後進）：要換掉的從現在的透明度 0–0.10 秒淡出；要換上的等別層淡完（0.10–0.32 秒）才淡入，
/// 別層本來就看不到＝馬上淡入（0–0.22 秒）。兩層不會同時半透明；同一串對話（一直是要換上的那層、本來就是 1）一直是 1。
struct GlobalDMFade: Equatable, Sendable {
    var origin: Double
    var incoming: Bool
    var waits: Bool

    func value(at tau: Double) -> Double {
        let out = DMPhone.Slide.fadeOut
        guard incoming else { return origin * (1 - GlobalDMEase.step(0, out, tau)) }
        let start = waits ? out : 0
        return origin + (1 - origin) * GlobalDMEase.step(start, start + DMPhone.Slide.fadeIn, tau)
    }
}

// MARK: - 一格的樣子

/// 轉換中的一格（純資料）：框在螢幕上的矩形與框裡各層的樣子。
struct GlobalDMSlideFrame: Equatable, Sendable {
    /// 框在螢幕上的矩形（不含陰影邊；螢幕座標，y 往上）。圓角固定 DMPhone.screenRadius（W184 F3：不跟著大小、形態變）。
    var box: CGRect
    /// 0＝單欄、1＝內橫兩欄：對話欄寬＝框寬 ×（1 → 左欄比例）、右欄露出多少。
    var duo: Double
    /// 對話那一層（頂列＋欄）、倒放那一層的透明度。
    var chat: Double
    var tent: Double
    /// 內橫中間分隔線的透明度。
    var divider: Double
    /// 整個框的透明度（減少動態效果的淡出淡入；滑的時候一直是 1）。
    var opacity: Double
    /// 內橫的框寬：右欄寬度照它算（寬度用它最後的寬度，不跟著框寬變）。
    var landWidth: CGFloat
    /// 要去的形態（框裡的角色照它）。
    var form: GlobalDMForm

    /// 停在某個形態的樣子。
    static func rest(_ form: GlobalDMForm, box: CGRect) -> GlobalDMSlideFrame {
        GlobalDMSlideFrame(box: box, duo: form.isDuo ? 1 : 0, chat: form == .tent ? 0 : 1, tent: form == .tent ? 1 : 0,
                           divider: form.isDuo ? 1 : 0, opacity: 1, landWidth: box.width, form: form)
    }
}

/// 一格的速度（轉向時接著走）。
struct GlobalDMSlideSpeed: Equatable, Sendable {
    var x = 0.0, y = 0.0, width = 0.0, height = 0.0, duo = 0.0
    static let zero = GlobalDMSlideSpeed()
}

/// 一段（開始、或每一次轉向之後）：框的四個數、欄的進度各走一條彈簧（圓角固定，不走彈簧）；兩層內容各自先出後進。
struct GlobalDMSlideSegment: Equatable, Sendable {
    let start: Double
    let style: GlobalDMFormTransition.Style
    let form: GlobalDMForm
    let target: CGRect
    let x: GlobalDMSpring, y: GlobalDMSpring, width: GlobalDMSpring, height: GlobalDMSpring
    let duo: GlobalDMSpring
    let chat: GlobalDMFade, tent: GlobalDMFade
    let landWidth: CGFloat
    /// 開始那一刻看得到的樣子（減少動態效果淡出的就是它）。
    let before: GlobalDMSlideFrame

    init(start: Double, style: GlobalDMFormTransition.Style, from frame: GlobalDMSlideFrame, speed: GlobalDMSlideSpeed,
         to form: GlobalDMForm, target: CGRect) {
        self.start = start
        self.style = style
        self.form = form
        self.target = target
        before = frame
        x = GlobalDMSpring(origin: frame.box.minX, velocity: speed.x, target: target.minX)
        y = GlobalDMSpring(origin: frame.box.minY, velocity: speed.y, target: target.minY)
        width = GlobalDMSpring(origin: frame.box.width, velocity: speed.width, target: target.width)
        height = GlobalDMSpring(origin: frame.box.height, velocity: speed.height, target: target.height)
        duo = GlobalDMSpring(origin: frame.duo, velocity: speed.duo, target: form.isDuo ? 1 : 0)
        let intoTent = form == .tent
        chat = GlobalDMFade(origin: frame.chat, incoming: !intoTent, waits: !intoTent && frame.tent > 0.001)
        tent = GlobalDMFade(origin: frame.tent, incoming: intoTent, waits: intoTent && frame.chat > 0.001)
        landWidth = form.isDuo ? target.width : frame.landWidth
    }

    /// 這一段走多久算停（滑：0.6 秒、離新框 ≤1pt；減少動態效果：淡出＋淡入）。
    var length: Double { style == .fade ? DMPhone.Slide.reduceOut + DMPhone.Slide.reduceIn : DMPhone.Slide.settle }

    func frame(at tau: Double) -> GlobalDMSlideFrame {
        if style == .fade {
            let out = DMPhone.Slide.reduceOut
            guard tau >= out else {
                var shown = before
                shown.opacity = before.opacity * (1 - GlobalDMEase.step(0, out, tau))
                return shown
            }
            var after = GlobalDMSlideFrame.rest(form, box: target)
            after.landWidth = landWidth
            after.opacity = GlobalDMEase.step(out, out + DMPhone.Slide.reduceIn, tau)
            return after
        }
        let progress = GlobalDMEase.clamp(duo.value(at: tau))
        let divider = form.isDuo
            ? GlobalDMEase.clamp((progress - DMPhone.Slide.dividerIn) / (1 - DMPhone.Slide.dividerIn))
            : 1 - GlobalDMEase.clamp((1 - progress) / DMPhone.Slide.dividerOut)
        let box = CGRect(x: x.value(at: tau), y: y.value(at: tau),
                         width: max(1, width.value(at: tau)), height: max(1, height.value(at: tau)))
        return GlobalDMSlideFrame(box: box, duo: progress,
                                  chat: chat.value(at: tau), tent: tent.value(at: tau), divider: divider, opacity: 1,
                                  landWidth: landWidth, form: form)
    }

    func speed(at tau: Double) -> GlobalDMSlideSpeed {
        guard style == .slide else { return .zero }
        return GlobalDMSlideSpeed(x: x.speed(at: tau), y: y.speed(at: tau), width: width.speed(at: tau), height: height.speed(at: tau),
                                  duo: duo.speed(at: tau))
    }
}

/// 一整段轉換（開始＋每一次轉向）：t＝從開始算的秒數；frame(at:) 是 t 的純函式（自測在指定秒數取樣）。
struct GlobalDMFormPlan: Equatable, Sendable {
    private(set) var segments: [GlobalDMSlideSegment]

    init(from frame: GlobalDMSlideFrame, to form: GlobalDMForm, target: CGRect, style: GlobalDMFormTransition.Style) {
        segments = [GlobalDMSlideSegment(start: 0, style: style == .fade ? .fade : .slide, from: frame, speed: .zero,
                                         to: form, target: target)]
    }

    private var last: GlobalDMSlideSegment { segments[segments.count - 1] }
    var form: GlobalDMForm { last.form }
    var target: CGRect { last.target }
    /// 最後一段走完（停下）的時間。
    var end: Double { last.start + last.length }

    func segment(at t: Double) -> GlobalDMSlideSegment {
        segments.last { $0.start <= t } ?? segments[0]
    }

    func frame(at t: Double) -> GlobalDMSlideFrame {
        let segment = segment(at: t)
        return segment.frame(at: t - segment.start)
    }

    func isSettled(at t: Double) -> Bool { t >= end }

    /// 停下的樣子：剛好是新框。
    var rest: GlobalDMSlideFrame { GlobalDMSlideFrame.rest(last.form, box: last.target) }

    /// 轉向：從 t 這一刻的樣子與速度接著走，換成新目標（不排隊、不跳、不重設速度）。
    mutating func retarget(at t: Double, to form: GlobalDMForm, target: CGRect) {
        let current = segment(at: t)
        let tau = t - current.start
        segments.append(GlobalDMSlideSegment(start: t, style: current.style, from: current.frame(at: tau),
                                             speed: current.speed(at: tau), to: form, target: target))
    }
}

// MARK: - 原生網頁畫面：轉換期間的遮蔽狀態（不重建）

/// 放原生網頁畫面（CEF）的容器：換形態的轉換期間，裡面的 NSView 藏起來、容器用頁面底色佔位，走完再顯示。
/// 私訊框 Browser 的頁面容器是一個；房 E 倒放的影片容器也照這個掛上來。
@MainActor
protocol GlobalDMNativePageHost: NSView {
    /// 遮蔽結束時這個容器裡的頁面照樣藏著（例：倒放的影片有卡蓋著）。預設＝顯示回來。
    var keepsPagesHidden: Bool { get }
    /// 頁面藏著時容器的佔位色（預設＝頁面底色）。
    var placeholderFill: CGColor { get }
}

extension GlobalDMNativePageHost {
    var keepsPagesHidden: Bool { false }
    var placeholderFill: CGColor { NSColor.textBackgroundColor.cgColor }
}

extension DMBrowserPageContainer: GlobalDMNativePageHost {}

extension DMTentVideoContainer {
    /// 有卡蓋著時影片藏在下面：遮蔽結束不把它顯示出來（它自己的 covered 管）。
    var keepsPagesHidden: Bool { covered }
    /// W184 F2：倒放影片的佔位是黑的（對話淡出後淡入的是暗的，不會先白一下再變黑）。
    /// W184 F 小修正（真機 v2.0.21.030：沒有影片時轉換中淡入黑底、停下才換成米色空狀態卡，最後一刻從黑閃成米色）：
    /// 佔位跟停下之後會顯示的一致——真的有影片（借著、要收進來、正帶著離開）才黑；空狀態＝不塗（底下的米色照樣透出來）。
    var placeholderFill: CGColor {
        if !subviews.isEmpty { return NSColor.black.cgColor }   // 影片（原生頁）就在裡面（藏著）
        guard let video, video.entering || video.leaving || video.shown != nil || video.lentTabID != nil else { return NSColor.clear.cgColor }
        return NSColor.black.cgColor
    }
}

/// W184 AB（GPT-6 審查 #3）：換形態期間「原生網頁一律藏起來」是一個持續有效的遮蔽狀態（照 token 持有），不是動畫開始那一刻拍一張照：
/// - 開始（begin）之後：面板裡現有的頁面藏起來（cover）；遮蔽中新掛上、被搬到另一個容器的頁面（DMBrowser 的 attach 叫 present）照樣藏。
/// - 結束（最後一個 token 放手）：把這一段藏過的頁面全部顯示回來——不看它現在掛在哪個容器（搬走的也還原）；容器底色還原。
/// - 只動 isHidden 與容器底色：頁面不拿下來、不關、不重新載入。
@MainActor
final class GlobalDMNativePageMask: ObservableObject {
    static let shared = GlobalDMNativePageMask()

    /// 遮蔽中（換形態的轉換進行中）：原生網頁畫面一律藏著（房 D 判斷「配對頁真的在畫面上」可以看這個）。
    @Published private(set) var isMasking = false
    private var holders: Set<Int> = []
    private var nextToken = 0
    /// 這一段遮蔽藏過的頁面（弱參照；頁面關掉就不管它）。
    private let hidden = NSHashTable<NSView>.weakObjects()
    /// 塗過佔位色的容器與它原本的底色。
    @MainActor private final class Painted {
        weak var host: NSView?
        let background: CGColor?
        init(host: NSView, background: CGColor?) { self.host = host; self.background = background }
    }
    private var painted: [Painted] = []

    init() {}

    /// 頁面底色佔位。
    var fill: CGColor { NSColor.textBackgroundColor.cgColor }

    /// 開始一段遮蔽（回傳持有的 token）。
    @discardableResult
    func begin() -> Int {
        nextToken += 1
        holders.insert(nextToken)
        if !isMasking { isMasking = true }
        return nextToken
    }

    /// 放掉這一個 token；最後一個放手＝這一段藏過的頁面全部顯示回來（不看它現在掛在哪）、容器底色還原。重複放手沒事。
    func end(_ token: Int) {
        guard holders.remove(token) != nil, holders.isEmpty else { return }
        for view in hidden.allObjects {
            if let host = view.superview as? GlobalDMNativePageHost, host.keepsPagesHidden { continue }
            view.isHidden = false
        }
        hidden.removeAllObjects()
        for entry in painted { entry.host?.layer?.backgroundColor = entry.background }
        painted = []
        if isMasking { isMasking = false }
    }

    /// 遮蔽中：這個畫面底下所有原生網頁容器裡顯示著的頁面藏起來、容器塗佔位色（別人本來就藏著的不碰）。回傳每個容器這一次藏的頁面。
    @discardableResult
    func cover(in root: NSView?) -> [(host: NSView, hidden: [NSView])] {
        guard isMasking, let root else { return [] }
        var result: [(host: NSView, hidden: [NSView])] = []
        var stack: [NSView] = [root]
        var visited = 0
        while let view = stack.popLast(), visited < 4000 {
            visited += 1
            if view is GlobalDMNativePageHost {
                let shown = view.subviews.filter { !$0.isHidden }
                for sub in shown { hide(sub) }
                paint(view)
                result.append((host: view, hidden: shown))
                continue
            }
            stack.append(contentsOf: view.subviews)
        }
        return result
    }

    /// 頁面放進框（DMBrowser 的 attach，換容器、新掛上都一樣）：遮蔽中＝藏起來並記下（結束時顯示回來）；沒有遮蔽＝顯示。
    func present(_ view: NSView, in container: NSView) {
        guard isMasking else {
            view.isHidden = false
            return
        }
        hide(view)
        paint(container)
    }

    /// 這個畫面在不在原生網頁容器裡（內橫右欄的網頁拿著鍵盤時 Esc 給網頁）。
    static func isInsideNativePage(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let node = current {
            if node is GlobalDMNativePageHost { return true }
            current = node.superview
        }
        return false
    }

    /// 這一段遮蔽現在藏著的頁面（自測看）。
    var hiddenPages: [NSView] { hidden.allObjects }

    private func hide(_ view: NSView) {
        view.isHidden = true
        hidden.add(view)
    }

    private func paint(_ host: NSView) {
        guard !painted.contains(where: { $0.host === host }) else { return }
        host.wantsLayer = true
        painted.append(Painted(host: host, background: host.layer?.backgroundColor))
        host.layer?.backgroundColor = (host as? GlobalDMNativePageHost)?.placeholderFill ?? fill
    }
}

/// 舊的一次性介面（房 E 的自測還在用）：cover＝開一段遮蔽並藏這個畫面底下的原生頁；uncover＝放掉那一段（照遮蔽狀態還原）。
@MainActor
struct GlobalDMNativePageCover {
    weak var host: NSView?
    /// 這一次在這個容器裡藏起來的頁面。
    let hidden: [NSView]
    let token: Int
    let mask: GlobalDMNativePageMask

    static func cover(in root: NSView?, mask: GlobalDMNativePageMask? = nil) -> [GlobalDMNativePageCover] {
        let mask = mask ?? .shared
        let token = mask.begin()
        let covered = mask.cover(in: root)
        guard !covered.isEmpty else {
            mask.end(token)
            return []
        }
        return covered.map { GlobalDMNativePageCover(host: $0.host, hidden: $0.hidden, token: token, mask: mask) }
    }

    static func isInsideNativePage(_ view: NSView) -> Bool { GlobalDMNativePageMask.isInsideNativePage(view) }

    func uncover() { mask.end(token) }
}

// MARK: - 轉換的進行與「轉換進行中」

/// 換形態的轉換（面板控制器一個）：isAnimating（可觀察）＝轉換進行中（從第一段開始到最後停下都是 true，轉向不中斷）；
/// plan＝這一整段的樣子（時間的純函式：自測、轉向、圖層的起點與速度都照它）；onFrame＝停下的那一格（面板控制器換回真的內容）。
/// W184 F3：動畫本身是 Core Animation 的圖層在畫面伺服器上跑（GlobalDMFormStage），這裡沒有逐格的回呼、主執行緒不逐格工作：
/// 只排一個「停下」的計時器。自測推時鐘（manualTime）時每一格 tick() 叫 onTick，讓圖層停在那個時間。
/// 轉換期間持有一段原生網頁遮蔽（GlobalDMNativePageMask），停下才放掉；停下叫 onIdle（桌面控制器接著做排隊的「要看到某個畫面」）。
@MainActor
final class GlobalDMFormMotion: ObservableObject {
    @Published private(set) var isAnimating = false
    /// 轉換走完（isAnimating 已經是 false）叫一次。
    var onIdle: (@MainActor () -> Void)?
    /// 停下那一格（finished＝true、剛好是新框）。W184 F3：動畫期間不再逐格叫（圖層自己動）。
    var onFrame: (@MainActor (GlobalDMSlideFrame, Bool) -> Void)?
    /// 自測推時鐘（manualTime）時每一格叫（elapsed 秒）：面板控制器讓圖層停在這個時間。正式不叫。
    var onTick: (@MainActor (Double) -> Void)?
    let nativePages: GlobalDMNativePageMask
    /// 在滑的是哪一個框（停靠框、浮動框）。
    var surface: GlobalDMSurface?
    /// 這一整段（開始＋轉向）；nil＝停著。
    private(set) var plan: GlobalDMFormPlan?
    /// 時鐘（自測換）。
    var clock: @MainActor () -> CFTimeInterval = { CACurrentMediaTime() }
    /// 自測：時鐘由自測推（不排停下的計時器；自測叫 tick() 一格一格走到停下）。
    var manualTime = false
    /// 這一整段開始的時間（clock 的時間）。
    private(set) var startedAt: CFTimeInterval = 0
    private var generation = 0
    private var maskToken: Int?
    private var settleTimer: Timer?

    init(nativePages: GlobalDMNativePageMask? = nil) {
        self.nativePages = nativePages ?? .shared
    }

    /// 這一段開始到現在幾秒。
    var elapsed: Double { plan == nil ? 0 : clock() - startedAt }

    /// 現在這一格（停著＝nil）。
    var current: GlobalDMSlideFrame? { plan.map { $0.frame(at: elapsed) } }

    /// 現在這一格的速度（轉向時圖層的彈簧從這個速度接著走）。
    var currentSpeed: GlobalDMSlideSpeed? {
        plan.map { plan in
            let segment = plan.segment(at: elapsed)
            return segment.speed(at: elapsed - segment.start)
        }
    }

    /// W184 F3：拍圖之前先做——持有遮蔽、藏好面板裡現有的原生頁、「轉換進行中」＝true（配對碼同步藏起來），
    /// 這樣原生網頁與配對碼都不會被拍進圖層。
    func hold(host: NSView?) {
        if maskToken == nil { maskToken = nativePages.begin() }
        nativePages.cover(in: host)   // 面板裡現有的原生頁藏起來；之後新掛上、搬家的由 attach 照遮蔽狀態藏
        if !isAnimating { isAnimating = true }
    }

    /// 開始一段轉換，或轉換中直接轉向（從現在滑到一半的位置與速度接著走；不排隊、不等）。
    /// start＝停著時現在的樣子（轉向時不用：照現在這一格）；host＝面板內容（原生網頁藏起來）。
    func slide(from start: GlobalDMSlideFrame, to form: GlobalDMForm, target: CGRect,
               style: GlobalDMFormTransition.Style, host: NSView?) {
        generation += 1
        if var plan {
            plan.retarget(at: elapsed, to: form, target: target)
            self.plan = plan
        } else {
            plan = GlobalDMFormPlan(from: start, to: form, target: target, style: style)
            startedAt = clock()
        }
        hold(host: host)
        scheduleSettle()
    }

    /// 停下的計時器（最後一段走完的時間；轉向＝重排）。自測推時鐘時不排。
    private func scheduleSettle() {
        settleTimer?.invalidate()
        settleTimer = nil
        guard !manualTime, let plan else { return }
        let timer = Timer(timeInterval: max(0, plan.end - elapsed) + 0.002, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    /// 看一下時間：走完就停；自測推時鐘時叫 onTick（圖層停在這個時間）；計時器早到＝再排一次。
    func tick() {
        guard let plan else { return }
        let t = elapsed
        guard !plan.isSettled(at: t) else { return finish() }
        if manualTime { onTick?(t) } else { scheduleSettle() }
    }

    /// 停下：最後一格剛好是新框（面板換回剛好是新框、換回真的內容）；遮蔽放掉（原生網頁顯示回來）；排隊的接著做。
    /// W184 F／G1（查證 #5）：notify＝false（收框途中停下）＝排隊的不在這個呼叫裡做，排到下一輪 run loop（那時沒有新的轉換才做），
    /// 收框的路徑走完之前不會有別的整理插進來。
    func finish(notify: Bool = true) {
        settleTimer?.invalidate()
        settleTimer = nil
        if let plan {
            self.plan = nil
            onFrame?(plan.rest, true)
        }
        release(notify: notify)
    }

    private func release(notify: Bool) {
        if let maskToken {
            self.maskToken = nil
            nativePages.end(maskToken)
        }
        guard isAnimating else { return }
        isAnimating = false
        if notify { onIdle?() } else { idleLater() }
    }

    /// 下一輪 run loop 才叫 onIdle（那時又開始轉換了就不叫：新的那一段走完會叫）。
    private func idleLater() {
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isAnimating else { return }
                self.onIdle?()
            }
        }
    }

    /// 沒有面板的自測：假一段轉換（duration 秒後自己停；一樣持有遮蔽、停下叫 onIdle）。
    @discardableResult
    func begin(duration: Double) -> Int {
        generation += 1
        let token = generation
        if maskToken == nil { maskToken = nativePages.begin() }
        if !isAnimating { isAnimating = true }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((duration + 0.03) * 1_000_000_000))
            self?.end(token)
        }
        return token
    }

    /// 結束 begin(duration:) 的那一段（晚到的舊編號不動新的；真的在滑的不動）。
    func end(_ token: Int, notify: Bool = true) {
        guard token == generation, plan == nil else { return }
        release(notify: notify)
    }
}
