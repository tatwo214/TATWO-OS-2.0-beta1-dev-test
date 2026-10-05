import Darwin
import Foundation

#if DEBUG
// W183 R4：真的走 os.sock 的整合測試（`TATWO2_SELFTEST=w183gateway` 的一段；取代原本唯一的 SKIP，接口約定 v3 V21）。
// 全部用真的元件：App 端 os.sock 橋（OSAgentBridge.shared 在自測模式開 listener，位置是 staging 隔離的 TATWO2_OS_SOCKET）、
// HandsService.shared／HandsAuth／HandsTools／HandsState.shared（畫面的按鈕：開始配對、撤銷、開關），以及 ChatGPTHandsService
// 在 Seatbelt 裡起的 gateway.mjs（真的登記成 `.externalAI`）。不起 cloudflared（通道位置用 w183gateway 同一個 Node 替身，不連網）；
// HTTP 直接打關口的 unix socket，帶偽造的 `CF-Connecting-IP`（203.0.113.0/24＝測試寫進的 OpenAI 清單；198.51.100.x＝使用者的瀏覽器）與正確 Host。
// 關口的 unix socket 路徑有 104 位元組上限，staging 的 App Support 太深：關口的資料夾放 /tmp，裡面的 app/ 指到 HandsService 真正的
// app/——一個 settings.json 同時管 App 與關口（正式版兩者本來就是同一個 `<App Support>/TATWO OS Hands`），開關關掉兩邊一起生效。
// 假資料全部在 staging 與 /tmp；不碰鑰匙圈、~/.cloudflared、使用者資料。印出來的只有步驟與狀態碼，不印 token、配對碼、授權碼。

/// 固定值（不綁 actor：關口服務的回呼在它自己的佇列上讀）。
enum HandsIntegrationFixture {
    static let host = "hands.example.com"
    static let issuer = "https://hands.example.com"
    static let resource = "https://hands.example.com/mcp"
    static let deviceID = "device-test-1"
    /// 203.0.113.0/24 是測試寫進關口清單的「OpenAI 公布的」網段。
    static let openAIIP = "203.0.113.10"
    static let mcpIP = "203.0.113.11"
    /// 使用者自己的瀏覽器（不在 OpenAI 清單裡）：每次配對用不同的來源，互不吃對方的次數上限。
    static let browserIPs = ["198.51.100.20", "198.51.100.21", "198.51.100.22", "198.51.100.23"]
    static let redirect = HandsSettings.defaultCallbacks[0]
    static let fixtureLine = "w183 integration fixture line"

    /// 關口服務的依賴（在不綁 actor 的地方建：這些回呼在服務自己的佇列上跑）。
    /// register／unregister 用預設：真的 OSSocketCaller.registerExternalAI。
    static func gatewayDependencies(environment: [String: String], root: URL, osSocket: String, node: URL,
                                    fakeCloudflared: URL) -> ChatGPTHandsService.Dependencies {
        var deps = ChatGPTHandsService.Dependencies()
        deps.environment = environment
        deps.allowUnderTest = true
        deps.handsRoot = root
        deps.hostConfirmed = { _ in true }   // W183 R8c：每台啟用許可另在 w183build 驗；這裡只驗關口本身
        deps.programDirectory = HandsGatewayAcceptance.repoProgramDirectory()
        deps.node = node
        deps.osSocket = osSocket
        deps.cloudflared = { fakeCloudflared }
        deps.tunnelProgramPrefix = ["-e", HandsGatewayAcceptance.fakeCloudflaredScript(canaryFD: 200)]
        deps.localDeviceID = { deviceID }
        deps.tunnelToken = HandsGatewayAcceptance.MemoryToken(value: "tunnel-CANARY-" + String(repeating: "i", count: 40))
        deps.fetchRanges = { $0(.failure(HandsGatewayLaunch.Failure.invalidList)) }   // 不上網
        deps.restartDelay = 0.5
        deps.monitorInterval = 1
        return deps
    }
}

/// 關口回的一個 HTTP 回應（請求一律 Connection: close；chunked 先解開）。
struct HandsGatewayReply: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    var text: String { String(decoding: body, as: UTF8.self) }
    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    /// JSON-RPC 訊息：SSE 回應取 data 行，其他照 JSON。
    var rpc: [String: Any] {
        guard headers["content-type"]?.hasPrefix("text/event-stream") == true else { return json }
        guard let line = text.components(separatedBy: "\n").last(where: { $0.hasPrefix("data: ") }) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8))) as? [String: Any] ?? [:]
    }
}

