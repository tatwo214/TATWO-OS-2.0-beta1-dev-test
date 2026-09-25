import AppKit
import SwiftUI

/// W176（使用者 2026-09-23）：「可以做進App 不要叫測試 叫TATWO OS 並且預設用os開啟時就是tatwo os播放 不要手動再喬」。
/// OS 瀏覽器的 Spotify 網頁播放器只能播約 10 秒（Spotify 的授權只給有 Google 正式 VMP 簽章的瀏覽器）。
/// App 內建一台叫「TATWO OS」的 Spotify 裝置（Contents/Helpers/tatwo-spotify，librespot），聲音由 OS 自己播；
/// 在 OS 瀏覽器打開 open.spotify.com 時自動把播放轉到這台。登入只走 Spotify 官方頁，憑證留在本機 0700 資料夾。
@MainActor
final class SpotifyConnect: ObservableObject {
    static let shared = SpotifyConnect()
    static let deviceName = "TATWO OS"
    static let loginPort = 5589
    static let spotifyHost = "open.spotify.com"

    enum Status: Equatable {
        case unavailable, signedOut, signingIn, connecting, connected
        case failed(String)
    }

    @Published private(set) var status: Status
    @Published private(set) var isPlaying = false {
        didSet { if isPlaying != oldValue { BrowserAudibleTabs.shared.setPlayingElsewhere(host: Self.spotifyHost, isPlaying) } }
    }
    @Published private(set) var isActive = false

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var pendingTransfer = false
    private var pendingLogin = false
    private var crashes: [Date] = []
    private var stopping = false
    /// 打開 Spotify 分頁後由 TATWO OS 接手播放。2026-09-23～24 實測：接手後約 1 秒被搶回，兇手是別的瀏覽器（Dia）開著的
    /// Spotify 網頁播放器，不是 OS 自己的分頁；關掉那一頁後直接接手就不再被搶。
    /// 等網頁載入完才接手；打開後 30 秒內又被搶走就再接手（最多 3 次），之後使用者自己換裝置不會被搶。
    /// （曾試過在網頁裡自動點「連接裝置」：頁面快照的防誤點過濾把 Spotify 播放列按鈕判成被遮住，抓不到，已移除。）
    static let handoffDelay: TimeInterval = 4
    static let handoffGuard: TimeInterval = 30
    private var handoffUntil: Date?
    private var handoffRetries = 0
    private var terminationObserver: NSObjectProtocol?

