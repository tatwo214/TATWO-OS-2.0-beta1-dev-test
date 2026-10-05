import AppKit
import Carbon
import Combine
import Foundation

// W179 E：桌面圓鈕、形態（W184 前是「展開尺寸」）、⌥⌘＋自訂鍵（R7、R8）的純邏輯與設定。畫面與 Carbon 熱鍵在同資料夾的另外幾個檔。

// MARK: - 形態（W184 AB）

/// W184 AB（使用者 09-29：「私訊鈕的ui…應該要參照手機app的規格去設計」「duo的形式已經ok就照你的設計去做」）：
/// 私訊框＝一支 iPhone Duo 的四種拿法。停靠框、浮動框、桌面圓鈕旁的框都照目前形態，放不下等比縮；⌘⌥Tab 照 `next` 依序換。
/// 舊的「展開尺寸」（私訊框／ChatGPT 快捷視窗／iPhone Duo 闔起／打開）不再出現，存著的舊值照 `stored(_:)` 對應。
enum GlobalDMForm: String, CaseIterable, Identifiable, Sendable {
    /// 外直：闔起、外螢幕直拿（Apple 規格 1398×2034 像素＠3x）。
    case outerPortrait
    /// 內橫：打開、橫拿；一條頂列跨兩欄。
    case innerLandscape
    /// 內直：打開直拿。
    case innerPortrait
    /// 倒放：橫著倒放，預設當影片子畫面（內容在 GlobalDMTentContent）。
    case tent

    var id: String { rawValue }

    var size: CGSize {
        switch self {
        case .outerPortrait: CGSize(width: 466, height: 678)
        case .innerLandscape: CGSize(width: 890, height: 626)
        case .innerPortrait: CGSize(width: 626, height: 890)
        case .tent: CGSize(width: 678, height: 466)
        }
    }

    var title: String {
        switch self {
        case .outerPortrait: "外直（闔起）"
        case .innerLandscape: "內橫（打開）"
        case .innerPortrait: "內直（打開直拿）"
        case .tent: "倒放（影片子畫面）"
        }
    }

    var menuTitle: String { "\(title)  \(Int(size.width))×\(Int(size.height))" }

    /// ⌘⌥Tab 的順序：外直 → 內橫 → 內直 → 倒放 → 外直。
    var next: GlobalDMForm {
        switch self {
        case .outerPortrait: .innerLandscape
        case .innerLandscape: .innerPortrait
        case .innerPortrait: .tent
        case .tent: .outerPortrait
        }
    }

    /// 內橫：左欄對話、右欄 Browser（沒有分頁時是另一個對象的對話）。
    var isDuo: Bool { self == .innerLandscape }

    /// 設定裡存的值換成形態：新值照原樣；舊的展開尺寸 iPhone Duo 打開＝內橫，其他（私訊框、ChatGPT 快捷視窗、iPhone Duo 闔起、認不得的）＝外直。
    static func stored(_ raw: String?) -> GlobalDMForm {
        guard let raw else { return .outerPortrait }
        if let form = GlobalDMForm(rawValue: raw) { return form }
        return raw == "iPhoneOpen" ? .innerLandscape : .outerPortrait
    }
}

// MARK: - 版面（純計算，好測）

enum GlobalDMDeskLayout {
    /// 框離螢幕可用範圍四邊至少留這麼多（同浮動框的內縮）。
    static let edge: CGFloat = GlobalDMLayout.floatingInset
    /// 桌面圓鈕的預設位置：主螢幕右下，內縮 24。
    static let bubbleInset: CGFloat = 24

    /// 比螢幕可用範圍大時等比縮到放得下；放得下就原尺寸。
    static func fitted(_ size: CGSize, in visible: CGRect) -> CGSize {
        let width = max(1, visible.width - edge * 2)
        let height = max(1, visible.height - edge * 2)
        let scale = min(1, width / size.width, height / size.height)
        guard scale < 1 else { return size }
        return CGSize(width: (size.width * scale).rounded(.down), height: (size.height * scale).rounded(.down))
    }

    /// W179 UI：框與圓鈕之間留這麼多，圓鈕留著當收合鈕、不被框蓋住。
    static let bubbleGap: CGFloat = 12

    /// 圓鈕旁的四邊（上方、左側、下方、右側）。
    enum BubbleSide: Int, CaseIterable, Sendable { case above, left, below, right }

    /// 圓鈕旁邊放框（螢幕座標）：在可用範圍內縮 8 裡，依序試上方（右緣對齊圓鈕）、左側（下緣對齊圓鈕）、下方、右側，
    /// 每一邊都先扣掉「圓鈕＋12」；原尺寸放得下就用第一個放得下的。都放不下就挑等比縮得最少的那一邊（往下取整）。
    /// 所以框永遠不蓋圓鈕、整個在那個螢幕的可用範圍裡。
    static func boxBeside(bubble: CGRect, wanted: CGSize, visible: CGRect) -> CGRect {
        boxBesideSide(bubble: bubble, wanted: wanted, visible: visible).box
    }

