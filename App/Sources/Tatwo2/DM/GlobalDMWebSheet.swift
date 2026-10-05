import AppKit
import SwiftUI

// W183 R5b（使用者 09-28：「在這台開啟授權頁面改成自動跳轉與小視窗 不要跳去browser分頁 這樣會中斷使用者思緒 改用私訊鈕跳轉？」
// 「私訊鈕的UI邏輯 一率當成手機做搭建 之後穩定後就會知道手機遠端要以什麼方式搭建」）：授權頁在私訊框裡開（手機 App 的內嵌瀏覽器）。
// - 網頁用這台 OS 瀏覽器的同一個 human 設定檔（正式的頁面宿主 GlobalDMCEFWebPageHost）；頁面宿主可替換（自測＝假宿主）。
// - 敏感：頁面不進分頁清單、tabs.json、最近關閉、瀏覽紀錄；AI 與 Computer Use 的瀏覽器工具看不到。
// - 只收驗過的起點（GlobalDMWebSheet 只能從 cloudflareAuthorization 建：HandsCloudflared.loginURL 驗過的 Cloudflare 授權頁網址）。
// W183 R8b（使用者 09-28 晚：「私訊鈕授權在上方tatwoos跟chatgpt圓鈕新增一欄bowser，以手機ui去搭建瀏覽器，然後授權一率從那邊就不會遺失」）：
// 蓋在對話上的那一張頁面改成私訊框第三顆圓鈕「Browser」裡的分頁（DM/DMBrowser.swift、DM/DMBrowserView.swift）；這裡留：
// 驗過的起點、頁面與頁面宿主的介面、網域與鎖頭的判斷、「連上 ChatGPT」原生卡片（R6b）掛在私訊框上的那一層。

/// 私訊框網頁的起點（URL、標題、來源）。只能從驗過的工廠方法建。
struct GlobalDMWebSheet: Identifiable, Equatable {
    enum Source: String, Equatable, Sendable {
        /// ChatGPT 手腳的 Cloudflare 授權頁（標準設定流程第 3 步）。
        case cloudflareAuthorization
    }

    let id: UUID
    let url: URL
    let title: String
    /// 網址的網域。
    let host: String
    let source: Source

    private init(url: URL, title: String, host: String, source: Source) {
        id = UUID()
        self.url = url
        self.title = title
        self.host = host
        self.source = source
    }

    /// Cloudflare 授權頁：只收 HandsCloudflared.loginURL 驗過的網址（https、cloudflare.com、/argotunnel、沒有帳密與埠號），其他一律不開。
    static func cloudflareAuthorization(_ url: URL) -> GlobalDMWebSheet? {
        guard HandsCloudflared.loginURL(in: url.absoluteString) == url, let host = url.host?.lowercased() else { return nil }
        return GlobalDMWebSheet(url: url, title: "Cloudflare 授權", host: host, source: .cloudflareAuthorization)
    }
}

extension GlobalDMWebSheet {
    /// 網址 pill 上的網域（帶非預設埠號時一起顯示）。
    static func displayHost(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// 鎖頭：只有 https（敏感頁本來就只准 https、憑證錯誤一律擋；這裡再保險一次，不是 https 就顯示警告）。
    static func isSecure(_ url: URL) -> Bool { url.scheme?.lowercased() == "https" }
}

/// W183 R5b 審查：頁面現在的樣子（看得到的那一頁）。
struct GlobalDMWebPageState: Equatable, Sendable {
    var loading = true
    /// 載入失敗的白話原因（nil＝沒事）。
    var error: String?
    /// 看得到的那一頁實際載入的主框架網址（http／https；還沒有、空白頁、別的協定＝nil：網址 pill 寫「尚未確認來源」，W183 R8b 審查不再顯示起點）。
    var committedURL: URL?
    /// 頁內開的新視窗疊在上面幾層（>0＝上一頁會先收掉最上面那一層）。
    var stacked = 0
    /// W183 R8b：手機式瀏覽器的上一頁、下一頁（最上面那一頁的瀏覽紀錄）。
    var canGoBack = false
    var canGoForward = false

