import CryptoKit
import Darwin
import Foundation

// W183 R3：標準設定流程用到的 cloudflared（威脅模型 T10、T13；接口約定 v2 §10）。
//
// 1. 找：**只用**我們自己下載、驗過雜湊的那一份（W183 R3 審查：Homebrew 的路徑同一個使用者的任何程式都改得到，
//    只看路徑、可不可執行就把授權憑證交給它＝繞過固定版本的雜湊；所以不再用 Homebrew 版）。
// 2. 下載：固定版本、固定雜湊（壓縮檔與解開後的執行檔各一個），放 `<App Support>/TATWO OS Hands/bin/`；不自動更新。
//    雜湊對不上一律不用（也不留下檔案）。只從 GitHub 的 release 網址下載，轉址只跟到 GitHub 自己的下載主機。
//    壓縮檔讀進記憶體一次：驗雜湊與交給 tar（stdin）解開的是同一份位元組，不依路徑重開。
//    殘餘（寫明、不宣稱已涵蓋）：執行時仍是依路徑開 bin/cloudflared。每次開指令前都重驗雜湊，但「驗完到 exec」之間，
//    同一個使用者身分、改得到 `<App Support>` 的程式仍能換掉它（macOS 沒有對任意執行檔綁定內容的 exec）；這一類程式本來就能改 App 的資料。
// 3. 跑設定指令（login／create／route／token）：獨立 HOME（`<Hands>/cf-setup`）、明確 --config、最小環境（PATH 指到空資料夾）、
//    不繼承 App 的 fd、放棄責任行程；外面包看門程式（沙盒外的 /bin/sh：umask 077；App 當掉＝stdin EOF → 收掉 cloudflared、
//    等它真的結束、刪暫存憑證與授權檔）；再包一層 Seatbelt：**先全拒寫**、只開設定家目錄；只准執行 cloudflared 本身、不准 fork；
//    對外只開 443 與 DNS、不准連本機服務與其他 unix socket；家目錄、手腳資料夾的其他地方、外接卷讀不到；不准送 Apple Event。
//    秘密不進 argv、不進環境：憑證只以 0600 暫存檔交給 `--origincert`，用完就刪。

enum HandsCloudflared {
    static let pinnedVersion = "2026.9.1"

    struct Pin: Equatable, Sendable {
        let arch: String
        let url: URL
        /// 壓縮檔（.tgz）的 sha256，下載完、解開前先驗。
        let archiveSHA256: String
        let archiveBytes: Int
        /// 解開後的 cloudflared 執行檔的 sha256（Cloudflare release 說明裡公布的那個）；裝好後每次使用前再驗。
        let binarySHA256: String
    }

    /// 2026.9.1（2026-09-11 發布）。兩個雜湊都在主導的機器上實際下載核對過：壓縮檔＝GitHub 算的 digest，執行檔＝release 說明。
    static let pins: [String: Pin] = [
        "arm64": Pin(arch: "arm64",
                     url: URL(string: "https://github.com/cloudflare/cloudflared/releases/download/2026.9.1/cloudflared-darwin-arm64.tgz")!,
                     archiveSHA256: "c27ab8fd0aa489449e3d201eb02f957ef460a13b613662928b1b23394bf1bcfe", archiveBytes: 19_217_478,
                     binarySHA256: "9a0b19f67dc7a3011bc6b972c7ce06a5fcea8784ac6bd599ffa382ea4aeb5a6e"),
        "x86_64": Pin(arch: "x86_64",
                      url: URL(string: "https://github.com/cloudflare/cloudflared/releases/download/2026.9.1/cloudflared-darwin-amd64.tgz")!,
                      archiveSHA256: "ff0d3b51d5ff70eceef89d6b32145fee985018a2174596a5dbe405e2766e2ac4", archiveBytes: 21_118_723,
                      binarySHA256: "1ea07ae775b03236bd6be18ca1848d6bdc4af2f4f3bce398823b5a36e5761b75"),
    ]

