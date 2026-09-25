import Darwin
import Foundation

/// W178：Pod（ChatGPT 網頁裡的腳本）交給原生端下載的外部網址，只准連到公開網際網路的 https。
///
/// 網頁若被植入腳本，可以把圖示、檔案網址換成區網設備（路由器、NAS、印表機）或本機服務，
/// 借 App 的原生連線替它發請求。這裡擋三件事：非 https／帶帳密／非 443 埠、主機解析到私有或保留位址、
/// 轉址到上述任何一種。解析檢查與實際連線之間若 DNS 被換（DNS rebinding），連線雖會到內網位址，
/// 但 TLS 仍用網址上的主機名驗憑證，內網設備拿不出那個網域的有效憑證，交握失敗、請求送不出去；回應也只進原生畫面、不回給網頁。
enum TapRemoteFetch {
    enum Failure: LocalizedError {
        case blocked
        case status(Int)
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .blocked: "網址不是公開的 https，已擋下"
            case let .status(code): "下載失敗（HTTP \(code)）"
            case .tooLarge: "檔案太大，已停止下載"
            }
        }
    }

    static func fetch(_ url: URL, maxBytes: Int, session: URLSession) async throws -> Data {
        guard await isAllowed(url) else { throw Failure.blocked }
        let (stream, response) = try await session.bytes(from: url, delegate: RedirectGuard.shared)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure.status((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        if response.expectedContentLength > Int64(maxBytes) { throw Failure.tooLarge }
        var data = Data()
        data.reserveCapacity(Int(min(max(response.expectedContentLength, 0), Int64(maxBytes))))
        for try await byte in stream {
            data.append(byte)
            if data.count > maxBytes { throw Failure.tooLarge }
        }
        return data
    }

    /// https、沒有帳密、預設埠，而且主機（IP 或解析結果）全部是公開位址。
    static func isAllowed(_ url: URL) async -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let rawHost = url.host?.lowercased(), !rawHost.isEmpty
        else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let localSuffixes = [".local", ".localhost", ".internal", ".lan", ".home.arpa", ".intranet"]
        if host == "localhost" || localSuffixes.contains(where: { host.hasSuffix($0) }) { return false }
        // IPv6 字面寫法沒有歧義，直接判；IPv4 一律交給 getaddrinfo——它跟實際連線用同一套規則讀數字
        // （0177.0.0.1 是八進位的 127.0.0.1、2130706433 也是），自己用 inet_pton 解會跟連線解出不同位址。
        if host.contains(":") { return addressBytes(host).map(isPublic) ?? false }
        return await Task.detached(priority: .utility) { resolvedAddressesArePublic(host) }.value
    }

    private static func resolvedAddressesArePublic(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(result) }
        var sawAny = false
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ai_next }
            guard let address = entry.pointee.ai_addr else { continue }
            let bytes: [UInt8]
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) }
                }
            case AF_INET6:
                bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
                }
            default:
                continue
            }
            sawAny = true
            if !isPublic(bytes) { return false }
        }
        return sawAny
    }

    /// IPv6 字面位址（可帶 %zone）轉成位元組；不是 IPv6 字面位址就回 nil。
    static func addressBytes(_ host: String) -> [UInt8]? {
        let bare = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        var v6 = in6_addr()
        if inet_pton(AF_INET6, bare, &v6) == 1 { return withUnsafeBytes(of: v6) { Array($0) } }
        return nil
    }

    /// 私有、本機、連結本地、CGNAT、多播、文件範例與保留位址都不算公開。
    /// IPv6 用白名單：只有全球單播 2000::/3 才可能公開，再排除其中的特殊區段；其他（含 fec0::/10 等舊式本地）一律不算。
    static func isPublic(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 4 { return isPublicIPv4(bytes) }
        guard bytes.count == 16 else { return false }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            return isPublicIPv4(Array(bytes[12..<16]))                                    // ::ffff:a.b.c.d
        }
        if bytes[0..<12] == [0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0] {
            return isPublicIPv4(Array(bytes[12..<16]))                                    // 64:ff9b::/96（NAT64）
        }
        guard bytes[0] & 0xE0 == 0x20 else { return false }                               // 只收 2000::/3
        if bytes[0] == 0x20 && bytes[1] == 0x01 {
            if bytes[2] == 0x0D && bytes[3] == 0xB8 { return false }                       // 2001:db8::/32 文件範例
            if bytes[2] == 0x00 && bytes[3] == 0x00 { return false }                       // 2001::/32 Teredo（內含 IPv4）
            if bytes[2] == 0x00 && bytes[3] & 0xF0 == 0x10 { return false }                // 2001:10::/28 ORCHID
            if bytes[2] == 0x00 && bytes[3] & 0xF0 == 0x20 { return false }                // 2001:20::/28 ORCHIDv2
        }
        if bytes[0] == 0x20 && bytes[1] == 0x02 { return false }                           // 2002::/16 6to4（內含 IPv4）
        if bytes[0] == 0x3F && bytes[1] == 0xFF && bytes[2] & 0xF0 == 0x00 { return false } // 3fff::/20 文件範例
        return true
    }

    private static func isPublicIPv4(_ b: [UInt8]) -> Bool {
        switch (b[0], b[1], b[2]) {
        case (0, _, _), (10, _, _), (127, _, _): return false
        case (100, 64...127, _): return false
        case (169, 254, _): return false
        case (172, 16...31, _): return false
        case (192, 0, 0), (192, 0, 2), (192, 168, _): return false
        case (198, 18...19, _), (198, 51, 100), (203, 0, 113): return false
        default: return b[0] < 224
        }
    }

    /// 每一次轉址都重新檢查；不合格就不跟（回應會是 3xx，下載當失敗處理）。
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        static let shared = RedirectGuard()

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, await TapRemoteFetch.isAllowed(url) else { return nil }
            return request
        }
    }
}
