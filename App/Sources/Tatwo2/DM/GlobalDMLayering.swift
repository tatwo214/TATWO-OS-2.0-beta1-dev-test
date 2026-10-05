import AppKit
import Combine
import SwiftUI

// W179 UI：私訊框的圖層與版面規則。
// - 主視窗有東西整頁蓋上來（設定、搜尋、筆記、模型／協作面板、資訊卡、燈箱、sheet、App 層級確認框）時，停靠圓鈕與停靠框先收起。
//   例外：工具核准的確認框不收——私訊框的「等你核准」列就在那時出現。
// - 停靠框不蓋主視窗的輸入框：框的下緣在輸入框上緣之上，右緣對齊圓鈕；視窗太矮先縮框，再考慮重疊。
// - 框裡的選單只在標題列以下、輸入列以上。W184 AB：框級圖示鈕（✕、尺寸）拿掉，頂列在 GlobalDMPhoneBox；W184 F：右上 ⋯、⌄ 也拿掉（選單在左上圓鈕的右鍵）。
// 純計算的部分都在這裡，`TATWO2_SELFTEST=w179ui` 驗。

// MARK: - 版面診斷紀錄

/// 平常不記。要查停靠框擺位時：`defaults write ai.tatwo.tatwo2 tatwo.dm.layoutLog -bool YES`，
/// 重開 App 後看 `~/Library/Application Support/tatwo2/logs/dm-layout.log`；查完 `defaults delete` 並刪檔。
/// 寫檔不寫系統紀錄：系統紀錄會把 NSLog 的內容遮成 <private>。
enum GlobalDMLayoutLog {
    static func note(_ message: @autoclosure () -> String) {
        guard UserDefaults.standard.bool(forKey: "tatwo.dm.layoutLog") else { return }
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = base.appendingPathComponent("tatwo2/logs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("dm-layout.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message())\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

// MARK: - 用 AppKit 量主視窗輸入框

/// Coder 與 TATWO 的輸入框都是 `ChatComposerTextView`（AppKit 文字區）。擺停靠框當下直接在主視窗裡找它、
/// 用 AppKit 換成螢幕座標：不受 SwiftUI 啟動時序影響（v2.0.21.005／.006 實機：剛啟動時回報的位置是舊的，框蓋上輸入框）。
@MainActor
enum GlobalDMComposerProbe {
    /// 文字區上緣到輸入框卡片上緣的內距（ChatPage+Composer 的 `.padding(.top, 15)`）。
    static let cardTopPadding: CGFloat = 15
    /// 卡片左右比文字區多出的寬度（文字區左右各 20 內距）。
    static let cardSidePadding: CGFloat = 20

    /// 主視窗裡看得到、最靠下的那個輸入文字區，換成「輸入框佔用的範圍」：上緣＝文字區上緣＋內距，
    /// 下緣＝內容區底部（卡片、工具列、狀態抽屜都在文字區下面）。找不到回 nil。
    static func card(in window: NSWindow, content: NSRect, limit: Int = 6000) -> NSRect? {
        guard let root = window.contentView else { return nil }
        var best: NSRect?
        var stack: [NSView] = [root]
        var visited = 0
        while let view = stack.popLast(), visited < limit {
            visited += 1
            if view is ChatComposerTextView.ComposerNSTextView {
                guard !view.isHiddenOrHasHiddenAncestor else { continue }
                let host: NSView = view.enclosingScrollView ?? view
                let rect = window.convertToScreen(host.convert(host.bounds, to: nil))
                if rect.width > 40, rect.height > 4, best.map({ rect.minY < $0.minY }) ?? true { best = rect }
                continue
            }
            stack.append(contentsOf: view.subviews)
        }
        guard let text = best else { return nil }
        let top = text.maxY + cardTopPadding
        return NSRect(x: text.minX - cardSidePadding, y: content.minY,
                      width: text.width + cardSidePadding * 2, height: max(1, top - content.minY))
    }
}

// MARK: - 主視窗的蓋層

/// 主視窗這一刻有沒有東西整頁蓋上來。
struct GlobalDMMainCover: Equatable {
    /// SwiftUI 回報的蓋層（設定、搜尋、筆記、面板、燈箱…），一個 id 一種。
    var overlays: Set<String> = []
    /// 主視窗正掛著（或正要掛上）sheet。
    var sheet = false
    /// App 層級的確認框（runModal）開著。
    var appModal = false
    /// 有工具在等核准：這時的 App 層級確認框就是核准框，不算蓋層。私訊框的「等你核准」列只在這段時間出現
    /// （面板 worksWhenModal 才點得到），而且系統確認框本來就在 modalPanel 層、比停靠面板高，收起面板不改善圖層。
    var approvalPending = false

    var isCovered: Bool { !overlays.isEmpty || sheet || (appModal && !approvalPending) }
}

/// 各畫面回報「我現在蓋著主視窗」的地方；控制器訂閱它決定停靠面板要不要收起。只放記憶體。
@MainActor
final class GlobalDMCoverRegistry: ObservableObject {
    static let shared = GlobalDMCoverRegistry()

    @Published private(set) var overlays: Set<String> = []
    /// 每個 id 目前是哪幾份畫面在蓋：同一個畫面換新（啟動、重建）時，新那份先登記、舊那份後消失，
    /// 舊那份只拿掉自己，不會把新那份的蓋層清掉。
    private var holders: [String: Set<UUID>] = [:]
    /// 自測與沒有分身的呼叫端用的固定持有者。
    nonisolated static let anonymous = UUID(uuidString: "00000000-0000-0000-0000-000000000179")!

    init() {}

    /// 值沒變就不寫，免得每次重畫都通知控制器。
    func set(_ id: String, active: Bool, owner: UUID = GlobalDMCoverRegistry.anonymous) {
        var owners = holders[id] ?? []
        if active { owners.insert(owner) } else { owners.remove(owner) }
        holders[id] = owners.isEmpty ? nil : owners
        let covered = !owners.isEmpty
        if covered, !overlays.contains(id) { overlays.insert(id) }
        if !covered, overlays.contains(id) { overlays.remove(id) }
    }
}

private struct GlobalDMCoverReporter: ViewModifier {
    let active: Bool
    let id: String
    /// 這一個畫面自己登記過沒有：選單列面板那份 ChatPage（永遠 false）不會把主視窗登記的同一個 id 清掉。
    @State private var reported = false
    /// 這一份畫面的持有者編號：只清自己登記的那一筆。
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: active, initial: true) { _, now in report(now) }
            .onDisappear { report(false) }
    }

