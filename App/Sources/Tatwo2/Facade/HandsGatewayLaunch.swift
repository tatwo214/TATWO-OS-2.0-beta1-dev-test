import Foundation
import Darwin
import Security

/// W183 R2／R2b：ChatGPT 手腳關口的啟動參數（純函式，自測直接驗）：路徑、Seatbelt 參數、子行程環境、cloudflared 參數、
/// OpenAI IP 清單的解析與新鮮度、config.json 與 cf.yml 的內容、關口健康探測、日誌格式。
/// 規格 docs/specs/183-chatgpt-hands/（接口約定 v2 §1、§2、§10，v3 V8；威脅模型 T1、T8、T10、T13）。
enum HandsGatewayLaunch {
    /// 接口約定 v2 §10：手腳的資料都在 `<App Support>/TATWO OS Hands/`。
    static let rootFolderName = "TATWO OS Hands"
    /// 接口約定 v2 §1：關口身分不綁對話（App 對 `.externalAI` 一律看 grant、忽略 thread）。登記 API 還要一個值，就給固定的全零。
    static let unboundThread = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    /// OpenAI 公布的 ChatGPT 外掛來源 IP（T1）。App 每天抓一次，驗過格式才寫進關口的 config.json。
    static let connectorsURL = URL(string: "https://openai.com/chatgpt-connectors.json")!
    static let staleAfter: TimeInterval = 7 * 24 * 3600
    static let refreshEvery: TimeInterval = 24 * 3600
    static let ancestorSlots = 24
    /// 太寬的網段（例如 0.0.0.0/0）視為清單被竄改，整份不用（關口 gateway.mjs 用同樣的下限）。
    static let minPrefixV4 = 12
    static let minPrefixV6 = 32
    static let maxRanges = 5000
    static let sandboxExec = "/usr/bin/sandbox-exec"
    static let shell = "/bin/sh"
    /// 看門程式的 $0：ps 看得出是我們的（recordedCommandIsOurs 認 "chatgpt-hands"）。
    static let guardName = "chatgpt-hands/tunnel-guard"
    static let tokenFilePrefix = ".tunnel-token-"
    /// 關口發現自己的 socket 被換掉或刪掉時的結束碼（gateway.mjs 的 TAMPER_EXIT_CODE；W183 R2b）。
    static let tamperExitCode: Int32 = 3

    enum Failure: Error, Equatable {
        case invalidList, tooBroad, tooMany, invalidHost, invalidPath, pathTooDeep, socketPathTooLong, unsafeDirectory
    }

    // MARK: 路徑（接口約定 v2 §10）
    struct Paths: Equatable {
        /// `<App Support>/TATWO OS Hands`
        let root: URL
        /// App 端（R1）：settings.json 與 OAuth 狀態。關口讀不到（gateway.sb 沒開）。
        var appDir: URL { root.appendingPathComponent("app", isDirectory: true) }
        var settingsFile: URL { appDir.appendingPathComponent("settings.json") }
        /// 關口端：App 寫、關口唯讀的 config.json；socket 資料夾由 App 預建（0700）。
        var gatewayDir: URL { root.appendingPathComponent("gateway", isDirectory: true) }
        var gatewayConfig: URL { gatewayDir.appendingPathComponent("config.json") }
        var socketDir: URL { gatewayDir.appendingPathComponent("sock", isDirectory: true) }
        var socket: URL { socketDir.appendingPathComponent("gw.sock") }
        /// cloudflared：獨立 HOME、App 產生的設定（不讀 ~/.cloudflared，T13）。
        var cloudflaredConfig: URL { root.appendingPathComponent("cf.yml") }
        var cloudflaredHome: URL { root.appendingPathComponent("cf-home", isDirectory: true) }
        /// 關口的請求日誌（關口印到 stdout，App 檢查格式後才寫）。
        var logDir: URL { root.appendingPathComponent("logs", isDirectory: true) }
        var logFile: URL { logDir.appendingPathComponent("gateway.log") }
        /// 通道 token 檔：每次啟動一個新名字（0600、O_EXCL|O_NOFOLLOW），cloudflared 讀完、連上就刪（T10「用完刪」）。
        func newTunnelTokenFile() -> URL {
            cloudflaredHome.appendingPathComponent(HandsGatewayLaunch.tokenFilePrefix + UUID().uuidString.lowercased())
        }