    /// 同 boxBeside，另外回傳用的是哪一邊；prefer＝那一邊放得下就先用它（W184 F／G1 修正核對 #6、#8：圓鈕模式縮放過的那一邊鎖著，不跳邊）。
    static func boxBesideSide(bubble: CGRect, wanted: CGSize, visible: CGRect, prefer: BubbleSide? = nil) -> (box: CGRect, side: BubbleSide) {
        let sides = BubbleSide.allCases.map { (side: $0, region: besideRegion($0, bubble: bubble, visible: visible)) }
        func fits(_ region: CGRect) -> Bool { wanted.width <= region.width && wanted.height <= region.height }
        if let prefer, let side = sides.first(where: { $0.side == prefer }), fits(side.region) {
            return (CGRect(origin: besideOrigin(prefer, size: wanted, region: side.region, bubble: bubble), size: wanted), prefer)
        }
        if let side = sides.first(where: { fits($0.region) }) {
            return (CGRect(origin: besideOrigin(side.side, size: wanted, region: side.region, bubble: bubble), size: wanted), side.side)
        }
        func scale(_ region: CGRect) -> CGFloat {
            guard wanted.width > 0, wanted.height > 0 else { return 0 }
            return max(0, min(1, region.width / wanted.width, region.height / wanted.height))
        }
        guard let best = sides.max(by: { scale($0.region) < scale($1.region) }) else {
            return (CGRect(origin: visible.insetBy(dx: 8, dy: 8).origin, size: wanted), .above)
        }
        let factor = scale(best.region)
        let size = CGSize(width: max(1, (wanted.width * factor).rounded(.down)),
                          height: max(1, (wanted.height * factor).rounded(.down)))
        return (CGRect(origin: besideOrigin(best.side, size: size, region: best.region, bubble: bubble), size: size), best.side)
    }

    /// 那一邊可以放框的範圍（可用範圍內縮 8、扣掉「圓鈕＋12」；圓鈕貼著螢幕邊時某一邊可能是 0）。
    static func besideRegion(_ side: BubbleSide, bubble: CGRect, visible: CGRect) -> CGRect {
        let inner = visible.insetBy(dx: 8, dy: 8)
        let gap = bubbleGap
        switch side {
        case .above:
            let above = max(0, inner.maxY - bubble.maxY - gap)
            return CGRect(x: inner.minX, y: inner.maxY - above, width: inner.width, height: above)
        case .left:
            return CGRect(x: inner.minX, y: inner.minY, width: max(0, bubble.minX - gap - inner.minX), height: inner.height)
        case .below:
            return CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: max(0, bubble.minY - gap - inner.minY))
        case .right:
            let right = max(0, inner.maxX - bubble.maxX - gap)
            return CGRect(x: inner.maxX - right, y: inner.minY, width: right, height: inner.height)
        }
    }

    /// 那一邊放一個 size 大小的框時的位置：上方、下方＝右緣對齊圓鈕；左側、右側＝下緣對齊圓鈕（都夾在範圍裡）。
    static func besideOrigin(_ side: BubbleSide, size: CGSize, region: CGRect, bubble: CGRect) -> CGPoint {
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { min(max(value, low), max(low, high)) }
        switch side {
        case .above: return CGPoint(x: clamp(bubble.maxX - size.width, region.minX, region.maxX - size.width), y: region.minY)
        case .left: return CGPoint(x: region.maxX - size.width, y: clamp(bubble.minY, region.minY, region.maxY - size.height))
        case .below: return CGPoint(x: clamp(bubble.maxX - size.width, region.minX, region.maxX - size.width), y: region.maxY - size.height)
        case .right: return CGPoint(x: region.minX, y: clamp(bubble.minY, region.minY, region.maxY - size.height))
        }
    }

    /// 主視窗的標題列高度（拖得動的那一條）。
    static let titleBarHeight: CGFloat = 28

    /// 恢復主視窗用：縮起前的位置與大小，標題列還有一段（至少 80pt 寬）在某個螢幕的可用範圍裡就原樣；
    /// 否則（外接螢幕拔掉、解析度變小）放到它還有一部分所在的螢幕、都不在就主螢幕，大小縮到放得下，整個夾進可用範圍。
    static func restorableFrame(saved: CGRect, visibleFrames: [CGRect], main: CGRect) -> CGRect {
        let titleBar = CGRect(x: saved.minX, y: saved.maxY - titleBarHeight, width: saved.width, height: titleBarHeight)
        let grab = min(80, saved.width)
        let reachable = visibleFrames.contains { visible in
            let hit = visible.intersection(titleBar)
            return !hit.isNull && hit.width >= grab && hit.height > 0
        }
        if reachable { return saved }
        func overlap(_ visible: CGRect) -> CGFloat {
            let hit = visible.intersection(saved)
            return hit.isNull ? 0 : hit.width * hit.height
        }
        let best = visibleFrames.max { overlap($0) < overlap($1) }
        let target = best.flatMap { overlap($0) > 0 ? $0 : nil } ?? main
        guard target.width > 0, target.height > 0 else { return saved }
        let size = CGSize(width: min(saved.width, target.width), height: min(saved.height, target.height))
        return CGRect(x: min(max(saved.minX, target.minX), target.maxX - size.width),
                      y: min(max(saved.minY, target.minY), target.maxY - size.height),
                      width: size.width, height: size.height)
    }

    static func defaultBubbleOrigin(visible: CGRect) -> CGPoint {
        CGPoint(x: visible.maxX - bubbleInset - GlobalDMLayout.buttonSize, y: visible.minY + bubbleInset)
    }

    /// 圓鈕放哪：沒拖過就主螢幕右下；存的位置不在任何螢幕上（例如外接螢幕拔掉）也回主螢幕右下；
    /// 在的話夾進那個螢幕的可用範圍，整顆看得到。
    static func placeBubble(saved: CGPoint?, visibleFrames: [CGRect], main: CGRect) -> CGPoint {
        guard let saved else { return defaultBubbleOrigin(visible: main) }
        let side = GlobalDMLayout.buttonSize
        let rect = CGRect(origin: saved, size: CGSize(width: side, height: side))
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let visible = visibleFrames.first(where: { $0.contains(center) })
                ?? visibleFrames.first(where: { $0.intersects(rect) }) else {
            return defaultBubbleOrigin(visible: main)
        }
        return CGPoint(x: min(max(saved.x, visible.minX), visible.maxX - side),
                       y: min(max(saved.y, visible.minY), visible.maxY - side))
    }
}

