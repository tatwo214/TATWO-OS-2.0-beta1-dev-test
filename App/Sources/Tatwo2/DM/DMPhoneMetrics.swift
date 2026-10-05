import CoreGraphics

// W184（使用者 09-29：「私訊鈕的ui完全垃圾 應該要參照手機app的規格去設計」；對照稿 https://claude.ai/artifact/RoVoQkiMN13LDhD9Hj2s2g ）：
// 私訊框的手機規格 token——字級、觸控、同心圓角、間距。私訊框的畫面一律從這裡取值，不在各處寫死數字。
// 顏色不在這裡：照 GlobalDMPalette 的規則用 App 的玻璃 token 與系統語意色；玻璃參數沿用既有 token，不自創。
enum DMPhone {
    /// 字級只用這四種（iOS 預設 Large）：內文 17、次要 15、說明 13、最小 11。
    enum TextSize {
        static let body: CGFloat = 17
        static let secondary: CGFloat = 15
        static let footnote: CGFloat = 13
        static let caption: CGFloat = 11
    }

    /// 可以按的東西至少 44×44（頁面圓鈕、上一頁、下一頁、分頁）。
    static let touch: CGFloat = 44
    /// 框裡的小圓鈕（＋附件、送出／停止）。
    static let smallControl: CGFloat = 36
    /// chip（記憶、模型、取消）的高度；圓角＝高度一半（膠囊）。
    static let chipHeight: CGFloat = 32

    /// 框的圓角（iPhone 螢幕弧度，W181 定案 52）。
    static let screenRadius: CGFloat = GlobalDMLayout.cornerRadius
    /// 貼著框邊的東西（輸入框、Browser 頁面框、操作列）離框邊的距離。
    static let edgeInset: CGFloat = GlobalDMLayout.composerInset
    /// 同心圓角：內＝外 − 間距（iPhone 的做法）。
    static func concentric(_ outer: CGFloat, inset: CGFloat) -> CGFloat { max(0, outer - inset) }
    /// 輸入框、Browser 操作列：52 − 12 = 40。
    static var barRadius: CGFloat { concentric(screenRadius, inset: edgeInset) }
    /// 框裡的內容卡（Browser 頁面框、浮卡、分頁卡、底部 sheet 的群組）。
    static let cardRadius: CGFloat = 28

    /// 內容左右留白：外螢幕 16、內螢幕（內橫、內直）20。
    static let margin: CGFloat = 16
    static let wideMargin: CGFloat = 20
    /// W184 AB：照形態挑左右留白：內橫（兩欄）20，其他 16（施工單「左右 16（內橫 20）」；同房 C 的 GlobalDMChatLayout.sideMargin(for:)，
    /// 內橫兩欄的角色＝20、單欄＝16，頂列與訊息區對齊）。
    static func sideMargin(for form: GlobalDMForm) -> CGFloat { form.isDuo ? wideMargin : margin }
    /// 頂列：上 14、下 10，中間是 44 的圓鈕列。
    static let headerTop: CGFloat = 14
    static let headerBottom: CGFloat = 10
    static var headerHeight: CGFloat { headerTop + touch + headerBottom }

    // MARK: W184 AB：框、頂列、內橫兩欄、形態轉換

    // W184 F3（使用者 09-29 17:10：「r角現在會變 導致輸入筐根外ｒ角不齊」）：框的圓角任何形態、任何大小（縮放 0.7–1.3）、轉場中都固定
    // screenRadius（52）；輸入框、操作列固定 barRadius（40，同心：內距 12）。內容不縮放、字級不變，圓角也不變（舊的 screenRadius(for:form:) 等比縮拿掉）。

    /// 頂列左上的圓鈕列（對照稿 A-Proto）：52×52 的裁切容器（外距 −4、內距 4）裝 44 的圓鈕、間距 8；
    /// 平常只露目前頁面那顆，滑鼠指到向右展開（三顆＝156 寬）。目前那顆 2pt 強調色外圈、其他 1pt 淡框。
    enum Strip {
        static let inset: CGFloat = 4
        static let spacing: CGFloat = 8
        static var collapsed: CGFloat { touch + inset * 2 }
        static func width(count: Int, open: Bool) -> CGFloat {
            guard open, count > 1 else { return collapsed }
            return inset * 2 + CGFloat(count) * touch + CGFloat(count - 1) * spacing
        }
        static let currentRing: CGFloat = 2
        static let otherRing: CGFloat = 1
        /// 展開、收回：260ms，同一條曲線（motionCurve）。
        static let duration: Double = 0.26
    }

    /// 內橫（對照稿 Open-Landscape-*）：左欄約 400（890 寬時；縮小時等比）、中間 0.5 分隔線、線的上下各留 6／18。
    static let duoLeadingFraction: CGFloat = 400 / 890
    static let hairline: CGFloat = 0.5
    static let dividerTop: CGFloat = 6
    static let dividerBottom: CGFloat = 18

    /// 動作曲線 cubic-bezier(0.2, 0.8, 0.2, 1)（圓鈕列 260ms、Browser 操作列浮出用它）。
    static let motionCurve: (x1: Double, y1: Double, x2: Double, y2: Double) = (0.2, 0.8, 0.2, 1)

    /// W184 G2c（使用者 09-29 17:50：「瀏覽器右側目前用起來不好 改成跟browser space一樣滑鼠指到左列」）：私訊框裡的左側抽屜
    /// （Browser 的左列；ChatGPT 私訊的左側抽屜用同一種互動、同一組數字）：滑鼠指到左緣的把手帶才從左邊滑出、移開收回，
    /// 曲線用 motionCurve。CEF 會吃 hover，所以兩邊都照滑鼠位置判斷（DMBrowserBarReveal），不靠 SwiftUI 的 onHover。
    enum Drawer {
        /// 左緣的把手帶寬（滑鼠指到這一條才滑出）。
        static let handle: CGFloat = 22
        /// 滑出：從左 18 滑進來 220ms、透明度 180ms。
        static let slide: CGFloat = 18
        static let slideDuration: Double = 0.22
        static let fadeDuration: Double = 0.18
    }

    /// W184 F2（使用者 09-29：「變化特效我不喜歡…精煉絲滑」「我要滑開」「往右滑開可以 但倒不行」；對照稿第 2 版）：換形態全部用「滑」。
    /// 框的矩形用阻尼比 1 的彈簧（SwiftUI .smooth(duration: 0.42)：response 0.42、不回彈），0.6 秒算停（離新框 ≤1pt）；
    /// 換內容（任何形態↔倒放）先出後進：舊的 0–0.10 秒淡出、新的 0.10–0.32 秒淡入；進內橫分隔線在後 70% 淡入、出內橫在前 60% 淡出；
    /// 系統「減少動態效果」：整個框 0.12 秒淡出 → 換成新框 → 0.15 秒淡入，不滑。
    enum Slide {
        static let response: Double = 0.42
        static let settle: Double = 0.6
        static let fadeOut: Double = 0.10
        static let fadeIn: Double = 0.22
        static let dividerIn: Double = 0.3
        static let dividerOut: Double = 0.6
        static let reduceOut: Double = 0.12
        static let reduceIn: Double = 0.15
        /// W184 AB（使用者 09-30 .031：「動畫切換展開時 邊線會多幾條」）：內橫的右欄跟著分欄的進度出現——進度 0→0.35 從透明到全出
        ///（出內橫反過來：最後 35% 淡掉）。剛開始分欄時右欄只露出貼右緣的一小條（它的輸入框右端＝跟外框同心的第二條弧線），不再整條實心出現。
        static let rightIn: Double = 0.35
    }
}