    private func report(_ now: Bool) {
        guard now != reported else { return }
        reported = now
        GlobalDMCoverRegistry.shared.set(id, active: now, owner: owner)
    }
}

extension View {
    /// 只回報，不改畫面：`active` 為 true 時私訊圓鈕與停靠框先收起。
    func globalDMCovers(_ active: Bool, id: String) -> some View {
        modifier(GlobalDMCoverReporter(active: active, id: id))
    }
}

/// ChatGPT 的圖片燈箱開著時回報蓋層。放在燈箱旁邊，不讓控制器一開機就去碰 ChatGPT 的模型。
struct GlobalDMLightboxCover: View {
    @ObservedObject var model: ChatGPTSpaceModel

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .globalDMCovers(model.zoomedImage != nil, id: "lightbox")
    }
}

// MARK: - 主視窗輸入框的位置

/// 哪一個輸入框：Coder（聊天、自訂 Space）、TATWO 助理頁或 ChatGPT Space。
enum GlobalDMComposerSource: Hashable {
    case coder, tatwo, chatgpt

    /// 這個模式畫的是哪一個輸入框；CLI、Bot、Browser 沒有（照舊用估算）。
    static func forMode(_ mode: ChatRunMode?) -> Self? {
        switch mode {
        case .tatwo?: return .tatwo
        case .chatgpt?: return .chatgpt
        case .cli?, .bot?, .browser?, nil: return nil
        case .chat?, .custom?: return .coder
        }
    }
}