    static var helperURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tatwo-spotify") }
    static var cacheDirectory: URL { EnginePaths().appSupportRoot.appendingPathComponent("spotify", isDirectory: true) }
    static var hasCredentials: Bool {
        FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent("credentials.json").path)
    }
    static var isBundled: Bool { FileManager.default.isExecutableFile(atPath: helperURL.path) }

    /// 自動選裝置的每一步記在 spotify/app.log（App 的 stderr 導到 /dev/null、系統記錄也看不到，只能寫檔）。只留最近 200 行。
    static func trace(_ message: String) {
        let url = cacheDirectory.appendingPathComponent("app.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let previous = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").suffix(199).joined(separator: "\n") ?? ""
        try? ((previous.isEmpty ? "" : previous + "\n") + "\(stamp) \(message)\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private init() {
        status = !Self.isBundled ? .unavailable : Self.hasCredentials ? .connecting : .signedOut
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { SpotifyConnect.shared.stop() }
        }
    }

    /// App 啟動：登入過就先開好，手機等其他裝置也看得到「TATWO OS」。
    func startIfSignedIn() {
        guard Self.isBundled, Self.hasCredentials else { return }
        start()
    }

    /// OS 瀏覽器的分頁第一次打開 Spotify（每個分頁一次，之後在網頁裡換頁不再搶）。
    func spotifyTabOpened() {
        guard Self.isBundled, Self.hasCredentials else { return }
        Self.trace("tab opened; status=\(status) active=\(isActive)")
        handoffUntil = Date().addingTimeInterval(Self.handoffGuard)
        handoffRetries = 0
        if process?.isRunning != true { start() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handoffDelay) {
            SpotifyConnect.shared.requestTransfer()
        }
    }

    private func requestTransfer() {
        guard status == .connected, process?.isRunning == true else {
            Self.trace("transfer deferred; status=\(status)"); pendingTransfer = true; return
        }
        guard !isActive else { Self.trace("transfer skipped; already active"); return }
        Self.trace("transfer requested")
        send("transfer")
    }

    /// 設定頁的「登入 Spotify」：開官方登入頁，使用者按同意後自動連上。
    func signIn() {
        guard Self.isBundled else { return }
        pendingLogin = true
        status = .signingIn
        if process?.isRunning == true { send("login"); pendingLogin = false } else { start() }
    }

    func signOut() {
        send("logout")
        isPlaying = false
        status = .signedOut
    }

    func stop() {
        stopping = true
        send("quit")
        try? input?.close()
        let running = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if running?.isRunning == true { running?.terminate() }
        }
        process = nil
        input = nil
    }

    private func start() {
        guard process?.isRunning != true, Self.isBundled else {
            if pendingLogin { send("login"); pendingLogin = false }
            return
        }
        let directory = Self.cacheDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            status = .failed("Spotify 資料夾建不起來：\(error.localizedDescription)")
            return
        }
        let task = Process()
        task.executableURL = Self.helperURL
        task.arguments = ["--cache", directory.path, "--name", Self.deviceName, "--port", String(Self.loginPort)]
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        task.standardInput = stdinPipe
        task.standardOutput = stdoutPipe
        // 一般記錄只留最近一次，放在同一個 0700 資料夾；librespot 在 info 等級不寫權杖。
        let logURL = directory.appendingPathComponent("helper.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        task.standardError = (try? FileHandle(forWritingTo: logURL)) ?? FileHandle.nullDevice
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            DispatchQueue.main.async { SpotifyConnect.shared.receive(data) }
        }
        task.terminationHandler = { finished in
            DispatchQueue.main.async { SpotifyConnect.shared.exited(finished) }
        }
        do {
            try task.run()
        } catch {
            status = .failed("Spotify 裝置程式開不起來：\(error.localizedDescription)")
            return
        }
        stopping = false
        process = task
        input = stdinPipe.fileHandleForWriting
        if status != .signingIn { status = Self.hasCredentials ? .connecting : .signedOut }
    }

    private func send(_ command: String) {
        guard let input, process?.isRunning == true else { return }
        try? input.write(contentsOf: Data((command + "\n").utf8))
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[..<end], as: UTF8.self)
            buffer.removeSubrange(...end)
            handle(line: line)
        }
    }

    private func handle(line: String) {
        // librespot 自己印的登入網址。只開 Spotify 官方網域。
        if line.hasPrefix("Browse to: ") {
            let raw = String(line.dropFirst("Browse to: ".count)).trimmingCharacters(in: .whitespaces)
            if let url = URL(string: raw), url.scheme == "https", url.host == "accounts.spotify.com" {
                NSWorkspace.shared.open(url)
            }
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let event = object["event"] as? String else { return }
        switch event {
        case "needs_login":
            if pendingLogin { pendingLogin = false; status = .signingIn; send("login") } else { status = .signedOut }
        case "starting", "reconnecting":
            if status != .signingIn { status = .connecting }
        case "logged_in":
            status = .connecting
        case "connected":
            status = .connected
            if pendingTransfer { pendingTransfer = false; requestTransfer() }
        case "login_failed":
            status = .failed("登入沒有完成：\(object["message"] as? String ?? "")")
        case "logged_out":
            status = .signedOut
        case "active":
            isActive = true
        case "inactive":
            isActive = false
            isPlaying = false
            if let until = handoffUntil, until > Date(), handoffRetries < 3 {
                handoffRetries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { SpotifyConnect.shared.requestTransfer() }
            }
        case "playing": isPlaying = true
        case "paused", "stopped", "unavailable": isPlaying = false
        case "error":
            if let message = object["message"] as? String { Self.trace("helper error: \(message)") }
        default: break
        }
    }

    private func exited(_ finished: Process) {
        guard finished === process || process == nil else { return }
        process = nil
        input = nil
        isPlaying = false
        guard !stopping else { return }
        // 意外結束：十分鐘內最多自動重開三次。
        crashes = crashes.filter { $0.timeIntervalSinceNow > -600 } + [Date()]
        if crashes.count <= 3, Self.hasCredentials {
            status = .connecting
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { SpotifyConnect.shared.start() }
        } else {
            status = Self.hasCredentials ? .failed("Spotify 裝置程式一直停止，請到設定重新登入") : .signedOut
        }
    }

    static func statusText(_ status: Status) -> String {
        switch status {
        case .unavailable: "這個版本沒有內建 Spotify 裝置。"
        case .signedOut: "還沒登入。登入一次後，在 OS 瀏覽器打開 Spotify 就會由「\(deviceName)」播放。"
        case .signingIn: "已打開 Spotify 登入頁，登入並按「同意」後會自動連上。"
        case .connecting: "正在連上 Spotify…"
        case .connected: "已連上。在 OS 瀏覽器打開 Spotify 會自動由「\(deviceName)」播放。"
        case .failed(let message): message
        }
    }
}

/// 設定 › 瀏覽器 › 音樂與影片 裡的 Spotify 區塊。
struct SpotifyConnectSettingsView: View {
    @ObservedObject private var spotify = SpotifyConnect.shared

    var body: some View {
        VStack(alignment: .leading, spacing: BrowserSidebarMetrics.settingsRowSpacing) {
            Text("Spotify").font(.headline)
            HStack(spacing: 10) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(SpotifyConnect.statusText(spotify.status)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                switch spotify.status {
                case .signedOut, .failed:
                    OSChipButton(title: "登入 Spotify", isPrimary: true) { spotify.signIn() }
                case .connected, .connecting:
                    OSChipButton(title: "登出") { spotify.signOut() }
                case .signingIn:
                    OSChipButton(title: "重開登入頁") { spotify.signIn() }
                case .unavailable:
                    EmptyView()
                }
            }
            Text("Spotify 的網頁播放器在 OS 瀏覽器只能播約 10 秒（它只把授權給有 Google 簽章的瀏覽器），所以改由 TATWO OS 自己當一台 Spotify 裝置播放。需要 Premium；音質最高 320 kbps，不支援無損。這是第三方播放程式（開源 librespot），Spotify 條款並不鼓勵。")
                .font(.footnote).foregroundStyle(LiquidGlassTokens.browserMutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: spotify.status) { _ in SetupChecklist.shared.refresh(logins: SetupChecklist.shared.lastLogins) }
    }

    private var dotColor: Color {
        switch spotify.status {
        case .connected: LiquidGlassTokens.browserSuccessFill
        case .unavailable, .signedOut: Color.secondary.opacity(0.4)
        case .signingIn, .connecting, .failed: LiquidGlassTokens.brandAccent
        }
    }
}