// MARK: - 使用者拖過、縮放過的框（W184 G1、G1b）

/// W184 G1b（使用者 09-29：「左下也可以調尺寸好了」「拖拽範圍跟體驗有很多問題」：拖的時候卡、跟不上滑鼠／範圍太小／不知道哪裡能抓／
/// 縮成桌面圓鈕時拖不動）：縮放的角——右上角拉＝左下角不動；左下角拉＝右上角不動（拖哪個角那個角就跟著滑鼠）。
enum GlobalDMResizeCorner: String, Equatable, Sendable {
    case topRight, bottomLeft
}

/// W184 G1：頂列空白處拖＝整個框移動；角拖＝整個框等比縮放。浮動框、停靠框、桌面圓鈕模式各記一份（純資料與純計算，好測）。
/// - offset：框右下角相對於參考範圍右下角的位移（螢幕座標：dx 往右為正、dy 往上為正；nil＝照預設的位置）。
///   參考範圍＝浮動框的螢幕 visibleFrame、停靠框的主視窗內容區、圓鈕模式的圓鈕（框跟著圓鈕走）。
/// - scale：等比縮放（四種形態共用；0.7–1.3，上限再受範圍大小限制；1＝預設）。字級不變：框變大＝多看到內容。
/// W184 G1b：範圍的唯一限制＝頂列至少 44pt 在範圍裡（拖得回來）；停靠框使用者自己放的可以蓋到輸入框（預設擺法照舊避開）。
struct GlobalDMBoxPlacement: Equatable, Sendable {
    static let minScale: CGFloat = 0.7
    static let maxScale: CGFloat = 1.3
    /// 頂列至少這麼多留在範圍裡（拖得回來）。
    static let grabbable: CGFloat = 44

    var offset: CGSize?
    var scale: CGFloat = 1

    static let standard = GlobalDMBoxPlacement()

    /// 沒拖過也沒縮放過（右鍵選單的「回到預設位置與大小」只在不是這樣時出現）。
    var isStandard: Bool { offset == nil && abs(scale - 1) < 0.001 }

    /// 照使用者的位置與大小擺框：預設的框（照形態、既有的擺法）→ 等比縮放（沒拖過：右下角照預設）→ 拖過就用記住的右下角 →
    /// 頂列至少 44pt 在範圍裡（W184 G1b：其他照使用者放的，不整個推回範圍裡）。比例上限受範圍大小限制（整個框放得進範圍，不縮字）。
    func box(standard base: CGRect, reference: CGRect, bounds area: CGRect) -> CGRect {
        guard !isStandard else { return base }   // 沒拖過、沒縮放過＝跟改之前一模一樣
        let size = Self.sized(base.size, factor: factor(standard: base, bounds: area))
        let corner = offset.map { CGPoint(x: reference.maxX + $0.width, y: reference.minY + $0.height) }
            ?? CGPoint(x: base.maxX, y: base.minY)
        return Self.keepGrabbable(CGRect(x: corner.x - size.width, y: corner.y, width: size.width, height: size.height), in: area)
    }

    /// 框實際用的比例：記住的比例（0.7–1.3），再受範圍大小限制（整個框放得進範圍）。
    func factor(standard base: CGRect, bounds: CGRect) -> CGFloat {
        guard !isStandard else { return 1 }
        let fit = min(bounds.width / max(1, base.width), bounds.height / max(1, base.height))
        let wanted = min(max(scale, 0.01), Self.maxScale)
        return min(wanted, max(fit, 0.01))
    }

    /// 預設大小 × 比例（整數點；比例 1＝原樣）。擺框、縮放共用，放開那一刻不差一個像素。
    static func sized(_ base: CGSize, factor: CGFloat) -> CGSize {
        abs(factor - 1) < 0.000_1 ? base : CGSize(width: (base.width * factor).rounded(), height: (base.height * factor).rounded())
    }

    /// 右下角相對於參考範圍右下角的位移。
    static func offset(of box: CGRect, reference: CGRect) -> CGSize {
        CGSize(width: box.maxX - reference.maxX, height: box.minY - reference.minY)
    }

    /// W184 G1b：唯一的範圍限制——頂列至少 44pt 在範圍裡、拖得回來：框的上緣不超過範圍上緣、頂列最上面 44pt 不低於範圍下緣、
    /// 左右至少 44pt 跟範圍重疊。其他（框的一部分在範圍外、蓋到輸入框）都照使用者放的。
    static func keepGrabbable(_ box: CGRect, in area: CGRect) -> CGRect {
        var box = box
        box.origin.y = min(box.minY, area.maxY - box.height)
        box.origin.y = max(box.minY, area.minY + grabbable - box.height)
        box.origin.x = min(box.minX, area.maxX - grabbable)
        box.origin.x = max(box.minX, area.minX + grabbable - box.width)
        return box
    }

    /// 頂列有沒有至少 44pt 在範圍裡（keepGrabbable 不用動它）。
    static func isGrabbable(_ box: CGRect, in area: CGRect) -> Bool {
        keepGrabbable(box, in: area) == box
    }

