import Foundation
import Network
import Security

// W183 R7a：新網址外部確認的第二條路（mini 實測 09-28：隨機→固定遷移後「外部確認新網址」記成 dns.probe category=network，
// 舊的隨機紀錄照設計留著）。
// - 可能的原因：這個名字在 DNS 紀錄建好之前被查過，系統（mDNSResponder）把「不存在」快取了（Cloudflare 網域的負快取可到 30 分鐘），
//   或這台用的 DNS（路由器、公司網路）還沒更新。App 本身沒有 App Sandbox（沒有 entitlements），不是網路權限的問題；
//   確認在 App 行程裡做，不在 Seatbelt 裡。
// - 做法：不經系統解析——直接連 Cloudflare 的公開 DNS（https://1.1.1.1/dns-query，用 IP 連，不用先查名字；憑證照驗）問這個名字的
//   A（這個名字乾淨地沒有 A 才問 AAAA），再直接連那個位址的 443：TLS 的 SNI 與憑證驗證照樣用這個名字（SecPolicyCreateSSL＋主機名，
//   驗不過一律拒），送一個不帶任何 token、cookie 的 GET /.well-known/oauth-protected-resource，回應照同一個 gatewayVerdict 判斷
//   （只有 TATWO 關口的 403「forbidden」或它自己的中介資料才算）。
// - 不放寬：任何一步不行（公開 DNS 查不到、位址不是公開位址、連不上、憑證不對、不是 TATWO 的關口）＝回分類，呼叫端照舊不刪。
// - 殘餘（寫進報告）：這台連不到 1.1.1.1（公司網路擋、只准自己的 DNS）時第二條路也不通，只能等系統那條路的快取過期（自動重試會一直試）。
// W183 R7a 審查（GPT-6）：
// - 「備援連得到」跟「可以刪」分開：每個公開解析器都要問，每一個都要乾淨地回答（HTTP 200、JSON 看得懂、沒有截斷、問題就是這個名字與型別、
//   答案沿著 CNAME 接得上這個名字、沒有私人位址），而且答案一致，才拿去直連確認；部分失敗、格式不對、答案不一致＝這一輪不確認（舊紀錄照留，
//   之後自動再試）。A 不是「乾淨地沒有」（失敗、格式不對）就不改問 AAAA。
// - 位址判斷用 inet_pton 的位元組（不是字串前綴）：IPv4 排除本機、私人、CGNAT、鏈結本地、文件用、基準測試、多播、保留；
//   IPv6 只收 2000::/3 全域單播，再排除文件用、6to4、Teredo 與 IETF 協定保留段（含 IPv4 對應、展開寫法的 ::1 一律不算）。
//   連線直接用位元組建的位址（不再經過任何名字解析）。
// - HTTP 回應嚴格照框：接收出錯一律「連不上」（不會變成確認）；Content-Length 與 chunked 不能同時有、同一個長度標頭不能出現兩次、
//   內容不能多也不能少；chunked 每段後面一定要 CRLF、最後一段之後要收到 trailers 的空行才算收完；沒有長度的回應只在正常關線時才算收完。
extension HandsCloudflared {
    static let publicResolvers = ["1.1.1.1", "1.0.0.1"]
    static let probePath = "/.well-known/oauth-protected-resource"

    /// 一個公開解析器對一個問題（名字＋型別）的回答。
    enum DoHAnswer: Equatable, Sendable {
        /// 乾淨的回答：這個型別的公開位址（可以是空的＝這個名字乾淨地沒有這種紀錄）。
        case addresses([String])
        /// 分類：nxdomain、failed（連不上、不是 200、太大）、malformed、status、truncated、question、unlinked、private、invalid。
        case failure(String)
    }