/// 輸入框回報自己在視窗裡的位置（SwiftUI 的 global 座標）；控制器換成螢幕座標擺停靠框。
@MainActor
final class GlobalDMComposerFrames: ObservableObject {
    static let shared = GlobalDMComposerFrames()

    @Published private(set) var frames: [GlobalDMComposerSource: CGRect] = [:]
    /// 每個來源目前的位置是哪一份畫面回報的。App 剛啟動時同一個輸入框會先建一份、再換成新的一份：
    /// 新那份先回報、舊那份消失時才清——只准清自己回報的，不然停靠框會拿不到輸入框位置而蓋上去。
    private var owners: [GlobalDMComposerSource: UUID] = [:]

    init() {}

    /// 寬或高不到 1pt 當作沒有；值沒變不寫。清除（nil）只在位置是同一個持有者回報的時候才生效。
    func report(_ source: GlobalDMComposerSource, _ rect: CGRect?, owner: UUID = GlobalDMCoverRegistry.anonymous) {
        let value = rect.flatMap { $0.width > 1 && $0.height > 1 ? $0 : nil }
        GlobalDMLayoutLog.note("composer report \(source) rect=\(String(describing: value)) owner=\(owner.uuidString.prefix(8)) holder=\(owners[source].map { String($0.uuidString.prefix(8)) } ?? "-")")
        if value == nil {
            guard owners[source] == nil || owners[source] == owner else { return }
            owners[source] = nil
        } else {
            owners[source] = owner
        }
        if frames[source] != value { frames[source] = value }
    }

    /// SwiftUI global 座標（左上原點）→ 承載視圖的座標：承載視圖是 flipped 就原樣，否則 y 翻過來。
    nonisolated static func windowRect(global: CGRect, hostHeight: CGFloat, hostIsFlipped: Bool) -> CGRect {
        if hostIsFlipped { return global }
        return CGRect(x: global.minX, y: hostHeight - global.maxY, width: global.width, height: global.height)
    }
}

private struct GlobalDMComposerFrameReporter: ViewModifier {
    let source: GlobalDMComposerSource
    let active: Bool
    @State private var last: CGRect?
    /// 這一個畫面自己回報過位置沒有：選單列面板那份（active 永遠 false）不會把主視窗回報的位置清掉。
    @State private var reported = false
    /// 這一份畫面的持有者編號：消失時只清自己回報的位置。
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                last = rect
                report(active ? rect : nil)
            }
            .onChange(of: active) { _, now in report(now ? last : nil) }
            .onAppear { if active, let last { report(last) } }
            .onDisappear { report(nil) }
    }

    private func report(_ rect: CGRect?) {
        guard rect != nil || reported else { return }
        reported = rect != nil
        GlobalDMComposerFrames.shared.report(source, rect, owner: owner)
    }
}

extension View {
    /// 只讀位置，不改排版、外觀或點擊：停靠私訊框據此放在輸入框上方。
    func globalDMComposerFrame(_ source: GlobalDMComposerSource, active: Bool = true) -> some View {
        modifier(GlobalDMComposerFrameReporter(source: source, active: active))
    }
}

// MARK: - 停靠面板的狀態機

/// 主視窗裡的停靠圓鈕與停靠框：看不到（總開關關、主視窗藏著）、被蓋住（先收起）、顯示（框開或關）。
enum GlobalDMDockedPresence: Equatable {
    case hidden
    case covered
    case shown(boxOpen: Bool)

    static func resolve(enabled: Bool, mainWindowVisible: Bool, covered: Bool, boxOpen: Bool) -> Self {
        guard enabled, mainWindowVisible else { return .hidden }
        if covered { return .covered }
        return .shown(boxOpen: boxOpen)
    }

    /// 只有「圓鈕在、框剛打開」拿鍵盤焦點；蓋層拿掉後回來、主視窗回來都不搶焦點。
    static func takesFocus(from old: Self, to new: Self) -> Bool {
        old == .shown(boxOpen: false) && new == .shown(boxOpen: true)
    }
}

// MARK: - 停靠框擺哪