    /// W184 G1b：兩個角等比縮放。拖的那個角跟著滑鼠（滑鼠投影到對角線上：比例不變時離滑鼠最近的那一點），對角固定
    /// （右上角拉＝左下角不動；左下角拉＝右上角不動）。base＝比例 1 的大小；回傳這一格的框與要記住的比例。
    /// 比例的合法區間（legalScales）：0.7–1.3，上限再受「整個框放得進範圍」與「右上角拉時頂列不超過範圍上緣」限制；
    /// W184 G1b 第二輪（GPT-6 G1b 審查 #2：框部分在範圍外時再縮小，整個框跑出範圍、放開後固定的角被推走）：下限再加「縮完頂列照樣至少
    /// 44pt 在範圍裡」——縮放途中就夾在這個區間裡，放開時不用再推（固定的角一個點都不動）。
    /// startScale＝開始的框用的比例（沒給＝照寬度算）：夾完跟它差不到 1pt（例如剛好在範圍邊上還要縮）＝框原樣、比例原樣（不因為四捨五入多 1pt）。
    static func resized(_ start: CGRect, corner: GlobalDMResizeCorner, base: CGSize, by delta: CGSize,
                        area: CGRect, startScale: CGFloat? = nil) -> (box: CGRect, scale: CGFloat) {
        let width = max(1, base.width), height = max(1, base.height)
        let initial = startScale ?? start.width / width
        let fixed = corner == .topRight ? CGPoint(x: start.minX, y: start.minY) : CGPoint(x: start.maxX, y: start.maxY)
        let dragged = corner == .topRight ? CGPoint(x: start.maxX + delta.width, y: start.maxY + delta.height)
            : CGPoint(x: start.minX + delta.width, y: start.minY + delta.height)
        let sign: CGFloat = corner == .topRight ? 1 : -1
        let along = ((dragged.x - fixed.x) * sign * width + (dragged.y - fixed.y) * sign * height) / (width * width + height * height)
        let legal = legalScales(start, corner: corner, base: base, area: area)
        // 區間是空的（開始的框本身就不合規則，不該發生）＝不縮放，照開始的框。
        guard legal.lower <= legal.upper else { return (start, initial) }
        let scale = min(max(along, legal.lower), legal.upper)
        guard abs(scale - initial) * max(width, height) >= 1 else { return (start, initial) }
        return (box(fixed: fixed, corner: corner, size: sized(base, factor: scale)), scale)
    }

    /// 縮放時比例能到哪（固定的角不動）：
    /// - 上限：1.3、整個框放得進範圍、右上角拉時框的上緣不超過範圍上緣。
    /// - 下限：0.7；右上角拉（左下角固定）＝框的右緣至少在範圍左緣＋44、上緣至少在範圍下緣＋44；左下角拉（右上角固定）＝框的左緣至多在
    ///   範圍右緣−44（上緣、右緣是固定的角，縮放不動它們）。邊界上多留 0.5pt，四捨五入成整數點時照樣合規則。
    static func legalScales(_ start: CGRect, corner: GlobalDMResizeCorner, base: CGSize, area: CGRect) -> (lower: CGFloat, upper: CGFloat) {
        let width = max(1, base.width), height = max(1, base.height)
        var upper = min(maxScale, area.width / width, area.height / height)
        var lower = minScale
        if corner == .topRight {
            upper = min(upper, (area.maxY - start.minY - 0.5) / height)
            lower = max(lower, (area.minX + grabbable - start.minX + 0.5) / width, (area.minY + grabbable - start.minY + 0.5) / height)
        } else {
            lower = max(lower, (start.maxX - (area.maxX - grabbable) + 0.5) / width)
        }
        return (lower, max(0.01, upper))   // lower > upper＝空區間（開始的框本身不合規則）
    }

    /// 固定的角＋大小＝框（右上角拉：左下角固定；左下角拉：右上角固定）。
    private static func box(fixed: CGPoint, corner: GlobalDMResizeCorner, size: CGSize) -> CGRect {
        corner == .topRight ? CGRect(x: fixed.x, y: fixed.y, width: size.width, height: size.height)
            : CGRect(x: fixed.x - size.width, y: fixed.y - size.height, width: size.width, height: size.height)
    }

    /// W184 G1b：縮放中最大會長到哪（畫布要包住它）：比例到上限時的框。
    static func largest(_ start: CGRect, corner: GlobalDMResizeCorner, base: CGSize, area: CGRect) -> CGRect {
        resized(start, corner: corner, base: base, by: corner == .topRight ? CGSize(width: 10_000, height: 10_000)
                : CGSize(width: -10_000, height: -10_000), area: area).box
    }

    /// W184 G1b：桌面圓鈕模式放開時框蓋到圓鈕（含 12 的間隔）＝往最近的一邊讓開一點（不蓋就原樣），再照「頂列至少 44pt 在範圍裡」。
    /// W184 G1b 第二輪（GPT-6 G1b 審查 #4：讓開之後又被 44pt 的規則推回來，框跟圓鈕還疊著——圓鈕的層級比框高，疊到的那一塊點不到框）：
    /// 上、下、左、右四個讓開的方向各自先照範圍的規則夾好，拿掉夾完還疊著的，挑位移最短的；四個都不行再試斜的（上下＋左右），
    /// 還是不行＝預設的位置（開在圓鈕旁：fallback）。
    static func clearing(_ box: CGRect, bubble: CGRect, in area: CGRect, fallback: CGRect,
                         gap: CGFloat = GlobalDMDeskLayout.bubbleGap) -> CGRect {
        let zone = bubble.insetBy(dx: -gap, dy: -gap)
        func overlaps(_ rect: CGRect) -> Bool {
            let hit = rect.intersection(zone)
            return !hit.isNull && hit.width > 0.001 && hit.height > 0.001
        }
        let kept = keepGrabbable(box, in: area)
        guard overlaps(kept) else { return kept }
        let up = zone.maxY - box.minY, down = zone.minY - box.maxY, left = zone.minX - box.maxX, right = zone.maxX - box.minX
        let straight = [CGSize(width: 0, height: up), CGSize(width: 0, height: down), CGSize(width: left, height: 0), CGSize(width: right, height: 0)]
        let diagonal = [up, down].flatMap { dy in [left, right].map { dx in CGSize(width: dx, height: dy) } }
        for moves in [straight, diagonal] {
            let legal = moves.map { keepGrabbable(box.offsetBy(dx: $0.width, dy: $0.height), in: area) }.filter { !overlaps($0) }
            if let best = legal.min(by: { distance(box, $0) < distance(box, $1) }) { return best }
        }
        return keepGrabbable(fallback, in: area)
    }

