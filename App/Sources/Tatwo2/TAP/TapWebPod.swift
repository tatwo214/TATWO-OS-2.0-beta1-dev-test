import AppKit
import Darwin
import TatwoCEFBridge

enum TapPodError: LocalizedError {
    case profileUnavailable
    case scriptRejected

    var errorDescription: String? {
        switch self {
        case .profileUnavailable: "瀏覽器安裝或資料目錄無效，Pod 無法啟動"
        case .scriptRejected: "瀏覽器核心沒有接受這個 Pod 的腳本"
        }
    }
}

/// TAP 的網頁艙（Pod）：用 OS 自己的瀏覽器核心跑外部 App 的真網頁版。
/// - 一個 Pod 一個獨立的登入空間（CEF 設定檔），登入資料只留在這裡，OS 核心拿不到。
/// - Tap 的腳本只注入這個瀏覽器（TatwoCEFBridge 的 configurePod），一般分頁完全不受影響。
/// - 平常看不到它：畫面上的 Space 開著時墊在畫面外（仍算「看得見」，網頁不會被節流）；
///   Space 不在畫面時收進一個不顯示的停泊視窗。需要登入時由 Space 把它移到畫面上。
/// - 同一時間可能有兩個畫面要它（Space、設定頁的網頁版視窗）：最後叫它的那個拿到，放手後回到前一個。
@MainActor
final class TapWebPod {
    private struct Host {
        weak var view: NSView?
    }

    let podID: String
    let profile: EmbeddedBrowserRuntimeProfile
    let homeURL: URL
    private let script: String
    private(set) var browser: TatwoCEFBrowserView?
    private var lease: TatwoCEFProfileLeaseRegistry.Lease?
    private var hosts: [Host] = []
    private var parking: NSWindow?
    /// Pod 主框架所在的渲染程序（腳本注入時由瀏覽器核心回報）；只用來讀記憶體用量。
    private(set) var rendererPID: pid_t?
    /// Tap 腳本回報的 JSON 字串。
    var onEvent: ((String) -> Void)?

    init(podID: String, profileID: UUID, homeURL: URL, script: String) {
        self.podID = podID
        self.profile = .persistent(profileID)
        self.homeURL = homeURL
        self.script = script
    }

    var isRunning: Bool { browser != nil }

    /// 照 OS 瀏覽器開分頁的同一套步驟：找設定檔 → 取租約（一個設定檔同時只給一個宿主）→ 初始化核心 → 建頁面。
    func start() throws {
        guard browser == nil else { return }
        guard let location = try TatwoCEFProfileLocationResolver.resolve(profile: profile) else {
            throw TapPodError.profileUnavailable
        }
        if lease == nil {
            lease = try TatwoCEFProfileLocationResolver.prepareForRuntime(location)
        }
        TatwoCEFRuntime.configureRendererProcessLimit(BrowserMemorySettings.load().limit() ?? 0)
        try TatwoCEFRuntime.initialize(
            withRootCachePath: location.rootCachePath,
            helperExecutablePath: location.helperExecutablePath,
            logFilePath: location.logFilePath,
            bundledDenyListPath: BrowserBundledHostDenyList.verifiedResourceURL().path)
        let view = try TatwoCEFBrowserView(
            frame: NSRect(x: 0, y: 0, width: 1100, height: 800),
            persistentProfile: location.persistentProfilePath,
            initialURL: "about:blank", actor: .human)
        guard view.configurePod(script: script) else { throw TapPodError.scriptRejected }
        view.onPodEvent = { [weak self] json in
            guard let self else { return }
            if json.hasPrefix(Self.processPrefix) {
                self.rendererPID = Self.processID(json)
            } else {
                self.onEvent?(json)
            }
        }
        // 登入流程開的新視窗（例如用 Google 登入）留在同一個 Pod 裡，登入資料才會存在這個 Pod。
        BrowserHumanInteraction.shared.configure(view, onForegroundTab: { [weak view] url in
            view?.loadURLString(url.absoluteString)
        }) { [weak view] url in
            view?.loadURLString(url.absoluteString)
        }
        browser = view
        place()
        view.loadURLString(homeURL.absoluteString)
    }

    /// 某個畫面要顯示（或墊著）Pod：最後叫的那個拿到。
    func claim(_ container: NSView) {
        hosts.removeAll { $0.view == nil || $0.view === container }
        hosts.append(Host(view: container))
        place()
    }

    /// 畫面不要了：回到前一個還在的畫面，都沒有就收回停泊視窗（仍在跑，只是看不到）。
    func release(_ container: NSView) {
        hosts.removeAll { $0.view == nil || $0.view === container }
        place()
    }

    /// 有沒有任何畫面正拿著 Pod（拿著就不休眠）。
    var isHosted: Bool { hosts.contains { $0.view?.window != nil } }

    /// Pod 渲染程序目前的實體記憶體（位元組）；沒在跑或讀不到回 nil，不假裝是 0。
    var footprintBytes: UInt64? {
        guard browser != nil, let pid = rendererPID else { return nil }
        var usage = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return status == 0 ? usage.ri_phys_footprint : nil
    }

    private func place() {
        guard let browser else { return }
        let target = hosts.last(where: { $0.view != nil })?.view ?? parkingView()
        guard browser.superview !== target else { return }
        browser.removeFromSuperview()
        browser.frame = target.bounds
        browser.autoresizingMask = [.width, .height]
        target.addSubview(browser)
    }

    private static let processPrefix = #"{"type":"process","#
    static func processID(_ json: String) -> pid_t? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return pid
    }

    /// 執行 Tap 自己的指令（只有 Pod 瀏覽器會接受）。
    func run(_ javascript: String) {
        browser?.runPodCommand(javascript)
    }

    /// 關掉網頁、還回設定檔租約。登入資料留在設定檔裡，下次開不用重登。
    func stop() {
        guard let browser else { return }
        self.browser = nil
        rendererPID = nil
        browser.onPodEvent = nil
        let lease = self.lease
        self.lease = nil
        browser.closeBrowser(completion: {
            Task { @MainActor in
                browser.removeFromSuperview()
                if let lease { TatwoCEFProfileLeaseRegistry.shared.release(lease) }
            }
        })
    }

    private func parkingView() -> NSView {
        if let view = parking?.contentView { return view }
        let frame = NSRect(x: -30_000, y: -30_000, width: 1100, height: 800)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = content
        parking = window
        return content
    }
}
