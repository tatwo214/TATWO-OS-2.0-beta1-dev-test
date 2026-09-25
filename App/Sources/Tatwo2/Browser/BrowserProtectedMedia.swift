import AppKit
import SwiftUI

/// 受保護的音樂與影片（Spotify、Netflix…）要 Widevine。Chromium 只在執行時由元件下載器向 Google 取得它，
/// 而 OS 瀏覽器平常關掉背景下載與元件更新（TatwoCEFBridge.mm）。這個開關打開，下次啟動瀏覽器時才放行下載。
/// 2026-09-23 實測：MacBook 打開後下載 WidevineCdm 4.10.3050.0，重開一次 TATWO OS，Spotify 在 OS 裡播放成功。
enum BrowserProtectedMedia {
    /// Bridge（TatwoCEFBridge.mm）在瀏覽器啟動時讀這兩個鍵；舊的實驗鍵照認，打開過的設備不用重設。
    static let key = "tatwo.browser.protectedMedia"
    static let legacySpikeKey = "tatwo.browser.widevineSpike"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) || UserDefaults.standard.bool(forKey: legacySpikeKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            UserDefaults.standard.removeObject(forKey: legacySpikeKey)
        }
    }

    /// 這次 App 啟動時的值；瀏覽器核心只在啟動時讀開關，改了要重開才生效。App 啟動時先讀一次。
    static let enabledAtLaunch = isEnabled
    static let launchedAt = Date()

    /// 已下載的 Widevine：版本與下載完成時間（沒有就是 nil）。
    static func installed(rootCache: URL? = TatwoCEFProfileLocationResolver.rootCacheURL()) -> (version: String, date: Date)? {
        guard let root = rootCache?.appendingPathComponent("WidevineCdm"), let version = installedVersion(rootCache: rootCache) else { return nil }
        let arch = ProcessInfo.processInfo.machineHardwareName == "x86_64" ? "mac_x64" : "mac_arm64"
        let file = root.appendingPathComponent("\(version)/_platform_specific/\(arch)/libwidevinecdm.dylib")
        let date = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? .distantPast
        return (version, date)
    }

    static func installedVersion(rootCache: URL? = TatwoCEFProfileLocationResolver.rootCacheURL()) -> String? {
        guard let root = rootCache?.appendingPathComponent("WidevineCdm"),
              let versions = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return nil }
        let arch = ProcessInfo.processInfo.machineHardwareName == "x86_64" ? "mac_x64" : "mac_arm64"
        return versions.filter { version in
            FileManager.default.fileExists(atPath: root.appendingPathComponent(
                "\(version)/_platform_specific/\(arch)/libwidevinecdm.dylib").path)
        }.sorted { $0.compare($1, options: .numeric) == .orderedAscending }.last
    }

    enum Status: Equatable {
        case off, needsRestart, downloading, downloadedNeedsRestart(String), ready(String)
    }

    static func status(enabled: Bool = isEnabled, launched: Bool = enabledAtLaunch,
                       cdm: (version: String, date: Date)? = installed(), launchDate: Date = launchedAt) -> Status {
        guard enabled else { return .off }
        if !launched { return .needsRestart }
        guard let cdm else { return .downloading }
        // 實測：元件在瀏覽器啟動後才下載好時，這次執行用不到，要重開一次。
        return cdm.date > launchDate ? .downloadedNeedsRestart(cdm.version) : .ready(cdm.version)
    }

    static func statusText(_ status: Status) -> String {
        switch status {
        case .off: "關閉：需要播放元件的影音網站在 OS 瀏覽器裡不能播放。"
        case .needsRestart: "已打開，重新啟動 TATWO OS 後生效。"
        case .downloading: "已打開，正在向 Google 下載播放元件（約 20 MB，打開瀏覽器幾分鐘內完成）。下載好後再重新啟動一次 TATWO OS。"
        case .downloadedNeedsRestart(let version): "播放元件 Widevine \(version) 已下載好，重新啟動 TATWO OS 後就能播放。"
        case .ready(let version): "可以播放。播放元件 Widevine \(version)。"
        }
    }

    /// 診斷報告那一行。
    static var diagnosticsLine: String {
        switch status() {
        case .off: "DRM 影片（Widevine）：關閉（設定 › 瀏覽器 › 音樂與影片）"
        case .needsRestart: "DRM 影片（Widevine）：已打開，待重新啟動"
        case .downloading: "DRM 影片（Widevine）：已打開，尚未下載"
        case .downloadedNeedsRestart(let version): "DRM 影片（Widevine）：\(version) 已下載，待重新啟動"
        case .ready(let version): "DRM 影片（Widevine）：可用 \(version)"
        }
    }

    /// 重新啟動：先起一個等 App 結束再打開它的小程序，然後照更新時的方式乾淨退出。
    @MainActor static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundle = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done; /usr/bin/open \"$0\"", bundle]
        guard (try? task.run()) != nil else { return }
        TatwoTerminationCoordinator.bypassNextConfirmation = true
        NSApplication.shared.terminate(nil)
    }
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/// 設定 › 瀏覽器 › 音樂與影片。
struct BrowserProtectedMediaSettingsView: View {
    @State private var enabled = BrowserProtectedMedia.isEnabled
    @State private var status = BrowserProtectedMedia.status()
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: BrowserSidebarMetrics.settingsRowSpacing) {
            Toggle("允許播放受保護的音樂與影片", isOn: $enabled)
                .onChange(of: enabled) { value in
                    BrowserProtectedMedia.isEnabled = value
                    refresh()
                }
            Text("這類網站要 Google 的播放元件 Widevine。打開後，OS 瀏覽器會向 Google 下載它（也會一併更新 Chromium 的其他小元件）；關掉就不再下載。")
                .foregroundStyle(LiquidGlassTokens.browserMutedInk)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(BrowserProtectedMedia.statusText(status)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if needsRestart {
                    OSChipButton(title: "重新啟動 TATWO OS", isPrimary: true) { BrowserProtectedMedia.relaunch() }
                }
            }
            Text("Netflix 這類網站另外需要 Google 的正式簽章，OS 瀏覽器目前播不了；Spotify 改由下面的「TATWO OS」裝置播放。")
                .font(.footnote).foregroundStyle(LiquidGlassTokens.browserMutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(timer) { _ in refresh() }
    }

    /// 打開了但這次啟動時是關的，或元件剛下載好（瀏覽器啟動時還沒有），都要重開一次。
    private var needsRestart: Bool {
        switch status {
        case .needsRestart, .downloadedNeedsRestart: true
        case .downloading: false
        case .off, .ready: false
        }
    }

    private var dotColor: Color {
        switch status {
        case .ready: LiquidGlassTokens.browserSuccessFill
        case .off: Color.secondary.opacity(0.4)
        case .needsRestart, .downloading, .downloadedNeedsRestart: LiquidGlassTokens.brandAccent
        }
    }

    private func refresh() {
        let next = BrowserProtectedMedia.status()
        if next != status { status = next }
        SetupChecklist.shared.refresh(logins: SetupChecklist.shared.lastLogins)
    }
}