/// 最小的 HTTP/1.1 用戶端（unix socket、阻塞 I/O；只在背景執行緒用，主執行緒一邊轉 run loop 一邊等）。
enum HandsGatewayHTTP {
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }

    static func form(_ fields: [(String, String)]) -> String {
        fields.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&")
    }

    static func request(_ method: String, _ target: String, ip: String, headers: [(String, String)], body: Data?) -> Data {
        var head = "\(method) \(target) HTTP/1.1\r\nHost: \(HandsIntegrationFixture.host)\r\nConnection: close\r\nCF-Connecting-IP: \(ip)\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        if let body { head += "Content-Length: \(body.count)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        if let body { data.append(body) }
        return data
    }

    static func send(_ socket: String, _ request: Data, timeout: Int) -> HandsGatewayReply? {
        guard let fd = HandsGatewayLaunch.connectUnix(socket, timeout: timeout) else { return nil }
        defer { close(fd) }
        let bytes = [UInt8](request)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { return nil }
            offset += written
        }
        var raw = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while raw.count < 16 * 1024 * 1024 {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            raw.append(contentsOf: chunk.prefix(count))
        }
        return parse(raw)
    }

    static func parse(_ raw: Data) -> HandsGatewayReply? {
        guard let split = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: raw[raw.startIndex..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let statusParts = lines.first?.split(separator: " ") ?? []
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        var body = Data(raw[split.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true { body = dechunk(body) }
        return HandsGatewayReply(status: status, headers: headers, body: body)
    }

    static func dechunk(_ data: Data) -> Data {
        var out = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while index < data.endIndex, let lineEnd = data.range(of: crlf, in: index..<data.endIndex) {
            let sizeField = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeField.trimmingCharacters(in: .whitespaces), radix: 16), size > 0 else { break }
            let start = lineEnd.upperBound
            guard let end = data.index(start, offsetBy: size, limitedBy: data.endIndex) else { break }
            out.append(data[start..<end])
            index = data.index(end, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return out
    }
}

/// 背景執行緒做完的結果（主執行緒轉 run loop 等）。
final class HandsIntegrationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    private var finished = false
    func finish(_ value: T?) { lock.lock(); stored = value; finished = true; lock.unlock() }
    var done: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    var value: T? { lock.lock(); defer { lock.unlock() }; return stored }
}

@MainActor
final class HandsGatewayIntegration {
    typealias Check = (Bool, String) -> Void
    private typealias F = HandsIntegrationFixture

    struct PairingPage {
        let display: String
        let transaction: String
        let csrf: String
        let cookie: String
    }

    struct Grant {
        let access: String
        let refresh: String
        let id: String
    }

    struct ToolReply {
        let status: Int
        let text: String
        let isError: Bool
    }

    private let check: Check
    private let state = HandsState.shared
    private let service = HandsService.shared
    private var socket = ""
    private var osSocket = ""
    private var projectID = UUID()
    private var base: URL?
    private var live: ChatLiveEngine?
    private var model: ChatPageModel?
    private var gateway: ChatGPTHandsService?
    private var gatewayRoot: URL?
    /// 走過的 token、refresh、授權碼、配對碼（最後確認都沒落在日誌、關口設定、App 紀錄）。
    private var secrets: [String] = []
    private var nextID = 1

    private init(check: @escaping Check) { self.check = check }

    /// 十步整合（印出的順序：1–7、10、8、9，因為 8 會撤銷全部 grant、9 要先把關口的登記讓出來）。
    static func run(_ check: @escaping Check) {
        let run = HandsGatewayIntegration(check: check)
        defer { run.cleanup() }
        guard run.prepare() else { return }
        run.steps()
    }

    private func report(_ name: String, _ conditions: [Bool], _ evidence: @autoclosure () -> String = "") {
        let failed = conditions.enumerated().filter { !$0.element }.map(\.offset)
        let detail = failed.isEmpty ? "" : "（沒過的條件 \(failed)\(evidence().isEmpty ? "" : "；" + evidence())）"
        check(failed.isEmpty, name + detail)
    }

    private func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool { HandsGatewayAcceptance.waitUntil(seconds, condition) }

    private func takeID() -> Int { nextID += 1; return nextID }

    // MARK: 準備（假資料、真的 os.sock 橋、真的關口）

    private func prepare() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment), NativeStagingIsolation.validationError(environment) == nil,
              let stagingRaw = environment["TATWO_STAGING_ROOT"], let staging = HandsPath.realpath(stagingRaw),
              let liveRaw = environment["TATWO2_LIVE_ROOT"], let liveReal = HandsPath.realpath(liveRaw), liveReal.hasPrefix(staging + "/"),
              let socketRaw = environment["TATWO2_OS_SOCKET"],
              (HandsGatewayLaunch.realPath(socketRaw) ?? socketRaw).hasPrefix(staging + "/") else {
            check(false, "整合準備：要在完整隔離的 staging 裡跑（TATWO_STAGING_ROOT、TATWO2_LIVE_ROOT、TATWO2_OS_SOCKET 都在 staging 裡）")
            return false
        }
        // 絕不碰真的 App Support：HandsService.shared 的資料夾必須在 staging 的假家目錄裡（CFFIXED_USER_HOME）。
        let handsRoot = service.paths.root.path
        guard handsRoot.hasPrefix(staging + "/") || handsRoot.hasPrefix(stagingRaw + "/") else {
            check(false, "整合準備：HandsService 的資料夾不在 staging 裡，不跑"); return false
        }
        osSocket = socketRaw
        // W183 R8c：這個自測只驗關口本身（staging 沒有 ChatGPT build 的設定＝許可一律不給）；每台啟用許可、grant 綁定在 w183build 驗。
        // 只換這個自測行程裡的許可判斷（grant 綁定照舊接著：這台的設備 id、這台的網址）。
        service.permitCheck = { true }
        guard prepareFixture(staging: staging, liveReal: liveReal, environment: environment) else { return false }
        guard prepareSettings() else { return false }
        OSAgentBridge.shared.startSecurityTestListener()
        guard waitFor(5, { OSAgentBridge.shared.isListening }) else {
            check(false, "整合準備：App 端 os.sock 橋沒有開起來"); return false
        }
        return startGateway(environment: environment)
    }

    private func git(_ arguments: [String], _ cwd: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false", "-c", "core.fsmonitor=false"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("GIT_") { env[key] = nil }
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func prepareFixture(staging: String, liveReal: String, environment: [String: String]) -> Bool {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: staging).appendingPathComponent("w183i-" + UUID().uuidString.prefix(8), isDirectory: true)
        self.base = base
        do {
            func dir(_ name: String) throws -> String {
                let url = base.appendingPathComponent(name, isDirectory: true)
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                return HandsPath.realpath(url.path) ?? url.path
            }
            let fakeHome = try dir("fakehome"), entry = try dir("entry"), appSupport = try dir("appsupport"), project = try dir("project")
            try fm.createDirectory(atPath: entry + "/memory", withIntermediateDirectories: true)
            try "# Integration fixture\n\(F.fixtureLine)\n".write(toFile: project + "/README.md", atomically: true, encoding: .utf8)
            let committed = git(["init", "-q", "-b", "main"], project) && git(["add", "-A"], project)
                && git(["-c", "user.name=fixture", "-c", "user.email=hands-fixture@localhost", "commit", "-q", "-m", "base"], project)
            guard committed else { check(false, "整合準備：測試專案的 git 建不起來"); return false }
            let liveRoot = URL(fileURLWithPath: liveReal).appendingPathComponent("w183i", isDirectory: true)
            try fm.createDirectory(at: liveRoot, withIntermediateDirectories: true)
            let live = ChatLiveEngine(store: ChatLiveStore(root: liveRoot), environment: environment)
            self.live = live
            let model = ChatPageModel(environment: environment, botCoreFixture: (live, BotStore(root: liveRoot)))
            self.model = model
            projectID = live.newProject(name: "Hands integration", workdir: project)
            let node = HandsRuntime.nodeExecutable(environment: environment)
            service.runtime = HandsRuntime(paths: service.paths, home: fakeHome, entryRoot: entry, appSupport: appSupport,
                                           fsopPath: HandsRuntime.fsopScript(), nodePath: node?.path, nodeBundled: node?.bundled ?? false,
                                           extraDeniedDirectories: [], environment: [:])
            service.deviceIDOverride = F.deviceID
            let memory = TatwoMemoryStore()
            memory.pathsOverride = EngineMemoryPaths(home: fakeHome, entryRoot: URL(fileURLWithPath: entry))
            service.memoryStore = memory
            service.noticeSink = { _, _ in }
            service.attach(model: model)
            return true
        } catch {
            check(false, "整合準備：假資料建不起來 \(error)"); return false
        }
    }

    /// 設定一律走 App 的畫面狀態（HandsState.shared → HandsService.updateSettings），跟使用者按的一樣。
    private func prepareSettings() -> Bool {
        state.setHost(deviceID: F.deviceID, publicHost: F.host)
        state.setAllowedProjects([projectID])
        state.setLevel(1)
        state.setEnabled(true)
        let settings = state.settings
        let ok = state.lastError == nil && settings.enabled && settings.level == 1 && settings.allowedProjectIDs == [projectID.uuidString]
            && settings.publicHost == F.host && settings.hostDeviceID == F.deviceID && state.activeGrants.isEmpty
        if !ok { check(false, "整合準備：App 的手腳設定寫不進去（\(state.lastError ?? "設定不對")）") }
        return ok
    }

    private func startGateway(environment: [String: String]) -> Bool {
        guard let node = HandsGatewayAcceptance.findNode(), let fakeCloudflared = HandsGatewayAcceptance.fakeCloudflaredNode() else {
            check(false, "整合準備：找不到 Node（關口與通道替身要用）"); return false
        }
        let root = HandsGatewayAcceptance.tempRoot("w183i")
        gatewayRoot = root
        do {
            // 關口的 app/ 指到 HandsService 真正的 app/：同一個 settings.json（正式版兩者就是同一個資料夾）。
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("app", isDirectory: true), withDestinationURL: service.paths.appDir)
            try HandsGatewayAcceptance.seedRanges(root)
        } catch { check(false, "整合準備：關口資料夾準備失敗 \(error)"); return false }
        let deps = F.gatewayDependencies(environment: environment, root: root, osSocket: osSocket, node: node, fakeCloudflared: fakeCloudflared)
        let gateway = ChatGPTHandsService(dependencies: deps)
        self.gateway = gateway
        socket = HandsGatewayLaunch.Paths(root: root).socket.path
        gateway.startIfEnabled()
        let url = F.resource
        guard waitFor(30, { gateway.debugPhase == .running(url: url) }), let process = gateway.debugProcesses.gateway else {
            check(false, "整合準備：關口沒有起來（\(gateway.debugPhase)）"); return false
        }
        let roots = OSSocketCaller.currentRoots()
        report("整合準備：真的 os.sock 橋在 staging 開著；ChatGPTHandsService 在 Seatbelt 裡起的關口 pid 登記成外部 AI（App 直接開、App 端認得）", [
            roots[process.pid]?.root == .externalAI,
            OSSocketCaller.classify(pid: process.pid, roots: roots) == .externalAI,
            OSSocketCaller.parentPID(of: process.pid) == getpid(),
            OSSocketCaller.executablePath(process.pid)?.hasSuffix("/node") == true,
        ])
        return true
    }

    // MARK: HTTP（背景執行緒送、主執行緒轉 run loop 等：App 端處理 hands_* 會回主執行緒記房間）

    private func send(_ method: String, _ target: String, ip: String, headers: [(String, String)] = [], body: Data? = nil,
                      timeout: Int = 60) -> HandsGatewayReply? {
        let request = HandsGatewayHTTP.request(method, target, ip: ip, headers: headers, body: body)
        let socket = self.socket
        let box = HandsIntegrationBox<HandsGatewayReply>()
        DispatchQueue.global(qos: .userInitiated).async { box.finish(HandsGatewayHTTP.send(socket, request, timeout: timeout)) }
        _ = waitFor(TimeInterval(timeout + 15)) { box.done }
        return box.value
    }

    private func register(_ uris: [String]) -> HandsGatewayReply? {
        let body = (try? JSONSerialization.data(withJSONObject: ["redirect_uris": uris, "client_name": "ChatGPT"])) ?? Data()
        return send("POST", "/register", ip: F.openAIIP, headers: [("Content-Type", "application/json")], body: body)
    }

    private func authorizeTarget(client: String, verifier: String, state: String) -> String {
        "/authorize?" + HandsGatewayHTTP.form([
            ("response_type", "code"), ("client_id", client), ("redirect_uri", F.redirect),
            ("code_challenge", HandsAuth.challenge(for: verifier)), ("code_challenge_method", "S256"), ("state", state),
            ("resource", F.resource), ("scope", "tatwo.hands"),
        ])
    }

    private func submit(_ page: PairingPage, code: String, ip: String) -> HandsGatewayReply? {
        let body = HandsGatewayHTTP.form([("transaction_id", page.transaction), ("csrf", page.csrf), ("code", code)])
        return send("POST", "/authorize", ip: ip, headers: [
            ("Origin", F.issuer), ("Sec-Fetch-Site", "same-origin"), ("Cookie", page.cookie),
            ("Content-Type", "application/x-www-form-urlencoded"),
        ], body: Data(body.utf8))
    }

    private func token(_ fields: [(String, String)]) -> HandsGatewayReply? {
        send("POST", "/token", ip: F.openAIIP, headers: [("Content-Type", "application/x-www-form-urlencoded")],
             body: Data(HandsGatewayHTTP.form(fields).utf8))
    }

    private func rpc(_ access: String, session: String?, method: String, params: [String: Any]? = nil, id: Int? = nil,
                     stream: Bool = false) -> HandsGatewayReply? {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params }
        if let id { message["id"] = id }
        var headers: [(String, String)] = [("Authorization", "Bearer " + access), ("Content-Type", "application/json"),
                                          ("Accept", stream ? "application/json, text/event-stream" : "application/json")]
        if let session { headers += [("Mcp-Session-Id", session), ("MCP-Protocol-Version", "2025-06-18")] }
        let body = (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
        return send("POST", "/mcp", ip: F.mcpIP, headers: headers, body: body, timeout: 180)
    }

    /// MCP initialize（發 session）＋ notifications/initialized。
    private func initialize(_ access: String) -> String? {
        let client = "w183-integration"
        let params: [String: Any] = ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                                     "clientInfo": ["name": client, "version": "1"]]
        let reply = rpc(access, session: nil, method: "initialize", params: params, id: takeID())
        guard reply?.status == 200, let session = reply?.headers["mcp-session-id"] else { return nil }
        _ = rpc(access, session: session, method: "notifications/initialized")
        return session
    }

    private func toolNames(_ access: String, session: String) -> (status: Int, names: [String]) {
        let reply = rpc(access, session: session, method: "tools/list", params: [:], id: takeID())
        let tools = (reply?.rpc["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        return (reply?.status ?? 0, tools.compactMap { $0["name"] as? String })
    }

    /// tools/call 照 ChatGPT 的樣子要 SSE（關口的長呼叫保活路徑）；token 不對時關口在開串流前就回 401。
    private func callTool(_ access: String, session: String, _ name: String, _ arguments: [String: Any], id: Int? = nil) -> ToolReply {
        let reply = rpc(access, session: session, method: "tools/call", params: ["name": name, "arguments": arguments], id: id ?? takeID(), stream: true)
        let result = reply?.rpc["result"] as? [String: Any] ?? [:]
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return ToolReply(status: reply?.status ?? 0, text: text, isError: (result["isError"] as? Bool) ?? true)
    }

    private static func object(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// 關口的 escapeHTML 只輸出 `&#NN;`。
    private static func unescape(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "&#(\\d+);") else { return text }
        var out = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: out), let digits = Range(match.range(at: 1), in: out),
                  let code = UInt32(out[digits]), let scalar = Unicode.Scalar(code) else { continue }
            out.replaceSubrange(whole, with: String(Character(scalar)))
        }
        return out
    }

    /// 授權頁：交易編號、表單的交易與防偽欄位、防偽 cookie（名稱=值）。
    private static func pairingPage(_ reply: HandsGatewayReply?) -> PairingPage? {
        guard let reply, reply.status == 200 else { return nil }
        let html = reply.text
        guard let display = capture("交易編號 <strong>([^<]+)</strong>", html).map(unescape),
              let transaction = capture("name=\"transaction_id\" value=\"([^\"]+)\"", html).map(unescape),
              let csrf = capture("name=\"csrf\" value=\"([^\"]+)\"", html).map(unescape),
              let cookie = reply.headers["set-cookie"]?.components(separatedBy: ";").first, cookie.hasPrefix("__Host-tatwo-tx-") else { return nil }
        return PairingPage(display: display, transaction: transaction, csrf: csrf, cookie: cookie)
    }

    private static func queryValue(_ name: String, _ url: String) -> String? {
        URLComponents(string: url)?.queryItems?.first { $0.name == name }?.value
    }

    /// App「ChatGPT 手腳」根對話與工作區房間的每一列（給其他 AI 讀的那份）。
    private func handsRows() -> [String] {
        guard let live else { return [] }
        return live.doc.threads.filter { $0.engine == ChatLiveEngine.handsEngine }.flatMap { live.transcript(for: $0.id).map(\.text) }
    }

    /// 完整配對一次（App 按開始配對 → 授權頁 → 讀 App 確認卡的配對碼送出 → /token）。給第 10 步的兩組 grant 用。
    private func pair(client: String, browserIP: String, label: String) -> Grant? {
        state.startPairing()
        guard waitFor(3, { self.state.pairingWindowExpiresAt != nil }) else { return nil }
        let verifier = HandsAuth.random(bytes: 32)
        guard let page = Self.pairingPage(send("GET", authorizeTarget(client: client, verifier: verifier, state: "state-" + label), ip: browserIP)),
              waitFor(3, { self.state.pendingPairing?.displayCode == page.display }),
              let code = state.pendingPairing?.pairingCode else { return nil }
        secrets.append(code)
        guard let done = submit(page, code: code, ip: browserIP), done.status == 302,
              let authCode = done.headers["location"].flatMap({ Self.queryValue("code", $0) }) else { return nil }
        secrets.append(authCode)
        let reply = token([("grant_type", "authorization_code"), ("code", authCode), ("code_verifier", verifier), ("client_id", client),
                           ("redirect_uri", F.redirect), ("resource", F.resource)])
        guard reply?.status == 200, let access = reply?.json["access_token"] as? String, let refresh = reply?.json["refresh_token"] as? String,
              let grant = service.auth.grant(forAccess: access) else { return nil }
        secrets += [access, refresh]
        return Grant(access: access, refresh: refresh, id: grant.grantID)
    }

    // MARK: 十步

    private func steps() {
        let otherClient = step1()
        guard let pending = step2() else { return skipRest(from: 3) }
        guard let authCode = step3(pending) else { return skipRest(from: 4) }
        guard let grantA = step4(client: pending.client, verifier: pending.verifier, code: authCode) else { return skipRest(from: 5) }
        guard let session = step5(grantA) else { return skipRest(from: 6) }
        step6(grantA, session: session)
        step7(grantA, client: pending.client, session: session)
        guard let otherClient else { return skipRest(from: 10) }
        guard let cross = step10(clientA: pending.client, clientB: otherClient) else { return skipRest(from: 8) }
        step8(cross)
        step9()
        leakCheck()
    }

    /// 前面一步沒過：後面的一樣記 FAIL（不是略過）。順序照實際執行的 1–7、10、8、9。
    private func skipRest(from step: Int) {
        let order = [3, 4, 5, 6, 7, 10, 8, 9]
        guard let start = order.firstIndex(of: step) else { return }
        for number in order[start...] { check(false, "整合 \(number)/10：前一步沒過，這一步無法驗") }
    }

    /// 1. 沒開配對窗口 → /authorize 被拒（client 已經註冊好：擋下來的原因只可能是窗口）。
    private func step1() -> String? {
        let registered = register([F.redirect])
        let client = registered?.json["client_id"] as? String ?? ""
        let page = send("GET", authorizeTarget(client: client, verifier: HandsAuth.random(bytes: 32), state: "state-closed"), ip: F.browserIPs[0])
        report("整合 1/10：App 沒開配對窗口 → /authorize 被拒（403「請先在 TATWO 按開始配對」、沒有交易、沒有防偽 cookie、App 沒有確認卡）", [
            registered?.status == 201,
            client.hasPrefix("hc_"),
            page?.status == 403,
            page?.text.contains("再連一次") == true,   // W183 R12：白話的過期頁（沒有「開始配對」這顆鈕了）
            page?.text.contains("交易編號") == false,
            page?.headers["set-cookie"] == nil,
            state.pendingPairing == nil,
            state.pairingWindowExpiresAt == nil,
        ], "register=\(registered?.status ?? 0) authorize=\(page?.status ?? 0)")
        return client.hasPrefix("hc_") ? client : nil
    }

    /// 2. App 開窗口 → 動態註冊（callback 在清單內）→ /authorize GET 顯示交易編號，與 App 確認卡上的一致。
    private func step2() -> (client: String, verifier: String, page: PairingPage)? {
        state.startPairing()
        let windowOpen = waitFor(3) { self.state.pairingWindowExpiresAt != nil }
        let bad = register(["https://evil.example.com/oauth/callback"])
        let good = register([F.redirect])
        let client = good?.json["client_id"] as? String ?? ""
        let verifier = HandsAuth.random(bytes: 32)
        let reply = send("GET", authorizeTarget(client: client, verifier: verifier, state: "state-a"), ip: F.browserIPs[1])
        let page = Self.pairingPage(reply)
        let shown = waitFor(3) { page != nil && self.state.pendingPairing?.displayCode == page?.display }
        let card = state.pendingPairing
        let expected = [projectID.uuidString]
        report("整合 2/10：App 開窗口 → 動態註冊（清單外的 callback 400 invalid_redirect_uri、清單內 201）→ 授權頁顯示的交易編號跟 App 確認卡一致（回呼網域 chatgpt.com、等級 L1、這個專案；CSP 擋框架）", [
            windowOpen,
            bad?.status == 400,
            bad?.json["error"] as? String == "invalid_redirect_uri",
            good?.status == 201,
            client.hasPrefix("hc_"),
            page != nil,
            shown,
            card?.callbackHost == "chatgpt.com",
            card?.callbackURL == F.redirect,
            reply?.text.contains("chatgpt.com") == true,
            card?.scope.level == 1,
            card?.scope.projects.map(\.id) == expected,
            reply?.headers["content-security-policy"]?.contains("frame-ancestors 'none'") == true,
        ], "bad=\(bad?.status ?? 0) good=\(good?.status ?? 0) authorize=\(reply?.status ?? 0)")
        guard let page, shown else { return nil }
        return (client, verifier, page)
    }

    /// 3. 錯碼 → 剩餘次數遞減；對碼（從 App 狀態讀）→ 302 帶授權碼。
    private func step3(_ pending: (client: String, verifier: String, page: PairingPage)) -> String? {
        let code = state.pendingPairing?.pairingCode ?? ""
        let wrongCode = code == "22222222" ? "33333333" : "22222222"
        let wrong = submit(pending.page, code: wrongCode, ip: F.browserIPs[1])
        let decremented = waitFor(3) { self.state.pendingPairing?.attemptsLeft == 4 }
        let right = submit(pending.page, code: code, ip: F.browserIPs[1])
        let location = right?.headers["location"] ?? ""
        let authCode = Self.queryValue("code", location) ?? ""
        let closed = waitFor(3) { self.state.pendingPairing == nil && self.state.pairingWindowExpiresAt == nil }
        secrets += [code, authCode]
        report("整合 3/10：錯碼 → 授權頁「還可以再試 4 次」、App 確認卡同步剩 4 次；對碼（從 App 狀態讀）→ 302 帶授權碼回 ChatGPT 回呼（state 原樣、iss）、清掉防偽 cookie、窗口關閉", [
            code.count == 8,
            wrong?.status == 400,
            wrong?.text.contains("還可以再試 4 次") == true,
            decremented,
            right?.status == 302,
            location.hasPrefix(F.redirect + "?"),
            authCode.hasPrefix("tatwoh_ac_"),
            Self.queryValue("state", location) == "state-a",
            Self.queryValue("iss", location) == F.issuer,
            right?.headers["set-cookie"]?.contains("Max-Age=0") == true,
            closed,
        ], "wrong=\(wrong?.status ?? 0) right=\(right?.status ?? 0)")
        return authCode.hasPrefix("tatwoh_ac_") ? authCode : nil
    }

    /// 4. /token（PKCE S256）拿到 access＋refresh。
    private func step4(client: String, verifier: String, code: String) -> Grant? {
        let reply = token([("grant_type", "authorization_code"), ("code", code), ("code_verifier", verifier), ("client_id", client),
                           ("redirect_uri", F.redirect), ("resource", F.resource)])
        let body = reply?.json ?? [:]
        let access = body["access_token"] as? String ?? ""
        let refresh = body["refresh_token"] as? String ?? ""
        secrets += [access, refresh]
        let grant = service.auth.grant(forAccess: access)
        let grantID = grant?.grantID ?? "-"
        let listed = waitFor(3) { self.state.activeGrants.contains { $0.id == grantID } }
        report("整合 4/10：/token（PKCE S256）拿到 access＋refresh（Bearer、3600 秒、no-store）；App 記成一個 L1 grant（這個 client、這個專案），設定頁看得到", [
            reply?.status == 200,
            access.hasPrefix("tatwoh_at_"),
            refresh.hasPrefix("tatwoh_rt_"),
            body["token_type"] as? String == "Bearer",
            body["expires_in"] as? Int == 3600,
            reply?.headers["cache-control"] == "no-store",
            grant?.grantLevel == 1,
            grant?.clientID == client,
            grant?.projectIDs == [projectID.uuidString],
            listed,
        ], "token=\(reply?.status ?? 0)")
        guard let grant else { return nil }
        return Grant(access: access, refresh: refresh, id: grant.grantID)
    }

    /// 5. initialize、tools/list（L1 看不到 L2 工具）、tools/call 讀測試專案的檔。
    private func step5(_ grant: Grant) -> String? {
        let session = initialize(grant.access)
        let listed = session.map { toolNames(grant.access, session: $0) }
        let names = Set(listed?.names ?? [])
        let levelOne = Set(HandsTools.catalog(level: 1).map(\.name))
        let levelTwo = HandsTools.all.filter { $0.level == 2 }.map(\.name)
        let read = session.map { callTool(grant.access, session: $0, "read_file", ["project_id": projectID.uuidString, "path": "README.md"]) }
        let lines = Self.object(read?.text ?? "")["lines"] as? String ?? ""
        let rows = handsRows()
        let known = secrets
        report("整合 5/10：initialize 發 session；tools/list 只有 L0＋L1 的 \(names.count) 個工具（L2 的 \(levelTwo.count) 個一個都看不到）；tools/call read_file 讀到測試專案目前 commit 的 README.md；App 的「ChatGPT 手腳」紀錄記了這一列（標外部資料、沒有 token）", [
            session != nil,
            listed?.status == 200,
            !names.isEmpty && names == levelOne,
            !levelTwo.isEmpty && levelTwo.allSatisfy { !names.contains($0) },
            read?.status == 200,
            read?.isError == false,
            lines.contains(F.fixtureLine),
            rows.contains { $0.contains("read_file") && $0.contains("外部資料") },
            !rows.contains { row in known.contains { !$0.isEmpty && row.contains($0) } },
        ], "tools=\(names.sorted()) read=\(read?.status ?? 0)")
        return session
    }

    /// 6. 同 request_id＋同參數重送 → 同結果、不重做；不同參數 → 拒。（關口的 request_id＝grant＋session＋JSON-RPC id 推出來的。）
    private func step6(_ grant: Grant, session: String) {
        let arguments: [String: Any] = ["title": "integration note", "content": "the integration fixture passed step six"]
        let id = takeID()
        let first = callTool(grant.access, session: session, "memory_inbox_save", arguments, id: id)
        let again = callTool(grant.access, session: session, "memory_inbox_save", arguments, id: id)
        var changed = arguments
        changed["content"] = "different content under the same request id"
        let conflict = callTool(grant.access, session: session, "memory_inbox_save", changed, id: id)
        let list = callTool(grant.access, session: session, "memory_inbox_list", [:])
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: service.inboxDirectory.path)) ?? []).filter { $0.hasSuffix(".json") }
        report("整合 6/10：同 request_id＋同參數重送 → 回同一個結果、不重做（收件匣只有 1 條）；同 request_id 換參數 → 拒（request_id reused with different arguments）", [
            first.status == 200,
            !first.isError,
            again.status == 200,
            again.text == first.text,
            again.isError == first.isError,
            conflict.isError,
            conflict.text.contains("request_id reused"),
            Self.object(list.text)["total"] as? Int == 1,
            files.count == 1,
        ], "first=\(first.status) again=\(again.status) conflict=\(conflict.status) files=\(files.count)")
    }

    /// 7. refresh 輪替成功；舊 refresh 再用 → 該 grant 被撤銷 → access token 401。
    private func step7(_ grant: Grant, client: String, session: String) {
        let rotated = token([("grant_type", "refresh_token"), ("refresh_token", grant.refresh), ("client_id", client)])
        let access = rotated?.json["access_token"] as? String ?? ""
        let refresh = rotated?.json["refresh_token"] as? String ?? ""
        secrets += [access, refresh]
        let fresh = toolNames(access, session: session)
        let oldAccess = rpc(grant.access, session: session, method: "tools/list", params: [:], id: takeID())
        let reuse = token([("grant_type", "refresh_token"), ("refresh_token", grant.refresh), ("client_id", client)])
        let after = callTool(access, session: session, "tatwo_status", [:])
        let record = service.auth.grantRecord(grant.id)
        let shown = waitFor(3) { self.state.grants.first { $0.id == grant.id }?.revokedAt != nil }
        report("整合 7/10：refresh 輪替成功（新 access 可用、舊 access 401）；舊 refresh 再用 → 400 invalid_grant、該 grant 撤銷（refresh_reused，設定頁看得到）→ 這個 grant 的 access 一律 401", [
            rotated?.status == 200,
            access.hasPrefix("tatwoh_at_"),
            refresh.hasPrefix("tatwoh_rt_") && refresh != grant.refresh,
            fresh.status == 200 && !fresh.names.isEmpty,
            oldAccess?.status == 401,
            oldAccess?.headers["www-authenticate"]?.contains("invalid_token") == true,
            reuse?.status == 400,
            reuse?.json["error"] as? String == "invalid_grant",
            after.status == 401,
            record?.revokedAt != nil,
            record?.revokeReason == "refresh_reused",
            shown,
        ], "rotate=\(rotated?.status ?? 0) old=\(oldAccess?.status ?? 0) reuse=\(reuse?.status ?? 0) after=\(after.status)")
    }

    /// 10. 跨 grant：第二組配對（另一個 ChatGPT 連線）拿到的 token 看不到第一組的工作區。兩組都要 L2 才開得了工作區。
    private func step10(clientA: String, clientB: String) -> (x: Grant, y: Grant, sessionX: String, sessionY: String, workspace: String)? {
        state.setLevel(2)
        guard let x = pair(client: clientA, browserIP: F.browserIPs[2], label: "x"),
              let y = pair(client: clientB, browserIP: F.browserIPs[3], label: "y"),
              let sessionX = initialize(x.access), let sessionY = initialize(y.access) else {
            check(false, "整合 10/10：兩組 L2 配對沒有完成，跨 grant 無法驗"); return nil
        }
        let opened = callTool(x.access, session: sessionX, "open_workspace", ["project_id": projectID.uuidString, "title": "integration"])
        let workspace = Self.object(opened.text)["workspace_id"] as? String ?? ""
        let listX = callTool(x.access, session: sessionX, "list_workspaces", [:])
        let ownRead = callTool(x.access, session: sessionX, "read_file", ["workspace_id": workspace, "path": "README.md"])
        let listY = callTool(y.access, session: sessionY, "list_workspaces", [:])
        let crossRead = callTool(y.access, session: sessionY, "read_file", ["workspace_id": workspace, "path": "README.md"])
        let statusY = callTool(y.access, session: sessionY, "tatwo_status", [:])
        report("整合 10/10：第二組配對（另一個 ChatGPT 連線）的 token 看不到第一組的工作區（list_workspaces 空、read_file 回 workspace_not_found、狀態裡沒有）；第一組自己讀得到", [
            x.id != y.id,
            service.auth.grant(forAccess: x.access)?.grantLevel == 2,
            service.auth.grant(forAccess: y.access)?.clientID == clientB,
            !opened.isError,
            UUID(uuidString: workspace) != nil,
            listX.text.contains(workspace),
            !ownRead.isError && ownRead.text.contains(F.fixtureLine),
            !listY.isError,
            (Self.object(listY.text)["workspaces"] as? [Any])?.isEmpty == true,
            crossRead.isError,
            crossRead.text.contains("workspace_not_found"),
            !crossRead.text.contains(F.fixtureLine),
            !statusY.isError && !statusY.text.contains(workspace),
        ], "open=\(opened.isError ? "error" : "ok") crossRead=\(crossRead.isError ? "error" : "ok")")
        guard !workspace.isEmpty else { return nil }
        return (x, y, sessionX, sessionY, workspace)
    }

    /// 8. 從 App 撤銷 grant → tools/call 401；開關關掉 → 全部 grant 撤銷（關口一起停、解除登記）；重新打開 → 舊 token 一律 401。
    private func step8(_ cross: (x: Grant, y: Grant, sessionX: String, sessionY: String, workspace: String)) {
        guard let gateway else { return check(false, "整合 8/10：關口不在") }
        state.revokeGrant(cross.x.id)
        let revokedCall = callTool(cross.x.access, session: cross.sessionX, "list_workspaces", [:])
        let otherStill = callTool(cross.y.access, session: cross.sessionY, "tatwo_status", [:])
        let locked = UUID(uuidString: cross.workspace).flatMap { service.workspaceStore.record($0) }?.isLocked == true
        let before = gateway.debugProcesses.gateway
        state.setEnabled(false)
        let allRevoked = service.auth.activeGrantIDs.isEmpty && waitFor(3) { self.state.activeGrants.isEmpty }
        let stopped = waitFor(15) {
            gateway.debugPhase == .stopped && gateway.debugProcesses.gateway == nil && !(before.map { HandsGatewayAcceptance.alive($0.pid) } ?? true)
        }
        let unregistered = before.map { OSSocketCaller.currentRoots()[$0.pid] == nil } ?? false
        state.setEnabled(true)
        let url = F.resource
        let back = waitFor(30) { gateway.debugPhase == .running(url: url) }
        let again = gateway.debugProcesses.gateway
        let reRegistered = again.map { $0.pid != before?.pid && OSSocketCaller.currentRoots()[$0.pid]?.root == .externalAI } ?? false
        let yAfter = callTool(cross.y.access, session: cross.sessionY, "tatwo_status", [:])
        let xAfter = callTool(cross.x.access, session: cross.sessionX, "tatwo_status", [:])
        report("整合 8/10：從 App 撤銷一個 grant → 它的 tools/call 401、它的工作區鎖住，另一個照常；開關關掉 → 全部 grant 撤銷、關口停下並解除登記；重新打開 → 關口重新登記，舊 token 一律 401（要重新配對）", [
            revokedCall.status == 401,
            otherStill.status == 200 && !otherStill.isError,
            locked,
            before != nil,
            allRevoked,
            stopped,
            unregistered,
            back,
            reRegistered,
            yAfter.status == 401,
            xAfter.status == 401,
        ], "revoked=\(revokedCall.status) other=\(otherStill.status) phase=\(gateway.debugPhase) y=\(yAfter.status) x=\(xAfter.status)")
    }

    /// 9. 身分：測試用小程式登記成 `.externalAI` 直接連 os.sock 叫白名單外的方法 → 全拒；它開的子行程連 os.sock → `.other`、`hands_*` 也拒。
    /// 一次只有一個外部 AI 登記：先把關口停掉（解除登記）再做。
    private func step9() {
        if let gateway {
            gateway.stop()
            _ = waitFor(15) { gateway.debugPhase == .stopped && gateway.debugProcesses.gateway == nil }
        }
        OSSocketCaller.unregisterExternalAI()
        let outside = ["transcript", "dispatch_rooms", "hands_setup_status", "list_devices", "run_background", "memory_save",
                       "get_document", "send_message", "os_status", "computer_screenshot"]
        var refused: [String] = []
        var registeredAll = true
        for method in outside {
            let result = viaSocket(exec: true, method: method, params: ["callerThreadID": UUID().uuidString])
            registeredAll = registeredAll && result.registered
            if result.reply.contains("caller_not_trusted") { refused.append(method) }
        }
        let own = viaSocket(exec: true, method: "hands_tools", params: ["access_token": "tatwoh_at_not-a-real-token"])
        let childTools = viaSocket(exec: false, method: "hands_tools", params: ["access_token": "tatwoh_at_not-a-real-token"])
        let childAuth = viaSocket(exec: false, method: "hands_auth", params: ["op": "check", "access_token": "tatwoh_at_not-a-real-token"])
        let statusTool = "tatwo_status"
        let childCall = viaSocket(exec: false, method: "hands_call", params: ["access_token": "tatwoh_at_not-a-real-token", "name": statusTool])
        OSSocketCaller.unregisterExternalAI()
        report("整合 9/10：測試用小程式登記成外部 AI、直接連 os.sock：白名單外的 \(outside.count) 個方法（transcript、dispatch_rooms、hands_setup_status…）全拒；它自己叫 hands_tools 只被 token 擋（身分有認）；它開的子行程連 os.sock＝其他程式，hands_tools／hands_auth／hands_call 也全拒", [
            registeredAll,
            refused == outside,
            own.registered,
            own.reply.contains("\"unauthorized\""),
            !own.reply.contains("caller_not_trusted"),
            childTools.registered && childTools.reply.contains("caller_not_trusted"),
            childAuth.registered && childAuth.reply.contains("caller_not_trusted"),
            childCall.registered && childCall.reply.contains("caller_not_trusted"),
        ], "refused=\(refused.count)/\(outside.count) own=\(own.reply.prefix(120)) child=\(childTools.reply.prefix(120))")
    }

    /// `/bin/sh -c "sleep; [exec] nc -U os.sock < 請求 > 回應"`：App 直接開、馬上登記 sh 的 pid 成外部 AI。
    /// exec＝nc 換掉 sh（連線的就是登記的 pid 本人）；不 exec＝nc 是它的子行程（最後多一個指令，sh 不會直接換成 nc）。
    private func viaSocket(exec: Bool, method: String, params: [String: Any]) -> (reply: String, registered: Bool) {
        guard let base else { return ("", false) }
        let tag = UUID().uuidString.prefix(8)
        let requestFile = base.appendingPathComponent("req-\(tag).json").path
        let outputFile = base.appendingPathComponent("out-\(tag).json").path
        guard var body = try? JSONSerialization.data(withJSONObject: ["id": "r4", "method": method, "params": params]) else { return ("", false) }
        body.append(0x0A)
        guard FileManager.default.createFile(atPath: requestFile, contents: body) else { return ("", false) }
        let nc = "/usr/bin/nc -w 5 -U \"$0\" < \"$1\" > \"$2\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.5; " + (exec ? "exec " + nc : nc + "; rc=$?; exit $rc"), osSocket, requestFile, outputFile]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = HandsIntegrationBox<Bool>()
        process.terminationHandler = { _ in finished.finish(true) }
        do { try process.run() } catch { return ("", false) }
        let pid = process.processIdentifier
        OSSocketCaller.registerExternalAI(pid: pid, startTime: OSSocketCaller.processStartTime(pid) ?? 0, thread: HandsGatewayLaunch.unboundThread)
        let registered = OSSocketCaller.currentRoots()[pid]?.root == .externalAI
        _ = waitFor(15) { finished.done }
        OSSocketCaller.unregisterExternalAI(pid: pid)
        return ((try? String(contentsOfFile: outputFile, encoding: .utf8)) ?? "", registered)
    }

    /// 秘密不外流：走過的 token、refresh、授權碼、配對碼都不在關口日誌、關口設定、App 的手腳紀錄裡。
    private func leakCheck() {
        guard let gatewayRoot else { return }
        let paths = HandsGatewayLaunch.Paths(root: gatewayRoot)
        let log = (try? String(contentsOf: paths.logFile, encoding: .utf8)) ?? ""
        let config = (try? String(contentsOf: paths.gatewayConfig, encoding: .utf8)) ?? ""
        let rows = handsRows().joined(separator: "\n")
        let known = secrets.filter { $0.count >= 8 }
        let leaked = known.filter { log.contains($0) || config.contains($0) || rows.contains($0) }
        report("整合：這一輪走過的 \(known.count) 個 token／refresh／授權碼／配對碼，沒有一個落在關口日誌、關口設定或 App 的手腳紀錄", [
            known.count >= 10,
            log.contains(" POST mcp 200 "),
            leaked.isEmpty,
        ], "leaked=\(leaked.count)")
    }

    private func cleanup() {
        if let gateway {
            gateway.stop()
            _ = waitFor(10) { gateway.debugPhase == .stopped && gateway.debugProcesses.gateway == nil }
        }
        OSSocketCaller.unregisterExternalAI()
        if state.settings.enabled { state.setEnabled(false) }   // 撤銷全部 grant、鎖工作區
        HandsSandbox.terminateAll()
        live?.shutdownAll()
        if let gatewayRoot { try? FileManager.default.removeItem(at: gatewayRoot) }   // app/ 是捷徑：只刪捷徑本身
    }
}
#endif