    /// nil＝確認了；否則分類（doh_nxdomain、doh_empty、doh_partial、doh_inconsistent、doh_failed、doh_private…、network、tls、timeout、not_gateway）。
    static func probeViaPublicDNS(host: String, completion: @escaping (String?) -> Void) {
        probeViaPublicDNS(host: host, query: { name, type, done in queryAll(host: name, type: type, completion: done) },
                          probe: { address, name, done in probeAddress(address, host: name, completion: done) }, completion: completion)
    }

    /// 判斷的順序（自測換掉「問公開 DNS」與「直連」，看它問了什麼、連了哪裡）。
    static func probeViaPublicDNS(host: String, query: @escaping (String, String, @escaping ([DoHAnswer]) -> Void) -> Void,
                                  probe: @escaping (String, String, @escaping (String?) -> Void) -> Void,
                                  completion: @escaping (String?) -> Void) {
        query(host, "A") { answers in
            let v4 = combineDoH(answers)
            if let failure = v4.failure { return completion("doh_" + failure) }
            if let address = v4.addresses?.first { return probe(address, host, completion) }
            // 每個解析器都乾淨地說「沒有 A」才問 AAAA（A 失敗、格式不對不改問）。
            query(host, "AAAA") { answers6 in
                let v6 = combineDoH(answers6)
                if let failure = v6.failure { return completion("doh_" + failure) }
                guard let address = v6.addresses?.first else { return completion("doh_empty") }
                probe(address, host, completion)
            }
        }
    }

    /// 刪除判定用（純判斷；自測用）：每個解析器都乾淨、答案一致＝（位址, nil）（位址可以是空的）；否則（nil, 分類）。
    /// 全部同一種失敗（例如都說 NXDOMAIN）＝那一種；有的答、有的失敗＝partial；都答了但不一樣＝inconsistent。
    static func combineDoH(_ answers: [DoHAnswer]) -> (addresses: [String]?, failure: String?) {
        guard !answers.isEmpty else { return (nil, "failed") }
        var sets: [Set<String>] = []
        var failures: [String] = []
        for answer in answers {
            switch answer {
            case .addresses(let list): sets.append(Set(list))
            case .failure(let category): failures.append(category)
            }
        }
        if !failures.isEmpty {
            if sets.isEmpty { return (nil, Set(failures).count == 1 ? failures[0] : "failed") }
            return (nil, "partial")
        }
        guard let first = sets.first, sets.allSatisfy({ $0 == first }) else { return (nil, "inconsistent") }
        return (first.sorted(), nil)
    }

    /// 每個公開解析器都問一次（依序；不經系統解析）。
    static func queryAll(host: String, type: String, resolvers: [String] = publicResolvers, collected: [DoHAnswer] = [],
                         completion: @escaping ([DoHAnswer]) -> Void) {
        guard let resolver = resolvers.first else { return completion(collected) }
        resolvePublic(host: host, type: type, resolver: resolver) { answer in
            queryAll(host: host, type: type, resolvers: Array(resolvers.dropFirst()), collected: collected + [answer], completion: completion)
        }
    }