    static var currentArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// 下載只跟到這些主機（GitHub release 會轉到它自己的下載主機）。
    static let downloadHosts: Set<String> = ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]

    /// W183 R3 審查：只剩「我們下載、驗過雜湊的」這一種（不再接受 Homebrew 版）。
    enum Source: String, Codable, Sendable { case downloaded }

    struct Location: Equatable, Sendable {
        let url: URL
        let source: Source
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case unsupportedArch, download, size, hash, extract, binaryHash, install, isolated
        var description: String {
            switch self {
            case .unsupportedArch: "這台 Mac 的處理器沒有對應的 cloudflared 版本"
            case .download: "下載 cloudflared 失敗（網路不通或 GitHub 暫時連不上）；稍後按「重試」"
            case .size, .hash: "下載到的 cloudflared 跟固定版本的雜湊對不上，已丟掉沒有使用"
            case .extract: "解開 cloudflared 失敗"
            case .binaryHash: "解開後的 cloudflared 跟固定版本的雜湊對不上，已丟掉沒有使用"
            case .install: "放不進 TATWO 的資料夾（權限或空間不足）"
            case .isolated: HandsSetup.isolatedMessage
            }
        }
    }

    static func binDirectory(root: URL) -> URL { root.appendingPathComponent("bin", isDirectory: true) }
    static func installedBinary(root: URL) -> URL { binDirectory(root: root).appendingPathComponent("cloudflared") }

    static func sha256(ofFile url: URL, limit: Int = 256 * 1024 * 1024) -> String? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int(info.st_size) <= limit else { return nil }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; return nil }
            if count == 0 { break }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 我們自己下載的那份：是一般檔（不是捷徑）、屬於自己、可執行、雜湊等於固定版本。任何一項不對就當作沒有。
    static func verifiedInstalled(root: URL, pin: Pin? = pins[currentArch]) -> URL? {
        guard let pin else { return nil }
        let binary = installedBinary(root: root)
        var info = stat()
        guard lstat(binary.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              (info.st_mode & 0o022) == 0, (info.st_mode & 0o100) != 0,
              sha256(ofFile: binary) == pin.binarySHA256 else { return nil }
        return binary
    }

    /// 只用我們下載、驗過雜湊的那份（W183 R3 審查：Homebrew 版不再用；每次呼叫都重驗雜湊）。
    static func locate(root: URL) -> Location? {
        verifiedInstalled(root: root).map { Location(url: $0, source: .downloaded) }
    }

    static func sha256(of data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// 壓縮檔整份讀進記憶體（不跟隨捷徑、一般檔、大小要剛好）：之後驗雜湊與解開都用這一份位元組，不再依路徑重開。
    static func readArchive(_ url: URL, expectedBytes: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.download }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.download }
        guard Int(info.st_size) == expectedBytes, expectedBytes > 0 else { throw Failure.size }
        var data = Data(count: expectedBytes)
        let complete = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < expectedBytes {
                let count = Darwin.read(fd, base.advanced(by: offset), expectedBytes - offset)
                if count < 0 { if errno == EINTR { continue }; return false }
                if count == 0 { return false }
                offset += count
            }
            return true
        }
        guard complete else { throw Failure.download }
        return data
    }

    /// 下載好的壓縮檔 → 讀進記憶體、驗壓縮檔雜湊 → 同一份位元組經 stdin 交給 /usr/bin/tar，只解 `cloudflared` 一個檔到暫存資料夾 →
    /// 驗是一般檔、驗執行檔雜湊 → 0755 → 原子改名進 bin/。任何一步失敗都把暫存的東西刪掉。
    static func install(archive: URL, root: URL, pin: Pin) throws -> URL {
        let data = try readArchive(archive, expectedBytes: pin.archiveBytes)
        guard sha256(of: data) == pin.archiveSHA256 else { throw Failure.hash }
        let bin = binDirectory(root: root)
        do { try HandsFiles.ensureDirectory(root); try HandsFiles.ensureDirectory(bin) } catch { throw Failure.install }
        let staging = bin.appendingPathComponent(".extract-" + UUID().uuidString, isDirectory: true)
        do { try HandsFiles.ensureDirectory(staging) } catch { throw Failure.install }
        defer { try? FileManager.default.removeItem(at: staging) }
        let input = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", "-", "-C", staging.path, "--no-same-owner", "cloudflared"]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C"]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw Failure.extract }
        try? input.fileHandleForReading.close()   // 只留 tar 那一端：tar 提早結束時寫入會拿到 EPIPE，不會卡住
        let writer = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(writer, F_SETNOSIGPIPE, 1)
        let written = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(writer, base.advanced(by: offset), buffer.count - offset)
                if count < 0 { if errno == EINTR { continue }; return false }
                offset += count
            }
            return true
        }
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        guard written, process.terminationStatus == 0 else { throw Failure.extract }
        let extracted = staging.appendingPathComponent("cloudflared")
        var info = stat()
        guard lstat(extracted.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.extract }
        guard sha256(ofFile: extracted) == pin.binarySHA256 else { throw Failure.binaryHash }
        guard chmod(extracted.path, 0o755) == 0, rename(extracted.path, installedBinary(root: root).path) == 0 else { throw Failure.install }
        return installedBinary(root: root)
    }

    /// 只從固定網址下載（ephemeral、不帶 cookie、轉址只跟到 GitHub 的下載主機、大小有上限）。完成後呼叫 install。
    static func download(pin: Pin, root: URL, completion: @escaping (Result<URL, Failure>) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: DownloadGuard(), delegateQueue: nil)
        var request = URLRequest(url: pin.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpShouldHandleCookies = false
        session.downloadTask(with: request) { location, response, error in
            defer { session.finishTasksAndInvalidate() }
            guard error == nil, let location, let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let host = http.url?.host, downloadHosts.contains(host) else {
                return completion(.failure(.download))
            }
            // 下載的暫存檔在這個回呼結束就會被刪：先搬到自己的資料夾（0700）。
            let bin = binDirectory(root: root)
            let kept = bin.appendingPathComponent(".download-" + UUID().uuidString + ".tgz")
            do {
                try HandsFiles.ensureDirectory(root); try HandsFiles.ensureDirectory(bin)
                try FileManager.default.moveItem(at: location, to: kept)
            } catch { return completion(.failure(.install)) }
            defer { unlink(kept.path) }
            do { completion(.success(try install(archive: kept, root: root, pin: pin))) }
            catch let failure as Failure { completion(.failure(failure)) }
            catch { completion(.failure(.install)) }
        }.resume()
    }

    private final class DownloadGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, url.scheme == "https", let host = url.host, downloadHosts.contains(host) else {
                return completionHandler(nil)
            }
            completionHandler(request)
        }
    }

    // MARK: - 授權憑證（cloudflared tunnel login 寫的 cert.pem）

    struct OriginCert: Equatable {
        let accountID: String
        let zoneID: String
        /// 只在記憶體裡用一次（查網域名稱）；不存、不印。
        let apiToken: String
        /// 原文（收進鑰匙圈）。
        let pem: String
    }

    /// cert.pem 裡的 `ARGO TUNNEL TOKEN` 區段：base64 的 JSON {zoneID, accountID, apiToken}。只取 id 與 token，格式不對回 nil。
    static func parseOriginCert(_ pem: String) -> OriginCert? {
        guard pem.utf8.count <= 64 * 1024,
              let begin = pem.range(of: "-----BEGIN ARGO TUNNEL TOKEN-----"),
              let end = pem.range(of: "-----END ARGO TUNNEL TOKEN-----", range: begin.upperBound..<pem.endIndex) else { return nil }
        let body = pem[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(body)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let zone = (object["zoneID"] as? String)?.lowercased(), let account = (object["accountID"] as? String)?.lowercased(),
              let token = object["apiToken"] as? String, !token.isEmpty, token.utf8.count <= 4096,
              CloudflareAccountsStore.validID(zone), CloudflareAccountsStore.validID(account) else { return nil }
        return OriginCert(accountID: account, zoneID: zone, apiToken: token, pem: pem)
    }

    /// 用授權裡的 token 查網域名稱與帳號名稱（只打 api.cloudflare.com、不跟隨轉址、不帶 cookie）。查不到回 nil（建通道時會從 DNS 結果補上）。
    static func lookupZone(zoneID: String, apiToken: String, completion: @escaping (_ domain: String?, _ accountName: String?) -> Void) {
        guard CloudflareAccountsStore.validID(zoneID), let url = URL(string: "https://api.cloudflare.com/client/v4/zones/\(zoneID)") else {
            return completion(nil, nil)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            guard error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200, let data, data.count <= 1 << 20,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["success"] as? Bool == true,
                  let result = object["result"] as? [String: Any] else { return completion(nil, nil) }
            let name = (result["name"] as? String).flatMap { HandsGatewayLaunch.validHost($0) }
            let account = ((result["account"] as? [String: Any])?["name"] as? String).map { String($0.filter { !$0.isNewline }.prefix(80)) }
            completion(name, account)
        }.resume()
    }

    // MARK: - W183 R6a：DNS 紀錄（固定子網域：確認新紀錄、刪 TATWO 自己建的那一筆舊紀錄）
    // 照 lookupZone：只打 api.cloudflare.com、ephemeral、不帶 cookie、不跟隨轉址；token 只在這次請求的記憶體裡；
    // 錯誤只回白名單分類（auth、not_found、rate_limited、network、api、malformed），不回原文。

    /// Cloudflare 上的一筆 DNS 紀錄（只拿要比對的欄位）。
    struct DNSRecord: Equatable, Sendable {
        let id: String
        let type: String
        let name: String
        let content: String
        /// W183 R6a 審查（GPT-6）：經過 Cloudflare 代理（橘雲）；通道的 CNAME 要是 true 外面才連得到。
        var proxied: Bool = false
    }

    enum DNSLookup: Equatable, Sendable {
        case records([DNSRecord])
        /// 錯誤分類（白名單）。
        case failure(String)
    }

    /// 通道的 CNAME 指向的地方（`<通道 id>.cfargotunnel.com`）。
    static let tunnelSuffix = ".cfargotunnel.com"
    static func tunnelTarget(_ tunnelID: String) -> String { tunnelID.lowercased() + tunnelSuffix }

    /// Cloudflare 紀錄 id（32 位十六進位）。
    static func validRecordID(_ value: String) -> Bool { value.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil }

    static func httpCategory(_ status: Int) -> String {
        switch status {
        case 401, 403: "auth"
        case 404: "not_found"
        case 429: "rate_limited"
        default: "api"
        }
    }

    static let dnsNameQuery = "name"

    /// 這個網域裡名字「完全等於」host 的紀錄（GET /zones/<zone>/dns_records?name=<host>）。
    static func dnsRecords(zoneID: String, name host: String, apiToken: String, completion: @escaping (DNSLookup) -> Void) {
        guard CloudflareAccountsStore.validID(zoneID), let name = HandsGatewayLaunch.validHost(host),
              var parts = URLComponents(string: "https://api.cloudflare.com/client/v4/zones/\(zoneID)/dns_records") else {
            return completion(.failure("invalid"))
        }
        parts.queryItems = [(dnsNameQuery, name), ("per_page", "50")].map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = parts.url else { return completion(.failure("invalid")) }
        apiRequest(url, method: "GET", apiToken: apiToken) { result in
            switch result {
            case .failure(let category): completion(.failure(category))
            case .success(let object):
                guard let rows = object["result"] as? [[String: Any]], rows.count <= 50 else { return completion(.failure("malformed")) }
                var records: [DNSRecord] = []
                for row in rows {
                    guard let id = (row["id"] as? String)?.lowercased(), validRecordID(id), let type = row["type"] as? String, type.count <= 16,
                          let recordName = (row["name"] as? String).flatMap({ HandsGatewayLaunch.validHost($0) }),
                          let content = row["content"] as? String, content.utf8.count <= 1024 else { return completion(.failure("malformed")) }
                    records.append(DNSRecord(id: id, type: type.uppercased(), name: recordName, content: content.lowercased(),
                                             proxied: row["proxied"] as? Bool ?? false))
                }
                completion(.records(records))
            }
        }
    }

    /// 刪一筆紀錄（DELETE /zones/<zone>/dns_records/<id>）。nil＝刪了；否則錯誤分類。
    static func deleteDNSRecord(zoneID: String, recordID: String, apiToken: String, completion: @escaping (String?) -> Void) {
        guard CloudflareAccountsStore.validID(zoneID), validRecordID(recordID),
              let url = URL(string: "https://api.cloudflare.com/client/v4/zones/\(zoneID)/dns_records/\(recordID)") else {
            return completion("invalid")
        }
        apiRequest(url, method: "DELETE", apiToken: apiToken) { result in
            switch result {
            case .failure(let category): completion(category)
            case .success: completion(nil)
            }
        }
    }

    /// W183 R6a 審查（Claude）：這個網域裡 CNAME 指到的通道 id（GET /zones/<zone>/dns_records?type=CNAME）。超過一頁、看不懂＝nil（不猜）。
    static func dnsTunnelTargets(zoneID: String, apiToken: String, completion: @escaping (Set<String>?) -> Void) {
        guard CloudflareAccountsStore.validID(zoneID),
              var parts = URLComponents(string: "https://api.cloudflare.com/client/v4/zones/\(zoneID)/dns_records") else { return completion(nil) }
        parts.queryItems = [("type", "CNAME"), ("per_page", "100")].map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = parts.url else { return completion(nil) }
        apiRequest(url, method: "GET", apiToken: apiToken) { result in
            guard case .success(let object) = result, let rows = object["result"] as? [[String: Any]], rows.count <= 100 else { return completion(nil) }
            if let info = object["result_info"] as? [String: Any], let pages = info["total_pages"] as? Int, pages > 1 { return completion(nil) }
            var ids = Set<String>()
            for row in rows {
                guard let content = (row["content"] as? String)?.lowercased(), content.utf8.count <= 1024 else { return completion(nil) }
                if content.hasSuffix(tunnelSuffix), let id = uuid(String(content.dropLast(tunnelSuffix.count))) { ids.insert(id) }
            }
            completion(ids)
        }
    }

    /// W183 R6a 審查（GPT-6「新網址確認通了實際只確認通道連上 Cloudflare」）：從外面連 `https://<host>/.well-known/oauth-protected-resource`——
    /// DNS 對、Cloudflare 的 TLS 對（系統驗憑證）、回的是 TATWO 的關口：這台不在 OpenAI 的 IP 清單裡，關口回 403 純文字 "forbidden"
    /// （Cloudflare 自己的錯誤頁是 HTML、5xx；DNS 還沒生效＝連不上）；萬一放行了，回的中介資料要是這個網址的 TATWO OS。
    /// 不帶任何 token 或 cookie、不跟隨轉址、ephemeral。nil＝確認了；否則分類（network、not_gateway、invalid）。
    static func probeGateway(host: String, completion: @escaping (String?) -> Void) {
        guard let name = HandsGatewayLaunch.validHost(host), let url = URL(string: "https://\(name)/.well-known/oauth-protected-resource") else {
            return completion("invalid")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            let verdict = error == nil ? gatewayVerdict(response as? HTTPURLResponse, data: data, host: name) : "network"
            // W183 R7a：系統這條路連不上（剛建的名字被系統的 DNS 快取記成「不存在」等）：改走公開 DNS＋直連（HandsPublicProbe.swift），
            // 判斷照同一個 gatewayVerdict；也確認不了＝照舊回分類（確認不了就不刪）。
            guard verdict == "network" else { return completion(verdict) }
            probeViaPublicDNS(host: name) { second in completion(second.map { "network+" + $0 }) }
        }.resume()
    }

    /// 回應是不是 TATWO 的關口（純判斷；自測用）。
    static func gatewayVerdict(_ http: HTTPURLResponse?, data: Data?, host: String) -> String? {
        guard let http else { return "network" }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let body = data.flatMap { $0.count <= 64 * 1024 ? $0 : nil } ?? Data()
        if http.statusCode == 403, type.hasPrefix("text/plain"), String(data: body, encoding: .utf8) == "forbidden" { return nil }
        if http.statusCode == 200, type.hasPrefix("application/json"),
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           object["resource"] as? String == "https://\(host)/mcp", object["resource_name"] as? String == "TATWO OS" { return nil }
        return "not_gateway"
    }

    private enum APIResult { case success([String: Any]), failure(String) }

    private static func apiRequest(_ url: URL, method: String, apiToken: String, completion: @escaping (APIResult) -> Void) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            guard error == nil, let http = response as? HTTPURLResponse else { return completion(.failure("network")) }
            guard http.statusCode == 200 else { return completion(.failure(httpCategory(http.statusCode))) }
            guard let data, data.count <= 1 << 20, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["success"] as? Bool == true else { return completion(.failure("malformed")) }
            completion(.success(object))
        }.resume()
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    // MARK: - 解析 cloudflared 的輸出（只拿需要的欄位；原文一行都不存）

    /// 授權網址：只收固定版本 cloudflared（pins：2026.9.1）`tunnel login` 印的那一種，其他一律不開。
    /// W183 R5b 審查（GPT-6）：原始碼 cmd/cloudflared/tunnel/login.go＋token/transfer.go（buildRequestURL，cli＝false）：
    /// `https://dash.cloudflare.com/argotunnel?aud=&callback=https%3A%2F%2Flogin.cloudflareaccess.org%2F<公鑰>`，
    /// 公鑰＝32 位元組的 base64url（44 字、結尾一個 =）。App 不帶 --fedramp、--loginURL、--callbackURL，所以：
    /// - 主機只有 dash.cloudflare.com、路徑正好 /argotunnel、沒有帳密、埠號、fragment；
    /// - 參數正好兩個、各一次：aud（空的）、callback；不認得的、重複的參數一律不收；
    /// - callback 自己也驗：https、主機正好 login.cloudflareaccess.org、沒有帳密、埠號、參數、fragment，路徑是 /<公鑰>。
    static func loginURL(in line: String) -> URL? {
        guard let range = line.range(of: #"https://[^\s"'<>]+"#, options: .regularExpression),
              let url = URL(string: String(line[range])), url.scheme == "https", url.host?.lowercased() == loginHost,
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              // URL.path 會吃掉結尾的「/」：用原樣的路徑比（/argotunnel/ 不算）。
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.percentEncodedPath == loginPath,
              parts.percentEncodedFragment == nil,
              let items = parts.queryItems, items.count == 2, Set(items.map(\.name)) == ["aud", "callback"],
              items.first(where: { $0.name == "aud" })?.value ?? "" == "",
              let raw = items.first(where: { $0.name == "callback" })?.value, validCallback(raw) else { return nil }
        return url
    }

    static let loginHost = "dash.cloudflare.com"
    static let loginPath = "/argotunnel"
    static let callbackHost = "login.cloudflareaccess.org"

    /// callback：https://login.cloudflareaccess.org/<32 位元組公鑰的 base64url>（cloudflared 的 Encrypter.PublicKey）。
    static func validCallback(_ raw: String) -> Bool {
        guard raw.utf8.count <= 128, let callback = URL(string: raw), callback.scheme == "https",
              callback.host?.lowercased() == callbackHost, callback.user == nil, callback.password == nil, callback.port == nil,
              callback.query == nil, callback.fragment == nil,
              let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false), parts.percentEncodedQuery == nil,
              parts.percentEncodedFragment == nil else { return false }
        return parts.percentEncodedPath.range(of: #"^/[A-Za-z0-9_-]{43}=$"#, options: .regularExpression) != nil
    }

    /// 任何 https 網址（用來分辨「給了一個不是 Cloudflare 的網址」）。
    static func anyURL(in line: String) -> Bool { line.range(of: #"https://[^\s"'<>]+"#, options: .regularExpression) != nil }

    static let uuidPattern = #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#

    /// W183 R5 審查（GPT-6）：`tunnel create --output json` 的通道 id——只看 stdout 的整段 JSON（log 在 stderr，不混進來），
    /// 必須是物件、id 合法、名字就是這次要建的那個；其他一律不認（寧可停下也不抓錯）。
    static func createdTunnelID(stdout: [String], name: String) -> String? {
        guard let object = stdoutJSON(stdout) as? [String: Any], object["name"] as? String == name else { return nil }
        return uuid(object["id"])
    }

    /// W183 R5 審查：用名字找通道的結果。只有 absent（看得懂、確定沒有）才准建新的；foreign（有同名的、但建立時間早於這一輪記名字）＝別人的，不認領。
    enum TunnelLookup: Equatable { case found(String), absent, foreign, ambiguous, malformed }

    /// `tunnel list --name <名字> --output json` 的 stdout：整段是 JSON 陣列、每一筆都是物件才算看得懂。
    /// 名字完全相同、還沒刪掉的：0 筆＝absent；1 筆＝建立時間不早於 `since`（容許 5 分鐘時差）才算 found，否則 foreign；多筆＝ambiguous。
    /// W183 R5 審查（GPT-6 複查）：每一筆都要有字串的 name 與 id，deleted_at 只能是沒有、null、零時間或看得懂的時間，否則整份 malformed；
    /// 建立時間要落在 [記名字前 5 分鐘, 現在＋5 分鐘] 才算這一輪建的，否則 foreign（呼叫端停下，不認領也不重建）。
    static func lookupTunnel(stdout: [String], name: String, since: Date, now: Date = Date()) -> TunnelLookup {
        guard let array = stdoutJSON(stdout) as? [Any] else { return .malformed }
        var matches: [[String: Any]] = []
        for item in array {
            guard let object = item as? [String: Any], let itemName = object["name"] as? String, object["id"] is String else { return .malformed }
            let active: Bool
            switch object["deleted_at"] {
            case nil, is NSNull: active = true
            case let text as String where text.isEmpty || text.hasPrefix("0001-"): active = true
            case let text as String where parseDate(text) != nil: active = false
            default: return .malformed
            }
            if itemName == name, active { matches.append(object) }
        }
        if matches.isEmpty { return .absent }
        guard matches.count == 1 else { return .ambiguous }
        guard let id = uuid(matches[0]["id"]), let text = matches[0]["created_at"] as? String, let created = parseDate(text) else { return .malformed }
        return created >= since.addingTimeInterval(-300) && created <= now.addingTimeInterval(300) ? .found(id) : .foreign
    }

    private static func uuid(_ value: Any?) -> String? {
        guard let id = (value as? String)?.lowercased(), UUID(uuidString: id) != nil else { return nil }
        return id
    }

    private static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// W183 R6a：「沒用到的 TATWO 通道」（`tunnel list --output json` 的 stdout）：名字 tatwo-hands- 開頭、還沒刪、
    /// 沒有任何連線、不是目前在用的（excludingIDs／excludingNames：狀態與帳號清單記的通道、建到一半記下的名字）。
    /// 看不懂（不是陣列、有一筆缺 id／name、connections 不是陣列）＝nil：整份不列，寧可不給刪。
    static let tatwoTunnelPrefix = "tatwo-hands-"

    static func unusedTatwoTunnels(stdout: [String], excludingIDs: Set<String>, excludingNames: Set<String>) -> [UnusedTunnel]? {
        guard let array = stdoutJSON(stdout) as? [Any] else { return nil }
        let excluded = Set(excludingIDs.map { $0.lowercased() })
        var out: [UnusedTunnel] = []
        for item in array {
            guard let object = item as? [String: Any], let name = object["name"] as? String, let id = uuid(object["id"]) else { return nil }
            let active: Bool
            switch object["deleted_at"] {
            case nil, is NSNull: active = true
            case let text as String where text.isEmpty || text.hasPrefix("0001-"): active = true
            case let text as String where parseDate(text) != nil: active = false
            default: return nil
            }
            guard let connections = object["connections"] as? [Any] else {
                if name.hasPrefix(tatwoTunnelPrefix) { return nil }   // 我們的名字卻看不出有沒有連線＝整份不列
                continue
            }
            guard active, name.hasPrefix(tatwoTunnelPrefix), name.count <= 64, connections.isEmpty,
                  !excluded.contains(id), !excludingNames.contains(name) else { continue }
            out.append(UnusedTunnel(id: id, name: name, createdAt: (object["created_at"] as? String).flatMap(parseDate)))
        }
        return out.sorted { $0.name < $1.name }
    }

    struct UnusedTunnel: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let createdAt: Date?
    }

    /// W183 R6a 審查：`tunnel list --output json` 的每一條（id、名字、還沒刪、連線數）。看不懂＝nil（整份不用）。
    struct ListedTunnel: Equatable, Sendable {
        let id: String
        let name: String
        let active: Bool
        let connections: Int
    }

    static func listedTunnels(stdout: [String]) -> [ListedTunnel]? {
        guard let array = stdoutJSON(stdout) as? [Any] else { return nil }
        var out: [ListedTunnel] = []
        for item in array {
            guard let object = item as? [String: Any], let name = object["name"] as? String, let id = uuid(object["id"]) else { return nil }
            let active: Bool
            switch object["deleted_at"] {
            case nil, is NSNull: active = true
            case let text as String where text.isEmpty || text.hasPrefix("0001-"): active = true
            case let text as String where parseDate(text) != nil: active = false
            default: return nil
            }
            out.append(ListedTunnel(id: id, name: name, active: active, connections: (object["connections"] as? [Any])?.count ?? 0))
        }
        return out
    }

    /// stdout 整段當一個 JSON（上限 1 MB、只解析一次）；看不懂回 nil。
    static func stdoutJSON(_ stdout: [String]) -> Any? {
        // 有 NUL 標記＝收的時候超過上限或整行太長被丟掉（LineBuffer／runCommand 補的）：整份作廢。
        guard !stdout.contains(where: { $0.contains("\u{0}") }) else { return nil }
        let text = stdout.joined(separator: "\n")
        guard !text.isEmpty, text.utf8.count <= 1_048_576, let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// W183 R5 審查（GPT-6 高）：錯誤紀錄不留任何原文（洗字洗不乾淨），只留白名單分類。
    static func errorCategory(_ output: [String]) -> String {
        let text = output.joined(separator: "\n").lowercased()
        let table: [(String, [String])] = [
            ("auth", ["authentication error", "unauthorized", "403", "forbidden"]),
            ("network", ["no such host", "dial tcp", "timeout", "network is unreachable", "connection refused", "tls handshake"]),
            ("exists", ["already exists"]),
            ("credentials_write", ["couldn't write tunnel credentials"]),
            ("rate_limited", ["429", "rate limit", "too many requests"]),
            ("not_found", ["404", "not found"]),
            ("usage", ["incorrect usage", "flag provided but not defined", "requires exactly"]),
            ("api", ["api call failed", "rest request failed", "api error"]),
            ("cert", ["origin certificate", "origincert"]),
        ]
        let hits = table.filter { _, words in words.contains { text.contains($0) } }.map(\.0)
        return hits.isEmpty ? "unknown" : hits.joined(separator: "+")
    }

    /// `route dns` 的「Added CNAME <名稱> which will route to this tunnel」或「<名稱> is already configured to route to your tunnel」。
    static func routedHost(in output: [String]) -> String? {
        for line in output {
            if let range = line.range(of: #"Added CNAME [A-Za-z0-9.-]+"#, options: .regularExpression) {
                return HandsGatewayLaunch.validHost(String(line[range].dropFirst("Added CNAME ".count)))
            }
            if let range = line.range(of: #"[A-Za-z0-9.-]+ is already configured to route to your tunnel"#, options: .regularExpression) {
                return HandsGatewayLaunch.validHost(String(line[range].split(separator: " ").first ?? ""))
            }
        }
        return nil
    }

    /// `tunnel token` 印在 stdout 的 token（最後一行像 token 的）。
    static func token(in output: [String]) -> String? {
        output.reversed().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.utf8.count >= 32 && HandsGatewayLaunch.validToken($0) && !$0.contains(" ") && $0.range(of: #"^[A-Za-z0-9+/=_-]+$"#, options: .regularExpression) != nil }
    }

    /// 白話錯誤（不回原文：原文可能有路徑）。
    static func explain(_ output: [String], fallback: String) -> String {
        let text = output.joined(separator: "\n").lowercased()
        if text.contains("already exists") || text.contains("record with that host already exists") { return "這個名字在 Cloudflare 上已經有了（TATWO 不覆蓋既有的東西）；到 Cloudflare 後台看一下再按「重試」" }
        if text.contains("authentication error") || text.contains("unauthorized") || text.contains("403") { return "Cloudflare 拒絕這個授權（可能過期或權限不夠）；到 環境登入 › Cloudflare 重新登入" }
        if text.contains("no such host") || text.contains("dial tcp") || text.contains("timeout") || text.contains("network is unreachable") {
            return "連不到 Cloudflare（網路不通）；稍後按「重試」"
        }
        return fallback
    }
}

// MARK: - 跑 cloudflared 的設定指令

protocol HandsRunningCommand: AnyObject {
    /// 收掉整組（看門程式會先收掉 cloudflared、等它結束、刪暫存檔，再自己結束）。
    func cancel()
    /// 看門程式（整組）已經結束、也收完屍了。
    var hasExited: Bool { get }
    /// 等它真的結束（最多 timeout 秒）；回傳有沒有結束。
    func waitForExit(timeout: TimeInterval) -> Bool
    /// 行程群組（＝看門程式的 pid）；App 當掉後重開時用來找上次沒收掉的那一組。0＝沒有真的行程（自測的假指令）。
    var processGroup: pid_t { get }
}

protocol HandsCloudflaredRunning: AnyObject {
    /// 開一個 cloudflared 設定指令。每一行輸出（stdout＋stderr）交給 onLine（不存、不記）；結束時 onExit（正常結束的結束碼，被殺是 nil）。
    func start(cloudflared: URL, arguments: [String], home: URL, handsRoot: URL,
               onLine: @escaping (String) -> Void, onExit: @escaping (Int32?) -> Void) throws -> HandsRunningCommand
    /// W183 R5 審查（GPT-6）：同上，另外把 **stdout** 的每一行單獨交給 onStdout（`--output json` 的 JSON 在 stdout、log 在 stderr；
    /// 解析只看 stdout，不會被 log 誤導）。onLine 照舊收到兩邊的每一行。
    func start(cloudflared: URL, arguments: [String], home: URL, handsRoot: URL, onLine: @escaping (String) -> Void,
               onStdout: @escaping (String) -> Void, onExit: @escaping (Int32?) -> Void) throws -> HandsRunningCommand
}

extension HandsCloudflaredRunning {
    /// 預設（自測的假 runner）：分不出 stdout 與 stderr，每一行都當 stdout。
    func start(cloudflared: URL, arguments: [String], home: URL, handsRoot: URL, onLine: @escaping (String) -> Void,
               onStdout: @escaping (String) -> Void, onExit: @escaping (Int32?) -> Void) throws -> HandsRunningCommand {
        try start(cloudflared: cloudflared, arguments: arguments, home: home, handsRoot: handsRoot,
                  onLine: { line in onLine(line); onStdout(line) }, onExit: onExit)
    }
}

final class HandsCloudflaredRunner: HandsCloudflaredRunning {
    /// 放棄責任行程（子行程不沿用 App 的輔助使用、螢幕錄製、自動化、外接卷等 TCC 權限）。正式一律開；
    /// 只有 DEBUG 自測關掉：staging 放在外接卷，放棄責任的子行程連假 cloudflared 腳本都讀不到（R2 的看門程式也踩過）。
    let disclaimResponsibility: Bool
    /// 只給自測：在 cloudflared 的參數前面插一段（用 Node 扮演 cloudflared：`node -e <腳本> tunnel …`）；規則、看門程式、環境照正式。
    let programPrefix: [String]
    init() { disclaimResponsibility = true; programPrefix = [] }
    #if DEBUG
    init(disclaimResponsibilityForTesting: Bool, programPrefix: [String] = []) {
        disclaimResponsibility = disclaimResponsibilityForTesting
        self.programPrefix = programPrefix
    }
    #endif

    /// Seatbelt（W183 R3 審查：照 R2b 的 cloudflared.sb 改成「先全拒、只開必要的」）：
    /// - 寫檔先全拒，只開設定家目錄（cloudflared 的 HOME：授權檔、用完就刪的暫存憑證）與 /dev/null。被打穿的 cloudflared
    ///   改不到 Homebrew、/tmp、App 的資料或任何沙盒外會被執行的檔。
    /// - 只准執行 cloudflared 本身、不准 fork：開不了預設瀏覽器（授權網址由 App 在 OS 瀏覽器開）、開不了任何其他程式。
    /// - 對外先全拒，只開 443（Cloudflare 的 API 與授權頁輪詢）與 DNS；本機（127.0.0.1、::1）一律不准連（本機服務），只留本機 DNS；
    ///   unix socket 只准系統 DNS（mDNSResponder）。殘餘：Seatbelt 分不出公網與內網，內網主機的 443／53 仍連得到（寫進報告）。
    /// - 家目錄（含 ~/.cloudflared、~/.ssh、鑰匙圈檔、入口）、手腳資料夾的其他地方、外接卷讀不到。
    /// - 不准送 Apple Event、不准碰剪貼簿、畫面、TCC、LaunchServices、Dock、輔助使用、鑰匙圈服務。
    ///   實測（真的 cloudflared 2026.3、這份規則、暫存家目錄）：`tunnel login` 照樣印出授權網址、以 443 輪詢 Cloudflare（TLS 驗證正常）；
    ///   同一份規則拿掉 443 就立刻「Failed to write the certificate」——證明規則有在擋、443 是必要的那一條。
    /// 路徑都 realpath 後用 -D 傳，不拼進規則文字。後面的規則蓋過前面的。
    static let profile = """
    (version 1)
    (allow default)
    (deny process-exec)
    (allow process-exec (literal (param "CF_BIN")))
    (deny process-fork)
    (deny file-write*)
    (deny file-read* (subpath (param "USER_HOME")) (subpath (param "HANDS_ROOT")) (subpath "/Volumes"))
    (allow file-read-metadata (literal (param "USER_HOME")))
    (allow file-read* file-write* (subpath (param "SETUP_HOME")))
    (allow file-read* (literal (param "CF_BIN")))
    (allow file-write-data (literal "/dev/null") (literal "/dev/dtracehelper"))
    (deny network-outbound)
    (allow network-outbound
      (remote unix-socket (path-literal "/private/var/run/mDNSResponder"))
      (remote tcp "*:443")
      (remote udp "*:53") (remote tcp "*:53"))
    (deny network-outbound (remote ip "localhost:*"))
    (allow network-outbound (remote udp "localhost:53") (remote tcp "localhost:53"))
    (deny appleevent-send)
    (deny mach-lookup
      (global-name-prefix "com.apple.pasteboard")
      (global-name-prefix "com.apple.windowserver")
      (global-name-prefix "com.apple.tccd")
      (global-name "com.apple.coreservices.launchservicesd")
      (global-name-prefix "com.apple.lsd")
      (global-name "com.apple.dock.server")
      (global-name-prefix "com.apple.accessibility")
      (global-name "com.apple.hiservices-xpcservice")
      (global-name-prefix "com.apple.screencapture")
      (global-name "com.apple.replayd")
      (global-name-prefix "com.apple.ScreenCaptureKit")
      (global-name "com.apple.CoreServices.coreservicesd")
      (global-name "com.apple.SecurityServer")
      (global-name "com.apple.securityd.xpc")
      (global-name-prefix "com.apple.security.keychain"))
    """

    /// 看門程式的 $0（App 重開時用它認出「上次沒收掉的那一組是我們的」）。
    static let guardName = "chatgpt-hands/setup-guard"

    /// 看門程式（沙盒外、只用 /bin/sh 內建指令與 /bin/sleep、/bin/rm；跟 cloudflared 同一個行程群組）：
    /// - umask 077：cloudflared 自己寫的授權檔（cert.pem）、通道憑證 json 一律只有自己讀得到（不管它用什麼權限建檔）。
    /// - App 給的 stdin 收到 EOF（App 結束、當掉、被強制結束）或收到 SIGTERM／SIGINT／SIGHUP（App 取消）→ 收掉 cloudflared、
    ///   **等它真的結束**（2 秒後 SIGKILL）、刪設定家目錄裡的暫存憑證（oc-*）、通道憑證（cred-*）、授權檔（.cloudflared/*），才結束。
    /// - cloudflared 自己正常結束：照它的結束碼結束，不刪（App 還要讀授權檔；讀完就刪）。
    /// 用 `-c` 帶全文（不讀腳本檔）：`/bin/sh -c <全文> chatgpt-hands/setup-guard <設定家目錄> /usr/bin/sandbox-exec …`。
    static let guardScript = """
    home=$1
    shift
    [ -n "$home" ] && [ "$#" -gt 0 ] || exit 64
    umask 077
    child=
    watcher=
    stop() {
      trap '' HUP INT TERM
      exec 2>/dev/null
      [ -n "$watcher" ] && kill -KILL "$watcher" 2>/dev/null
      if [ -n "$child" ]; then
        kill -TERM "$child" 2>/dev/null
        { /bin/sleep 2; kill -KILL "$child" 2>/dev/null; } >/dev/null 2>&1 &
        killer=$!
        wait "$child" 2>/dev/null
        kill -KILL "$killer" 2>/dev/null
      fi
      /bin/rm -f -- "$home"/oc-* "$home"/cred-* "$home"/.cloudflared/* 2>/dev/null
      exit 143
    }
    trap stop HUP INT TERM
    exec 3<&0 </dev/null
    "$@" 3<&- &
    child=$!
    { while read -r _ <&3; do :; done; kill -TERM "$$" 2>/dev/null; } >/dev/null 2>&1 &
    watcher=$!
    exec 3<&-
    wait "$child"
    code=$?
    kill -KILL "$watcher" 2>/dev/null
    exit "$code"
    """

    /// 設定家目錄與 cloudflared 的上層資料夾只開「看屬性」（stat；不能列內容、不能讀檔）：路徑解析要一層一層 lstat（實測：
    /// 整個手腳資料夾拒讀時，連它自己的屬性也讀不到，程式就找不到自己的家目錄）。沒用到的格子填 "/"。
    static let ancestorSlots = 24
    static var fullProfile: String {
        profile + "\n" + (0..<ancestorSlots).map { "(allow file-read-metadata (literal (param \"ANC_\($0)\")))" }.joined(separator: "\n") + "\n"
    }

    /// 一個指令＝自己的行程群組（取消時整組收掉）。輸出讀到 EOF、看門程式收完屍才算完（最後一行也收得到，例如 `tunnel token` 印完就結束）。
    /// App 手上握著看門程式 stdin 的寫入端（CLOEXEC）：App 當掉＝核心關掉它＝看門程式收到 EOF，自己收掉 cloudflared 並清檔。
    final class Command: HandsRunningCommand, @unchecked Sendable {
        let pid: pid_t
        private let condition = NSCondition()
        private var finished = false
        private var stdinWriter: Int32
        init(pid: pid_t, stdinWriter: Int32) { self.pid = pid; self.stdinWriter = stdinWriter }
        var processGroup: pid_t { pid }
        func markFinished() {
            condition.lock()
            finished = true
            if stdinWriter >= 0 { close(stdinWriter); stdinWriter = -1 }
            condition.broadcast()
            condition.unlock()
        }
        var hasExited: Bool { condition.lock(); defer { condition.unlock() }; return finished }
        func waitForExit(timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            condition.lock(); defer { condition.unlock() }
            while !finished { if !condition.wait(until: deadline) { return finished } }
            return true
        }
        /// SIGTERM 給整組（看門程式收掉 cloudflared、等它結束、清檔再結束）；5 秒後還沒結束就整組 SIGKILL（App 這邊結束後也會再清一次）。
        func cancel() {
            guard !hasExited, pid > 1 else { return }
            _ = killpg(pid, SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self, pid] in
                guard let self, !self.hasExited else { return }
                _ = killpg(pid, SIGKILL)
            }
        }
        #if DEBUG
        /// 自測：模擬 App 當掉（看門程式的 stdin 收到 EOF），不送任何訊號。
        func debugCloseStdin() {
            condition.lock()
            if stdinWriter >= 0 { close(stdinWriter); stdinWriter = -1 }
            condition.unlock()
        }
        #endif
    }

    /// 這個 pid 是不是我們的看門程式（App 重開時才用：pid 可能被別的程式重用，所以要看 argv）：
    /// argv 是 `/bin/sh -c <看門腳本> chatgpt-hands/setup-guard <這個設定家目錄> …`，而且它自己是行程群組的頭。
    static func isOurGuard(pid: pid_t, setupHome: String) -> Bool {
        guard pid > 1, getpgid(pid) == pid, let argv = processArguments(pid), argv.count >= 5 else { return false }
        return argv[0] == "/bin/sh" && argv[1] == "-c" && argv[2] == guardScript && argv[3] == guardName && argv[4] == setupHome
    }

    /// KERN_PROCARGS2：行程的 argv（只讀自己使用者的行程）。
    static func processArguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 4 * 1024 * 1024 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        guard argc > 0, argc < 4096 else { return nil }
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }   // 執行檔路徑
        while index < size, buffer[index] == 0 { index += 1 }
        var strings: [String] = []
        var start = index
        while index < size, strings.count < argc {
            if buffer[index] == 0 {
                strings.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        return strings.count == argc ? strings : nil
    }

    /// 一行一行交出去；一行太長就丟掉那一段。
    final class LineBuffer {
        private var pending = Data()
        private let emit: (String) -> Void
        init(_ emit: @escaping (String) -> Void) { self.emit = emit }
        func feed(_ data: Data) {
            pending.append(data)
            while let end = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<end], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...end)
                emit(line)
            }
            // 一行太長就丟掉，並補一行 NUL 標記（W183 R5 審查：解析端才知道資料不完整、不會把剩下的片段當完整 JSON）。
            if pending.count > 65_536 { pending.removeAll(); emit("\u{0}") }
        }
        func flush() {
            let rest = pending; pending.removeAll()
            if !rest.isEmpty { emit(String(decoding: rest, as: UTF8.self)) }
        }
    }

    /// posix_spawn：新行程群組、`POSIX_SPAWN_CLOEXEC_DEFAULT`（只留 stdin＝App 握著寫入端的 pipe、stdout／stderr＝同一條 pipe）、放棄責任行程。
    /// 一條背景執行緒讀到 EOF、再 waitpid，最後才呼叫 onExit（輸出一行都不會掉）。
    /// W183 R5 審查：給了 onStdout＝stderr 走另一條 pipe、另一條執行緒讀；兩邊都讀到 EOF 才 waitpid、才 onExit。
    static func spawn(executable: String, arguments: [String], environment: [String: String], currentDirectory: String,
                      disclaim: Bool = true,
                      onLine: @escaping (String) -> Void, onStdout: ((String) -> Void)? = nil,
                      onExit: @escaping (Int32?) -> Void) throws -> Command {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw POSIXError(.EIO) }
        let readEnd = fds[0], writeEnd = fds[1]
        var errors: [Int32] = [-1, -1]
        if onStdout != nil { guard pipe(&errors) == 0 else { close(readEnd); close(writeEnd); throw POSIXError(.EIO) } }
        let errRead = errors[0], errWrite = errors[1]
        var input: [Int32] = [-1, -1]
        guard pipe(&input) == 0 else {
            close(readEnd); close(writeEnd); if errRead >= 0 { close(errRead); close(errWrite) }
            throw POSIXError(.EIO)
        }
        let stdinRead = input[0], stdinWrite = input[1]
        for fd in [readEnd, writeEnd, stdinRead, stdinWrite, errRead, errWrite] where fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(stdinWrite, F_SETNOSIGPIPE, 1)
        func closeAll() {
            close(readEnd); close(writeEnd); close(stdinRead); close(stdinWrite)
            if errRead >= 0 { close(errRead); close(errWrite) }
        }
        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else {
            closeAll(); throw POSIXError(.EIO)
        }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, stdinRead, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errWrite >= 0 ? errWrite : writeEnd, STDERR_FILENO)
        let chdirResult = currentDirectory.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) }
        guard chdirResult == 0 else { closeAll(); throw POSIXError(.EIO) }
        var flags: Int16 = 0
        posix_spawnattr_getflags(&attributes, &flags)
        flags |= Int16(POSIX_SPAWN_SETPGROUP) | Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        posix_spawnattr_setflags(&attributes, flags)
        posix_spawnattr_setpgroup(&attributes, 0)
        if disclaim, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") {
            typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>?, Int32) -> Int32
            _ = unsafeBitCast(symbol, to: Disclaim.self)(&attributes, 1)
        }
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        let envp: [UnsafeMutablePointer<CChar>?] = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
        defer {
            argv.forEach { if let pointer = $0 { free(UnsafeMutableRawPointer(pointer)) } }
            envp.forEach { if let pointer = $0 { free(UnsafeMutableRawPointer(pointer)) } }
        }
        var argvPointers = argv + [nil]
        var envPointers = envp + [nil]
        var pid: pid_t = 0
        let result = executable.withCString { posix_spawn(&pid, $0, &actions, &attributes, &argvPointers, &envPointers) }
        close(writeEnd)
        close(stdinRead)
        if errWrite >= 0 { close(errWrite) }
        guard result == 0 else {
            close(readEnd); close(stdinWrite); if errRead >= 0 { close(errRead) }
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
        let command = Command(pid: pid, stdinWriter: stdinWrite)
        // stderr 另一條（只有給了 onStdout 才有）：讀到 EOF 才放行 waitpid／onExit。
        let errorsDone = DispatchSemaphore(value: 0)
        if errRead >= 0 {
            let errorThread = Thread {
                let buffer = LineBuffer(onLine)
                var chunk = [UInt8](repeating: 0, count: 16_384)
                while true {
                    let count = Darwin.read(errRead, &chunk, chunk.count)
                    if count < 0 { if errno == EINTR { continue }; break }
                    if count == 0 { break }
                    buffer.feed(Data(chunk.prefix(count)))
                }
                close(errRead)
                buffer.flush()
                errorsDone.signal()
            }
            errorThread.stackSize = 512 * 1024
            errorThread.start()
        } else {
            errorsDone.signal()
        }
        let thread = Thread {
            let emit: (String) -> Void
            if let onStdout { emit = { line in onLine(line); onStdout(line) } } else { emit = onLine }
            let buffer = LineBuffer(emit)
            var chunk = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = Darwin.read(readEnd, &chunk, chunk.count)
                if count < 0 { if errno == EINTR { continue }; break }
                if count == 0 { break }
                buffer.feed(Data(chunk.prefix(count)))
            }
            close(readEnd)
            buffer.flush()
            errorsDone.wait()
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            command.markFinished()
            onExit((status & 0x7f) == 0 ? (status >> 8) & 0xff : nil)
        }
        thread.stackSize = 512 * 1024
        thread.start()
        return command
    }

    func start(cloudflared: URL, arguments: [String], home: URL, handsRoot: URL,
               onLine: @escaping (String) -> Void, onExit: @escaping (Int32?) -> Void) throws -> HandsRunningCommand {
        try start(cloudflared: cloudflared, arguments: arguments, home: home, handsRoot: handsRoot, onLine: onLine, stdout: nil, onExit: onExit)
    }

    func start(cloudflared: URL, arguments: [String], home: URL, handsRoot: URL, onLine: @escaping (String) -> Void,
               onStdout: @escaping (String) -> Void, onExit: @escaping (Int32?) -> Void) throws -> HandsRunningCommand {
        try start(cloudflared: cloudflared, arguments: arguments, home: home, handsRoot: handsRoot, onLine: onLine, stdout: onStdout, onExit: onExit)
    }

    private func start(cloudflared: URL, arguments: [String], home: URL, handsRoot: URL, onLine: @escaping (String) -> Void,
                       stdout onStdout: ((String) -> Void)?, onExit: @escaping (Int32?) -> Void) throws -> HandsRunningCommand {
        guard let bin = HandsGatewayLaunch.realPath(cloudflared.path), let setupHome = HandsGatewayLaunch.realPath(home.path),
              let hands = HandsGatewayLaunch.realPath(handsRoot.path) else { throw HandsGatewayLaunch.Failure.invalidPath }
        let userHome = HandsGatewayLaunch.realPath(HandsGatewayLaunch.accountHome()) ?? HandsGatewayLaunch.accountHome()
        for value in [bin, setupHome, hands, userHome] + arguments where value.contains("\0") || value.contains("\n") {
            throw HandsGatewayLaunch.Failure.invalidPath
        }
        // PATH 指到空資料夾：cloudflared 找不到 open，就只印授權網址（由 App 在 OS 瀏覽器開）。
        let emptyBin = URL(fileURLWithPath: setupHome).appendingPathComponent("nobin", isDirectory: true)
        let tmp = URL(fileURLWithPath: setupHome).appendingPathComponent("tmp", isDirectory: true)
        try HandsFiles.ensureDirectory(emptyBin)
        try HandsFiles.ensureDirectory(tmp)
        let environment = ["HOME": setupHome, "PATH": emptyBin.path, "TMPDIR": tmp.path + "/", "LANG": "en_US.UTF-8"]
        var sandbox = ["-p", Self.fullProfile]
        for (key, value) in [("USER_HOME", userHome), ("HANDS_ROOT", hands), ("SETUP_HOME", setupHome), ("CF_BIN", bin)] {
            sandbox += ["-D", "\(key)=\(value)"]
        }
        let parents = HandsGatewayLaunch.ancestors(of: [setupHome + "/x", bin])
        guard parents.count <= Self.ancestorSlots else { throw HandsGatewayLaunch.Failure.pathTooDeep }
        for index in 0..<Self.ancestorSlots { sandbox += ["-D", "ANC_\(index)=\(index < parents.count ? parents[index] : "/")"] }
        // 看門程式（沙盒外）→ sandbox-exec（套規則）→ cloudflared。看門程式收到 App 的 EOF 或訊號就收掉 cloudflared 並清檔。
        let guarded = ["-c", Self.guardScript, Self.guardName, setupHome, HandsGatewayLaunch.sandboxExec] + sandbox + [bin] + programPrefix + arguments
        return try Self.spawn(executable: HandsGatewayLaunch.shell, arguments: guarded,
                              environment: environment, currentDirectory: setupHome, disclaim: disclaimResponsibility,
                              onLine: onLine, onStdout: onStdout, onExit: onExit)
    }
}