    /// 兩個同樣大小的框的位移（左下角的距離）。
    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY)
    }
}

// MARK: - 形態、圓鈕位置、單按 ⌥⌘ 的設定

/// 私訊框的外觀設定：上次的形態、圓鈕拖到哪。對話內容一律不寫。
@MainActor
final class GlobalDMDeskSettings: ObservableObject {
    static let shared = GlobalDMDeskSettings()
    /// W184 AB：形態沿用 W179 E「展開尺寸」的鍵；舊值照 GlobalDMForm.stored 對應，改了才寫新值。
    nonisolated static let formKey = "tatwo2.globalDM.expandSize"
    nonisolated static let bubbleOriginKey = "tatwo2.globalDM.bubbleOrigin"
    nonisolated static let chordToggleKey = "tatwo2.globalDM.chordToggle"
    /// W184 G1：使用者拖過、縮放過的框（浮動、停靠各一份）：{"dx", "dy", "scale"}（dx、dy 沒有＝照預設的位置）。
    nonisolated static let floatingPlacementKey = "tatwo2.globalDM.placement.floating"
    nonisolated static let dockedPlacementKey = "tatwo2.globalDM.placement.docked"
    /// W184 G1b：縮成桌面圓鈕時的框另存一份（位置相對於圓鈕：框右下角減圓鈕右下角；比例自己一份）。
    nonisolated static let bubblePlacementKey = "tatwo2.globalDM.placement.bubble"

    /// 記住上次的形態；改了才寫。
    @Published var form: GlobalDMForm {
        didSet { if form != oldValue { defaults.set(form.rawValue, forKey: Self.formKey) } }
    }
    /// 圓鈕（44pt 本體）左下角的螢幕座標；nil＝還沒拖過。
    @Published private(set) var bubbleOrigin: CGPoint?
    /// W184 G1：浮動框、停靠框各自的位置與大小（沒拖過、沒縮放過＝standard）。
    @Published private(set) var floatingPlacement: GlobalDMBoxPlacement
    @Published private(set) var dockedPlacement: GlobalDMBoxPlacement
    /// W184 G1b：縮成桌面圓鈕時的框（沒拖過、沒縮放過＝standard：照舊開在圓鈕旁）。
    @Published private(set) var bubblePlacement: GlobalDMBoxPlacement
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.form = GlobalDMForm.stored(defaults.string(forKey: Self.formKey))
        if let pair = defaults.array(forKey: Self.bubbleOriginKey) as? [Double], pair.count == 2,
           pair.allSatisfy({ $0.isFinite }) {
            self.bubbleOrigin = CGPoint(x: pair[0], y: pair[1])
        } else {
            self.bubbleOrigin = nil
        }
        floatingPlacement = Self.loadPlacement(defaults, key: Self.floatingPlacementKey)
        dockedPlacement = Self.loadPlacement(defaults, key: Self.dockedPlacementKey)
        bubblePlacement = Self.loadPlacement(defaults, key: Self.bubblePlacementKey)
    }

    /// 這個框的位置與大小。
    func placement(_ surface: GlobalDMSurface) -> GlobalDMBoxPlacement {
        surface == .floating ? floatingPlacement : dockedPlacement
    }

    /// 放開才存（重開 App 還在）；standard＝拿掉記錄（回到預設位置與大小）。
    func savePlacement(_ placement: GlobalDMBoxPlacement, for surface: GlobalDMSurface) {
        let key = surface == .floating ? Self.floatingPlacementKey : Self.dockedPlacementKey
        if surface == .floating { floatingPlacement = placement } else { dockedPlacement = placement }
        store(placement, key: key)
    }

    /// W184 G1b：縮成桌面圓鈕時的框放開才存（另存一份）；standard＝回到「開在圓鈕旁」。
    func saveBubblePlacement(_ placement: GlobalDMBoxPlacement) {
        bubblePlacement = placement
        store(placement, key: Self.bubblePlacementKey)
    }

    private func store(_ placement: GlobalDMBoxPlacement, key: String) {
        guard !placement.isStandard else { return defaults.removeObject(forKey: key) }
        var stored: [String: Double] = ["scale": Double(placement.scale)]
        if let offset = placement.offset {
            stored["dx"] = Double(offset.width)
            stored["dy"] = Double(offset.height)
        }
        defaults.set(stored, forKey: key)
    }

    private static func loadPlacement(_ defaults: UserDefaults, key: String) -> GlobalDMBoxPlacement {
        guard let stored = defaults.dictionary(forKey: key) else { return .standard }
        var placement = GlobalDMBoxPlacement.standard
        if let scale = stored["scale"] as? Double, scale.isFinite {
            placement.scale = min(max(CGFloat(scale), GlobalDMBoxPlacement.minScale), GlobalDMBoxPlacement.maxScale)
        }
        if let dx = stored["dx"] as? Double, let dy = stored["dy"] as? Double, dx.isFinite, dy.isFinite {
            placement.offset = CGSize(width: dx, height: dy)
        }
        return placement
    }

    /// 拖完放開才存；重開 App 還在那裡。
    func saveBubbleOrigin(_ origin: CGPoint) {
        bubbleOrigin = origin
        defaults.set([Double(origin.x), Double(origin.y)], forKey: Self.bubbleOriginKey)
    }

    /// 「單按 ⌥⌘ 開關私訊框」（預設開）；⌥⌘ 監聽每次放開時讀一次，設定頁用 @AppStorage 寫同一個鍵。
    nonisolated static func chordToggleEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: chordToggleKey) as? Bool ?? true
    }
}