    /// 問一個公開 DNS（DoH JSON；用 IP 連，不經系統解析；URLSession 照常驗那個 IP 的憑證）。
    static func resolvePublic(host: String, type: String, resolver: String, completion: @escaping (DoHAnswer) -> Void) {
        guard let name = HandsGatewayLaunch.validHost(host), addressBytes(resolver)?.count == 4,
              var parts = URLComponents(string: "https://\(resolver)/dns-query") else { return completion(.failure("invalid")) }
        parts.queryItems = [(dnsNameQuery, name), ("type", type)].map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = parts.url else { return completion(.failure("invalid")) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: PublicProbeNoRedirect(), delegateQueue: nil)
        session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            guard error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200, let data, data.count <= 64 * 1024 else {
                return completion(.failure("failed"))
            }
            completion(parseDNSJSON(data, host: name, type: type))
        }.resume()
    }

    /// DoH JSON（application/dns-json）→ 這個型別的公開位址（純判斷；自測用）。
    /// 要：Status 0、沒有截斷（TC）、Question 只有一個而且就是這個名字與型別、每一列答案都接得上這個名字（CNAME 鏈，最多 8 層）、
    /// 位址是這個型別的合法位址而且都是公開位址。NXDOMAIN、其他狀態、看不懂、接不上、有私人位址＝失敗分類。
    static func parseDNSJSON(_ data: Data, host: String, type: String) -> DoHAnswer {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let status = dnsInteger(object["Status"]) else {
            return .failure("malformed")
        }
        let code = type == "AAAA" ? 28 : 1
        let name = dnsName(host)
        // 問題要對得上（NXDOMAIN 也要是問這個名字才算）。
        guard let questions = object["Question"] as? [[String: Any]], questions.count == 1,
              (questions[0]["name"] as? String).map(dnsName) == name, dnsInteger(questions[0]["type"]) == code else { return .failure("question") }
        if status == 3 { return .failure("nxdomain") }
        guard status == 0 else { return .failure("status") }
        if object["TC"] as? Bool == true { return .failure("truncated") }
        guard let rows = (object["Answer"] ?? [[String: Any]]()) as? [[String: Any]], rows.count <= 32 else { return .failure("malformed") }
        // CNAME 鏈：從這個名字開始，每個名字最多一個 CNAME。
        var cnames: [String: String] = [:]
        for row in rows where dnsInteger(row["type"]) == 5 {
            guard let owner = (row["name"] as? String).map(dnsName), let target = (row["data"] as? String).map(dnsName),
                  !owner.isEmpty, !target.isEmpty, cnames[owner] == nil else { return .failure("malformed") }
            cnames[owner] = target
        }
        var chain: [String] = [name]
        while let next = cnames[chain[chain.count - 1]], chain.count <= 8 {
            guard !chain.contains(next) else { return .failure("malformed") }   // 迴圈
            chain.append(next)
        }
        let linked = Set(chain)
        var found: [String] = []
        for row in rows {
            guard let rowType = dnsInteger(row["type"]), let owner = (row["name"] as? String).map(dnsName), linked.contains(owner) else {
                return .failure("unlinked")   // 跟這個名字接不上的列（別的名字、看不懂的型別）
            }
            if rowType == 5 { continue }
            guard rowType == code, let value = row["data"] as? String, let bytes = addressBytes(value), bytes.count == (code == 28 ? 16 : 4) else {
                return .failure("unlinked")
            }
            guard isPublicAddress(value) else { return .failure("private") }   // 有一個不是公開位址就整份不收
            found.append(value)
        }
        return .addresses(found)
    }

    /// DNS 名字比對用：小寫、去掉結尾的點。
    static func dnsName(_ raw: String) -> String {
        var lower = raw.lowercased()
        while lower.hasSuffix(".") { lower.removeLast() }
        return lower
    }

    /// JSON 裡的整數（不收 true／1.5）。
    private static func dnsInteger(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), Double(number.intValue) == number.doubleValue else { return nil }
        return number.intValue
    }

    static func isIPAddress(_ value: String, v6: Bool) -> Bool { addressBytes(value)?.count == (v6 ? 16 : 4) }

    /// inet_pton 的位元組（IPv4 四個、IPv6 十六個）；不是位址＝nil。
    static func addressBytes(_ value: String) -> [UInt8]? {
        guard !value.isEmpty, value.utf8.count <= 45, !value.contains("%") else { return nil }
        if value.contains(":") {
            var buffer = [UInt8](repeating: 0, count: 16)
            return value.withCString { inet_pton(AF_INET6, $0, &buffer) } == 1 ? buffer : nil
        }
        var buffer = [UInt8](repeating: 0, count: 4)
        return value.withCString { inet_pton(AF_INET, $0, &buffer) } == 1 ? buffer : nil
    }

    /// 公開位址（照位元組判斷；字串怎麼寫都一樣）。
    static func isPublicAddress(_ value: String) -> Bool {
        guard let bytes = addressBytes(value) else { return false }
        return bytes.count == 4 ? isPublicIPv4(bytes) : isPublicIPv6(bytes)
    }

    static func isPublicIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch (b[0], b[1], b[2]) {
        case (0, _, _), (10, _, _), (127, _, _): return false               // 「這個網路」、私人、本機
        case (100, 64...127, _): return false                                // CGNAT
        case (169, 254, _): return false                                     // 鏈結本地
        case (172, 16...31, _), (192, 168, _): return false                  // 私人
        case (192, 0, 0), (192, 0, 2), (192, 88, 99): return false           // IETF 協定、文件用、6to4 中繼
        case (198, 18...19, _), (198, 51, 100), (203, 0, 113): return false  // 基準測試、文件用
        default: return b[0] < 224                                           // 多播、保留、廣播
        }
    }

    static func isPublicIPv6(_ b: [UInt8]) -> Bool {
        guard b.count == 16, b[0] & 0xE0 == 0x20 else { return false }       // 只收 2000::/3（::1、::、::ffff:…、fc00::/7、fe80::/10、ff00::/8 都不在裡面）
        if b[0] == 0x20, b[1] == 0x01, b[2] < 0x02 { return false }           // 2001::/23 IETF 協定保留（含 Teredo 2001::/32）
        if b[0] == 0x20, b[1] == 0x01, b[2] == 0x0D, b[3] == 0xB8 { return false }   // 2001:db8::/32 文件用
        if b[0] == 0x20, b[1] == 0x02 { return false }                        // 2002::/16 6to4（裡面包 IPv4）
        if b[0] == 0x3F, b[1] == 0xFF, b[2] & 0xF0 == 0 { return false }      // 3fff::/20 文件用
        return true
    }

    /// 直接連這個位址的 443（SNI 與憑證驗證用 host），送不帶秘密的 GET，回應照 gatewayVerdict。nil＝確認了。
    static func probeAddress(_ address: String, host: String, timeout: TimeInterval = 15, completion: @escaping (String?) -> Void) {
        guard isPublicAddress(address), let name = HandsGatewayLaunch.validHost(host), let bytes = addressBytes(address) else {
            return completion("doh_private")
        }
        // 用位元組建位址（不經過任何名字解析）。
        let endpoint: NWEndpoint.Host
        if bytes.count == 4, let v4 = IPv4Address(Data(bytes)) {
            endpoint = .ipv4(v4)
        } else if bytes.count == 16, let v6 = IPv6Address(Data(bytes)) {
            endpoint = .ipv6(v6)
        } else {
            return completion("doh_private")
        }
        let queue = DispatchQueue(label: "tatwo.chatgpt-hands.public-probe")
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        sec_protocol_options_set_tls_server_name(security, name)
        sec_protocol_options_add_tls_application_protocol(security, "http/1.1")
        // 憑證一定要對這個名字（系統信任的根、名字相符、沒過期）；驗不過＝連線失敗。
        sec_protocol_options_set_verify_block(security, { _, trust, verified in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            SecTrustSetPolicies(secTrust, SecPolicyCreateSSL(true, name as CFString))
            verified(SecTrustEvaluateWithError(secTrust, nil))
        }, queue)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.preferNoProxies = true
        let connection = NWConnection(host: endpoint, port: 443, using: parameters)
        let state = PublicProbeState(completion: completion)
        let finish: @Sendable (String?) -> Void = { verdict in
            guard state.finish(verdict) else { return }
            connection.cancel()
        }
        connection.stateUpdateHandler = { update in
            switch update {
            case .ready:
                let request = "GET \(probePath) HTTP/1.1\r\nHost: \(name)\r\nAccept: application/json\r\nUser-Agent: TATWO-OS-probe\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                    if error != nil { return finish("network") }
                    receive(connection, state: state, host: name, finish: finish)
                })
            case .failed(let error):
                if case .tls = error { finish("tls") } else { finish("network") }
            case .waiting:
                finish("network")
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish("timeout") }
    }

    private static func receive(_ connection: NWConnection, state: PublicProbeState, host: String, finish: @escaping @Sendable (String?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, closed, error in
            if let data, !state.append(data) { return finish("not_gateway") }   // 回應太大：不是 TATWO 的關口
            if let verdict = receiveVerdict(state.snapshot, closed: closed, failed: error != nil, host: host) { return finish(verdict) }
            receive(connection, state: state, host: host, finish: finish)
        }
    }

    /// 收到一段之後怎麼辦（純判斷；自測用）：.none＝再收；.some(nil)＝確認了；.some(分類)＝不確認。
    /// 接收出錯一律「network」（不管收到了什麼，都不會變成確認）；格式不對、收不完就關線＝not_gateway。
    static func receiveVerdict(_ raw: Data, closed: Bool, failed: Bool, host: String) -> String?? {
        if failed { return .some("network") }
        switch parseHTTP(raw, closed: closed) {
        case .complete(let parsed): return .some(gatewayVerdict(parsed.response(host: host), data: parsed.body, host: host))
        case .malformed: return .some("not_gateway")
        case .incomplete: return closed ? .some("not_gateway") : .none
        }
    }

    /// 解析的 HTTP/1.1 回應（純判斷；自測用）。
    struct ParsedHTTP: Equatable {
        let status: Int
        let contentType: String
        let body: Data

        func response(host: String) -> HTTPURLResponse? {
            guard let url = URL(string: "https://\(host)\(HandsCloudflared.probePath)") else { return nil }
            return HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])
        }
    }

    enum HTTPParse: Equatable {
        /// 還沒收完（標頭沒完、內容沒完）。
        case incomplete
        /// 格式不對（狀態列、標頭、長度、chunk 分隔、衝突的標頭、多出來的位元組）。
        case malformed
        case complete(ParsedHTTP)
    }

    /// 嚴格照框（純判斷；自測用）：狀態列 HTTP/1.0 或 1.1＋三位數（1xx 不收）；每個標頭都要是「名字: 值」（名字是 token、沒有折行）；
    /// Content-Length、Transfer-Encoding、Content-Type 不能出現兩次；Content-Length 與 Transfer-Encoding 不能同時有；
    /// Transfer-Encoding 只收 chunked；Content-Length 只收數字、內容一個位元組都不能多；沒有長度＝正常關線才算收完。
    static func parseHTTP(_ raw: Data, closed: Bool) -> HTTPParse {
        let bytes = Data(raw)
        let limit = 64 * 1024
        guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else { return bytes.count > 16 * 1024 ? .malformed : .incomplete }
        guard end.lowerBound - bytes.startIndex <= 16 * 1024,
              let head = String(data: bytes[bytes.startIndex..<end.lowerBound], encoding: .utf8) else { return .malformed }
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "HTTP/1.1" || parts[0] == "HTTP/1.0", parts[1].count == 3, parts[1].allSatisfy(isDigit),
              let status = Int(parts[1]), (200...599).contains(status), !statusLine.contains("\n") else { return .malformed }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex, line[..<colon].allSatisfy(isTokenChar) else { return .malformed }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard !value.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else { return .malformed }
            if ["content-length", "transfer-encoding", "content-type"].contains(key), headers[key] != nil { return .malformed }
            if headers[key] == nil { headers[key] = value }
        }
        let rest = Data(bytes[end.upperBound...])
        let type = headers["content-type"] ?? ""
        switch (headers["transfer-encoding"], headers["content-length"]) {
        case (.some, .some):
            return .malformed
        case (.some(let encoding), .none):
            guard encoding.lowercased() == "chunked" else { return .malformed }
            switch dechunk(rest) {
            case .malformed: return .malformed
            case .incomplete: return closed ? .malformed : .incomplete
            case .complete(let body): return .complete(ParsedHTTP(status: status, contentType: type, body: body))
            }
        case (.none, .some(let text)):
            guard !text.isEmpty, text.count <= 6, text.allSatisfy(isDigit), let length = Int(text), length <= limit else { return .malformed }
            if rest.count > length { return .malformed }   // 多出來的位元組
            if rest.count < length { return closed ? .malformed : .incomplete }
            return .complete(ParsedHTTP(status: status, contentType: type, body: rest))
        case (.none, .none):
            guard rest.count <= limit else { return .malformed }
            return closed ? .complete(ParsedHTTP(status: status, contentType: type, body: rest)) : .incomplete
        }
    }

    enum Chunked: Equatable { case incomplete, malformed, complete(Data) }

    /// chunked 內容（嚴格）：每段「十六進位長度[;擴充]CRLF 內容 CRLF」；最後一段 0 之後是 trailers（每行「名字: 值」），
    /// 收到空行才算收完、空行之後不能再有東西。長度不是十六進位、內容後面不是 CRLF＝格式不對。
    static func dechunk(_ data: Data) -> Chunked {
        let bytes = Data(data)
        let crlf = Data("\r\n".utf8)
        var body = Data()
        var index = bytes.startIndex
        while true {
            guard let lineEnd = bytes.range(of: crlf, in: index..<bytes.endIndex) else {
                return bytes.distance(from: index, to: bytes.endIndex) > 1024 ? .malformed : .incomplete
            }
            guard let line = String(data: bytes[index..<lineEnd.lowerBound], encoding: .ascii) else { return .malformed }
            let sizeText = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            guard !sizeText.isEmpty, sizeText.count <= 8, sizeText.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                  let size = Int(sizeText, radix: 16), size <= 64 * 1024 else { return .malformed }
            let start = lineEnd.upperBound
            if size == 0 {
                var cursor = start
                while true {
                    guard let end = bytes.range(of: crlf, in: cursor..<bytes.endIndex) else {
                        return bytes.distance(from: cursor, to: bytes.endIndex) > 1024 ? .malformed : .incomplete
                    }
                    if end.lowerBound == cursor { return end.upperBound == bytes.endIndex ? .complete(body) : .malformed }
                    guard let trailer = String(data: bytes[cursor..<end.lowerBound], encoding: .ascii), let colon = trailer.firstIndex(of: ":"),
                          colon != trailer.startIndex, trailer[..<colon].allSatisfy(isTokenChar) else { return .malformed }
                    cursor = end.upperBound
                }
            }
            guard bytes.distance(from: start, to: bytes.endIndex) >= size + 2 else { return .incomplete }
            let chunkEnd = bytes.index(start, offsetBy: size)
            guard bytes[chunkEnd..<bytes.index(chunkEnd, offsetBy: 2)] == crlf else { return .malformed }
            body.append(bytes[start..<chunkEnd])
            guard body.count <= 64 * 1024 else { return .malformed }
            index = bytes.index(chunkEnd, offsetBy: 2)
        }
    }

    private static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isWholeNumber }

    /// HTTP token 字元（RFC 9110 tchar）。
    private static func isTokenChar(_ c: Character) -> Bool {
        guard c.isASCII else { return false }
        return c.isLetter || c.isNumber || "!#$%&'*+-.^_`|~".contains(c)
    }
}

/// 一次確認的狀態（收到的位元組、只回一次）。
final class PublicProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var buffer = Data()
    private let completion: (String?) -> Void

    init(completion: @escaping (String?) -> Void) { self.completion = completion }

    /// 第一次才回（回 true）；之後的一律不理。
    func finish(_ verdict: String?) -> Bool {
        lock.lock()
        guard !done else { lock.unlock(); return false }
        done = true
        lock.unlock()
        completion(verdict)
        return true
    }

    /// 收到的加上去；超過上限回 false。
    func append(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        return buffer.count <= 128 * 1024
    }

    var snapshot: Data { lock.lock(); defer { lock.unlock() }; return buffer }
}

/// 不跟隨轉址（公開 DNS 的查詢）。
private final class PublicProbeNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
