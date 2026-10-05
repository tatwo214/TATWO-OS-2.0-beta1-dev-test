import AppKit
import QuartzCore
import SwiftUI

// W184 AB（R2；GPT-6 審 G3c 第 4 條）：換形態時守住使用者在讀的那一則。
// 列表頂天以後（G3c：捲動區延伸到框的上緣、在頂列底下捲），使用者真正在讀的是「頂列底下看得到的第一則」，不是藏在頂列、
// 漸淡底下只露一截的那一則。換欄寬時 AppKit／SwiftUI 留住的是捲動區裡最上面那一列（常是頂列底下只露一截的那一則），
// 它重新換行長高就把下面整片往下推；懶載入的列重估高度也會讓位置跑掉。這裡記下每一則的位置，面板控制器換形態時
// （GlobalDMPanelCanvas.readingRows／settleLists）找出在讀的那一則，排版之後把它捲回原來的位置。

/// 一個訊息列表裡每一則目前的位置（捲動區座標：0＝捲動區的上緣＝框的上緣；頂列蓋住 0..<covered）。
/// 每一則的遮罩（GlobalDMEdgeFade）量位置時順手記下；捲出懶載入範圍的（onDisappear）拿掉。
@MainActor final class GlobalDMListRows {
    struct Row: Equatable {
        var top: CGFloat
        var bottom: CGFloat
        /// 第一行字離這一則上緣多遠（我說的泡泡＝泡泡的上內距；其他＝0）。
        var lead: CGFloat
        /// 量的那一刻內容捲開多少（這一則在內容裡的上緣 − 在捲動區裡的上緣）。跟最後量到的不一樣＝之後捲過、它沒再量
        /// （捲出去不畫的列遮罩不重算，也不一定收得到 onDisappear），位置是舊的。
        var offset: CGFloat
        /// 這一輪（beginPass 之後）有沒有重新量過。
        var fresh: Bool
    }

    /// 換形態前記下的：在讀的那一則與它的上緣，還有那時每一則的上緣（在讀的那一則這次沒量到時，用離它最近的一則估）。
    struct Snapshot: Equatable {
        let id: String
        let top: CGFloat
        let tops: [String: CGFloat]
    }

    /// 字的第一行最多這麼多在頂列下緣底下還算「看得到」：行框頂端到字形頂端約 3pt（字形本身整個露在頂列下面）。
    static let lineSlack: CGFloat = 3

    private(set) var rows: [String: Row] = [:]
    /// 頂列（內橫右欄的 ChatGPT 再加它自己那一排）蓋住的高度＝列表往上延伸的那一段。
    private(set) var covered: CGFloat = 0
    /// 捲動區看得到的高度。
    private(set) var viewport: CGFloat = 0
    /// 最後一次量的時候內容捲開多少（同一次畫面更新量的每一則都一樣）。
    private(set) var latestOffset: CGFloat = 0

    /// frame＝這一則在捲動區裡（GlobalDMMessageList.space）；content＝在跟著內容捲的座標裡（GlobalDMMessageList.contentSpace）。
    func record(_ id: String, frame: CGRect, content: CGRect, lead: CGFloat, covered: CGFloat, viewport: CGFloat) {
        #if DEBUG
        if Self.laidOutForSelfTest[id] == nil { Self.laidOutForSelfTest[id] = CACurrentMediaTime() }
        #endif
        let offset = content.minY - frame.minY
        rows[id] = Row(top: frame.minY, bottom: frame.maxY, lead: lead, offset: offset, fresh: true)
        latestOffset = offset
        self.covered = covered
        self.viewport = viewport
    }

    /// 現在畫面上的那幾則：跟最後量到的同一個捲動位置量的（捲過以後沒再量的不算：位置是舊的）。
    var current: [String: Row] {
        rows.filter { abs($0.value.offset - latestOffset) <= 0.5 }
    }

    func forget(_ id: String) {
        rows[id] = nil
    }

    /// 從這裡起重新看哪幾則量過（捲動、換大小之後，只信這之後量到的位置）。
    func beginPass() {
        rows = rows.mapValues { row in
            var row = row
            row.fresh = false
            return row
        }
    }

