import AppKit
import SwiftUI

// W184 E（使用者 09-29：「倒放 預設作為影片子畫面」；spec E1–E3；spike 報告 rooms/w183-handoff/w184-e-spike-report.md）：
// Browser 工作區的分頁借給私訊框的倒放（影片子畫面）。
// - 只搬 TatwoCEFBrowserView 這一個 NSView（同 W118 全螢幕的搬法）：不清 container.browserView、不重建、不重新載入；
//   切分頁的函式（showSelectedTab）不動。
// - 只借使用者本人的 Browser 工作區分頁（BrowserTentPolicy.lendable；施工單第 5 條）。
// - 主機（TatwoCEFTabHostView）管借出與還回：借出前先退出全螢幕、清掉頁面裡的鍵盤焦點；借出中的分頁算進睡眠保護；
//   分頁要關、主視窗對它下指令、主視窗按「拿回來」、頁面要全螢幕＝主機先放回自己的容器，再告訴借用者（BrowserTabReturnReason）。
// - 借出中的頁面：⌘ 組合鍵不落到主選單（BrowserLentKeys）、瀏覽器快捷鍵與 Esc 不作用到主視窗、
//   全螢幕與檔案框只在自己的容器開（BrowserWebFeatures.canPresent）、AI 與 Computer Use 找頁面時跳過。
// - 倒放不持有 WindowCaptureShield（框裡是一般網頁，沒有敏感內容；敏感頁一律不借）。

/// 一個 Browser 工作區分頁現在的樣子（倒放挑分頁用；純資料，不帶頁面內容）。
struct BrowserLendableTab: Equatable, Sendable {
    /// 原生頁面現在的旗標（主機回報；原生頁面還沒建好＝nil）。
    struct Native: Equatable, Sendable {
        /// 使用者本人操作的頁面（browserActor == .human）。
        var isHuman = true
        /// AI 控制中。
        var agentControlled = false
        /// 敏感頁（只准 https、頁內新視窗疊在同一頁：私訊框的授權頁、配對頁、登入 popup）。
        var sensitivePage = false
        /// 受保護的呈現（只准 https 的常駐頁）。
        var httpsOnly = false
        /// ChatGPT 的 Pod。
        var isPod = false
        /// 正在主視窗呈現（畫面在自己的容器裡、容器沒藏、視窗排在畫面上而且沒縮到 Dock；被別的視窗蓋住也算——寧可不搶）。
        var isOnScreen = false
        /// 頁面世代（主框架每導一次頁就加一；重新整理、上一頁、網址列都算）：倒放「框再出現就收回來」的資格綁它。
        var navigationGeneration: UInt64 = 0
        /// 現在的網址（同一份文件裡換網址也看得到，例如單頁 App 換影片）：同上，只拿來比對、不存不送。
        var pageURL: String? = nil
    }

    let id: String
    /// 網域（倒放框上寫「<網域>・Browser 分頁」）；沒有網址＝nil。
    var host: String?
    var title: String
    var lastActiveAt: Date
    /// 正在播影片：這一次開始播的時間；沒在播＝nil。
    var videoStartedAt: Date?
    /// Browser 工作區選中的分頁（主視窗正顯示的；Browser 不在畫面上時是最後用的那個）。
    var isSelected: Bool
    /// Browser 工作區擁有的分頁（不是聊天 session、不是 bot）。
    var ownedByWorkSpace: Bool
    var isAgentTab: Bool
    var isSleeping: Bool
    /// 登記簿標的敏感分頁（OS 瀏覽器退路開的一次性授權頁）。
    var isSensitive: Bool
    var native: Native?

    init(id: String, host: String? = nil, title: String = "", lastActiveAt: Date = .distantPast, videoStartedAt: Date? = nil,
         isSelected: Bool = false, ownedByWorkSpace: Bool = true, isAgentTab: Bool = false, isSleeping: Bool = false,
         isSensitive: Bool = false, native: Native? = Native()) {
        self.id = id
        self.host = host
        self.title = title
        self.lastActiveAt = lastActiveAt
        self.videoStartedAt = videoStartedAt
        self.isSelected = isSelected
        self.ownedByWorkSpace = ownedByWorkSpace
        self.isAgentTab = isAgentTab
        self.isSleeping = isSleeping
        self.isSensitive = isSensitive
        self.native = native
    }