/// 圓鈕右 12、下 8；碰到輸入框就抬到輸入框上方。框右緣對齊圓鈕、下緣在圓鈕與輸入框之上；
/// 空間不夠先縮到 280 高、貼著上緣，這時才允許蓋到輸入框。座標是螢幕座標（左下原點）。
enum GlobalDMDockLayout {
    /// 框離輸入框上緣至少這麼多。
    static let composerGap: CGFloat = 12
    /// 框頂離內容區頂端至少這麼多（紅綠燈那一條＋8）。
    static let topClearance: CGFloat = WindowChromeMetrics.bandHeight + 8

    struct Placement: Equatable {
        var button: CGRect
        var box: CGRect?
        var overlapsComposer: Bool
    }

    static func place(content: CGRect, composer: CGRect?, mode: ChatRunMode?, boxOpen: Bool,
                      boxSize: CGSize = GlobalDMLayout.box) -> Placement {
        let side = GlobalDMLayout.buttonSize
        let x = content.maxX - GlobalDMLayout.trailing - side
        var y = content.minY + GlobalDMLayout.bottom
        if let composer {
            let resting = CGRect(x: x, y: y, width: side, height: side)
            if overlaps(resting, composer.insetBy(dx: -8, dy: -8)) { y = composer.maxY + 8 }
        } else {
            y = content.minY + GlobalDMLayout.bottomInset(contentWidth: content.width, mode: mode)
        }
        let button = CGRect(x: x, y: y, width: side, height: side)
        guard boxOpen else { return Placement(button: button, box: nil, overlapsComposer: false) }

        let maxWidth = max(1, min(boxSize.width, content.width - 24))
        // W181：框矮下來時寬度跟著等比縮（保持 iPhone Duo 的比例），但不窄過 minimumDockedBoxWidth。
        func width(forHeight height: CGFloat) -> CGFloat {
            let scaled = (boxSize.width * min(1, height / max(1, boxSize.height))).rounded()
            return min(maxWidth, max(min(boxSize.width, GlobalDMLayout.minimumDockedBoxWidth), scaled))
        }
        // W184 AB：寬度放不下（例如內橫 890 寬、窄視窗）時高度也跟著等比縮，形態的比例不變。
        let tallest = boxSize.width > maxWidth ? max(1, (boxSize.height * maxWidth / boxSize.width).rounded(.down)) : boxSize.height
        var floor = button.maxY + GlobalDMLayout.gap
        // 輸入框位置還沒回報（例如 App 剛啟動）時用估計值擺框，寧可高一點也不蓋到輸入框；圓鈕仍照上面的規則。
        // 用最寬的框判斷會不會壓到輸入框（縮窄的框只會更靠右，不會多壓到）。
        if let floorComposer = composer ?? estimatedComposer(content: content, mode: mode),
           floorComposer.minX < button.maxX, floorComposer.maxX > button.maxX - maxWidth {
            floor = max(floor, floorComposer.maxY + composerGap)
        }
        let ceiling = content.maxY - topClearance
        let minimum = min(GlobalDMLayout.minimumDockedBoxHeight, tallest)
        if ceiling - floor >= minimum {
            let height = min(tallest, ceiling - floor)
            let width = width(forHeight: height)
            let box = CGRect(x: button.maxX - width, y: floor, width: width, height: height)
            return Placement(button: button, box: box, overlapsComposer: false)
        }
        let height = max(1, min(minimum, ceiling - (button.maxY + GlobalDMLayout.gap)))
        let boxWidth = width(forHeight: height)
        let box = CGRect(x: button.maxX - boxWidth, y: ceiling - height, width: boxWidth, height: height)
        return Placement(button: button, box: box, overlapsComposer: composer.map { overlaps(box, $0) } ?? false)
    }

    /// W184 G1：停靠框能拖的範圍：主視窗內容區左右各留 12、上面不蓋紅綠燈那一條、下面不低於預設框的下緣
    /// （不蓋輸入框與圓鈕的規則照舊）。standard＝place(...) 算出的預設框。
    static func dragBounds(standard: CGRect, content: CGRect) -> CGRect {
        let top = content.maxY - topClearance
        let bottom = min(standard.minY, top - 1)
        return CGRect(x: content.minX + GlobalDMLayout.trailing, y: bottom,
                      width: max(1, content.width - GlobalDMLayout.trailing * 2), height: max(1, top - bottom))
    }