// MARK: - ⌥⌘＋自訂鍵

/// ⌥⌘＋一個鍵。依實體鍵位（ANSI keyCode）辨認，跟目前的輸入法無關（注音開著按 G 也是 G）。
/// 可以設的只有英文字母與數字；Esc、Space、↓、↑、Tab 只為了辨認擋鍵清單（Tab＝換形態的預設鍵；W184 F45 起換形態的鍵使用者可以改，見 GlobalDMFormKeyBook）。
struct GlobalDMDirectKey: Hashable, Sendable {
    let rawValue: String
    let keyCode: UInt16

    static let escape = GlobalDMDirectKey(label: "Esc", code: kVK_Escape)
    static let space = GlobalDMDirectKey(label: "Space", code: kVK_Space)
    static let down = GlobalDMDirectKey(label: "Down", code: kVK_DownArrow)
    static let up = GlobalDMDirectKey(label: "Up", code: kVK_UpArrow)
    static let tab = GlobalDMDirectKey(label: "Tab", code: kVK_Tab)

    private static let assignableCodes: [(String, Int)] = [
        ("A", kVK_ANSI_A), ("B", kVK_ANSI_B), ("C", kVK_ANSI_C), ("D", kVK_ANSI_D), ("E", kVK_ANSI_E),
        ("F", kVK_ANSI_F), ("G", kVK_ANSI_G), ("H", kVK_ANSI_H), ("I", kVK_ANSI_I), ("J", kVK_ANSI_J),
        ("K", kVK_ANSI_K), ("L", kVK_ANSI_L), ("M", kVK_ANSI_M), ("N", kVK_ANSI_N), ("O", kVK_ANSI_O),
        ("P", kVK_ANSI_P), ("Q", kVK_ANSI_Q), ("R", kVK_ANSI_R), ("S", kVK_ANSI_S), ("T", kVK_ANSI_T),
        ("U", kVK_ANSI_U), ("V", kVK_ANSI_V), ("W", kVK_ANSI_W), ("X", kVK_ANSI_X), ("Y", kVK_ANSI_Y),
        ("Z", kVK_ANSI_Z), ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
        ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8),
        ("9", kVK_ANSI_9),
    ]
    private static let assignable: [GlobalDMDirectKey] = assignableCodes.map { GlobalDMDirectKey(label: $0.0, code: $0.1) }
    private static let all: [GlobalDMDirectKey] = assignable + [escape, space, down, up, tab]

    private init(label name: String, code: Int) {
        rawValue = name
        keyCode = UInt16(code)
    }

    init?(rawValue: String) {
        guard let key = Self.all.first(where: { $0.rawValue == rawValue }) else { return nil }
        self = key
    }

    init?(keyCode: UInt16) {
        guard let key = Self.all.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = key
    }

    var isAssignable: Bool { Self.assignable.contains(self) }

    var label: String {
        switch rawValue {
        case "Down": "↓"
        case "Up": "↑"
        default: rawValue
        }
    }

    var display: String { "⌥⌘" + label }
}

enum GlobalDMDirectKeyVerdict: Equatable, Sendable {
    case ok
    case blocked(GlobalDMDirectKey, reason: String)
    case taken(GlobalDMDirectKey, by: GlobalDMTarget)
    case occupied(GlobalDMDirectKey)
    case unsupported

    /// 一句白話說明為什麼不行；`ok` 是 nil。
    func message(title: (GlobalDMTarget) -> String) -> String? {
        switch self {
        case .ok: nil
        case .blocked(_, let reason): reason + "，不能用。"
        case .taken(let key, let other): "\(key.display) 已經給「\(title(other))」用了；先到那一列清掉，或換一個鍵。"
        case .occupied(let key): "\(key.display) 被別的 App 佔用了，換一個鍵試試。"
        case .unsupported: "只能用英文字母或數字，換一個鍵試試。"
        }
    }
}

enum GlobalDMDirectKeyRules {
    /// 系統或 TATWO 已經在用的 ⌥⌘ 組合（spec R8，加上 TATWO 自己的 ⌥⌘B），和為什麼不行。
    /// 存著的對照讀進來時也照這張表過濾（`GlobalDMDirectKeyBook.load`），以前存過的 B 會被丟掉。
    static let blocked: [String: String] = [
        "Esc": "⌥⌘Esc 是系統的「強制結束 App」",
        "D": "⌥⌘D 是系統的「顯示或隱藏 Dock」",
        "H": "⌥⌘H 是「隱藏其他 App」",
        "M": "⌥⌘M 是「縮小這個 App 的所有視窗」",
        "W": "⌥⌘W 是「關閉這個 App 的所有視窗」",
        "Space": "⌥⌘Space 是「Finder 搜尋」",
        "I": "⌥⌘I 是「顯示檢閱器」",
        // TATWO 自己的 ⌥⌘ 快捷鍵：Carbon 熱鍵是全系統獨佔，設下去連 TATWO 在前景時也會被搶走。
        "B": "⌥⌘B 是 TATWO 的「在聊天旁開啟瀏覽器」",
        "Down": "⌥⌘↓ 已經用來「縮成私訊鈕」",
        "Up": "⌥⌘↑ 已經用來「恢復主視窗」",
        "T": "⌥⌘T 是私訊框 Browser 的「新分頁」",   // W184 G2c 第二輪（房 D）：設成直達鍵＝全系統熱鍵先拿走，私訊框的新分頁就按不到
        // W184 F45：換形態的鍵不在這張表：使用者可以改（預設 Tab），照目前的鍵動態擋（formKeyReason）。
    ]