    /// 從登記簿的分頁組出來（Browser 工作區 runtime 用）：擁有者、AI 分頁、睡著照登記簿；原生旗標由主機給。
    init(tab: BrowserTab, isSensitive: Bool, videoStartedAt: Date?, isSelected: Bool, native: Native?) {
        let workSpace: Bool
        if case .workSpace = tab.owner { workSpace = true } else { workSpace = false }
        self.init(id: tab.id.uuidString, host: Self.displayHost(tab.url), title: tab.title, lastActiveAt: tab.lastActiveAt,
                  videoStartedAt: videoStartedAt, isSelected: isSelected, ownedByWorkSpace: workSpace,
                  isAgentTab: tab.isAgentTab == true || tab.usesAgentContext, isSleeping: tab.isSleeping,
                  isSensitive: isSensitive, native: native)
    }

    var isPlayingVideo: Bool { videoStartedAt != nil }
    var isOnScreen: Bool { native?.isOnScreen ?? false }

    /// 標籤上的網域：只取 http／https 的主機名稱、去掉 www.（不帶路徑、查詢字串）。
    static func displayHost(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}

enum BrowserTentPolicy {
    /// 施工單第 5 條：一律不借——
    /// - 私訊框 Browser 的授權頁、Pod（ChatGPT）、配對頁與登入 popup：不在 Browser 工作區的分頁清單（不是工作區擁有的），
    ///   原生旗標也是敏感頁／Pod；
    /// - AI 分頁、AI 控制中；
    /// - 敏感頁：登記簿標的授權分頁、敏感頁旗標、只准 https 的受保護頁；
    /// - 不是使用者本人操作的頁；
    /// - 睡著的分頁、原生頁面還沒建好的；
    /// - 聊天 session（與 bot）的分頁：不是 Browser 工作區擁有的。
    static func lendable(_ tab: BrowserLendableTab) -> Bool {
        guard tab.ownedByWorkSpace, !tab.isAgentTab, !tab.isSleeping, !tab.isSensitive, let native = tab.native else { return false }
        return native.isHuman && !native.agentControlled && !native.sensitivePage && !native.httpsOnly && !native.isPod
    }
}

/// 主機自己把借出的頁面放回原分頁容器的原因（主機先還回，再告訴借用者）。
enum BrowserTabReturnReason: Equatable, Sendable {
    /// 分頁要關（使用者關分頁、被睡、主機收掉）。
    case closing
    /// 主視窗對這個分頁下指令（重新整理、網址列、上一頁、尋找、翻譯…）：先拿回來再做。
    case command
    /// 主視窗那一格按了「拿回來」。
    case takenBack
    /// 頁面要全螢幕（倒放框裡不開）：started＝主視窗看得到這個分頁，全螢幕照常在那邊開了。
    case fullscreen(started: Bool)
}

/// 借到倒放框的頁面按 ⌘ 組合鍵：CEF 沒處理的會落到 App 的主選單（例如 ⌘W 會關到主視窗的東西）。
/// 只放行編輯鍵（拷貝、貼上、剪下、全選、還原、重做）與 ⌘Q、⌘H；其他 ⌘ 組合鍵一律在這裡吃掉。
/// 不帶 ⌘ 的鍵（打字、空白鍵暫停、方向鍵快轉）照常給頁面。
enum BrowserLentKeys {
    static let passThrough: Set<String> = ["c", "v", "x", "a", "z", "q", "h"]

    static func claims(characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers.intersection(.deviceIndependentFlagsMask).contains(.command) else { return false }
        return !passThrough.contains((characters ?? "").lowercased())
    }

    static func claims(_ event: NSEvent) -> Bool {
        claims(characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags)
    }
}

/// 主視窗裡被借走的那個分頁：原分頁那一格疊「這支影片在私訊框倒放播放」＋「拿回來」
/// （同「瀏覽器正在另一個視窗使用」的疊法）；按鈕掛 BrowserChromeHitLayer，外層的 CEF 容器才會把點擊讓出來。
struct BrowserTentPlaceholder: View {
    static let text = "這支影片在私訊框倒放播放"
    static let takeBackTitle = "拿回來"
    let onTakeBack: () -> Void

    var body: some View {
        VStack(spacing: DMPhone.edgeInset) {
            Image(systemName: "pip")
                .font(.system(size: DMPhone.TextSize.body, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(Self.text)
                .font(.system(size: DMPhone.TextSize.secondary, weight: .semibold))
                .multilineTextAlignment(.center)
            Button(action: onTakeBack) {
                Text(Self.takeBackTitle)
                    .font(.system(size: DMPhone.TextSize.secondary, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, DMPhone.wideMargin)
                    .frame(minWidth: DMPhone.touch * 2, minHeight: DMPhone.touch)
                    .background(GlobalDMGlassCapsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .background(BrowserChromeHitLayer())
            .accessibilityLabel(Self.takeBackTitle)
            .accessibilityIdentifier("tatwo.dm.tent.placeholder.takeBack")
        }
        .padding(DMPhone.wideMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TatwoActivePalette.current.canvasBase)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tatwo.dm.tent.placeholder")
    }
}