    /// W184 G1（GPT-6 審查 #2）：輸入框（上緣再加 composerGap）那一塊：拖過、縮放過的停靠框不准壓到它。
    static func composerZone(_ composer: CGRect) -> CGRect {
        CGRect(x: composer.minX, y: composer.minY, width: composer.width, height: composer.height + composerGap)
    }

    /// W184 G1（GPT-6 審查 #2）：拖過、縮放過的停靠框用「實際的框」再檢查一次輸入框（量不到就用估計值；dragBounds 只保證不低於預設框的下緣，
    /// 預設框不在輸入框上方時橫拖過去還是會壓到）：相交就往上推到輸入框上緣＋composerGap。修正核對 #1、#2：照 place 的規則——
    /// 框太高、推上去會超過 ceiling＝先等比縮小到放得下（右緣不動、下緣在輸入框上緣＋12）；連 minimum（280）都放不下才縮到 minimum、
    /// 貼著 ceiling（這時才允許蓋到輸入框）。不相交＝原樣。
    static func avoidComposer(_ box: CGRect, composer: CGRect?, ceiling: CGFloat,
                              minimum: CGFloat = GlobalDMLayout.minimumDockedBoxHeight) -> CGRect {
        guard let composer else { return box }
        let zone = composerZone(composer)
        guard overlaps(box, zone) else { return box }
        let room = ceiling - zone.maxY
        if box.height <= room { return CGRect(x: box.minX, y: zone.maxY, width: box.width, height: box.height) }
        func shrunk(to height: CGFloat) -> CGSize {
            guard height < box.height else { return box.size }
            return CGSize(width: max(1, (box.width * height / max(1, box.height)).rounded()), height: max(1, height))
        }
        let least = min(minimum, box.height)
        if room >= least {
            let size = shrunk(to: (room + 0.001).rounded(.down))
            return CGRect(x: box.maxX - size.width, y: zone.maxY, width: size.width, height: size.height)
        }
        let size = shrunk(to: least)
        return CGRect(x: box.maxX - size.width, y: ceiling - size.height, width: size.width, height: size.height)
    }

    /// 輸入框佔主視窗底部多高的估計（Coder／TATWO 在 v2.0.21.004 實測約 145pt：卡片＋下方狀態抽屜＋外距）。
    static let estimatedComposerHeight: CGFloat = 150

    /// 這個模式有輸入框、但位置還沒回報時的估計範圍：內容區底部整條。沒有輸入框的模式回 nil。
    static func estimatedComposer(content: CGRect, mode: ChatRunMode?) -> CGRect? {
        guard GlobalDMComposerSource.forMode(mode) != nil else { return nil }
        return CGRect(x: content.minX, y: content.minY, width: content.width, height: estimatedComposerHeight)
    }

    /// 真的重疊（只碰到邊不算）。
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let hit = a.intersection(b)
        return !hit.isNull && hit.width > 0.001 && hit.height > 0.001
    }
}

// MARK: - 框裡選單的範圍

/// 對象選單、session 搜尋、直達鍵頁只在「標題列以下、輸入列以上」；超出就在選單裡捲動。
/// 範圍怎麼來：選單疊在 `GlobalDMBodyRegion` 上（框裡標題列與輸入列之間那一塊，實際量到的大小），
/// 位置用 `pickerFrame` 從那一塊內縮；輸入列長高或提示列多一顆鈕時，那一塊自己變矮，選單跟著變矮。
enum GlobalDMMenuLayout {
    static let side: CGFloat = 8
    static let top: CGFloat = 2
    static let bottom: CGFloat = 8

    /// 選單在內容區裡的位置（內容區自己的座標，左上原點）。
    static func pickerFrame(bodySize: CGSize) -> CGRect {
        CGRect(x: side, y: top, width: max(0, bodySize.width - side * 2), height: max(0, bodySize.height - top - bottom))
    }
}