        /// 預設 `~/Library/Application Support/TATWO OS Hands`（staging 的 CFFIXED_USER_HOME 會把它帶到 staging 的家目錄；staging 本來就不啟動）。
        static func defaultRoot() -> URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(HandsGatewayLaunch.rootFolderName, isDirectory: true)
        }
    }

    /// realpath(3)：Seatbelt 比對的是真實路徑（/tmp 其實是 /private/tmp）。檔案還不存在就解析上層再接檔名。
    static func realPath(_ path: String) -> String? {
        if let resolved = realpath(path, nil) { defer { free(resolved) }; return String(cString: resolved) }
        let failure = errno
        let url = URL(fileURLWithPath: path)
        guard failure == ENOENT, url.pathComponents.count > 1,
              let parent = realpath(url.deletingLastPathComponent().path, nil) else { return nil }
        defer { free(parent) }
        return URL(fileURLWithPath: String(cString: parent)).appendingPathComponent(url.lastPathComponent).path
    }

    /// 帳號真正的家目錄（不看 HOME 環境變數）：cloudflared 的規則要擋的是真的家目錄。
    static func accountHome() -> String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    /// Homebrew 的 Node 會載入 opt/ 底下的程式庫；內附的 Node 是單一執行檔，只開它那一層。
    static func nodeRoot(forRealNode node: String) -> String {
        for prefix in ["/opt/homebrew", "/usr/local"] where node.hasPrefix(prefix + "/") { return prefix }
        return URL(fileURLWithPath: node).deletingLastPathComponent().path
    }

    /// 使用者已裝的 cloudflared（先用 Homebrew 版；R3 會做下載）。找不到回 nil＝「還沒安裝」。
    static func findCloudflared(candidates: [String] = ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"]) -> URL? {
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            if let real = realPath(candidate) { return URL(fileURLWithPath: real) }
        }
        return nil
    }

    /// 自己的資料夾：沒有就建（0700）；有就必須是真的資料夾（不是捷徑）、屬於自己，權限收回 0700。
    static func ensurePrivateDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw Failure.unsafeDirectory }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard lstat(url.path, &info) == 0 else { throw Failure.unsafeDirectory }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { throw Failure.unsafeDirectory }
        if (info.st_mode & 0o077) != 0 { guard chmod(url.path, 0o700) == 0 else { throw Failure.unsafeDirectory } }
    }

    /// 0600 原子寫入：O_EXCL|O_NOFOLLOW 建暫存檔再改名（照 BotLibrary.writeText）。
    static func writePrivate(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unsafeDirectory }
        var ok = true
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written <= 0 { if errno == EINTR { continue }; ok = false; break }
                offset += written
            }
        }
        if fsync(fd) != 0 { ok = false }
        close(fd)
        guard ok, rename(temp.path, url.path) == 0 else { unlink(temp.path); throw Failure.unsafeDirectory }
    }

    /// 讀小檔（不跟隨捷徑、只收一般檔案、有上限）。
    static func readPrivate(_ url: URL, limit: Int = 1 << 20) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= limit else { return nil }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, Int(info.st_size)) }
        return count == Int(info.st_size) ? data : nil
    }

    // MARK: 設定（R1 寫 <App Support>/TATWO OS Hands/app/settings.json，這裡只讀需要的欄位）
    struct Settings: Equatable {
        var enabled: Bool
        var publicHost: String?
        var hostDeviceID: String?
        var fingerprint: String { "\(enabled)|\(publicHost ?? "")|\(hostDeviceID ?? "")" }
    }

    static func readSettings(_ url: URL) -> Settings? {
        guard let data = readPrivate(url, limit: 256 * 1024),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // W183 R3b 審查：關掉時設定檔存不進去＝記憶體強制關閉（HandsForcedOff），關口一樣當成關的。
        return Settings(enabled: object["enabled"] as? Bool == true && !HandsForcedOff.shared.contains(url),
                        publicHost: object["public_host"] as? String,
                        hostDeviceID: object["host_device_id"] as? String)
    }

    // MARK: 主機名與 IP 清單
    static func validHost(_ value: String?) -> String? {
        guard var host = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !host.isEmpty, host.count <= 253 else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return nil }
        for (index, label) in labels.enumerated() {
            guard (1...63).contains(label.count), label.first != "-", label.last != "-",
                  label.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" }) else { return nil }
            if index == labels.count - 1, let first = label.first, !(first >= "a" && first <= "z") { return nil }
        }
        return host
    }

    /// "a.b.c.d/n" 或 IPv6 "x::/n"：位址要合法、前綴在範圍內、不能太寬。回傳去空白後的原字串。
    static func validRange(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespaces)
        let pieces = text.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, let prefix = Int(pieces[1]), pieces[1].count <= 3, pieces[1].allSatisfy(\.isNumber) else { return nil }
        let address = String(pieces[0])
        var v4 = in_addr(), v6 = in6_addr()
        if !address.contains(":"), inet_pton(AF_INET, address, &v4) == 1 {
            return (minPrefixV4...32).contains(prefix) ? text : nil
        }
        if address.contains(":"), !address.contains("%"), inet_pton(AF_INET6, address, &v6) == 1 {
            return (minPrefixV6...128).contains(prefix) ? text : nil
        }
        return nil
    }

    /// chatgpt-connectors.json：{ "creationTime": …, "prefixes": [ { "ipv4Prefix": "…" } | { "ipv6Prefix": "…" } ] }。
    /// 任何一筆不合法或太寬＝整份不收（保留舊清單，舊的過期就由關口全拒）。
    static func parseConnectorRanges(_ data: Data) throws -> [String] {
        guard data.count <= 1 << 20,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prefixes = object["prefixes"] as? [[String: Any]], !prefixes.isEmpty else { throw Failure.invalidList }
        guard prefixes.count <= maxRanges else { throw Failure.tooMany }
        var ranges: [String] = []
        var seen = Set<String>()
        for item in prefixes {
            guard let raw = (item["ipv4Prefix"] ?? item["ipv6Prefix"]) as? String else { throw Failure.invalidList }
            guard let range = validRange(raw) else {
                let pieces = raw.split(separator: "/")
                if pieces.count == 2, let prefix = Int(pieces[1]), prefix >= 0, prefix < (raw.contains(":") ? minPrefixV6 : minPrefixV4) { throw Failure.tooBroad }
                throw Failure.invalidList
            }
            if seen.insert(range).inserted { ranges.append(range) }
        }
        return ranges
    }

    /// 清單缺、過期 7 天、時間在未來超過 1 小時＝過期（關口全拒）。
    static func isStale(_ fetchedAt: Date?, now: Date = Date()) -> Bool {
        guard let fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) > staleAfter || fetchedAt.timeIntervalSince(now) > 3600
    }

    // MARK: 關口的 config.json（App 寫，關口唯讀；socket 路徑、public_host、IP 清單與時間。接口約定 v2 §10）
    struct GatewayDocument: Codable, Equatable {
        var socketPath: String
        var publicHost: String
        var allowedIPRanges: [String]
        var rangesFetchedAt: String?
        var lastAttemptAt: String?
        var lastError: String?

        enum CodingKeys: String, CodingKey {
            case socketPath = "socket_path", publicHost = "public_host", allowedIPRanges = "allowed_ip_ranges"
            case rangesFetchedAt = "ranges_fetched_at", lastAttemptAt = "last_attempt_at", lastError = "last_error"
        }
        var fetchedDate: Date? { rangesFetchedAt.flatMap { ISO8601DateFormatter().date(from: $0) } }
    }

    static func readGatewayDocument(_ url: URL) -> GatewayDocument? {
        readPrivate(url).flatMap { try? JSONDecoder().decode(GatewayDocument.self, from: $0) }
    }

    static func writeGatewayDocument(_ document: GatewayDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try writePrivate(try encoder.encode(document), to: url)
    }

    static func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    // MARK: cloudflared 設定（本機設定＋unix socket 轉發；不讀 ~/.cloudflared，T13）
    static func cloudflaredConfig(publicHost: String, socket: String) throws -> String {
        guard let host = validHost(publicHost), host == publicHost.lowercased() else { throw Failure.invalidHost }
        guard socket.hasPrefix("/"), socket.utf8.count < 104,
              !socket.unicodeScalars.contains(where: { $0.value < 0x20 || $0 == "\"" || $0 == "\\" || $0.value == 0x7f }) else { throw Failure.invalidPath }
        return """
        # TATWO OS ChatGPT 手腳：App 每次啟動關口時重寫，請勿手改。只轉到關口的 unix socket，其他一律 404。
        ingress:
          - hostname: "\(host)"
            service: "unix:\(socket)"
          - service: http_status:404
        metrics: 127.0.0.1:0
        no-autoupdate: true

        """
    }

    /// token 不進 argv、也不放環境變數（非系統程式的環境，同一個使用者的任何行程都能用 KERN_PROCARGS2 讀到）；
    /// 只給 cf-home 裡那個 0600 檔的路徑（cloudflared 2024 年起支援 --token-file）。
    static func cloudflaredArguments(config: URL, tokenFile: URL) -> [String] {
        ["tunnel", "--no-autoupdate", "--config", config.path, "run", "--token-file", tokenFile.path]
    }

    /// cloudflared（與它的看門程式）只拿到：自己的 HOME、最小 PATH。沒有任何秘密。
    static func cloudflaredEnvironment(paths: Paths) -> [String: String] {
        ["HOME": paths.cloudflaredHome.path, "PATH": "/usr/bin:/bin"]
    }

    /// 寫通道 token 檔：只建新檔（O_CREAT|O_EXCL|O_NOFOLLOW，0600），已存在或是捷徑一律失敗；寫不完整就刪掉。
    static func writeTokenFile(_ token: String, to url: URL) throws {
        guard url.lastPathComponent.hasPrefix(tokenFilePrefix) else { throw Failure.invalidPath }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unsafeDirectory }
        var ok = fchmod(fd, 0o600) == 0
        let bytes = Array(token.utf8)
        var offset = 0
        while ok, offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if written <= 0 { if errno == EINTR { continue }; ok = false; break }
            offset += written
        }
        close(fd)
        guard ok else { unlink(url.path); throw Failure.unsafeDirectory }
    }

    /// 刪 token 檔（unlink 不跟隨捷徑）。
    static func removeTokenFile(_ url: URL) { unlink(url.path) }

    /// 清掉 cf-home 裡留下的 token 檔（上次斷電、當機）。只看這個資料夾第一層、只刪名字對得上的。
    static func removeStaleTokenFiles(in directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(tokenFilePrefix) { unlink(directory.appendingPathComponent(name).path) }
    }

    static func tokenFiles(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix(tokenFilePrefix) }
    }

    /// 關口只拿到：最小 PATH、HOME（指到它唯讀的設定資料夾；它讀不了也寫不了那裡的其他東西）、語系、os.sock 位置。
    /// 沒有任何秘密（沒有 TUNNEL_TOKEN、沒有 Cloudflare 憑證、沒有 OAuth 狀態）、沒有 App 的其他環境變數。
    static func gatewayEnvironment(paths: Paths, osSocket: String) -> [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": paths.gatewayDir.path, "LANG": "en_US.UTF-8", "TATWO2_OS_SOCKET": osSocket]
    }

    static func validToken(_ token: String) -> Bool {
        (16...8192).contains(token.utf8.count) && token.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7f }
    }

    // MARK: Seatbelt 參數（每個路徑都 realpath 後用 -D 傳，不拼進規則文字）
    struct Launch: Equatable {
        let executable: String
        let arguments: [String]
    }

    static func ancestors(of paths: [String]) -> [String] {
        var out = Set<String>()
        for path in paths {
            var current = URL(fileURLWithPath: path).deletingLastPathComponent().path
            while current != "/" && !current.isEmpty {
                out.insert(current)
                current = URL(fileURLWithPath: current).deletingLastPathComponent().path
            }
        }
        return out.sorted()
    }

    private static func checkParameter(_ value: String) throws {
        guard value.hasPrefix("/"), !value.contains("\0"), !value.contains("\n") else { throw Failure.invalidPath }
    }

    /// `sandbox-exec -p <gateway.sb> -D … <node> <gateway.mjs> <config.json>`（沒有 supervisor；sandbox-exec 以 exec 換成 Node，
    /// pid 不變，登記的就是這個 pid）。傳進來的路徑都要是 realpath。
    static func gatewayLaunch(profile: String, node: String, programDir: String, paths: Paths, osSocket: String) throws -> Launch {
        guard paths.socket.path.utf8.count < 104, osSocket.utf8.count < 104 else { throw Failure.socketPathTooLong }
        let params: [(String, String)] = [
            ("NODE_BIN", node), ("NODE_ROOT", nodeRoot(forRealNode: node)), ("PROGRAM_DIR", programDir),
            ("CONFIG", paths.gatewayConfig.path), ("SOCKET", paths.socket.path), ("OS_SOCKET", osSocket),
        ]
        let parents = ancestors(of: [node, nodeRoot(forRealNode: node) + "/x", programDir + "/x", paths.gatewayConfig.path,
                                     paths.socket.path, osSocket])
        guard parents.count <= ancestorSlots else { throw Failure.pathTooDeep }
        var arguments = ["-p", profile]
        for (key, value) in params { try checkParameter(value); arguments += ["-D", "\(key)=\(value)"] }
        for index in 0..<ancestorSlots { arguments += ["-D", "ANC_\(index)=\(index < parents.count ? parents[index] : "/")"] }
        arguments += [node, URL(fileURLWithPath: programDir).appendingPathComponent("gateway.mjs").path, paths.gatewayConfig.path]
        return Launch(executable: sandboxExec, arguments: arguments)
    }

    /// 子行程的回呼：開行程時就裝好（W183 R2b：開好再設會掉最早的輸出與結束通知）。
    struct Handlers {
        var stdout: ((Data) -> Void)?
        var stderr: ((Data) -> Void)?
        var exit: (() -> Void)?
    }

    /// 開關口：新行程群組、`POSIX_SPAWN_CLOEXEC_DEFAULT`（只留 stdin／stdout／stderr，App 的其他 fd 一個都不給，v3 V8）。
    /// 服務與自測都走這一個，自測驗到的就是服務實際用的開法。
    static func spawnGateway(_ launch: Launch, paths: Paths, osSocket: String, handlers: Handlers = Handlers()) throws -> SidecarGroupedProcess {
        try SidecarGroupedProcess.spawn(executable: launch.executable, arguments: launch.arguments,
                                        environment: gatewayEnvironment(paths: paths, osSocket: osSocket),
                                        currentDirectory: paths.socketDir.path, closeInheritedDescriptors: true,
                                        onStdout: handlers.stdout, onStderr: handlers.stderr, onExit: handlers.exit)
    }

    /// 開 cloudflared（外面包看門程式）：自己一組、同樣 `POSIX_SPAWN_CLOEXEC_DEFAULT`、放棄責任行程（不沿用 App 的 TCC 權限）。
    static func spawnTunnel(_ launch: Launch, paths: Paths, handlers: Handlers = Handlers()) throws -> SidecarGroupedProcess {
        try SidecarGroupedProcess.spawn(executable: launch.executable, arguments: launch.arguments,
                                        environment: cloudflaredEnvironment(paths: paths),
                                        currentDirectory: paths.cloudflaredHome.path, closeInheritedDescriptors: true, disclaimResponsibility: true,
                                        onStdout: handlers.stdout, onStderr: handlers.stderr, onExit: handlers.exit)
    }

    /// `/bin/sh -c <tunnel-guard.sh 全文> chatgpt-hands/tunnel-guard <token 檔> sandbox-exec -p <cloudflared.sb> -D … <cloudflared>
    ///  tunnel --no-autoupdate --config <cf.yml> run --token-file <token 檔>`。
    /// 看門程式在沙盒外、和 cloudflared 同一組：App 當掉（stdin EOF）或 cloudflared 停了都整組收掉，並刪 token 檔。
    /// 用 `-c` 帶全文而不是給檔案路徑：這組放棄了責任行程，/bin/sh 不沿用 App 的權限，讀不到放在外接卷等受保護位置的腳本檔。
    /// 測試可在 cloudflared 的參數前面插一段（`programPrefix`，例如用 Node 扮演 cloudflared），規則與參數照舊。
    static func cloudflaredLaunch(profile: String, guardScript: String, cloudflared: String, paths: Paths, tokenFile: URL,
                                  userHome: String, programPrefix: [String]? = nil) throws -> Launch {
        let params: [(String, String)] = [
            ("CF_BIN", cloudflared), ("CF_HOME", paths.cloudflaredHome.path), ("CF_CONFIG", paths.cloudflaredConfig.path),
            ("GW_SOCKET", paths.socket.path), ("USER_HOME", userHome), ("HANDS_ROOT", paths.root.path),
        ]
        guard !guardScript.isEmpty, !guardScript.contains("\0") else { throw Failure.invalidPath }
        try checkParameter(tokenFile.path)
        guard tokenFile.deletingLastPathComponent().path == paths.cloudflaredHome.path,
              tokenFile.lastPathComponent.hasPrefix(tokenFilePrefix) else { throw Failure.invalidPath }
        var arguments = ["-c", guardScript, guardName, tokenFile.path, sandboxExec, "-p", profile]
        for (key, value) in params { try checkParameter(value); arguments += ["-D", "\(key)=\(value)"] }
        arguments += [cloudflared] + (programPrefix ?? []) + cloudflaredArguments(config: paths.cloudflaredConfig, tokenFile: tokenFile)
        return Launch(executable: shell, arguments: arguments)
    }
}