    /// 使用者在讀的那一則：頂列底下看得到的第一則——第一行字在頂列下緣以下（最多 lineSlack 在頂列底下）、在捲動區裡，最上面那一則；
    /// 沒有（一則長的從頂列底下一直佔到下面）＝跨過頂列下緣的那一則。都沒有＝nil。純計算（好測）。
    static func reading(_ rows: [String: Row], covered: CGFloat, viewport: CGFloat) -> (id: String, top: CGFloat)? {
        let shown = rows.filter { $0.value.bottom > covered && $0.value.top < viewport }
        if let first = shown.filter({ $0.value.top + $0.value.lead >= covered - lineSlack }).min(by: { $0.value.top < $1.value.top }) {
            return (first.key, first.value.top)
        }
        if let spanning = shown.max(by: { $0.value.top < $1.value.top }) {
            return (spanning.key, spanning.value.top)
        }
        return nil
    }

    var reading: (id: String, top: CGFloat)? {
        Self.reading(current, covered: covered, viewport: viewport)
    }

    /// 換形態前：記下在讀的那一則與現在畫面上每一則的位置，從這裡起重新看哪幾則量過。沒有在讀的＝nil。
    func snapshot() -> Snapshot? {
        guard let reading else { return nil }
        let result = Snapshot(id: reading.id, top: reading.top, tops: current.mapValues(\.top))
        beginPass()
        return result
    }

    /// 排版之後在讀的那一則跑了多少（正＝往下）：它這一輪量過就用它自己；沒量到（懶載入的範圍外）＝用這一輪量過、之前也在、
    /// 離它最近的那一則估（捲回去以後下一輪就量得到它自己）。這一輪什麼都沒量到＝nil（位置沒變，或量不到就不動）。
    func drift(from snapshot: Snapshot) -> CGFloat? {
        let now = current.filter { $0.value.fresh }
        if let row = now[snapshot.id] { return row.top - snapshot.top }
        var best: (distance: CGFloat, drift: CGFloat)?
        for (id, row) in now {
            guard let before = snapshot.tops[id] else { continue }
            let distance = abs(before - snapshot.top)
            if best.map({ distance < $0.distance }) ?? true { best = (distance, row.top - before) }
        }
        return best?.drift
    }

    /// 捲動區裡的那一個列表（找 GlobalDMListRowsProbe 放進捲動區的那個 view）。
    static func of(_ scroll: NSScrollView) -> GlobalDMListRows? {
        var stack: [NSView] = [scroll]
        var visited = 0
        while let view = stack.popLast(), visited < 4000 {
            visited += 1
            if let probe = view as? GlobalDMListRowsProbeView, probe.enclosingScrollView === scroll { return probe.rows }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }
}

#if DEBUG
extension GlobalDMListRows {
    /// 自測看（W184 AB，H12）：每一則第一次進到列表（GlobalDMMessageList 拿到它）的時間。
    static var listedForSelfTest: [String: CFTimeInterval] = [:]
    /// 自測看（W184 AB，H12）：每一則第一次排出位置（遮罩量到它）的時間。
    static var laidOutForSelfTest: [String: CFTimeInterval] = [:]

    static func noteListed(_ bubbles: [GlobalDMBubble]) -> Bool {
        let now = CACurrentMediaTime()
        for bubble in bubbles where listedForSelfTest[bubble.id] == nil { listedForSelfTest[bubble.id] = now }
        return true
    }
}
#endif

/// 把列表的位置記錄掛在捲動區裡（看不見、點不到、不進輔助使用）：面板控制器從 AppKit 那一層找得到「這個捲動區的列表」。
struct GlobalDMListRowsProbe: NSViewRepresentable {
    let rows: GlobalDMListRows

    func makeNSView(context: Context) -> GlobalDMListRowsProbeView {
        let view = GlobalDMListRowsProbeView()
        view.rows = rows
        return view
    }

    func updateNSView(_ view: GlobalDMListRowsProbeView, context: Context) {
        view.rows = rows
    }
}

final class GlobalDMListRowsProbeView: NSView {
    var rows: GlobalDMListRows?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

private struct GlobalDMListRowsKey: EnvironmentKey {
    static let defaultValue: GlobalDMListRows? = nil
}

private struct GlobalDMRowLeadKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// W184 AB：這個列表的位置記錄（GlobalDMEdgeFade 量到位置時記下）；nil＝不記。
    var globalDMListRows: GlobalDMListRows? {
        get { self[GlobalDMListRowsKey.self] }
        set { self[GlobalDMListRowsKey.self] = newValue }
    }

    /// W184 AB：這一則的第一行字離它的上緣多遠（我說的泡泡＝泡泡的上內距）。
    var globalDMRowLead: CGFloat {
        get { self[GlobalDMRowLeadKey.self] }
        set { self[GlobalDMRowLeadKey.self] = newValue }
    }
}