    /// W184 F45：換形態的鍵（預設 ⌥⌘Tab）被直達鍵選到時的說明。
    static func formKeyReason(_ key: GlobalDMDirectKey) -> String { "\(key.display) 已經用來「換私訊框的形態」" }

    /// formKey＝目前換形態的鍵（預設讀這台存的；沒改過＝Tab）：直達鍵不能選到它（兩個方向都擋：換形態那一列見 GlobalDMFormKeyBook.verdict）。
    static func verdict(_ key: GlobalDMDirectKey, for target: GlobalDMTarget,
                        in map: [GlobalDMTarget: GlobalDMDirectKey],
                        formKey: GlobalDMDirectKey = GlobalDMFormKeyBook.current()) -> GlobalDMDirectKeyVerdict {
        if let reason = blocked[key.rawValue] { return .blocked(key, reason: reason) }
        if key == formKey { return .blocked(key, reason: formKeyReason(key)) }   // W184 F45
        guard key.isAssignable else { return .unsupported }
        if let other = map.first(where: { $0.value == key && $0.key != target })?.key { return .taken(key, by: other) }
        return .ok
    }
}

/// 直達鍵對照的存取（GlobalDMStore 用）：UserDefaults 裡一個「對象 id → 鍵名」的字典；沒改過就是預設（只有 ⌥⌘G＝ChatGPT）。
enum GlobalDMDirectKeyBook {
    static let storageKey = "tatwo2.globalDM.directKeys"

    static var initial: [GlobalDMTarget: GlobalDMDirectKey] {
        guard let chatGPTKey = GlobalDMDirectKey(rawValue: "G") else { return [:] }
        return [.chatGPT: chatGPTKey]
    }

    static func load(from defaults: UserDefaults) -> [GlobalDMTarget: GlobalDMDirectKey] {
        guard let raw = defaults.dictionary(forKey: storageKey) as? [String: String] else { return initial }
        var map: [GlobalDMTarget: GlobalDMDirectKey] = [:]
        for (targetValue, keyValue) in raw.sorted(by: { $0.key < $1.key }) {
            guard let target = GlobalDMTarget(storageValue: targetValue),
                  let key = GlobalDMDirectKey(rawValue: keyValue),
                  GlobalDMDirectKeyRules.verdict(key, for: target, in: map) == .ok else { continue }
            map[target] = key
        }
        return map
    }

    static func save(_ map: [GlobalDMTarget: GlobalDMDirectKey], to defaults: UserDefaults) {
        var raw: [String: String] = [:]
        for (target, key) in map { raw[target.storageValue] = key.rawValue }
        defaults.set(raw, forKey: storageKey)
    }
}

// MARK: - 縮成圓鈕的狀態機

/// 主視窗 ↔ 桌面圓鈕。只放記憶體：App 結束時在圓鈕狀態，下次開啟照常是主視窗。
struct GlobalDMDeskMachine: Equatable {
    enum Phase: Equatable {
        case window
        /// `saved`＝縮起前主視窗的位置與大小；縮起時沒有看得到的主視窗就是 nil（恢復時重開）。
        case collapsed(saved: CGRect?)
    }

    enum Restore: Equatable {
        case notCollapsed
        case frame(CGRect)
        case reopen
    }

    private(set) var phase: Phase = .window

    var isCollapsed: Bool { phase != .window }

    /// 私訊鈕總開關關著、或已經是圓鈕時不動。
    mutating func collapse(enabled: Bool, frame: CGRect?) -> Bool {
        guard enabled, phase == .window else { return false }
        phase = .collapsed(saved: frame)
        return true
    }

    /// ⌥⌘↑／選單／圓鈕選單，或主視窗被別的路徑叫出來（Dock、通知）：回到原本的位置與大小。
    mutating func restore() -> Restore {
        guard case .collapsed(let saved) = phase else { return .notCollapsed }
        phase = .window
        return saved.map(Restore.frame) ?? .reopen
    }
}

// MARK: - 直達鍵＝打開（不是開關）

/// 框已經看得到就只換對象並給鍵盤焦點；否則照 ⌥⌘ 的規則（B 房）：App 在前景且主視窗看得到開停靠框，
/// 其他情況（別的 App 在前景、主視窗藏著、縮成圓鈕）開浮動框——縮成圓鈕時浮動框在圓鈕旁。
enum GlobalDMOpenAction: Equatable {
    case ignore
    case focusFloating
    case focusDocked
    case openDocked
    case openFloating

    static func resolve(enabled: Bool, floatingOpen: Bool, dockedShowing: Bool,
                        appActive: Bool, mainWindowVisible: Bool) -> Self {
        guard enabled else { return .ignore }
        if floatingOpen { return .focusFloating }
        let docks = appActive && mainWindowVisible
        if docks, dockedShowing { return .focusDocked }
        return docks ? .openDocked : .openFloating
    }
}

// MARK: - 內橫的右欄

/// W184 AB：內橫兩欄怎麼分（純判斷，好測）：左欄永遠是目前對象的對話；右欄＝Browser（有分頁，或按了 Browser 圓鈕＝store.isBrowsing，
/// 包括 DMBrowser.reveal 開的授權頁、配對頁），否則＝另一個對象的對話（第二個 store）。頂列只有一條（跨兩欄）。
enum GlobalDMDuoLayout {
    enum Pane: Equatable { case conversation, browser, otherConversation }

    static func rightShowsBrowser(browsing: Bool, hasTabs: Bool) -> Bool { browsing || hasTabs }