extension HandsGatewayLaunch {
    // MARK: 關口的 socket（App 端檢查：啟動前、健康探測）
    enum SocketState: Equatable { case absent, stale, live, occupied }

    /// 啟動前看 socket 路徑：沒有／留下的死 socket（可以清）／有人在聽（另一個關口還在）／不是 socket（不動它）。
    static func socketState(_ path: String) -> SocketState {
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT ? .absent : .occupied }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { return .occupied }
        guard let fd = connectUnix(path, timeout: 1) else { return .stale }
        close(fd)
        return .live
    }

    /// 連 unix socket（不跟隨也不建立任何檔案）；成功回 fd（CLOEXEC），呼叫端負責關。
    static func connectUnix(_ path: String, timeout: Int) -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = path.withCString { source in withUnsafeMutablePointer(to: &address.sun_path.0) { strlcpy($0, source, capacity) } }
        guard copied < capacity else { close(fd); return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { close(fd); return nil }
        var limit = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// 關口健康（v3 V8「關口健康 → 最後才起 cloudflared」）：連上 socket、送一個沒有來源 IP 的請求，
    /// 讀得到 HTTP 狀態行（關口會回 403）就算在服務；同時用 LOCAL_PEERPID 確認聽這個 socket 的正是我們登記的那個 pid。
    static func probeGateway(socketPath: String, timeout: Int = 3) -> (status: Int, peer: pid_t)? {
        guard let fd = connectUnix(socketPath, timeout: timeout) else { return nil }
        defer { close(fd) }
        let request = Array("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8)
        guard request.withUnsafeBufferPointer({ Darwin.write(fd, $0.baseAddress, $0.count) }) == request.count else { return nil }
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while response.count < 64 {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            response.append(contentsOf: chunk.prefix(count))
        }
        let parts = String(decoding: response.prefix(32), as: UTF8.self).split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]), let peer = OSSocketCaller.peerPID(fd) else { return nil }
        return (status, peer)
    }

    /// 聽這個 socket 的是哪個 pid（W183 R2b：App 定時確認關口的 socket 沒被同一個使用者的其他程式換掉）。
    /// 只連上、讀 LOCAL_PEERPID 就關，不送任何請求（關口不會有請求紀錄）。連不上回 nil。
    static func socketPeer(socketPath: String, timeout: Int = 1) -> pid_t? {
        guard let fd = connectUnix(socketPath, timeout: timeout) else { return nil }
        defer { close(fd) }
        return OSSocketCaller.peerPID(fd)
    }

    // MARK: 關口日誌（關口印到 stdout 的 {"ev":"req",…}；逐欄檢查格式才寫，T10）
    static let logLimit = 512 * 1024

    static func logLine(_ object: [String: Any], at date: Date) -> String? {
        guard object["ev"] as? String == "req" else { return nil }
        func matches(_ value: Any?, _ pattern: String) -> String? {
            guard let text = value as? String, text.range(of: pattern, options: .regularExpression) != nil else { return nil }
            return text
        }
        let method = matches(object["m"], #"^[A-Z]{3,7}$"#) ?? "OTHER"
        let route = matches(object["r"], #"^[a-z_]{1,16}$"#) ?? "other"
        let status = (object["s"] as? Int).flatMap { (100...599).contains($0) ? $0 : nil } ?? 0
        let millis = (object["ms"] as? Int).map { min(max($0, 0), 9_999_999) } ?? 0
        let rpc = matches(object["rpc"], #"^[a-z/]{1,40}$"#).map { " \($0)" } ?? ""
        return "\(timestamp(date)) \(method) \(route) \(status) \(millis)ms\(rpc)\n"
    }

    /// 0600、不跟隨捷徑；超過 512 KiB 換檔（留一份 .1）。
    static func appendLog(_ line: String, to url: URL) {
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_size > logLimit {
            _ = rename(url.path, url.path + ".1")
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
}

/// 通道 token 從哪裡拿（R3 接上真的 Cloudflare 帳號；自測用記憶體假資料，不碰真的鑰匙圈）。
protocol HandsTunnelTokenStore {
    func read() throws -> String?
}

/// 預設：鑰匙圈 generic password（service `tatwo2-cloudflare-tunnel`、account `tunnel`）。只讀、不跳授權框；
/// 寫入由 R3 的環境登入負責（ThisDeviceOnly、不給其他 App 讀）。值只寫進 cf-home 裡用完就刪的 0600 檔。
struct HandsTunnelKeychain: HandsTunnelTokenStore {
    static let service = "tatwo2-cloudflare-tunnel"
    var account = "tunnel"
    enum Failure: Error { case locked, unreadable }

    func read() throws -> String? {
        // W183 R3：R3 先寫 data-protection 鑰匙圈（ThisDeviceOnly 只在那裡有效），App 沒有權限（-34018）才退回登入鑰匙圈：兩邊都看。
        for dataProtection in [true, false] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            ]
            if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound || status == -34018 { continue }
            if status == errSecInteractionNotAllowed || status == errSecAuthFailed { throw Failure.locked }
            guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw Failure.unreadable }
            DeviceOnlyKeychain.harden(query)
            return value
        }
        return nil
    }
}