    /// 只收 http／https 的主框架網址（about:blank、錯誤頁不算）。
    static func committed(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

/// 一張網頁頁面（正式＝CEF 的 human 頁面；自測＝假頁面）。
@MainActor
protocol GlobalDMWebPage: AnyObject, Sendable {
    var view: NSView { get }
    var isHumanActor: Bool { get }
    /// 收掉最上面那一層（頁內開的新視窗）；沒有疊的就不動。
    func back()
    /// W183 R8b：上一頁（最上面那一頁有瀏覽紀錄就退一頁；沒有＝收掉最上面那一層新視窗）。
    func goBack()
    /// W183 R8b：下一頁。
    func goForward()
    /// W184 G2d（GPT-6 審查 G2d #1）：重新載入最上面那一頁——原生的重新載入（同一個瀏覽器、上一頁／下一頁的紀錄都在），不是關掉重開。
    func reload()
    /// 收回：從畫面拿掉並銷毀（不留在記憶體、不留在停泊視窗）。重複呼叫沒事。
    func close()
}

@MainActor
extension GlobalDMWebPage {
    func goBack() { back() }
    func goForward() {}
}

/// 頁面宿主：給一個起點網址，開一張頁面（正式＝這台 OS 瀏覽器的 human 設定檔；自測＝假宿主）。
@MainActor
protocol GlobalDMWebPageHosting: AnyObject, Sendable {
    func openPage(url: URL, onState: @escaping @MainActor (GlobalDMWebPageState) -> Void) async throws -> any GlobalDMWebPage
}

/// W183 R5b 審查（Claude）／R6b：原生卡片蓋著私訊框時，框裡的輸入列拿掉（字不會跑進看不見的草稿、Enter 不會送出）。
private struct GlobalDMWebSheetActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var globalDMWebSheetActive: Bool {
        get { self[GlobalDMWebSheetActiveKey.self] }
        set { self[GlobalDMWebSheetActiveKey.self] = newValue }
    }
}

/// W184 D（對照稿 Outer-Connect）：［連線］確認＝底部 sheet 的數字。
enum GlobalDMWebSheetLayout {
    /// sheet 頂端離框頂 96（露出頂列與一截對話，像手機的 sheet）。
    static let topInset: CGFloat = 96
    /// 上圓角 40、下圓角＝框的圓角 52（貼著框底；框縮小時框自己的圓角會再裁）。
    static let topRadius: CGFloat = 40
    static var bottomRadius: CGFloat { GlobalDMLayout.cornerRadius }
    static var cornerRadius: CGFloat { topRadius }
    static var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: topRadius, bottomLeadingRadius: bottomRadius, bottomTrailingRadius: bottomRadius,
                               topTrailingRadius: topRadius, style: .continuous)
    }
    /// 後面的遮罩：0.22 黑（點了不關：取消要按「取消」或往下拉）。
    static let dimOpacity: Double = 0.22
    /// 頂端 grabber 36×5，離頂 7；往下拉超過 110 放手＝取消。
    static let grabberSize = CGSize(width: 36, height: 5)
    static let grabberTop: CGFloat = 7
    static let pullToDismiss: CGFloat = 110
    /// 頂列：上 8、下 6、左右 16；「取消」是玻璃膠囊（44 高）、「連線」是強調色膠囊（44 高、白字）、標題 17 半粗。
    static let headerTop: CGFloat = 8
    static let headerBottom: CGFloat = 6
    /// 內容：內距 上 10、左右 16、下 16，間距 18。
    static let contentTop: CGFloat = 10
    static var contentSide: CGFloat { DMPhone.margin }
    static let contentBottom: CGFloat = 16
    static let contentSpacing: CGFloat = 18
    /// 群組圓角 26；列高 48（帳號、主機、網址）、52（專案、記憶，按進下一層）。
    static let groupRadius: CGFloat = 26
    static let rowHeight: CGFloat = 48
    static let navRowHeight: CGFloat = 52
    /// 「ChatGPT 能做到哪」分段：34 高、外框 3。
    static let segmentHeight: CGFloat = 34
    static let segmentInset: CGFloat = 3
    /// 頂列高度（R6b 起；W184 D 的頂列照上面的數字，這個留給還在讀它的地方）。
    static let barHeight: CGFloat = GlobalDMLayout.headerHeight
    static var slide: Animation { .spring(response: 0.36, dampingFraction: 0.9) }
}

// MARK: - 畫面

/// 蓋在私訊框上的那一層（停靠框、浮動框、內橫的整個兩欄框都用它；框的外觀不動）：R6b「連上 ChatGPT」的確認卡。
/// W183 R8b：授權頁不再蓋在對話上（在 Browser 的分頁裡）；W184 D：確認卡是底部 sheet，按了［連線］之後的卡片浮在 Browser 的頁上。
struct GlobalDMWebSheetOverlay: ViewModifier {
    @ObservedObject var store: GlobalDMStore
    var isShown = true
    /// 外層（iPhone 打開的兩欄框）已經蓋著：兩欄的輸入列都拿掉。
    @Environment(\.globalDMWebSheetActive) private var outerActive
    /// W183 R6b：「連上 ChatGPT」的原生卡片（HandsConnectDMLayer）；蓋著時輸入列一樣拿掉。
    @ObservedObject private var connect = HandsConnectPresenter.shared

    func body(content: Content) -> some View {
        content
            .environment(\.globalDMWebSheetActive, outerActive || (isShown && connect.covers(store)))   // W183 R5b 審查／R6b／R8b
            .overlay {
                if isShown { HandsConnectDMLayer(store: store) }   // W183 R6b
            }
    }
}