    /// W184 G2c 第二輪（房 D；GPT-6 #1）：內橫的右欄現在是不是 Browser——畫面（GlobalDMDuoBox）與 ⌘⌥T（routeNewTab）共用這一條：
    /// Browser 圓鈕開過（isBrowsingBeside；單欄帶過來的 isBrowsing 也算）或還有分頁；拿不到第二個 store＝右欄只能是 Browser。
    static func rightColumnShowsBrowser(browsing: Bool, browsingBeside: Bool, hasTabs: Bool, hasSecondary: Bool) -> Bool {
        rightShowsBrowser(browsing: browsingBeside || browsing, hasTabs: hasTabs) || !hasSecondary
    }

    /// W184 G2c 第二輪（房 D；GPT-6 #1）：私訊框這一刻看不看得到 Browser（跟畫面同一個判斷）：倒放沒有；單欄＝Browser 那一頁開著
    /// （GlobalDMBox：isBrowsing）；內橫＝右欄（rightColumnShowsBrowser：選了左欄的對話對象、旗標清掉了，還有分頁就照樣是 Browser）。
    static func showsBrowser(form: GlobalDMForm, browsing: Bool, browsingBeside: Bool, hasTabs: Bool, hasSecondary: Bool) -> Bool {
        if form == .tent { return false }
        guard form.isDuo else { return browsing }
        return rightColumnShowsBrowser(browsing: browsing, browsingBeside: browsingBeside, hasTabs: hasTabs, hasSecondary: hasSecondary)
    }

    /// 每一欄放什麼：單欄的形態只有一欄（Browser 開著＝那一欄是 Browser）；內橫＝左欄對話、右欄照 rightShowsBrowser。
    static func panes(form: GlobalDMForm, browsing: Bool, hasTabs: Bool) -> [Pane] {
        guard form.isDuo else { return [browsing ? .browser : .conversation] }
        return [.conversation, rightShowsBrowser(browsing: browsing, hasTabs: hasTabs) ? .browser : .otherConversation]
    }

    /// 頂列幾條：倒放沒有頂列（整塊是倒放內容），其他形態一條（內橫也只有一條，跨兩欄）。
    static func topBarCount(form: GlobalDMForm) -> Int { form == .tent ? 0 : 1 }
}

// MARK: - 內橫的右欄（第二個 store）

/// 右半邊是另一個 GlobalDMStore：自己的對象、草稿、清單與 ChatGPT 對話；另存一個 suite（只記上次的對象），
/// 不動左半邊的設定，也不管直達鍵。W184 AB：它沒有自己的頂列，也不開 Browser（Browser 只有一份，在右欄）。
@MainActor
final class GlobalDMDuo {
    static let shared = GlobalDMDuo(refreshChatGPTToolCatalog: {
        ChatGPTSpaceModel.shared.refreshToolCatalog()
    })
    nonisolated static let suiteName = "ai.tatwo.tatwo2.globalDM.duo"

    private let defaults: UserDefaults?
    private let refreshChatGPTToolCatalog: @MainActor () -> Void
    private var created: GlobalDMStore?

    init(defaults: UserDefaults? = UserDefaults(suiteName: GlobalDMDuo.suiteName),
         refreshChatGPTToolCatalog: @escaping @MainActor () -> Void = {}) {
        self.defaults = defaults
        self.refreshChatGPTToolCatalog = refreshChatGPTToolCatalog
    }

    /// W184 G3：已經建立的右欄 store（沒建立＝nil，不會為了問一下就建一個；Esc 關右欄 ChatGPT 的面板、語音用）。
    var existing: GlobalDMStore? { created }

    /// W184 G2c 第二輪（房 D）：右欄拿不拿得到第二個 store（跟 secondary != nil 同一個答案，但不為了問一下就建一個；⌘⌥T 看右欄是不是 Browser 用）。
    var hasSecondary: Bool { created != nil || defaults != nil }

    /// 拿不到獨立的 suite 時是 nil，iPhone 打開就只顯示一欄。
    var secondary: GlobalDMStore? {
        if let created { return created }
        guard let defaults else { return nil }
        let store = GlobalDMStore(defaults: defaults,
                                  refreshChatGPTToolCatalog: refreshChatGPTToolCatalog,
                                  directKeys: false)
        created = store
        return store
    }

    /// 右半邊預設：上次的 session（最近有動靜、而且不是左邊那個）；沒有 session 就助理或 ChatGPT。
    static func defaultSecondary(primary: GlobalDMTarget, sessions: [UUID], chatGPTAvailable: Bool) -> GlobalDMTarget {
        if let id = sessions.first(where: { GlobalDMTarget.thread($0) != primary }) { return .thread(id) }
        if primary != .assistant { return .assistant }
        return chatGPTAvailable ? .chatGPT : .assistant
    }

    /// 兩欄顯示時：接上同一個 model、確認對象還在、沒選過或跟左邊一樣就換成預設；右半邊的 ChatGPT 使用中租約跟著開關。
    func sync(primary: GlobalDMStore, showing: Bool) {
        guard showing || created != nil, let second = secondary else { return }
        if second.isBrowsing { second.isBrowsing = false }   // W184 AB：右欄的 Browser 是左邊那個 store 的（只有一份）
        if showing {
            if let model = primary.model { second.attach(model) }
            second.validateTarget()
            let chosen = defaults?.string(forKey: GlobalDMStore.lastTargetKey) != nil
            if !chosen || second.target == primary.target {
                let pick = Self.defaultSecondary(primary: primary.target,
                                                 sessions: primary.recentSessions().map(\.id),
                                                 chatGPTAvailable: primary.chatGPTAvailable)
                if pick != second.target { second.select(pick) }
            }
        }
        if second.isFloatingOpen != showing { second.isFloatingOpen = showing }
    }
}
