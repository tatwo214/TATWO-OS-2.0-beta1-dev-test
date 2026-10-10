import AppKit
import SwiftUI
import Network

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
    @Published private(set) var playbackNotice: String?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private struct Transfer {
        let id = UUID().uuidString
        var reason: String
        var retries = 0
        var deadline: Date?
    }
    private var pendingTransfer: Transfer?
    private var inFlight: Transfer?
    private var deviceID: String?
    private var lastGesture: Date?
    private var retakes: [Date] = []
    private var pendingLogin = false
    private var crashes: [Date] = []
    private var stopping = false
    private var terminationObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var networkSatisfied: Bool?
    private let transport: ((String) -> Void)?
    private let now: () -> Date
    private let log: (String) -> Void
    private var running: Bool { transport != nil || process?.isRunning == true }
    private var canStart: Bool { transport != nil || (Self.isBundled && Self.hasCredentials) }

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

    init(transport: ((String) -> Void)? = nil, now: @escaping () -> Date = Date.init,
         log: @escaping (String) -> Void = SpotifyConnect.trace) {
        self.transport = transport
        self.now = now
        self.log = log
        status = transport != nil ? .connecting : !Self.isBundled ? .unavailable : Self.hasCredentials ? .connecting : .signedOut
        if transport == nil {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
        }
    }

    /// App 啟動：登入過就先開好，手機等其他裝置也看得到「TATWO OS」。
    func startIfSignedIn() {
        guard canStart else { return }
        start()
    }

    func spotifyTabOpened() {
        guard canStart else { return }
        if !running { start() }
        requestTransfer(reason: "tab-open")
    }

    /// CEF 原生輸入監聽呼叫；不注入網頁腳本、不合成點擊。
    func spotifyGesture(host: String?) {
        guard host?.lowercased() == Self.spotifyHost, canStart else { return }
        lastGesture = now()
        if !running { start() }
        requestTransfer(reason: "gesture")
    }

    static func isMediaKeyDown(_ event: NSEvent) -> Bool {
        event.type == .systemDefined && event.subtype.rawValue == 8
            && ((event.data1 >> 8) & 0xff) == 0x0a
            && [16, 17, 18, 19, 20].contains((event.data1 >> 16) & 0xffff)
    }

    func spotifyPageChanged(host: String?) { if host?.lowercased() != Self.spotifyHost { playbackNotice = nil } }

    func spotifyInput(_ event: NSEvent, host: String?, isPageTarget: Bool) {
        guard isPageTarget,
              [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
                || Self.isMediaKeyDown(event) else { return }
        // A mouse event cannot distinguish the webpage's play and pause buttons.
        if event.type != .keyDown && !Self.isMediaKeyDown(event) {
            if host?.lowercased() == Self.spotifyHost { lastGesture = now() }
            return
        }
        spotifyGesture(host: host)
    }

    func networkChanged(satisfied: Bool) {
        let restored = networkSatisfied == false && satisfied
        networkSatisfied = satisfied
        guard restored, canStart, running, !stopping, status != .signedOut else { return }
        log("network restored; reconnect requested")
        send("reconnect")
    }

    private func requestTransfer(reason: String) {
        let cancelResume = reason == "gesture"
            && (inFlight?.reason == "reconnect-resume" || pendingTransfer?.reason == "reconnect-resume")
        if cancelResume {
            log("transfer reason=reconnect-resume result=cancelled-by-gesture")
            inFlight = nil; pendingTransfer = nil
        }
        guard !isActive || reason == "reconnect-resume" || cancelResume else {
            if playbackNotice != nil { playbackNotice = nil }
            return
        }
        // Only one transfer at a time. A new gesture supersedes deferred automatic resume.
        if inFlight != nil || (reason == "gesture" && pendingTransfer?.reason == "gesture") { return }
        let request = pendingTransfer ?? Transfer(reason: reason)
        pendingTransfer = reason == "gesture" ? Transfer(reason: reason) : request
        flushTransfer()
    }

    private func flushTransfer() {
        guard var request = pendingTransfer else { return }
        guard status == .connected, running else {
            log("transfer reason=\(request.reason) result=deferred")
            return
        }
        guard let deviceID, !deviceID.isEmpty else {
            failTransfer(request, message: "helper connected without current device id")
            return
        }
        pendingTransfer = nil
        request.deadline = now().addingTimeInterval(12)
        inFlight = request
        log("transfer reason=\(request.reason) attempt=\(request.retries + 1) result=requested")
        sendJSON(["command": "transfer", "id": request.id, "device_id": deviceID,
                  "resume": request.reason == "reconnect-resume", "reason": request.reason])
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.expireTransfer(id: request.id) }
    }

    func expireTransfer(id: String) {
        let request = inFlight ?? pendingTransfer
        guard let request, request.id == id, let deadline = request.deadline, now() >= deadline else { return }
        failTransfer(request, message: "helper did not complete takeover")
    }

    private func failTransfer(_ request: Transfer, message: String) {
        inFlight = nil
        pendingTransfer = nil
        playbackNotice = "Spotify 這次沒接手，再按一次播放"
        log("transfer reason=\(request.reason) result=failed")
        if request.reason == "reconnect-resume" { send("cancel_resume") }
    }

    private func retakeIfNeeded(web: Bool, playing: Bool) {
        guard web, playing, !isActive, status == .connected, let lastGesture,
              now().timeIntervalSince(lastGesture) <= 120 else { return }
        retakes.removeAll { now().timeIntervalSince($0) >= 60 }
        guard retakes.count < 2, inFlight == nil, pendingTransfer == nil else { return }
        retakes.append(now())
        requestTransfer(reason: "retake")
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
        isActive = false
        pendingTransfer = nil; inFlight = nil; deviceID = nil; playbackNotice = nil
        lastGesture = nil; retakes = []
        status = .signedOut
    }

    func stop() {
        stopping = true
        pathMonitor?.cancel(); pathMonitor = nil
        pendingTransfer = nil; inFlight = nil
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
        if transport != nil { return }
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
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { [weak self] in self?.receive(data) }
        }
        task.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async { self?.exited(finished) }
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
        if pathMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let satisfied = path.status == .satisfied
                DispatchQueue.main.async { self?.networkChanged(satisfied: satisfied) }
            }
            pathMonitor = monitor
            monitor.start(queue: DispatchQueue(label: "tatwo.spotify.network"))
        }
        if status != .signingIn { status = Self.hasCredentials ? .connecting : .signedOut }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let line = String(data: data, encoding: .utf8) else { return }
        send(line)
    }

    private func send(_ command: String) {
        if let transport { transport(command + "\n"); return }
        guard let input, process?.isRunning == true else { return }
        try? input.write(contentsOf: Data((command + "\n").utf8))
    }

    func receive(_ data: Data) {
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
        case "connected" where object["unconfirmed"] as? Bool == true: log("helper event=connected unconfirmed=true")
        case "playing", "paused", "active", "inactive": log("helper event=\(event)")
        case "device": log("helper event=device active=\(object["active"] as? Bool == true) web=\(object["web"] as? Bool == true)")
        case "transfer_options": log("helper event=transfer_options pause=\(object["pause"] as? Bool == true) play=\(object["play"] as? Bool == true)")
        case "reconnecting":
            let reason = object["reason"] as? String ?? "unknown"
            log("helper event=reconnecting reason=\(["task-ended", "registration-timeout", "connect-failed", "requested", "session-invalid"].contains(reason) ? reason : "unknown")")
        default: break
        }
        switch event {
        case "needs_login":
            if let request = inFlight ?? pendingTransfer { failTransfer(request, message: "helper needs login") }
            if pendingLogin { pendingLogin = false; status = .signingIn; send("login") } else { status = .signedOut }
        case "starting", "reconnecting":
            deviceID = nil
            isActive = false; isPlaying = false
            if status != .signingIn { status = .connecting }
        case "logged_in":
            status = .connecting
        case "connected":
            status = .connected
            deviceID = object["device_id"] as? String
            if object["resume"] as? Bool == true, pendingTransfer?.reason != "gesture" {
                if pendingTransfer != nil {
                    pendingTransfer?.reason = "reconnect-resume"
                    flushTransfer()
                } else { requestTransfer(reason: "reconnect-resume") }
            } else { flushTransfer() }
        case "login_failed":
            status = .failed("登入沒有完成：\(object["message"] as? String ?? "")")
        case "logged_out":
            status = .signedOut
        case "active":
            playbackNotice = nil
            isActive = true
        case "inactive":
            isActive = false
            isPlaying = false
        case "device":
            let active = object["active"] as? Bool == true
            if isActive != active { isActive = active }
            if !isActive && isPlaying { isPlaying = false }
            if !isActive { retakeIfNeeded(web: object["web"] as? Bool == true, playing: object["playing"] as? Bool == true) }
        case "transferred":
            guard let request = inFlight, object["id"] as? String == request.id else { return }
            inFlight = nil
            playbackNotice = nil
            log("transfer reason=\(request.reason) result=success")
        case "transfer_failed":
            guard var request = inFlight, object["id"] as? String == request.id else { return }
            let missing = object["not_found"] as? Bool == true
            if missing && request.retries == 0 {
                request.retries += 1
                request.deadline = now().addingTimeInterval(45)
                inFlight = nil
                pendingTransfer = request
                deviceID = nil
                status = .connecting
                log("transfer reason=\(request.reason) result=retry-after-connected")
                send("reconnect")
                DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in self?.expireTransfer(id: request.id) }
            } else { failTransfer(request, message: object["message"] as? String ?? "unknown") }
        case "playing": if !isPlaying { isPlaying = true }
        case "paused", "stopped", "unavailable": if isPlaying { isPlaying = false }
        case "error":
            log("helper event=error")
        default: break
        }
    }

    private func exited(_ finished: Process) {
        guard finished === process || process == nil else { return }
        process = nil
        input = nil
        isPlaying = false; isActive = false; deviceID = nil
        if let request = inFlight { failTransfer(request, message: "helper exited") }
        guard !stopping else { return }
        // 意外結束：十分鐘內最多自動重開三次。
        crashes = crashes.filter { $0.timeIntervalSinceNow > -600 } + [Date()]
        if crashes.count <= 3, Self.hasCredentials {
            status = .connecting
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
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
