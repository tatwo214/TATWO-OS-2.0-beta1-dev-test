#if DEBUG
import Darwin
import Foundation

/// `TATWO2_SELFTEST=w183hands`：ChatGPT 手腳的 App 核心（W183 R1＋R1b，接口 v2＋v3）。只在完整隔離的 staging 環境跑；
/// 不開通道、不啟動關口、不送引擎。涵蓋：外部 AI 身分（真的 os.sock 連線、不綁對話）、配對窗口與確認卡、grant 與 token、
/// 跨 grant 越權、Seatbelt 沙盒探針（真的跑 sandbox-exec）、匯出工作區（沒有正本歷史）、交件候選 commit（不觸發 hook／filter）、
/// 長工作與輸出區、request_id、記憶與收件匣、審查與合併的固定 SHA、施工房。
/// W183 R1b：另驗審查修正——真的在正本合併的陷阱測試、對照組、截斷即拒、啟動前授權、交件鎖、掃描無法判定、撤銷存檔失敗、遮蔽、磁碟。
enum HandsAcceptance {
    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
        func update(_ change: (inout T) -> Void) { lock.lock(); change(&value); lock.unlock() }
    }

    @MainActor static func run() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment),
              NativeStagingIsolation.validationError(environment) == nil,
              let livePath = environment["TATWO2_LIVE_ROOT"],
              let stagingPath = environment["TATWO_STAGING_ROOT"] else {
            throw BotLibraryError.invalid("w183hands needs a fully isolated staging environment")
        }
        let fm = FileManager.default
        guard let staging = HandsPath.realpath(stagingPath), let liveReal = HandsPath.realpath(livePath),
              liveReal.hasPrefix(staging + "/") else {
            throw BotLibraryError.invalid("TATWO2_LIVE_ROOT must be inside TATWO_STAGING_ROOT")
        }
        var passed = 0, failed = 0
        func check(_ condition: Bool, _ label: String, _ evidence: String = "") {
            if condition { passed += 1 } else { failed += 1 }
            print("W183HANDS \(condition ? "PASS" : "FAIL") \(label)\(condition || evidence.isEmpty ? "" : " — " + String(evidence.prefix(700)))")
        }

        // ---------- 假資料（全部在 staging 裡） ----------
        let base = URL(fileURLWithPath: staging).appendingPathComponent("w183-\(UUID().uuidString.prefix(8))", isDirectory: true)
        func dir(_ name: String) throws -> String {
            let url = base.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return HandsPath.realpath(url.path) ?? url.path
        }
        let fakeHome = try dir("fakehome"), entry = try dir("entry"), appSupport = try dir("appsupport")
        let outside = try dir("outside"), handsRoot = try dir("hands"), project = try dir("project"), flags = try dir("flags")
        let canary = "W183CANARY" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try fm.createDirectory(atPath: fakeHome + "/.ssh", withIntermediateDirectories: true)
        try (canary + "-ssh\n").write(toFile: fakeHome + "/.ssh/id_test", atomically: true, encoding: .utf8)
        try fm.createDirectory(atPath: entry + "/memory", withIntermediateDirectories: true)
        try (canary + "-user\n").write(toFile: entry + "/user.md", atomically: true, encoding: .utf8)
        try "---\nname: Favorite coffee\ndescription: coffee order\nmetadata:\n  type: user\n---\n\nThe user likes an oat latte (coffee).\n"
            .write(toFile: entry + "/memory/coffee.md", atomically: true, encoding: .utf8)
        try "---\nname: Coffee plan hidden\nchatgpt: hidden\nmetadata:\n  type: project\n---\n\ncoffee \(canary)-hidden\n"
            .write(toFile: entry + "/memory/coffee-hidden.md", atomically: true, encoding: .utf8)
        // W183 R1b：行尾有註解的安全欄位（舊的逐行 regex 認不出來）。
        try "---\nname: Coffee beans unverified\nmetadata:\n  type: reference\n  verified: false # 尚待確認\n---\n\ncoffee beans from a blog\n"
            .write(toFile: entry + "/memory/coffee-unverified.md", atomically: true, encoding: .utf8)
        try "---\nname: Coffee budget private\nchatgpt: hidden # 私人\nmetadata:\n  type: user\n---\n\ncoffee budget \(canary)-comment\n"
            .write(toFile: entry + "/memory/coffee-comment.md", atomically: true, encoding: .utf8)
        func git(_ args: [String], cwd: String, hooks: Bool = false) -> (Int32, String) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = (hooks ? [] : ["-c", "core.hooksPath=/dev/null"]) + ["-c", "commit.gpgSign=false", "-c", "core.fsmonitor=false"] + args
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            var env = ProcessInfo.processInfo.environment
            for key in env.keys where key.hasPrefix("GIT_") { env[key] = nil }
            env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_CONFIG_NOSYSTEM"] = "1"
            process.environment = env
            process.standardOutput = pipe; process.standardError = pipe
            do { try process.run() } catch { return (-1, "\(error)") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        func commit(_ message: String, cwd: String) {
            _ = git(["-c", "user.name=fixture", "-c", "user.email=hands-fixture@localhost", "commit", "-q", "-m", message], cwd: cwd)
        }
        // 正本：第一個 commit 有歷史秘密（之後刪掉）；.gitattributes 用一個 filter；.gitignore 排除 node_modules。
        try "history \(canary)-history\n".write(toFile: project + "/old-secret.txt", atomically: true, encoding: .utf8)
        _ = git(["init", "-q", "-b", "main"], cwd: project)
        _ = git(["add", "-A"], cwd: project)
        commit("first", cwd: project)
        let firstCommit = git(["rev-parse", "HEAD"], cwd: project).1.trimmingCharacters(in: .whitespacesAndNewlines)
        try fm.removeItem(atPath: project + "/old-secret.txt")
        try "base\n".write(toFile: project + "/README.md", atomically: true, encoding: .utf8)
        try "*.txt filter=trace\n".write(toFile: project + "/.gitattributes", atomically: true, encoding: .utf8)
        try "node_modules/\n.env\n.build/\n".write(toFile: project + "/.gitignore", atomically: true, encoding: .utf8)
        try "note\n".write(toFile: project + "/notes.txt", atomically: true, encoding: .utf8)
        try "{\"name\":\"fixture\"}\n".write(toFile: project + "/package.json", atomically: true, encoding: .utf8)
        try "agent rules\n".write(toFile: project + "/AGENTS.md", atomically: true, encoding: .utf8)
        // W183 R1b：子資料夾裡的指示文件（擋「整個上層資料夾搬走改完再搬回來」）、已提交的私鑰（遮蔽要看整個檔）。
        try fm.createDirectory(atPath: project + "/docs", withIntermediateDirectories: true)
        try "docs rules\n".write(toFile: project + "/docs/AGENTS.md", atomically: true, encoding: .utf8)
        try "# docs\n".write(toFile: project + "/docs/README.md", atomically: true, encoding: .utf8)
        let pemSecret = "PEMSECRET" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let pemBody = [pemSecret + "Aa1" + String(repeating: "Bb2", count: 12), "Cc3" + pemSecret + String(repeating: "Dd4", count: 10), "Ee5" + pemSecret]
        // 標記在執行時拼（原始碼裡不放完整的私鑰標記，公開倉掃描才不會誤判）。
        func keyMarker(_ kind: String, _ type: String = "") -> String {
            String(repeating: "-", count: 5) + kind + " " + type + "PRIVATE" + " KEY" + String(repeating: "-", count: 5)
        }
        let pemText = ([keyMarker("BEGIN")] + pemBody + [keyMarker("END")]).joined(separator: "\n") + "\n"
        try fm.createDirectory(atPath: project + "/keys", withIntermediateDirectories: true)
        try pemText.write(toFile: project + "/keys/fixture.pem", atomically: true, encoding: .utf8)
        // W183 R10：同一段私鑰也放進名字不像金鑰的檔（*.pem 現在整個讀不到——底線 A；內容遮蔽照樣要驗，改用這一個）。
        try ("key notes\n" + pemText).write(toFile: project + "/docs/key-notes.md", atomically: true, encoding: .utf8)
        func leaksPEM(_ text: String) -> Bool {
            let chars = Array(pemSecret)
            return (0...(chars.count - 12)).contains { text.contains(String(chars[$0..<($0 + 12)])) }
        }
        _ = git(["add", "-A"], cwd: project)
        commit("base", cwd: project)
        let baseCommit = git(["rev-parse", "HEAD"], cwd: project).1.trimmingCharacters(in: .whitespacesAndNewlines)
        try fm.createDirectory(atPath: project + "/node_modules/dep", withIntermediateDirectories: true)
        try "module.exports = 1;\n".write(toFile: project + "/node_modules/dep/index.js", atomically: true, encoding: .utf8)
        // W183 R10 第二輪（GPT-6 4）：依賴裡的金鑰與別人的 Git 物件庫（複製進工作區之後要拿掉）；.build 不提交（.gitignore）。
        try (canary + "-dep-env\n").write(toFile: project + "/node_modules/dep/.env", atomically: true, encoding: .utf8)
        try fm.createDirectory(atPath: project + "/node_modules/dep/.git", withIntermediateDirectories: true)
        try (canary + "-dep-git\n").write(toFile: project + "/node_modules/dep/.git/config", atomically: true, encoding: .utf8)
        try fm.createDirectory(atPath: project + "/.build/checkouts/pkg/Sources", withIntermediateDirectories: true)
        try "let x = 1\n".write(toFile: project + "/.build/checkouts/pkg/Sources/x.swift", atomically: true, encoding: .utf8)
        try fm.createDirectory(atPath: project + "/.build/checkouts/pkg/.git", withIntermediateDirectories: true)
        try (canary + "-checkout-git\n").write(toFile: project + "/.build/checkouts/pkg/.git/HEAD", atomically: true, encoding: .utf8)
        try fm.createDirectory(atPath: project + "/.build/repositories/pkg-1234", withIntermediateDirectories: true)
        try (canary + "-repositories\n").write(toFile: project + "/.build/repositories/pkg-1234/HEAD", atomically: true, encoding: .utf8)
        // 會留痕跡的 hook、filter、fsmonitor（加固的 git 一個都不能跑）。
        let trap = flags + "/trap.sh"
        try "#!/bin/sh\necho \"$0 $*\" >> '\(flags)/ran.log'\ncat\n".write(toFile: trap, atomically: true, encoding: .utf8)
        _ = chmod(trap, 0o755)
        for hook in ["pre-commit", "post-commit", "post-checkout", "reference-transaction", "post-index-change", "pre-auto-gc"] {
            try "#!/bin/sh\necho \(hook) >> '\(flags)/ran.log'\n".write(toFile: project + "/.git/hooks/" + hook, atomically: true, encoding: .utf8)
            _ = chmod(project + "/.git/hooks/" + hook, 0o755)
        }
        _ = git(["config", "filter.trace.clean", "'" + trap + "' clean"], cwd: project)
        _ = git(["config", "filter.trace.smudge", "'" + trap + "' smudge"], cwd: project)
        _ = git(["config", "core.fsmonitor", "'" + trap + "'"], cwd: project)
        _ = git(["config", "remote.origin.url", "https://x:\(canary)@example.com/r.git"], cwd: project)
        _ = git(["config", "user.name", "fixture"], cwd: project)   // 合併提交用（staging 沒有全域設定）
        _ = git(["config", "user.email", "hands-fixture@localhost"], cwd: project)
        /// 對照組用：不加任何 -c（會照正本的設定跑 fsmonitor、filter、hook）。
        func rawGit(_ args: [String], cwd: String) -> (Int32, String) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            var env = ProcessInfo.processInfo.environment
            for key in env.keys where key.hasPrefix("GIT_") { env[key] = nil }
            env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_CONFIG_NOSYSTEM"] = "1"
            process.environment = env
            process.standardOutput = pipe; process.standardError = pipe
            do { try process.run() } catch { return (-1, "\(error)") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        let ranLog = flags + "/ran.log"
        func trapsRan() -> Bool { fm.fileExists(atPath: ranLog) }

        // ---------- App：本機引擎資料＋model（不送引擎） ----------
        let liveRoot = URL(fileURLWithPath: liveReal).appendingPathComponent("w183", isDirectory: true)
        try fm.createDirectory(at: liveRoot, withIntermediateDirectories: true)
        let live = ChatLiveEngine(store: ChatLiveStore(root: liveRoot), environment: environment)
        defer { live.shutdownAll() }
        let bots = BotLibrary(root: liveRoot, skillsRoot: base.appendingPathComponent("bot-skills", isDirectory: true))
        await bots.ready()
        let model = ChatPageModel(environment: environment, botCoreFixture: (live, BotStore(library: bots)))
        let projectID = live.newProject(name: "Hands fixture", workdir: project)
        let homeProjectID = live.newProject(name: "Home folder", workdir: fakeHome)
        let selectedBefore = live.doc.selectedThreadID

        let paths = HandsPaths(root: URL(fileURLWithPath: handsRoot))
        let auth = HandsAuth(url: paths.authFile)
        let clock = Box(Date())
        auth.now = { clock.get() }
        let cards = Box<[HandsPairingCard?]>([])
        auth.onPairingCard = { card in cards.update { $0.append(card) } }
        let node = HandsRuntime.nodeExecutable(environment: environment)
        let runtime = HandsRuntime(paths: paths, home: fakeHome, entryRoot: entry, appSupport: appSupport, fsopPath: HandsRuntime.fsopScript(),
                                   nodePath: node?.path, nodeBundled: node?.bundled ?? false, extraDeniedDirectories: [], environment: [:])
        let service = HandsService(paths: paths, auth: auth, runtime: runtime)
        service.deviceIDOverride = "this-device"
        service.callsPerMinute = 100_000
        let memoryStore = TatwoMemoryStore()
        memoryStore.pathsOverride = EngineMemoryPaths(home: fakeHome, entryRoot: URL(fileURLWithPath: entry))
        service.memoryStore = memoryStore
        let islandTitles = Box<[String]>([])
        service.noticeSink = { title, _ in islandTitles.update { $0.append(title) } }
        service.attach(model: model)
        check(runtime.fsopPath != nil && runtime.nodePath != nil, "檔案小幫手與 node 找得到",
              "fsop=\(runtime.fsopPath ?? "nil") node=\(runtime.nodePath ?? "nil")")
        _ = try service.updateSettings { $0.enabled = true; $0.level = 2; $0.allowedProjectIDs = [projectID.uuidString, homeProjectID.uuidString] }

        func call(_ method: String, _ params: [String: Any]) async -> [String: Any] {
            let data = await Task.detached { () -> Data in
                let response = OSAgentBridge.handsResponse(method: method, params: params, service: service)
                return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
            }.value
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        func result(_ response: [String: Any]) -> [String: Any] { response["result"] as? [String: Any] ?? [:] }
        func errorCode(_ response: [String: Any]) -> String {
            ((response["error"] as? [String: Any])?["code"] as? String) ?? (response["error"] as? String ?? "")
        }
        func tool(_ name: String, _ arguments: [String: Any], token: String, requestID: String? = UUID().uuidString) async -> (text: String, isError: Bool, raw: [String: Any]) {
            var params: [String: Any] = ["access_token": token, "name": name, "arguments": arguments]
            if let requestID { params["request_id"] = requestID }
            let response = await call("hands_call", params)
            let content = (result(response)["content"] as? [[String: Any]])?.first?["text"] as? String ?? errorCode(response)
            return (content, (result(response)["isError"] as? Bool) ?? true, response)
        }
        func object(_ text: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:] }

        // ---------- 1. 身分（T7；接口 v2 §1：不綁對話） ----------
        func s1Identity() async throws {
            let externalCaller = OSSocketCaller.externalAI
            check(!externalCaller.isTrusted && !externalCaller.isLocalApp && externalCaller.boundThread == nil && externalCaller.label == "externalAI",
                  "身分：外部 AI 不是自己人、不是 App、不綁對話")
            let everything = OSAgentBridge.untrustedCallerMethods.union(OSAgentBridge.stagingReadOnlyMethods)
                .union(OSAgentBridge.sshForwardMethods).union([
                    "whoami", "run_background", "background_status", "stop_background", "dispatch_rooms", "list_rooms", "stop_room",
                    "stop_all_rooms", "merge_reports", "reclaim_room", "cli_open", "cli_send", "cli_tail", "cli_close", "computer_click",
                    "computer_screenshot", "computer_stop", "ipad_tap", "send_message", "transcript", "get_document", "new_thread",
                    "memory_search", "memory_get", "memory_save", "goal_list", "goal_propose", "goal_update", "user_remember",
                    "os_status", "goal_index", "app_terminate_for_update", "ui_probe", "github_import_from_gh", "job_submit",
                    "distill_write", "assistant_append_offline", "project_overview", "project_suggest", "bot_list",
                ])
            check(everything.allSatisfy { !OSAgentBridge.allows(caller: externalCaller, method: $0, params: [:], staging: true) },
                  "身分：白名單外的方法全拒（\(everything.count) 個，含 staging）")
            check(HandsContract.externalAIMethods.allSatisfy { OSAgentBridge.allows(caller: externalCaller, method: $0, params: [:], staging: false) },
                  "身分：外部 AI 只能用 hands_tools／hands_call／hands_auth")
            let someThread = UUID()
            check(HandsContract.externalAIMethods.allSatisfy { method in
                [OSSocketCaller.app, .engine(someThread), .job(someThread), .helper, .ssh, .other(pid: nil)].allSatisfy {
                    !OSAgentBridge.allows(caller: $0, method: method, params: [:], staging: true) } },
                  "身分：這三個方法別的呼叫者（含 App 自己、引擎、SSH）都不能用")
            let stripped = OSAgentBridge.handsParams(["callerThreadID": someThread.uuidString, "_threadID": someThread.uuidString, "op": "check"])
            check(stripped["callerThreadID"] == nil && stripped["_threadID"] == nil && stripped["op"] as? String == "check",
                  "身分：thread 參數一律拿掉（授權看 grant）")
            if let socketPath = environment["TATWO2_OS_SOCKET"] {
                OSAgentBridge.shared.configureCallerTest(model: model, manager: BackgroundJobManager())
                OSAgentBridge.shared.startSecurityTestListener()
                var waited = 0
                while !OSAgentBridge.shared.isListening && waited < 50 { try await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
                let request = base.appendingPathComponent("req-tools.json").path
                try "{\"id\":\"t\",\"method\":\"hands_tools\",\"params\":{\"access_token\":\"x\",\"callerThreadID\":\"\(someThread.uuidString)\"}}\n"
                    .write(toFile: request, atomically: true, encoding: .utf8)
                let requestDevices = base.appendingPathComponent("req-devices.json").path
                try "{\"id\":\"d\",\"method\":\"list_devices\",\"params\":{}}\n".write(toFile: requestDevices, atomically: true, encoding: .utf8)
                func viaSocket(exec: Bool, requestFile: String) async throws -> String {
                    let output = base.appendingPathComponent("sock-\(UUID().uuidString.prefix(6)).out").path
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    let nc = "/usr/bin/nc -w 5 -U \"$0\" < \"$1\" > \"$2\""
                    process.arguments = ["-c", "sleep 1; " + (exec ? "exec " : "") + nc, socketPath, requestFile, output]
                    try process.run()
                    let pid = process.processIdentifier
                    OSSocketCaller.registerExternalAI(pid: pid, startTime: OSSocketCaller.processStartTime(pid) ?? 0, thread: someThread)
                    let registered = OSSocketCaller.currentRoots()[pid] != nil
                    await Task.detached { process.waitUntilExit() }.value
                    OSSocketCaller.unregisterExternalAI(pid: pid)
                    let text = (try? String(contentsOfFile: output, encoding: .utf8)) ?? ""
                    return registered ? text : "not-registered"
                }
                // OSAgentBridge.shared 用的是 HandsService.shared（staging 的空設定＝關著）：一律 unauthorized。
                let own = try await viaSocket(exec: true, requestFile: request)
                check(own.contains("\"unauthorized\"") && !own.contains("caller_thread_mismatch"),
                      "身分（真的連線）：登記的 pid 本人是外部 AI，帶別條對話的 thread 也不擋（不綁對話），交給 grant 判斷", own)
                let ownDevices = try await viaSocket(exec: true, requestFile: requestDevices)
                check(ownDevices.contains("caller_not_trusted"), "身分（真的連線）：外部 AI 叫 list_devices 被拒", ownDevices)
                let child = try await viaSocket(exec: false, requestFile: request)
                check(child.contains("caller_not_trusted"), "身分（真的連線）：它開的子行程是其他程式（不沿用身分）", child)
                let bogus = Process()
                bogus.executableURL = URL(fileURLWithPath: "/bin/sleep"); bogus.arguments = ["5"]
                try bogus.run()
                OSSocketCaller.registerExternalAI(pid: bogus.processIdentifier, startTime: 1, thread: someThread)
                check(OSSocketCaller.currentRoots()[bogus.processIdentifier] == nil, "身分：啟動時間對不上的 pid 不登記")
                bogus.terminate()
            } else {
                check(false, "身分（真的連線）：需要 TATWO2_OS_SOCKET")
            }
        }
        try await s1Identity()

        // ---------- 2. 配對窗口、確認卡、grant 與 token（T2、T3、T15；v2 §3–§5；v3 V13、V15、V17） ----------
        let redirect = "https://chatgpt.com/connector_platform_oauth_redirect"
        let badRedirects = ["http://chatgpt.com/connector_platform_oauth_redirect", "https://example.com/oauth/callback",
                            "https://chatgpt.com.example.com/connector_platform_oauth_redirect", "https://chatgpt.com/other",
                            "https://chatgpt.com:8443/connector_platform_oauth_redirect", "https://x" + "@" + "chatgpt.com/connector_platform_oauth_redirect",
                            "https://chatgpt.com/connector/oauth/not-in-list", "https://chatgpt.com/connector_platform_oauth_redirect#x"]
        var badAccepted: [String] = []
        for bad in badRedirects {
            let response = await call("hands_auth", ["op": "register_client", "redirect_uris": [bad]])
            if errorCode(response) != "invalid_redirect_uri" { badAccepted.append(bad) }
        }
        check(badAccepted.isEmpty, "配對：redirect_uri 必須精確在 ChatGPT callback 清單裡（其他一律 invalid_redirect_uri）", "\(badAccepted)")
        let clientID = result(await call("hands_auth", ["op": "register_client", "redirect_uris": [redirect], "client_name": "ChatGPT"]))["client_id"] as? String ?? ""
        check(clientID.hasPrefix("hc_"), "配對：註冊 client（fixture 形狀：client_id）", clientID)
        func verifier() -> String { HandsAuth.random(bytes: 32) }
        let binding = "sha256:" + HandsAuth.hash("browser-a").prefix(32)
        func beginParams(_ v: String, client: String) -> [String: Any] {
            ["op": "authorize_begin", "client_id": client, "redirect_uri": redirect, "code_challenge": HandsAuth.challenge(for: v),
             "code_challenge_method": "S256", "state": "xyz", "resource": "https://hands.example.com/mcp", "scope": "tatwo.hands"]
        }
        let closed = await call("hands_auth", beginParams(verifier(), client: clientID))
        check(errorCode(closed) == "pairing_window_closed", "配對：App 沒開配對窗口＝authorize_begin 一律 pairing_window_closed（防釣魚）", "\(closed)")
        try service.startPairing()
        let v1 = verifier()
        let cardsBefore = cards.get().count
        let begun = await call("hands_auth", beginParams(v1, client: clientID))
        let begunResult = result(begun)
        let card = cards.get().dropFirst(cardsBefore).compactMap { $0 }.last
        let begunJSON = String(decoding: (try? JSONSerialization.data(withJSONObject: begun)) ?? Data(), as: UTF8.self)
        let alphabet = Set("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
        check((begunResult["transaction_id"] as? String)?.hasPrefix("tx_") == true && card?.displayCode == begunResult["display_code"] as? String
              && card?.displayCode.count == 4 && card?.callbackHost == "chatgpt.com" && card?.callbackURL == redirect
              && card?.scope.level == 2 && card?.scope.projects.contains { $0.name == "Hands fixture" } == true && !(card?.scope.memory.isEmpty ?? true)
              && card?.pairingCode.count == 8 && card?.pairingCode.allSatisfy(alphabet.contains) == true
              && !begunJSON.contains(card?.pairingCode ?? "--none--") && begunResult["expires_at"] is String,
              "確認卡：交易編號（網頁同一組）、callback 網域、等級、專案、記憶範圍、8 碼配對碼（V17 字元集；不經關口回傳）", begunJSON)
        check(errorCode(await call("hands_auth", beginParams(verifier(), client: clientID))) == "pairing_busy", "配對：一個窗口同時只有一筆（pairing_busy）")
        var plain = beginParams(v1, client: clientID); plain["code_challenge_method"] = "plain"
        check(errorCode(await call("hands_auth", plain)) == "invalid_request", "配對：PKCE 只收 S256")
        func submit(_ tx: String, _ code: String, _ bind: String? = nil) async -> [String: Any] {
            await call("hands_auth", ["op": "authorize_submit", "transaction_id": tx, "pairing_code": code, "browser_binding_hash": bind ?? binding])
        }
        let tx1 = begunResult["transaction_id"] as? String ?? ""
        var lefts: [Int] = []
        for _ in 0..<4 {
            let wrong = await submit(tx1, "22222222")
            lefts.append(((wrong["error"] as? [String: Any])?["attempts_left"] as? Int) ?? -1)
        }
        let fifth = await submit(tx1, "22222222")
        let afterBurn = await submit(tx1, card?.pairingCode ?? "")
        check(lefts == [4, 3, 2, 1] && errorCode(fifth) == "pairing_expired" && errorCode(afterBurn).hasPrefix("pairing_")
              && auth.windowExpiresAt == nil, "配對：錯碼 5 次整筆作廢、窗口一起關（之後對的碼也不收）", "\(lefts) \(fifth) \(afterBurn)")
        // 窗口到期（10 分鐘＝配對碼有效期）。
        try service.startPairing()
        let expiring = result(await call("hands_auth", beginParams(verifier(), client: clientID)))
        let expiringCard = cards.get().compactMap { $0 }.last
        clock.update { $0 = $0.addingTimeInterval(601) }
        let late = await submit(expiring["transaction_id"] as? String ?? "", expiringCard?.pairingCode ?? "")
        check(errorCode(late).hasPrefix("pairing_") && result(late)["authorization_code"] == nil, "配對：窗口 10 分鐘到期＝配對碼失效", "\(late)")
        // 防偽 token：第一次送出就綁住；換一個瀏覽器（別的雜湊）送對的碼也不收（算錯一次）。
        try service.startPairing()
        let bindTx = result(await call("hands_auth", beginParams(v1, client: clientID)))
        let bindCard = cards.get().compactMap { $0 }.last
        _ = await submit(bindTx["transaction_id"] as? String ?? "", "33333333")
        let otherBrowser = await submit(bindTx["transaction_id"] as? String ?? "", bindCard?.pairingCode ?? "", "sha256:" + String(HandsAuth.hash("browser-b").prefix(32)))
        let good = result(await submit(bindTx["transaction_id"] as? String ?? "", (bindCard?.pairingCode ?? "").lowercased()))
        let code1 = good["authorization_code"] as? String ?? ""
        check(errorCode(otherBrowser) == "invalid_pairing_code" && !code1.isEmpty && good["state"] as? String == "xyz" && good["redirect_uri"] as? String == redirect
              && auth.windowExpiresAt == nil, "配對：瀏覽器防偽雜湊綁交易；對的碼（不分大小寫）換到 60 秒授權碼，窗口關閉（一窗口一筆）", "\(otherBrowser)")
        let wrongPKCE = await call("hands_auth", ["op": "token", "grant_type": "authorization_code", "code": code1, "code_verifier": verifier(),
                                                  "client_id": clientID, "redirect_uri": redirect])
        let afterWrongPKCE = await call("hands_auth", ["op": "token", "grant_type": "authorization_code", "code": code1, "code_verifier": v1,
                                                       "client_id": clientID, "redirect_uri": redirect])
        check(errorCode(wrongPKCE) == "invalid_grant" && errorCode(afterWrongPKCE) == "invalid_grant", "token：PKCE 不符就拒、那個授權碼作廢")
        func pair() async -> (access: String, refresh: String, code: String, grant: String, verifier: String) {
            try? service.startPairing()
            let v = verifier()
            let tx = result(await call("hands_auth", beginParams(v, client: clientID)))
            let code = cards.get().compactMap { $0 }.last?.pairingCode ?? ""
            let authCode = result(await submit(tx["transaction_id"] as? String ?? "", code))["authorization_code"] as? String ?? ""
            let tokens = result(await call("hands_auth", ["op": "token", "grant_type": "authorization_code", "code": authCode, "code_verifier": v,
                                                          "client_id": clientID, "redirect_uri": redirect]))
            let access = tokens["access_token"] as? String ?? ""
            let checked = result(await call("hands_auth", ["op": "check", "access_token": access]))
            return (access, tokens["refresh_token"] as? String ?? "", authCode, checked["grant_id"] as? String ?? "", v)
        }
        let first = await pair()
        let firstCheck = result(await call("hands_auth", ["op": "check", "access_token": first.access]))
        check(first.access.hasPrefix("tatwoh_at_") && first.refresh.hasPrefix("tatwoh_rt_") && firstCheck["ok"] as? Bool == true
              && firstCheck["level"] as? Int == 2 && firstCheck["client_id"] as? String == clientID && first.grant.hasPrefix("g_"),
              "grant：配對成功＝一個 grant；check 回 grant_id、client_id、等級（fixture 形狀）", "\(firstCheck)")
        let rotated = result(await call("hands_auth", ["op": "token", "grant_type": "refresh_token", "refresh_token": first.refresh, "client_id": clientID]))
        let second = rotated["access_token"] as? String ?? ""
        check(!second.isEmpty && rotated["refresh_token"] as? String != first.refresh && rotated["token_type"] as? String == "Bearer"
              && rotated["expires_in"] as? Int == 3600 && auth.grant(forAccess: first.access) == nil && auth.grant(forAccess: second)?.grantID == first.grant,
              "token：refresh 每次換新（同一個 grant；舊 access 作廢）")
        let reuse = await call("hands_auth", ["op": "token", "grant_type": "refresh_token", "refresh_token": first.refresh, "client_id": clientID])
        check(errorCode(reuse) == "invalid_grant" && ((reuse["error"] as? [String: Any])?["message"] as? String) == "grant revoked"
              && auth.grant(forAccess: second) == nil && auth.grantRecord(first.grant)?.revokedAt != nil,
              "token：舊的 refresh 再被用＝撤銷該 grant（V15）", "\(reuse)")
        let codeReuse = await pair()
        let reusedCode = await call("hands_auth", ["op": "token", "grant_type": "authorization_code", "code": codeReuse.code, "code_verifier": codeReuse.verifier,
                                                   "client_id": clientID, "redirect_uri": redirect])
        check(errorCode(reusedCode) == "invalid_grant" && auth.grant(forAccess: codeReuse.access) == nil, "token：授權碼被重用＝用它換到的 grant 撤銷")
        // W183 R1b：用過的 refresh 存滿了＝停止換新（rate_limited），不淘汰舊證據：最早那個 refresh 再被用照樣撤銷 grant。
        func r1bRefreshEvidence() async throws {
            auth.usedRefreshCapPerGrant = 2
            let cappedPair = await pair()
            func refresh(_ token: String) async -> [String: Any] {
                await call("hands_auth", ["op": "token", "grant_type": "refresh_token", "refresh_token": token, "client_id": clientID])
            }
            let r1 = result(await refresh(cappedPair.refresh))["refresh_token"] as? String ?? ""
            let r2 = result(await refresh(r1))["refresh_token"] as? String ?? ""
            let full = await refresh(r2)
            let oldest = await refresh(cappedPair.refresh)
            auth.usedRefreshCapPerGrant = HandsAuth.maxUsedRefreshPerGrant
            check(!r1.isEmpty && !r2.isEmpty && errorCode(full) == "rate_limited" && errorCode(oldest) == "invalid_grant"
                  && auth.grantRecord(cappedPair.grant)?.revokeReason == "refresh_reused",
                  "token：用過的 refresh 紀錄滿了就停止換新（不丟證據）；最早的 refresh 被重用照樣撤銷 grant", "\(full) \(oldest)")
        }
        try await r1bRefreshEvidence()
        // App 端獨立限流（V13）：同一個 client 一分鐘最多 20 次 token。
        let limitedClient = result(await call("hands_auth", ["op": "register_client", "redirect_uris": [redirect]]))["client_id"] as? String ?? ""
        var tokenCodes: [String] = []
        for _ in 0..<21 {
            tokenCodes.append(errorCode(await call("hands_auth", ["op": "token", "grant_type": "authorization_code", "code": "tatwoh_ac_nope-nope-nope-nope",
                                                                  "code_verifier": verifier(), "client_id": limitedClient, "redirect_uri": redirect])))
        }
        check(tokenCodes.dropLast().allSatisfy { $0 == "invalid_grant" } && tokenCodes.last == "rate_limited", "限流：App 端每 client 的 token 次數（不只靠關口）", "\(tokenCodes.suffix(3))")

        // ---------- 3. 等級、開關、設備 ----------
        let statusTool = "tatwo_status"
        _ = try service.updateSettings { $0.level = 1 }
        let levelOne = await pair()
        _ = try service.updateSettings { $0.level = 2 }
        let capped = result(await call("hands_tools", ["access_token": levelOne.access]))
        let cappedNames = (capped["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        check(capped["level"] as? Int == 1 && !cappedNames.contains("run_command") && cappedNames.contains("memory_inbox_save"),
              "等級：grant 核准時是 L1，設定調回 L2 也還是 L1（取小）", "\(cappedNames)")
        let denied = await tool("run_command", ["workspace_id": UUID().uuidString, "command": "true"], token: levelOne.access)
        check(errorCode(denied.raw) == "tool_not_allowed", "等級：等級外的工具＝協定錯誤 tool_not_allowed（fixture）", "\(denied.raw)")
        _ = try service.updateSettings { $0.level = 0 }
        let l0 = ((result(await call("hands_tools", ["access_token": levelOne.access]))["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        check(!l0.isEmpty && l0.allSatisfy { HandsTools.tool(named: $0)?.level == 0 }, "等級：L0 看不到 L1／L2 工具", "\(l0)")
        _ = try service.updateSettings { $0.level = 2 }
        _ = try service.updateSettings { $0.enabled = false }
        let offCheck = result(await call("hands_auth", ["op": "check", "access_token": levelOne.access]))
        let offCalls = [await call("hands_tools", ["access_token": levelOne.access]),
                        await call("hands_call", ["access_token": levelOne.access, "name": statusTool, "arguments": [:]])]
        let offRegister = await call("hands_auth", ["op": "register_client", "redirect_uris": [redirect]])
        check(offCheck["ok"] as? Bool == false && offCalls.allSatisfy { errorCode($0) == "unauthorized" }
              && errorCode(offRegister) == "hands_disabled",
              "開關：關掉＝全部拒絕（check 回 ok:false）")
        _ = try service.updateSettings { $0.enabled = true }
        check(auth.grant(forAccess: levelOne.access) == nil && auth.activeGrantIDs.isEmpty, "開關：關掉＝撤銷全部 grant，重新打開要重新配對")
        _ = try service.updateSettings { $0.hostDeviceID = "another-device" }
        check(errorCode(await call("hands_auth", ["op": "register_client", "redirect_uris": [redirect]])) == "hands_not_on_this_device"
              && (try? service.startPairing()) == nil, "設備：只在指定的那台跑（T12）")
        _ = try service.updateSettings { $0.hostDeviceID = nil }
        let grantA = await pair()
        let tokenA = grantA.access
        check(errorCode(await call("hands_call", ["access_token": tokenA, "name": statusTool, "arguments": [:], "cli": "x"])) == "invalid_request",
              "參數：多一個欄位就拒")
        let authFile = (try? String(contentsOfFile: paths.authFile.path, encoding: .utf8)) ?? ""
        var authStat = stat(), settingsStat = stat()
        _ = lstat(paths.authFile.path, &authStat); _ = lstat(paths.settingsFile.path, &settingsStat)
        check(!authFile.isEmpty && !authFile.contains(tokenA) && !authFile.contains("tatwoh_at_") && !authFile.contains("tatwoh_rt_")
              && (authStat.st_mode & 0o777) == 0o600 && (settingsStat.st_mode & 0o777) == 0o600,
              "狀態檔：app/ 底下只存雜湊、0600")

        // ---------- 4. 專案、匯出工作區（V1–V4） ----------
        let status = await tool("tatwo_status", [:], token: tokenA)
        check(!status.isError && status.text.contains(projectID.uuidString) && !status.text.contains(project), "狀態：列出這個 grant 的專案（不給完整路徑）", status.text)
        let homeRefused = await tool("open_workspace", ["project_id": homeProjectID.uuidString, "title": "home"], token: tokenA)
        check(homeRefused.isError && homeRefused.text.contains("folder_contains_protected_data"), "專案：家目錄（含 .ssh）不給當專案", homeRefused.text)
        let mainRead = object(await tool("read_file", ["project_id": projectID.uuidString, "path": "README.md"], token: tokenA).text)
        try "uncommitted secret \(canary)\n".write(toFile: project + "/.env", atomically: true, encoding: .utf8)
        // W183 R10：「沒提交的讀不到」改用名字不像金鑰的檔驗（.env 現在不管有沒有提交都讀不到——底線 A，下一條）。
        try "uncommitted draft \(canary)\n".write(toFile: project + "/draft-uncommitted.md", atomically: true, encoding: .utf8)
        let draftRead = await tool("read_file", ["project_id": projectID.uuidString, "path": "draft-uncommitted.md"], token: tokenA)
        try? fm.removeItem(atPath: project + "/draft-uncommitted.md")
        check((mainRead["lines"] as? String) == "1\tbase\n" && mainRead["total_lines"] as? Int == 1 && (mainRead["sha256"] as? String)?.count == 64
              && draftRead.isError && !draftRead.text.contains(canary),
              "專案主線：只讀目前 commit（行號、總行數、sha256；沒提交的檔讀不到）", "\(mainRead) \(draftRead.text)")
        // W183 R10 底線 A：金鑰類檔案（.env*、*.pem、id_*、credentials*、鑰匙圈匯出…）在每個等級、每個工具都讀不到——已提交的也一樣。
        let envRead = await tool("read_file", ["project_id": projectID.uuidString, "path": ".env"], token: tokenA)
        let pemRead = await tool("read_file", ["project_id": projectID.uuidString, "path": "keys/fixture.pem"], token: tokenA)
        let upperRead = await tool("read_file", ["project_id": projectID.uuidString, "path": "keys/FIXTURE.PEM"], token: tokenA)
        let keysList = await tool("list_dir", ["project_id": projectID.uuidString, "path": "keys"], token: tokenA)
        let rootList = await tool("list_dir", ["project_id": projectID.uuidString], token: tokenA)
        let pemGrep = object(await tool("search", ["project_id": projectID.uuidString, "query": "PRIVATE", "glob": "**/*.pem"], token: tokenA).text)
        check(envRead.isError && envRead.text.contains("secret_file_refused") && !envRead.text.contains(canary)
              && pemRead.isError && pemRead.text.contains("secret_file_refused") && !leaksPEM(pemRead.text) && upperRead.text.contains("secret_file_refused")
              && !keysList.isError && !keysList.text.contains("fixture.pem") && rootList.text.contains("README.md") && !rootList.text.contains(".env")
              && ((pemGrep["items"] as? [Any]) ?? [1]).isEmpty,
              "W183 R10 底線 A：金鑰類檔案讀不到（.env、已提交的 keys/fixture.pem、大寫也算）、列目錄不列、搜尋不搜（指定 *.pem 也一樣）",
              "\(envRead.text.prefix(120)) \(pemRead.text.prefix(120)) \(keysList.text.prefix(160))")
        let projectSearch = object(await tool("search", ["project_id": projectID.uuidString, "query": "base"], token: tokenA).text)
        check((projectSearch["items"] as? [[String: Any]])?.first?["location"] as? String == "README.md:1:1" && projectSearch["complete"] as? Bool == true,
              "專案主線：搜尋回 path:line:col、complete", "\(projectSearch)")
        try? fm.removeItem(atPath: ranLog)
        let opened = await tool("open_workspace", ["project_id": projectID.uuidString, "title": "fixture"], token: tokenA)
        let openedObject = object(opened.text)
        let wsID = openedObject["workspace_id"] as? String ?? ""
        let ws = UUID(uuidString: wsID) ?? UUID()
        let repo = HandsPath.realpath(paths.repo(ws).path) ?? paths.repo(ws).path
        let wsLog = git(["log", "--oneline", "--all"], cwd: repo).1.split(separator: "\n")
        let historyInWS = git(["cat-file", "-e", firstCommit + "^{commit}"], cwd: repo).0
        let historySecret = git(["log", "-p", "--all"], cwd: repo).1.contains(canary)
        check(!opened.isError && fm.fileExists(atPath: repo + "/README.md") && fm.fileExists(atPath: repo + "/AGENTS.md")
              && wsLog.count == 1 && historyInWS != 0 && !historySecret && !fm.fileExists(atPath: repo + "/.env")
              && !fm.fileExists(atPath: repo + "/keys/fixture.pem") && fm.fileExists(atPath: repo + "/docs/key-notes.md")   // W183 R10 底線 A：匯出的快照拿掉金鑰類
              && (openedObject["base_commit"] as? String).map { baseCommit.hasPrefix($0) } == true,
              "匯出：工作區只有目前版本＋一個基準 commit（git log 只有基準、正本的舊 commit 不在、歷史秘密不在）；W183 R10：已提交的金鑰類檔案（keys/fixture.pem）不進工作區", opened.text + "\(wsLog)")
        let deps = openedObject["dependencies"] as? [String: Any] ?? [:]
        let depsCopied = (deps["copied"] as? [String] ?? []).contains("node_modules") && fm.fileExists(atPath: repo + "/node_modules/dep/index.js")
        check(depsCopied || (deps["missing"] as? [String] ?? []).contains("node_modules"), "依賴：只用 APFS 複製正本已下載的（node_modules），複製不了就明說", "\(deps)")
        let recordA = service.workspaceStore.record(ws)
        check(recordA?.grantID == grantA.grant && recordA?.baseSHA == baseCommit && live.threadRecord(ws)?.parentThreadID != nil
              && live.threadRecord(live.threadRecord(ws)?.parentThreadID)?.projectID == projectID && live.doc.selectedThreadID == selectedBefore,
              "房間：工作區紀錄帶 App 寫的 grant_id 與 base_sha；房間掛在該專案的「ChatGPT 手腳」根對話下、不改選取")
        check(!trapsRan(), "匯出：正本的 hook、filter、fsmonitor 一個都沒跑（影子 gitdir 乾淨設定）",
              (try? String(contentsOfFile: ranLog, encoding: .utf8)) ?? "")
        // W183 R1b：「沒跑」在沙盒裡本來就難留痕跡，所以直接看影子 gitdir 的設定：沒有 filter、fsmonitor、hooksPath、include。
        func r1bExportAndMasks() async throws {
            let shadowConfig = await Task.detached { () -> (String, Int32) in
                guard let projectGit = try? service.projectGit(HandsProject(id: projectID, name: "Hands fixture", workdir: project, problem: nil)),
                      let shadow = try? service.makeShadow(common: projectGit.common, objects: projectGit.objects) else { return ("no-shadow", -1) }
                defer { service.removeShadow(shadow) }
                let text = (try? String(contentsOfFile: shadow + "/config", encoding: .utf8)) ?? ""
                let found = (try? HandsGit.run(["config", "--file", shadow + "/config", "--get-regexp", "^(filter|core\\.fsmonitor|core\\.hookspath|include|includeif|remote|credential)"],
                                               cwd: "/", timeout: 10, cap: 64 * 1024))
                return (text + (found?.out ?? ""), found?.status ?? -1)
            }.value
            let projectConfigHasTraps = ((try? String(contentsOfFile: project + "/.git/config", encoding: .utf8)) ?? "").contains("filter \"trace\"")
            check(shadowConfig.1 == 1 && !shadowConfig.0.contains("trace") && !shadowConfig.0.contains("fsmonitor") && !shadowConfig.0.contains(canary)
                  && shadowConfig.0.contains("bare = true") && projectConfigHasTraps,
                  "匯出：影子 gitdir 的設定沒有 filter／fsmonitor／hooksPath／include／遠端（正本有）", shadowConfig.0)
            // W183 R1b：安全檢查用的 git 輸出一旦截斷就拒絕（不拿前段當完整結果）。
            let truncatedRefused = await Task.detached { () -> String in
                do { _ = try HandsGit.checked(["cat-file", "-p", "HEAD"], cwd: project, cap: 16); return "accepted" } catch { return "\(error)" }
            }.value
            check(truncatedRefused.contains("git_output_too_large"), "交件檢查：git 輸出被截斷＝拒絕（不當作完整結果）", truncatedRefused)
            // W183 R1b：已提交的私鑰——讀檔從中間那行開始也遮得住；搜尋不比對、不列出含私鑰的檔。
            // W183 R10：*.pem 整個讀不到（底線 A）；遮蔽照樣驗：同一段私鑰放在名字不像金鑰的 docs/key-notes.md（第 1 行是說明，私鑰從第 2 行開始）。
            let pemMiddle = await tool("read_file", ["project_id": projectID.uuidString, "path": "docs/key-notes.md", "offset_line": 3, "limit_lines": 2], token: tokenA)
            let pemSearch = object(await tool("search", ["project_id": projectID.uuidString, "query": String(pemSecret.dropFirst(9).prefix(10))], token: tokenA).text)
            check(!pemMiddle.isError && !leaksPEM(pemMiddle.text) && pemMiddle.text.contains("已遮蔽")
                  && ((pemSearch["items"] as? [Any]) ?? [1]).isEmpty,
                  "遮蔽：專案裡的私鑰從中間那行讀也遮住；搜尋猜不到內容", pemMiddle.text + "\(pemSearch)")
        }
        try await r1bExportAndMasks()

        // ---------- 5. 檔案工具（樂觀鎖、全有或全無、保護路徑） ----------
        func onWS(_ name: String, _ args: [String: Any], token: String? = nil, id: String? = nil) async -> (text: String, isError: Bool, raw: [String: Any]) {
            var arguments = args; arguments["workspace_id"] = id ?? wsID
            return await tool(name, arguments, token: token ?? tokenA)
        }
        let created = await onWS("write_file", ["path": "src/hello.txt", "content": "hello\n", "create_only": true])
        let again = await onWS("write_file", ["path": "src/hello.txt", "content": "x\n", "create_only": true])
        let neither = await onWS("write_file", ["path": "src/other.txt", "content": "x\n"])
        let readBack = object(await tool("read_file", ["workspace_id": wsID, "path": "src/hello.txt"], token: tokenA).text)
        let sha = readBack["sha256"] as? String ?? ""
        let stale = await onWS("edit_file", ["path": "src/hello.txt", "old_string": "hello", "new_string": "bye", "expected_sha256": String(repeating: "0", count: 64)])
        let edited = await onWS("edit_file", ["path": "src/hello.txt", "old_string": "hello", "new_string": "hello world", "expected_sha256": sha])
        check(!created.isError && again.isError && again.text.contains("file_exists") && neither.isError && readBack["lines"] as? String == "1\thello\n"
              && stale.isError && stale.text.contains("file_changed") && !edited.isError,
              "檔案：create_only／expected_sha256 樂觀鎖（別人先改了就拒）", created.text + again.text + neither.text + stale.text)
        let badPatch = await onWS("apply_patch", ["patch": "*** Begin Patch\n*** Add File: src/new.txt\n+new\n*** Update File: src/hello.txt\n@@\n-not there\n+x\n*** End Patch\n"])
        let goodPatch = await onWS("apply_patch", ["patch": "*** Begin Patch\n*** Add File: src/new.txt\n+patched\n*** End Patch\n"])
        check(badPatch.isError && !goodPatch.isError && ((try? String(contentsOfFile: repo + "/src/new.txt", encoding: .utf8)) == "patched\n"),
              "檔案：apply_patch 全有或全無（一部分失敗就什麼都沒寫）", badPatch.text)
        var protectedRefused: [String] = []
        for path in [".git/config", ".gitattributes", "sub/.gitmodules", ".claude/settings.json", "x/.mcp.json", ".vscode/tasks.json", ".cursor/rules",
                     "AGENTS.md", "agents.md", "deep/CLAUDE.md", "GEMINI.md", ".cursorrules", ".windsurfrules", ".github/copilot-instructions.md",
                     ".GITATTRIBUTES", ".github", "../outside.txt", "/etc/passwd"] {
            let attempt = await onWS("write_file", ["path": path, "content": "x", "create_only": true])
            if !attempt.isError { protectedRefused.append(path) }
        }
        check(protectedRefused.isEmpty, "檔案：保護路徑（任何層級、大小寫、指示文件）、跳出工作區、絕對路徑一律拒寫", "\(protectedRefused)")
        _ = symlink(fakeHome + "/.ssh/id_test", repo + "/leak")
        let symRead = await tool("read_file", ["workspace_id": wsID, "path": "leak"], token: tokenA)
        check(symRead.isError && !symRead.text.contains(canary), "檔案：捷徑讀不到（O_NOFOLLOW）", symRead.text)
        unlink(repo + "/leak")
        _ = link(repo + "/src/new.txt", repo + "/src/hard.txt")
        let hardWrite = await onWS("write_file", ["path": "src/hard.txt", "content": "x", "expected_sha256": String(repeating: "a", count: 64)])
        check(hardWrite.isError && hardWrite.text.contains("hardlink"), "檔案：連結數 > 1 的檔拒讀拒寫", hardWrite.text)
        unlink(repo + "/src/hard.txt")

        // ---------- 6. 沙盒探針（真的跑 sandbox-exec） ----------
        func run(_ command: String, timeout: Int = 30, token: String? = nil, id: String? = nil) async -> (text: String, isError: Bool) {
            let r = await tool("run_command", ["workspace_id": id ?? wsID, "command": command, "timeout_s": timeout], token: token ?? tokenA)
            return (r.text, r.isError)
        }
        func number(_ key: String, in text: String) -> Int? {
            guard let range = text.range(of: key + "=-?[0-9]+", options: .regularExpression) else { return nil }
            return Int(text[range].dropFirst(key.count + 1))
        }
        func leaksCanary(_ text: String) -> Bool {
            let chars = Array(canary)
            return (0...(chars.count - 12)).contains { text.contains(String(chars[$0..<($0 + 12)])) }
        }
        func alive(_ pid: pid_t) -> Bool { pid > 1 && kill(pid, 0) == 0 }
        func pidFile(_ path: String) -> pid_t {
            pid_t(((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        func gone(_ pid: pid_t, within seconds: Double = 2) async -> Bool {
            var waited = 0.0
            while alive(pid) && waited < seconds { try? await Task.sleep(nanoseconds: 100_000_000); waited += 0.1 }
            return pid > 1 && !alive(pid)
        }
        let fakeKey = String(decoding: [0x73, 0x6B, 0x2D], as: UTF8.self) + "proj" + canary
        func s6SandboxProbes() async throws {
            let inside = await run("echo ok > inside.txt && cat inside.txt")
            check(!inside.isError && inside.text.contains("exit 0") && fm.fileExists(atPath: repo + "/inside.txt"), "沙盒：寫工作區成功", inside.text)
            let escape = await run("echo x > '\(outside)/escape.txt'")
            check(escape.isError && !fm.fileExists(atPath: outside + "/escape.txt"), "沙盒：寫工作區外失敗", escape.text)
            let secrets = await run("cat '\(fakeHome)/.ssh/id_test'; cat '\(entry)/user.md'; cat '\(entry)/memory/coffee.md'")
            check(secrets.isError && !secrets.text.contains(canary) && !secrets.text.contains("oat latte"), "沙盒：讀 ~/.ssh、user.md、入口 memory（替身）都失敗", secrets.text)
            let mainGit = await run("cat '\(project)/.git/config'; echo rc_cfg=$?; ls '\(project)/.git/objects' > /dev/null; echo rc_obj=$?; cat '\(project)/README.md'; echo rc_readme=$?; "
                + "git --git-dir='\(project)/.git' log --oneline -1; echo rc_log=$?")
            check((number("rc_cfg", in: mainGit.text) ?? 0) != 0 && (number("rc_obj", in: mainGit.text) ?? 0) != 0 && (number("rc_readme", in: mainGit.text) ?? 0) != 0
                  && (number("rc_log", in: mainGit.text) ?? 0) != 0 && !leaksCanary(mainGit.text) && !mainGit.text.contains("example.com"),
                  "沙盒：正本（含 .git 設定、物件、歷史）一律讀不到", mainGit.text)
            let brew = await run("ls /opt/homebrew/bin > /dev/null; echo rc_brew=$?; ls /usr/local > /dev/null; echo rc_local=$?")
            check((number("rc_brew", in: brew.text) ?? 0) != 0 && (number("rc_local", in: brew.text) ?? 0) != 0, "沙盒：工具鏈不開 Homebrew（V2）", brew.text)
            let curl = await run("/usr/bin/curl -sS -m 5 https://example.com -o /dev/null")
            check(curl.isError, "沙盒：curl 連不上網路", curl.text)
            let fakeSocket = base.appendingPathComponent("fake-os.sock").path, flag = base.appendingPathComponent("fake-os.flag").path
            var listenerProcess: Process?
            if let nodePath = runtime.nodePath {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: nodePath)
                process.arguments = ["-e", "const n=require('net'),f=require('fs');const s=n.createServer(c=>{f.writeFileSync(process.argv[2],'x');c.end('HELLO\\n')});s.listen(process.argv[1]);setTimeout(()=>process.exit(0),60000)", fakeSocket, flag]
                try? process.run()
                listenerProcess = process
                try await Task.sleep(nanoseconds: 800_000_000)
            }
            let sock = await run("echo hi | /usr/bin/nc -w 3 -U '\(fakeSocket)'; echo nc=$?")
            let realSock = await run("echo '{\"method\":\"list_devices\"}' | /usr/bin/nc -w 3 -U '\(environment["TATWO2_OS_SOCKET"] ?? "/nonexistent")'; echo nc=$?")
            check(fm.fileExists(atPath: fakeSocket) && !fm.fileExists(atPath: flag) && !sock.text.contains("HELLO") && !sock.text.contains("nc=0")
                  && !realSock.text.contains("\"ok\"") && !realSock.text.contains("nc=0"), "沙盒：連 unix socket（假 os.sock、真的測試 os.sock）失敗", sock.text + realSock.text)
            listenerProcess?.terminate()
            let osa = await run("/usr/bin/osascript -e 'return 1'")
            check(osa.isError, "沙盒：執行 osascript 失敗", osa.text)

            // V7：任意指令也寫不了保護路徑（任何層級、大小寫、改名、刪除、捷徑、硬連結）；.git 逐字不變；工作區根刪不掉、改不了名。
            let gitConfigBefore = (try? String(contentsOfFile: repo + "/.git/config", encoding: .utf8)) ?? ""
            let gitHeadBefore = (try? String(contentsOfFile: repo + "/.git/HEAD", encoding: .utf8)) ?? ""
            let attributesBefore = (try? String(contentsOfFile: repo + "/.gitattributes", encoding: .utf8)) ?? ""
            let agentsBefore = (try? String(contentsOfFile: repo + "/AGENTS.md", encoding: .utf8)) ?? ""
            let probes: [(String, String)] = [
                ("nested_git", "mkdir -p a && mkdir a/.git"), ("git_init", "git init -q sub"), ("agents", "echo x > AGENTS.md"),
                ("agents_case", "mkdir -p sub2 && echo x > sub2/agents.md"), ("attributes_case", "echo x > .GITATTRIBUTES"),
                ("claude", "touch CLAUDE.md"), ("github_dir", "mkdir .github"), ("gemini_link", "ln -s README.md GEMINI.md"),
                ("cursor_hard", "ln README.md .cursorrules"), ("windsurf_mv", "cp README.md w.txt && mv w.txt .windsurfrules"),
                ("perl_rename", "/usr/bin/perl -e 'rename(\"README.md\", \".codex\") or exit 1'"), ("mcp_deep", "mkdir -p x/y && echo x > x/y/.mcp.json"),
                ("agents_rm", "rm AGENTS.md"), ("agents_mv", "mv AGENTS.md notes2.md"), ("git_rm", "rm -rf .git/HEAD"), ("git_mv", "mv .git gitx"),
                ("git_config", "echo '[core] fsmonitor = evil' >> .git/config"), ("root_rmdir", "cd .. && rmdir repo"), ("root_mv", "cd .. && mv repo repo2"),
                // W183 R1b：整個上層資料夾搬到暫存區（改完裡面的 AGENTS.md 再搬回來）：上層資料夾本身不准改名。
                ("ancestor_mv", "mv docs \"$TMPDIR/docs-moved\""), ("ancestor_rename", "mv docs docs2"),
            ]
            let probeScript = probes.map { "( \($0.1) ) 2>/dev/null; echo rc_\($0.0)=$?" }.joined(separator: "; ")
            let protectedProbe = await run(probeScript)
            let codes = probes.map { number("rc_" + $0.0, in: protectedProbe.text) }
            // APFS 預設不分大小寫：.GITATTRIBUTES 就是既有的 .gitattributes，改成比內容。
            let createdAny = [repo + "/a/.git", repo + "/sub/.git", repo + "/sub2/agents.md", repo + "/CLAUDE.md", repo + "/.github",
                              repo + "/GEMINI.md", repo + "/.cursorrules", repo + "/.windsurfrules", repo + "/.codex", repo + "/x/y/.mcp.json"]
                .filter { fm.fileExists(atPath: $0) }
            check(codes.allSatisfy { ($0 ?? 0) != 0 } && createdAny.isEmpty && fm.fileExists(atPath: repo + "/README.md")
                  && (try? String(contentsOfFile: repo + "/AGENTS.md", encoding: .utf8)) == agentsBefore && !attributesBefore.isEmpty
                  && (try? String(contentsOfFile: repo + "/.gitattributes", encoding: .utf8)) == attributesBefore
                  && (try? String(contentsOfFile: repo + "/.git/config", encoding: .utf8)) == gitConfigBefore
                  && (try? String(contentsOfFile: repo + "/.git/HEAD", encoding: .utf8)) == gitHeadBefore && fm.fileExists(atPath: repo),
                  "沙盒：巢狀 .git、AGENTS.md（大小寫）、指示文件、.github、改名、刪除、捷徑、硬連結，任意指令都寫不了；.git 逐字不變；工作區根刪不掉",
                  "\(zip(probes.map { $0.0 }, codes).map { "\($0.0)=\($0.1.map(String.init) ?? "nil")" }) created=\(createdAny)")
            let docsAgentsBefore = (try? String(contentsOfFile: repo + "/docs/AGENTS.md", encoding: .utf8)) ?? ""
            let insideDocs = await run("echo note > docs/note.md && cat docs/note.md; echo rc_note=$?; ls \"$TMPDIR\" | grep -c docs-moved; rm -f docs/note.md")
            check(number("rc_note", in: insideDocs.text) == 0 && docsAgentsBefore == "docs rules\n"
                  && (try? String(contentsOfFile: repo + "/docs/AGENTS.md", encoding: .utf8)) == docsAgentsBefore && fm.fileExists(atPath: repo + "/docs"),
                  "沙盒：有指示文件的資料夾搬不走、改不了名（裡面其他檔照常可以寫）", insideDocs.text)
            let wsGit = await run("git log --oneline | wc -l; git status --porcelain | head -3; echo rc_git=$?")
            check(number("rc_git", in: wsGit.text) == 0 && wsGit.text.contains("1"), "沙盒：工作區自己的 git 可以讀（log、status）", wsGit.text)
            let limitsProbe = await run("echo HU=$(ulimit -Hu) SU=$(ulimit -Su) HT=$(ulimit -Ht) HF=$(ulimit -Hf) HC=$(ulimit -Hc); "
                + "ulimit -u unlimited; ulimit -t unlimited; echo AU=$(ulimit -Su) AT=$(ulimit -St); /bin/sh -c 'ulimit -Hu 100000' 2>/dev/null; echo rc_shhu=$?")
            let hu = number("HU", in: limitsProbe.text), au = number("AU", in: limitsProbe.text), ht = number("HT", in: limitsProbe.text), at = number("AT", in: limitsProbe.text)
            check(hu != nil && au != nil && ht != nil && at != nil && number("HC", in: limitsProbe.text) == 0 && (au ?? .max) <= (hu ?? 0)
                  && (at ?? .max) <= (ht ?? 0) && (number("rc_shhu", in: limitsProbe.text) ?? 0) != 0,
                  "沙盒：行程數／CPU／檔案大小是硬上限（拉不高）", limitsProbe.text)
            let links = await run("ln -s '\(fakeHome)/.ssh/id_test' sl; cat sl; ln '\(outside)' hl 2>&1")
            check(links.isError && !links.text.contains(canary), "沙盒：捷徑讀不到外面", links.text)
            unlink(repo + "/sl")
            // 脫離群組：對照組（別的工具的沙盒孤兒）不能被誤殺。
            let controlPIDFile = base.appendingPathComponent("control.pid").path
            let controlLauncher = Process()
            controlLauncher.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            controlLauncher.arguments = ["-p", "(version 1)(allow default)(deny network*)", "/usr/bin/perl", "-e",
                                         "use POSIX qw(setsid); if (fork()==0) { setsid(); if (fork()==0) { open(F, '>', $ARGV[0]); print F $$; close F; sleep 120; exit 0 } exit 0 } exit 0",
                                         controlPIDFile]
            try controlLauncher.run()
            controlLauncher.waitUntilExit()
            try await Task.sleep(nanoseconds: 400_000_000)
            let controlPID = pidFile(controlPIDFile)
            let escapee = "sleep 1000 & echo $! > bg.pid; /usr/bin/perl -e 'use POSIX qw(setsid); if (fork()==0){ setsid(); if (fork()==0) { chdir(\"/\"); open(F,\">\",\"'\"$PWD\"'/esc.pid\"); print F $$; close F; sleep 1000; exit 0 } exit 0 } exit 0'; sleep 1000"
            let timed = await run(escapee, timeout: 3)
            try await Task.sleep(nanoseconds: 300_000_000)
            let bgPID = pidFile(repo + "/bg.pid"), escPID = pidFile(repo + "/esc.pid")
            let bgGone = await gone(bgPID), escGone = await gone(escPID)
            check(timed.isError && timed.text.contains("timed out") && bgGone, "沙盒：逾時收掉整個行程群組", timed.text)
            check(escPID > 1 && escGone, "沙盒：脫離群組（setsid＋double fork、cd 到別處）的也照標記收掉", "esc=\(escPID)")
            if alive(escPID) { _ = kill(escPID, SIGKILL) }
            check(controlPID > 1 && alive(controlPID), "沙盒：別的工具的沙盒孤兒（對照組）不會被手腳的掃描誤殺", "control=\(controlPID)")
            if controlPID > 1 { _ = kill(controlPID, SIGKILL) }
            setenv("TATWO_HANDS_ENV_CANARY", canary, 1)
            let noisy = await run("yes 0123456789 | head -c 200000; echo; echo \(fakeKey); echo Bearer \(canary); echo \(fakeHome)/x; env")
            unsetenv("TATWO_HANDS_ENV_CANARY")
            check(!noisy.text.contains(canary) && noisy.text.contains("[已遮蔽]") && noisy.text.contains("truncated")
                  && !noisy.text.contains(fakeHome) && !noisy.text.contains("TATWO_HANDS_ENV_CANARY"),
                  "沙盒：輸出截斷、遮蔽（canary 不出現）、App 的環境變數不進沙盒", String(noisy.text.suffix(600)))
            _ = await run("rm -f bg.pid esc.pid inside.txt; rm -rf a sub sub2 x")
        }
        try await s6SandboxProbes()

        // ---------- 7. 長工作、輸出區、request_id（V11、V12） ----------
        func s7Jobs() async throws -> String {
            let started = object(await onWS("job_start", ["command": "for i in 1 2 3; do echo line$i; sleep 1; done; echo \(fakeKey)", "timeout_s": 60]).text)
            let jobID = started["job_id"] as? String ?? ""
            let midStatus = object(await tool("job_status", ["job_id": jobID], token: tokenA).text)["state"] as? String
            var finalState = ""
            for _ in 0..<60 where finalState != "exited" {
                try await Task.sleep(nanoseconds: 250_000_000)
                finalState = object(await tool("job_status", ["job_id": jobID], token: tokenA).text)["state"] as? String ?? ""
            }
            var collected = "", offset = 0, pages = 0, complete = false
            while !complete && pages < 50 {
                let page = object(await tool("job_output", ["job_id": jobID, "offset": offset, "limit": 7], token: tokenA).text)
                collected += page["text"] as? String ?? ""
                offset = page["next_offset"] as? Int ?? offset
                complete = page["complete"] as? Bool ?? true
                pages += 1
            }
            check(jobID.hasPrefix("job_") && midStatus == "running" && finalState == "exited" && collected.contains("line1") && collected.contains("line3")
                  && !collected.contains(canary) && pages > 2, "長工作：job_start → job_status → job_output 翻頁（遮蔽，canary 不出現）", "\(midStatus ?? "nil") \(finalState) \(collected)")
            let outputFile = paths.output(grant: grantA.grant, job: jobID).appendingPathComponent("stdout.log").path
            let before = (try? String(contentsOfFile: outputFile, encoding: .utf8)) ?? ""
            let tamper = await run("echo hacked >> '\(outputFile)'; echo rc_tamper=$?; cat '\(outputFile)' > /dev/null; echo rc_read=$?")
            check((number("rc_tamper", in: tamper.text) ?? 0) != 0 && (number("rc_read", in: tamper.text) ?? 0) != 0 && !before.isEmpty
                  && (try? String(contentsOfFile: outputFile, encoding: .utf8)) == before, "輸出證據：沙盒裡改不了、也讀不到 job 的輸出（App 管理的輸出區）", tamper.text)
            // W183 R1b：秘密在寫進輸出區（磁碟）之前就遮好；分頁從哪裡開始都拼不回來（Bearer 換行、沒有 BEGIN 的金鑰內文）。
            func r1bOutputSecrets() async throws {
                // 指令文字裡不放完整的 canary（房間紀錄會記指令）：拆成 10 個字一段在沙盒裡拼。
                func pieces(_ secret: String) -> (assign: String, expr: String) {
                    let chars = Array(secret)
                    let parts = stride(from: 0, to: chars.count, by: 10).map { String(chars[$0..<min($0 + 10, chars.count)]) }
                    let assign = parts.enumerated().map { "p\($0.offset)='\($0.element)'" }.joined(separator: "; ")
                    return (assign, parts.indices.map { "$p\($0)" }.joined())
                }
                let bearerToken = pieces(canary.lowercased())
                let keyish = pieces("Ab1Ab1Ab1Ab1" + canary + "Zz9Zz9Zz9Zz9")
                let secretJob = object(await onWS("job_start", ["command": "\(bearerToken.assign); t=\"tok\(bearerToken.expr)\"; printf 'Authorization: Bearer\\n%s\\n' \"$t\"; "
                    + "printf 'x-api: Bearer %s\\n' \"$t\"; \(keyish.assign.replacingOccurrences(of: "p", with: "k")); k=\"\(keyish.expr.replacingOccurrences(of: "$p", with: "$k"))\"; "
                    + "printf '%s\\n%s\\nshort==\\n' \"$k\" \"$k\"; echo done", "timeout_s": 60]).text)["job_id"] as? String ?? ""
                var secretState = ""
                for _ in 0..<40 where secretState != "exited" {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    secretState = object(await tool("job_status", ["job_id": secretJob], token: tokenA).text)["state"] as? String ?? ""
                }
                let secretFile = paths.output(grant: grantA.grant, job: secretJob).appendingPathComponent("stdout.log").path
                let onDisk = (try? String(contentsOfFile: secretFile, encoding: .utf8)) ?? ""
                var pageLeak = false, pageCount = 0
                let totalBytes = onDisk.utf8.count
                for start in stride(from: 0, to: max(totalBytes, 1), by: 3) {
                    let page = object(await tool("job_output", ["job_id": secretJob, "offset": start, "limit": 24], token: tokenA).text)
                    if leaksCanary((page["text"] as? String ?? "").uppercased()) { pageLeak = true }
                    pageCount += 1
                }
                check(secretState == "exited" && !onDisk.isEmpty && onDisk.contains("done") && !leaksCanary(onDisk.uppercased()) && onDisk.contains("[已遮蔽]")
                      && onDisk.contains(HandsSecretLines.masked) && !pageLeak && pageCount > 3,
                      "輸出證據：秘密在寫進輸出區之前就遮好（磁碟上沒有原文）；job_output 從任何位置開始翻頁都拼不回秘密", onDisk)
                // 工作區裡的私鑰：從中間那行讀也遮住；搜尋不比對被遮蔽的行。
                try fm.createDirectory(atPath: repo + "/material", withIntermediateDirectories: true)   // W183 R10 第二輪：secrets* 本身現在就是金鑰類名字
                let keyText = [keyMarker("BEGIN", "OPENSSH "), "Ab1Ab1Ab1Ab1" + canary + "Zz9Zz9", "Yy8" + canary, keyMarker("END", "OPENSSH "), "after"]
                    .joined(separator: "\n") + "\n"
                // W183 R10：名字像金鑰的（id_*）整個讀不到（底線 A）；遮蔽照樣驗：同一段放在名字不像金鑰的檔。
                try keyText.write(toFile: repo + "/material/id_test", atomically: true, encoding: .utf8)
                try keyText.write(toFile: repo + "/material/test-material.txt", atomically: true, encoding: .utf8)
                let keyMiddle = await tool("read_file", ["workspace_id": wsID, "path": "material/test-material.txt", "offset_line": 2, "limit_lines": 1], token: tokenA)
                let keySearch = object(await tool("search", ["workspace_id": wsID, "query": String(canary.suffix(10))], token: tokenA).text)
                let idRead = await tool("read_file", ["workspace_id": wsID, "path": "material/id_test"], token: tokenA)
                let idList = await tool("list_dir", ["workspace_id": wsID, "path": "material"], token: tokenA)
                try fm.createDirectory(atPath: repo + "/cfg", withIntermediateDirectories: true)
                try "TOKEN=\(canary)\n".write(toFile: repo + "/cfg/.env.production", atomically: true, encoding: .utf8)
                let envSearch = object(await tool("search", ["workspace_id": wsID, "query": "TOKEN="], token: tokenA).text)
                let envStatus = await tool("git_status", ["workspace_id": wsID], token: tokenA)
                let envDiff = await tool("git_diff", ["workspace_id": wsID, "mode": "base"], token: tokenA)
                try? fm.removeItem(atPath: repo + "/material")
                try? fm.removeItem(atPath: repo + "/cfg")
                check(!keyMiddle.isError && !leaksCanary(keyMiddle.text) && keyMiddle.text.contains("已遮蔽")
                      && ((keySearch["items"] as? [Any]) ?? [1]).isEmpty,
                      "遮蔽：工作區裡的私鑰從中間那行讀也遮住；搜尋猜不到內容", keyMiddle.text + "\(keySearch)")
                check(idRead.isError && idRead.text.contains("secret_file_refused") && !leaksCanary(idRead.text) && !idList.text.contains("id_test")
                      && idList.text.contains("test-material.txt") && ((envSearch["items"] as? [Any]) ?? [1]).isEmpty
                      && !envStatus.isError && !envStatus.text.contains("cfg/.env.production") && !envStatus.text.contains("id_test")
                      && !envDiff.text.contains("cfg/.env.production") && !envDiff.text.contains("id_test"),
                      "W183 R10 底線 A：工作區裡的金鑰類檔案（id_*、.env.production）讀不到、列目錄不列、搜尋不搜、git 狀態與差異都不出現",
                      "\(idRead.text.prefix(120)) \(idList.text.prefix(160)) \(envStatus.text.prefix(160))")
            }
            try await r1bOutputSecrets()
            let long1 = object(await onWS("job_start", ["command": "sleep 30", "timeout_s": 60]).text)["job_id"] as? String ?? ""
            let long2 = object(await onWS("job_start", ["command": "sleep 30", "timeout_s": 60]).text)["job_id"] as? String ?? ""
            let third = await onWS("job_start", ["command": "sleep 30", "timeout_s": 60])
            let cancelled = object(await tool("job_cancel", ["job_id": long1], token: tokenA).text)
            _ = await tool("job_cancel", ["job_id": long2], token: tokenA)
            check(!long1.isEmpty && !long2.isEmpty && third.isError && third.text.contains("busy") && cancelled["state"] as? String == "cancelled",
                  "長工作：每個連線同時最多 2 個；job_cancel 收掉", third.text + "\(cancelled)")
            let rid = "rq_" + HandsAuth.hex(bytes: 8)
            let firstRun = await tool("run_command", ["workspace_id": wsID, "command": "echo x >> counter.txt; wc -l < counter.txt"], token: tokenA, requestID: rid)
            let retried = await tool("run_command", ["workspace_id": wsID, "command": "echo x >> counter.txt; wc -l < counter.txt"], token: tokenA, requestID: rid)
            let conflict = await tool("run_command", ["workspace_id": wsID, "command": "echo other"], token: tokenA, requestID: rid)
            let counter = ((try? String(contentsOfFile: repo + "/counter.txt", encoding: .utf8)) ?? "").split(separator: "\n").count
            let slowID = "rq_" + HandsAuth.hex(bytes: 8)
            let slow = Task { await tool("run_command", ["workspace_id": wsID, "command": "sleep 3; echo slow-done"], token: tokenA, requestID: slowID) }
            try await Task.sleep(nanoseconds: 1_200_000_000)
            let inProgress = object(await tool("run_command", ["workspace_id": wsID, "command": "sleep 3; echo slow-done"], token: tokenA, requestID: slowID).text)
            let slowResult = await slow.value
            check(firstRun.text == retried.text && counter == 1 && errorCode(conflict.raw) == "request_id_conflict"
                  && inProgress["status"] as? String == "running" && (inProgress["job_id"] as? String)?.hasPrefix("job_") == true && slowResult.text.contains("slow-done"),
                  "request_id：同 id 同參數回原結果（沒重跑）、不同參數 request_id_conflict、進行中重試回 running＋job_id", "\(counter) \(conflict.raw) \(inProgress)")
            _ = await run("rm -f counter.txt")
            return jobID
        }
        let jobID = try await s7Jobs()

        // ---------- 8. 跨 grant 越權（V9） ----------
        let grantB = await pair()
        let tokenB = grantB.access
        let crossRead = await tool("read_file", ["workspace_id": wsID, "path": "README.md"], token: tokenB)
        let crossWrite = await tool("write_file", ["workspace_id": wsID, "path": "b.txt", "content": "x", "create_only": true], token: tokenB)
        let crossRun = await tool("run_command", ["workspace_id": wsID, "command": "touch b.txt"], token: tokenB)
        let crossSubmit = await tool("submit_workspace", ["workspace_id": wsID, "summary": "steal"], token: tokenB)
        let crossStatus = await tool("git_status", ["workspace_id": wsID], token: tokenB)
        let crossJob = await tool("job_status", ["job_id": jobID], token: tokenB)
        let crossOutput = await tool("job_output", ["job_id": jobID], token: tokenB)
        let crossCancel = await tool("job_cancel", ["job_id": jobID], token: tokenB)
        let listB = object(await tool("list_workspaces", [:], token: tokenB).text)["workspaces"] as? [[String: Any]] ?? []
        let openedB = object(await tool("open_workspace", ["project_id": projectID.uuidString, "title": "b"], token: tokenB).text)["workspace_id"] as? String ?? ""
        let peek = await run("cat '\(repo)/README.md'; echo rc_peek=$?", token: tokenB, id: openedB)
        check([crossRead, crossWrite, crossRun, crossSubmit, crossStatus].allSatisfy { $0.isError && $0.text.contains("workspace_not_found") }
              && [crossJob, crossOutput, crossCancel].allSatisfy { $0.isError && $0.text.contains("job_not_found") }
              && listB.isEmpty && !openedB.isEmpty && (number("rc_peek", in: peek.text) ?? 0) != 0 && !fm.fileExists(atPath: repo + "/b.txt"),
              "跨 grant：別的連線的工作區、job、輸出一律當作找不到；沙盒裡也讀不到別的工作區",
              crossRead.text + crossJob.text + peek.text)

        // ---------- 9. 記憶與收件匣（L1、V14） ----------
        func s9Memory() async throws {
            let searched = object(await tool("memory_search", ["query": "coffee"], token: tokenA).text)
            let results = searched["results"] as? [[String: Any]] ?? []
            let hiddenGet = await tool("memory_get", ["id": "coffee-hidden.md"], token: tokenA)
            let normalGet = object(await tool("memory_get", ["id": "coffee.md"], token: tokenA).text)
            check(results.contains { $0["id"] as? String == "coffee.md" && $0["verified"] as? Bool == true } && !results.contains { $0["id"] as? String == "coffee-hidden.md" }
                  && hiddenGet.isError && !hiddenGet.text.contains(canary) && (normalGet["content"] as? String)?.contains("oat latte") == true
                  && normalGet["source"] != nil, "記憶：讀得到正式記憶（帶來源與驗證狀態）；標「不給 ChatGPT」的搜不到也讀不到", "\(searched) \(hiddenGet.text)")
            let forged = await tool("memory_inbox_save", ["title": "t", "content": "c", "source": "user", "verified": true, "grant_id": grantB.grant], token: tokenA)
            let saved = object(await tool("memory_inbox_save", ["title": "Build note", "content": "{\"source\":\"user\",\"verified\":true} run npm test", "workspace_id": wsID],
                                          token: tokenA).text)
            let inboxFile = memoryStore.memory.appendingPathComponent("chatgpt-inbox").appendingPathComponent(saved["id"] as? String ?? "none").path
            let stored = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: inboxFile)))) as? [String: Any] ?? [:]
            let savedB = await tool("memory_inbox_save", ["title": "B note", "content": "from b"], token: tokenB)
            let listA = object(await tool("memory_inbox_list", [:], token: tokenA).text)["items"] as? [[String: Any]] ?? []
            let secretSave = await tool("memory_inbox_save", ["title": "k", "content": "key is \(fakeKey)"], token: tokenA)
            check(forged.isError && forged.text.contains("unexpected_argument") && stored["source"] as? String == "chatgpt" && stored["verified"] as? Bool == false
                  && stored["grant_id"] as? String == grantA.grant && stored["workspace_id"] as? String == wsID && stored["created_at"] is String
                  && !savedB.isError && listA.count == 1 && listA.first?["title"] as? String == "Build note" && secretSave.isError,
                  "收件匣：source／verified／grant_id／時間由 App 寫（工具改不了）；只列自己連線的；像秘密的不收", "\(stored) \(listA)")
            let inboxBySandbox = await run("echo x > '\(memoryStore.memory.path)/chatgpt-inbox/forged.json'; echo rc_inbox=$?")
            check((number("rc_inbox", in: inboxBySandbox.text) ?? 0) != 0 && !fm.fileExists(atPath: memoryStore.memory.path + "/chatgpt-inbox/forged.json"),
                  "收件匣：沙盒裡寫不進記憶資料夾", inboxBySandbox.text)
            // W183 R1b：安全欄位結構化解析——行尾註解、引號都認；`chatgpt: hidden # 私人` 照樣不給，`verified: false # 尚待確認` 照樣未驗證。
            func r1bMemoryFields() async throws {
                let commented = await tool("memory_get", ["id": "coffee-comment.md"], token: tokenA)
                let unverified = object(await tool("memory_get", ["id": "coffee-unverified.md"], token: tokenA).text)
                check(commented.isError && !commented.text.contains(canary) && unverified["verified"] as? Bool == false
                      && HandsMemory.fieldValues(["chatgpt: 'hidden' # x"], keys: ["chatgpt"]) == [.text("hidden")]
                      && HandsMemory.fieldValues(["  hands: [a]"], keys: ["hands"]) == [.ambiguous]
                      && HandsMemory.fieldValues(["chatgpt: \"hidden"], keys: ["chatgpt"]) == [.ambiguous]
                      && HandsMemory.fieldValues(["verified: \"true\"  # ok"], keys: ["verified"]) == [.text("true")],
                      "記憶：行尾有註解的「不給 ChatGPT」「未驗證」照樣生效；看不懂的寫法一律往嚴的那邊判", commented.text + "\(unverified)")
                // W183 R1b：同一個 request_id 重送，只讀的工具一律重讀（照現在的「不給 ChatGPT」標記），不回舊內容。
                let replayID = "rq_" + HandsAuth.hex(bytes: 8)
                let firstGet = await tool("memory_get", ["id": "coffee.md"], token: tokenA, requestID: replayID)
                let coffeePath = entry + "/memory/coffee.md"
                let coffeeOriginal = (try? String(contentsOfFile: coffeePath, encoding: .utf8)) ?? ""
                try coffeeOriginal.replacingOccurrences(of: "name: Favorite coffee\n", with: "name: Favorite coffee\nchatgpt: hidden # 後來改成不給\n")
                    .write(toFile: coffeePath, atomically: true, encoding: .utf8)
                let replayed = await tool("memory_get", ["id": "coffee.md"], token: tokenA, requestID: replayID)
                try coffeeOriginal.write(toFile: coffeePath, atomically: true, encoding: .utf8)
                check(!firstGet.isError && firstGet.text.contains("oat latte") && replayed.isError && !replayed.text.contains("oat latte"),
                      "request_id：記憶後來標成不給 ChatGPT，用同一個 request_id 重送也拿不到舊內容", replayed.text)
            }
            try await r1bMemoryFields()
        }
        try await s9Memory()

        // ---------- 10. 交件（V5、V10）與審查合併（V6） ----------
        func s10Submit() async throws -> (String, UUID) {
            // 別的程式（不是手腳沙盒）開著工作區：證明不了已停＝不交件。
            let foreign = Process()
            foreign.executableURL = URL(fileURLWithPath: "/bin/sleep"); foreign.arguments = ["60"]
            foreign.currentDirectoryURL = URL(fileURLWithPath: repo)
            try foreign.run()
            try await Task.sleep(nanoseconds: 300_000_000)
            let refusedForeign = await onWS("submit_workspace", ["summary": "should refuse"])
            foreign.terminate(); foreign.waitUntilExit()
            check(refusedForeign.isError && refusedForeign.text.contains("workspace_writers_remain"), "交件：還有別的程式開著工作區（證明不了已停）就拒絕交件", refusedForeign.text)
            // 手腳沙盒裡 setsid 脫離、cwd 在工作區、標記已不在這次執行裡的行程：交件前被收掉。
            let orphanPIDFile = base.appendingPathComponent("orphan.pid").path
            let marks = HandsPath.realpath(paths.marksDir.path) ?? paths.marksDir.path
            let orphanLauncher = Process()
            orphanLauncher.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            orphanLauncher.arguments = ["-p", "(version 1)(allow default)(deny file-read-data (literal \"\(marks)/control\"))", "/usr/bin/perl", "-e",
                                        "use POSIX qw(setsid); if (fork()==0) { setsid(); if (fork()==0) { chdir($ARGV[1]); open(F, '>', $ARGV[0]); print F $$; close F; sleep 120; exit 0 } exit 0 } exit 0",
                                        orphanPIDFile, repo]
            try orphanLauncher.run()
            orphanLauncher.waitUntilExit()
            try await Task.sleep(nanoseconds: 400_000_000)
            let orphanPID = pidFile(orphanPIDFile)
            try? fm.removeItem(atPath: ranLog)
            _ = await onWS("write_file", ["path": "scripts/build.sh", "content": "echo build\n", "create_only": true])
            let submitted = await onWS("submit_workspace", ["summary": "加了 hello 與 new（測試：cat）"])
            let trapsAfterSubmit = trapsRan()   // 先記下來：下面的對照用 git 指令不能混進來
            let submitObject = object(submitted.text)
            let orphanGone = await gone(orphanPID)
            let ref = git(["rev-parse", "refs/heads/tatwo2-room-" + wsID.prefix(8)], cwd: project).1.trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = git(["rev-parse", ref + "^"], cwd: project).1.trimmingCharacters(in: .whitespacesAndNewlines)
            let author = git(["log", "-1", "--format=%an <%ae>|%cn <%ce>", ref], cwd: project).1
            let hello = git(["show", ref + ":src/hello.txt"], cwd: project).1
            let headAfter = git(["rev-parse", "HEAD"], cwd: project).1.trimmingCharacters(in: .whitespacesAndNewlines)
            let worktreeClean = !fm.fileExists(atPath: project + "/src/hello.txt")
            check(orphanPID > 1 && orphanGone, "交件：手腳沙盒裡 setsid 脫離、cwd 在工作區的行程被收掉（proc_pidinfo 掃描）", "orphan=\(orphanPID)")
            check(!submitted.isError && ref.hasPrefix(submitObject["candidate_commit"] as? String ?? "--") && parent == baseCommit
                  && hello == "hello world\n" && author.contains("ChatGPT 手腳 <chatgpt-hands@localhost>|ChatGPT 手腳 <chatgpt-hands@localhost>")
                  && headAfter == baseCommit && worktreeClean && service.workspaceStore.record(ws)?.candidateSHA == ref,
                  "交件：候選 commit 父親＝base_sha、內容對、中性作者；正本 HEAD 與工作副本都沒動（不 checkout）", submitted.text + author)
            check(!trapsAfterSubmit, "交件：正本的 hook、filter、fsmonitor 一個都沒跑（暫存 index＋乾淨 git）", (try? String(contentsOfFile: ranLog, encoding: .utf8)) ?? "")
            try? fm.removeItem(atPath: ranLog)
            _ = git(["update-ref", "refs/heads/trap-probe", "HEAD"], cwd: project, hooks: true)
            check(trapsRan(), "對照組：沒加固的 git update-ref 會跑正本的 reference-transaction hook（證明陷阱是活的）")
            _ = git(["update-ref", "-d", "refs/heads/trap-probe"], cwd: project)
            try? fm.removeItem(atPath: ranLog)
            // W183 R1b：filter、fsmonitor 也要有對照組（證明陷阱是活的，上面的「沒跑」才有鑑別力）。
            func r1bTrapControls() async throws {
                func ranLines() -> [String] { ((try? String(contentsOfFile: ranLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
                _ = rawGit(["archive", "-o", base.appendingPathComponent("control.tar").path, "HEAD", "notes.txt"], cwd: project)
                let smudgeControl = ranLines()
                try? fm.removeItem(atPath: ranLog)
                _ = rawGit(["status", "--porcelain"], cwd: project)
                let fsmonitorControl = ranLines()
                try? fm.removeItem(atPath: ranLog)
                check(smudgeControl.contains { $0.contains("trap.sh") && $0.hasSuffix("smudge") }, "對照組：沒加固的 git archive 會跑正本的 smudge filter（filter 陷阱是活的）", "\(smudgeControl)")
                check(fsmonitorControl.contains { $0.contains("trap.sh") && !$0.contains("smudge") && !$0.contains("clean") },
                      "對照組：沒加固的 git status 會跑正本的 fsmonitor（fsmonitor 陷阱是活的）", "\(fsmonitorControl)")
            }
            try await r1bTrapControls()
            func reports() -> [ChatMessage] {
                live.transcript(for: ws).filter { $0.role == .assistant && $0.eventKind == .message && $0.text.hasPrefix("〔外部資料・ChatGPT 交件") }
            }
            check(live.threadRecord(ws)?.subStatus == "done" && reports().count == 1 && reports().first?.text.contains("scripts/build.sh") == true
                  && islandTitles.get().contains { $0.contains("ChatGPT 交件") }, "交件：報告列（醒目標出腳本）、狀態待審、Island 通知")
            // 審查：Hands 專用後端；diff 用候選 SHA；複製合併指令關掉；沒看過這一版不能合併。
            model.document = live.document
            let context = try? model.dispatchGitContext(ws)
            let diff = await Task.detached { context.flatMap { try? DispatchGit.diff($0) } }.value
            let copyRefused = (try? context?.mergeCommand()) == nil
            let preview = DispatchMergePreview(head: baseCommit, branchHead: ref)
            let unreviewed = context.map { (try? model.handsMergeCheck($0, preview: preview)) == nil } ?? false
            if let context { model.handsMarkReviewed(context, truncated: diff?.truncated ?? true) }
            let reviewedNote = context.flatMap { try? model.handsMergeCheck($0, preview: preview) }
            check(context?.handsCandidate == ref && diff?.text.contains("hello world") == true && copyRefused && unreviewed && reviewedNote != nil
                  && !trapsRan(), "審查：施工卡 diff 用固定候選 SHA、不給複製合併指令、沒看過這一版的 diff 不能合併")
            let rooms = model.dispatchRooms(parent: live.threadRecord(ws)?.parentThreadID ?? UUID())
            check(rooms.contains { $0.id == ws && $0.isHands && $0.statusLabel == "已交件・待審" && $0.reportAvailable }, "審查：施工卡列出這個房間、報告可看")
            // 重新交件＝舊審查作廢；主線前進要標出。
            _ = await onWS("write_file", ["path": "src/second.txt", "content": "2\n", "create_only": true])
            let resubmitted = await onWS("submit_workspace", ["summary": "第二次"])
            let context2 = try? model.dispatchGitContext(ws)
            let stale2 = context2.map { (try? model.handsMergeCheck($0, preview: DispatchMergePreview(head: baseCommit, branchHead: $0.handsCandidate ?? ""))) == nil } ?? false
            try "main moved\n".write(toFile: project + "/MAIN.md", atomically: true, encoding: .utf8)
            _ = git(["add", "MAIN.md"], cwd: project)
            commit("main moved", cwd: project)
            let diff2 = await Task.detached { context2.flatMap { try? DispatchGit.diff($0) } }.value
            check(!resubmitted.isError && context2?.handsCandidate != ref && stale2 && diff2?.stat.contains("主線已前進") == true,
                  "審查：重新交件＝舊審查作廢；主線在交件後前進，卡上標「主線已前進」", resubmitted.text + (diff2?.stat.prefix(200).description ?? "nil"))
            try? fm.removeItem(atPath: ranLog)

            // ---------- W183 R1b：Hands 專用合併（T16、V6）——真的在正本合併，filter、merge driver、hook、fsmonitor 一個都不能跑 ----------
            func r1bMerge() async throws -> (String, UUID) {
                func mergeAttempt(_ context: DispatchGitContext?) async -> (outcome: String, traps: String) {
                    guard let context else { return ("no-context", "") }
                    try? fm.removeItem(atPath: ranLog)
                    let outcome = await Task.detached { () -> String in
                        do {
                            let preview = try DispatchGit.preview(context)
                            return "merged:" + (try DispatchGit.merge(context, expected: preview))
                        } catch { return "refused:\(error)" }
                    }.value
                    return (outcome, (try? String(contentsOfFile: ranLog, encoding: .utf8)) ?? "")
                }
                func projectHead() -> String { git(["rev-parse", "HEAD"], cwd: project).1.trimmingCharacters(in: .whitespacesAndNewlines) }
                let headBeforeMerge = projectHead()
                // 1. 候選會寫到有 filter 的檔（*.txt filter=trace）：App 不執行 filter，寫出來會不同＝不合併。
                let filtered = await mergeAttempt(context2)
                check(filtered.outcome.hasPrefix("refused:") && filtered.outcome.contains("filter") && filtered.traps.isEmpty && projectHead() == headBeforeMerge,
                      "合併：會寫到有 git filter 的檔＝不在 App 裡合併；filter、hook、fsmonitor 一個都沒跑", filtered.outcome + filtered.traps)
                // 2. 設定從專案工作樹裡的檔讀進來（ChatGPT 改得到）＝不合併。
                try "[core]\n\tautocrlf = false\n".write(toFile: project + "/inc.cfg", atomically: true, encoding: .utf8)
                _ = git(["config", "include.path", "../inc.cfg"], cwd: project)
                let included = await mergeAttempt(context2)
                _ = git(["config", "--unset", "include.path"], cwd: project)
                try? fm.removeItem(atPath: project + "/inc.cfg")
                check(included.outcome.hasPrefix("refused:") && included.outcome.contains("工作樹") && included.traps.isEmpty,
                      "合併：git 設定會讀專案工作樹裡的檔＝不合併", included.outcome)
                // 3. 新工作區：只改沒有 filter 的檔。
                let ws3ID = object(await tool("open_workspace", ["project_id": projectID.uuidString, "title": "merge-ok"], token: tokenA).text)["workspace_id"] as? String ?? ""
                let ws3 = UUID(uuidString: ws3ID) ?? UUID()
                _ = await onWS("write_file", ["path": "docs/merge.md", "content": "merged by the user\n", "create_only": true], id: ws3ID)
                let submitted3 = await onWS("submit_workspace", ["summary": "只改 docs/merge.md"], id: ws3ID)
                model.document = live.document
                let context3 = try? model.dispatchGitContext(ws3)
                // 3a. 設了外部合併程式（merge driver）：git 會直接執行它＝不合併。
                _ = git(["config", "merge.evil.driver", "'" + trap + "' %O %A %B"], cwd: project)
                let driver = await mergeAttempt(context3)
                _ = git(["config", "--remove-section", "merge.evil"], cwd: project)
                // 3b. filter 指令提到要改的檔（合併後下一次 git 就會跑 ChatGPT 改過的程式）＝不合併。
                _ = git(["config", "filter.inrepo.smudge", "sh docs/merge.md"], cwd: project)
                let mention = await mergeAttempt(context3)
                _ = git(["config", "--remove-section", "filter.inrepo"], cwd: project)
                check(!submitted3.isError && context3?.handsCandidate != nil && driver.outcome.hasPrefix("refused:") && driver.outcome.contains("合併程式")
                      && mention.outcome.hasPrefix("refused:") && mention.outcome.contains("filter 會執行") && driver.traps.isEmpty && mention.traps.isEmpty
                      && projectHead() == headBeforeMerge,
                      "合併：設了 merge driver、或 filter 指令提到要改的檔＝不合併，正本沒動、陷阱沒跑", driver.outcome + " | " + mention.outcome)
                // 3c. 都沒有：真的合併（固定 SHA、先預演、index 等於預演才提交），正本的 filter、hook、fsmonitor 一個都沒跑。
                let merged = await mergeAttempt(context3)
                let mergeParents = git(["rev-list", "--parents", "-n", "1", "HEAD"], cwd: project).1.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                check(merged.outcome.hasPrefix("merged:") && merged.traps.isEmpty && fm.fileExists(atPath: project + "/docs/merge.md")
                      && mergeParents.count == 3 && mergeParents[1] == headBeforeMerge && mergeParents[2] == context3?.handsCandidate
                      && git(["status", "--porcelain"], cwd: project).1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "合併：只改沒有 filter 的檔＝合併成功（父親是確認過的兩端）；正本的 filter、merge driver、hook、fsmonitor 一個都沒跑",
                      merged.outcome + merged.traps + "\(mergeParents)")
                // 對照組：沒加固的 merge-tree 會跑 merge driver（在另一個小倉庫，證明 merge driver 陷阱是活的）。
                let driverRepo = try dir("driver-probe")
                _ = git(["init", "-q", "-b", "main"], cwd: driverRepo)
                try "a\nb\nc\n".write(toFile: driverRepo + "/f.txt", atomically: true, encoding: .utf8)
                _ = git(["add", "-A"], cwd: driverRepo); commit("base", cwd: driverRepo)
                _ = git(["checkout", "-q", "-b", "side"], cwd: driverRepo)
                try "a\nb\nc2\n".write(toFile: driverRepo + "/f.txt", atomically: true, encoding: .utf8)
                _ = git(["add", "-A"], cwd: driverRepo); commit("side", cwd: driverRepo)
                _ = git(["checkout", "-q", "main"], cwd: driverRepo)
                try "a1\nb\nc\n".write(toFile: driverRepo + "/f.txt", atomically: true, encoding: .utf8)
                _ = git(["add", "-A"], cwd: driverRepo); commit("main", cwd: driverRepo)
                _ = git(["config", "merge.evil.driver", "'" + trap + "' %O %A %B"], cwd: driverRepo)
                try "* merge=evil\n".write(toFile: driverRepo + "/.git/info/attributes", atomically: true, encoding: .utf8)
                try? fm.removeItem(atPath: ranLog)
                _ = rawGit(["merge-tree", "--write-tree", "main", "side"], cwd: driverRepo)
                check(trapsRan(), "對照組：沒加固的 git merge-tree 會跑 merge driver（merge driver 陷阱是活的）")
                try? fm.removeItem(atPath: ranLog)
                return (ws3ID, ws3)
            }
            let (ws3ID, ws3) = try await r1bMerge()

            // ---------- W183 R1b：交件的工作區鎖（V5）、無法判定的掃描（V10）、保護項目被繞過（V7） ----------
            func r1bSubmitGuards() async throws {
                let ws4ID = object(await tool("open_workspace", ["project_id": projectID.uuidString, "title": "probe"], token: tokenA).text)["workspace_id"] as? String ?? ""
                let ws4 = UUID(uuidString: ws4ID) ?? UUID()
                _ = service.lockWorkspace(ws4ID)   // 模擬交件拿著工作區的鎖
                let busyJob = await onWS("job_start", ["command": "touch busy.txt", "timeout_s": 30], id: ws4ID)
                service.unlockWorkspace(ws4ID)
                service.beginSubmitting(ws4)       // 模擬交件進行中：已經排隊、還沒啟動的 job 在啟動前被擋
                let queuedJob = object(await onWS("job_start", ["command": "touch queued.txt", "timeout_s": 30], id: ws4ID).text)["job_id"] as? String ?? ""
                _ = await Task.detached { service.jobs.wait(queuedJob, seconds: 10) }.value
                let queuedMeta = object(await tool("job_status", ["job_id": queuedJob], token: tokenA).text)
                service.endSubmitting(ws4)
                let ws4Repo = HandsPath.realpath(paths.repo(ws4).path) ?? paths.repo(ws4).path
                check(busyJob.isError && busyJob.text.contains("workspace_busy") && queuedMeta["state"] as? String == "cancelled"
                      && (queuedMeta["not_started"] as? String)?.contains("workspace_submitting") == true
                      && !fm.fileExists(atPath: ws4Repo + "/busy.txt") && !fm.fileExists(atPath: ws4Repo + "/queued.txt"),
                      "交件：job_start 也拿工作區的鎖（交件中＝workspace_busy）；交件中才輪到的 job 在啟動前被擋、指令沒跑", busyJob.text + "\(queuedMeta)")
                let ws4Snapshot = try service.workspaceSnapshot(ws4)
                HandsSandbox.setFault(.enumerationFails, true)
                let blindScan = await Task.detached { HandsSandbox.quiesce(workspace: ws4ID, roots: [ws4Snapshot.dir], marksDirectory: marks) }.value
                HandsSandbox.setFault(.enumerationFails, false)
                let holder = Process()
                holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
                holder.arguments = ["-e", "opendir(my $d, $ARGV[0]) or die; chdir('/'); sleep 60", ws4Repo]
                try holder.run()
                try await Task.sleep(nanoseconds: 400_000_000)
                let heldScan = await Task.detached { HandsSandbox.quiesce(workspace: ws4ID, roots: [ws4Snapshot.dir], marksDirectory: marks) }.value
                holder.terminate(); holder.waitUntilExit()
                var blindUnknown = false, heldByPerl = false
                if case .unknown = blindScan { blindUnknown = true }
                if case .remaining(let found) = heldScan { heldByPerl = found.contains { $0.pid == holder.processIdentifier } }
                check(blindUnknown && heldByPerl, "交件：列舉行程失敗＝無法判定（不當作沒有寫入者）；別的程式只拿著工作區資料夾的 fd（之後可以 openat 寫）也算寫入者",
                      "\(blindScan) \(heldScan)")
                try "tampered\n".write(toFile: ws4Repo + "/docs/AGENTS.md", atomically: false, encoding: .utf8)   // 模擬繞過規則改了指示文件
                let drift = service.protectedDrift(ws4Snapshot)
                let driftSubmit = await onWS("submit_workspace", ["summary": "drift"], id: ws4ID)
                check(drift == "docs/AGENTS.md" && driftSubmit.isError && driftSubmit.text.contains("protected_tree_changed")
                      && service.workspaceStore.record(ws4)?.lockReason == "protected_tree_changed",
                      "交件：保護項目跟開的時候不一樣（被繞過改了）＝鎖住、不交件", driftSubmit.text)
                HandsSandbox.setFault(.probeUnavailable, true)
                let blindSubmit = await onWS("submit_workspace", ["summary": "again"], id: ws3ID)
                HandsSandbox.setFault(.probeUnavailable, false)
                check(blindSubmit.isError && blindSubmit.text.contains("cannot_verify_no_writers")
                      && service.workspaceStore.record(ws3)?.lockReason == "writers_unverifiable",
                      "交件：認不出手腳行程（探針不在）＝無法證明已停＝鎖住、不交件", blindSubmit.text)
            }
            try await r1bSubmitGuards()
            // 巢狀 .git（主機端放的；沙盒建不起來）：交件不收。
            try fm.createDirectory(atPath: repo + "/nested/.git", withIntermediateDirectories: true)
            let nestedSubmit = await onWS("submit_workspace", ["summary": "nested"])
            check(nestedSubmit.isError && nestedSubmit.text.contains("nested_git_refused"), "交件：巢狀 .git 不收", nestedSubmit.text)
            try fm.removeItem(atPath: repo + "/nested")
            return (ws3ID, ws3)
        }
        let (ws3ID, ws3) = try await s10Submit()

        // ---------- 11. 磁碟上限、撤銷與降級（V10） ----------
        func s11DiskRevoke() async throws {
            // W183 R1b：磁碟低水位——剩不夠就不寫檔、不跑指令、不開工作區（不只在指令結束後量）。
            func r1bDisk() async throws {
                service.diskLowWaterBytes = Int64.max / 4
                let lowWrite = await tool("write_file", ["workspace_id": openedB, "path": "low.txt", "content": "x", "create_only": true], token: tokenB)
                let lowJob = await tool("job_start", ["workspace_id": openedB, "command": "true"], token: tokenB)
                let lowOpen = await tool("open_workspace", ["project_id": projectID.uuidString, "title": "low"], token: tokenB)
                service.diskLowWaterBytes = HandsService.diskLowWater
                check([lowWrite, lowJob, lowOpen].allSatisfy { $0.isError && $0.text.contains("disk_low") }, "磁碟：快滿了＝寫檔、開長工作、開工作區一律不做",
                      lowWrite.text + lowJob.text + lowOpen.text)
                // 寫檔也算進工作區上限（不只指令）：超過＝鎖住。
                let bWrite = object(await tool("open_workspace", ["project_id": projectID.uuidString, "title": "b-write"], token: tokenB).text)["workspace_id"] as? String ?? ""
                service.diskQuotaBytes = 1
                let quotaWrite = await tool("write_file", ["workspace_id": bWrite, "path": "q.txt", "content": "x", "create_only": true], token: tokenB)
                service.diskQuotaBytes = HandsService.diskQuota
                check(quotaWrite.isError && quotaWrite.text.contains("disk_quota_exceeded")
                      && service.workspaceStore.record(UUID(uuidString: bWrite) ?? UUID())?.lockReason == "disk_quota_exceeded",
                      "磁碟：寫檔也算進工作區上限（超過就鎖住，不是只在指令結束後量）", quotaWrite.text)
                // 指令跑到一半磁碟快滿：看門的每 2 秒看一次，收掉並鎖住。
                let bMonitor = object(await tool("open_workspace", ["project_id": projectID.uuidString, "title": "b-monitor"], token: tokenB).text)["workspace_id"] as? String ?? ""
                let monitored = object(await tool("job_start", ["workspace_id": bMonitor, "command": "sleep 30", "timeout_s": 60], token: tokenB).text)["job_id"] as? String ?? ""
                service.diskLowWaterBytes = Int64.max / 4
                var monitoredState = ""
                for _ in 0..<40 where monitoredState == "" || monitoredState == "running" {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    monitoredState = object(await tool("job_status", ["job_id": monitored], token: tokenB).text)["state"] as? String ?? ""
                }
                service.diskLowWaterBytes = HandsService.diskLowWater
                check(monitoredState == "cancelled" && service.workspaceStore.record(UUID(uuidString: bMonitor) ?? UUID())?.lockReason == "disk_low",
                      "磁碟：指令跑到一半磁碟快滿＝收掉並鎖住（跑的時候就看，不等結束）", monitoredState)
                // 輸出區的保留政策：超過 7 天的輸出清掉。
                let oldOutput = paths.output(grant: grantB.grant, job: "job_00000000000000aa")
                try HandsFiles.ensureDirectory(paths.outputDir)
                try HandsFiles.ensureDirectory(paths.outputDir.appendingPathComponent(grantB.grant, isDirectory: true))
                try HandsFiles.ensureDirectory(oldOutput)
                try HandsFiles.writeAtomically(Data("{}".utf8), to: oldOutput.appendingPathComponent("meta.json"))
                try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86_400)], ofItemAtPath: oldOutput.appendingPathComponent("meta.json").path)
                service.jobs.pruneOutputs()
                check(!fm.fileExists(atPath: oldOutput.path), "輸出區：超過 7 天的輸出清掉（保留政策；每個連線、全部都有總量上限）")
            }
            try await r1bDisk()
            service.diskQuotaBytes = 1_000_000
            let big = await run("head -c 3000000 /dev/zero > big.bin; echo wrote", token: tokenB, id: openedB)
            let afterBig = await tool("write_file", ["workspace_id": openedB, "path": "after.txt", "content": "x", "create_only": true], token: tokenB)
            service.diskQuotaBytes = HandsService.diskQuota
            check(big.text.contains("disk quota exceeded") && afterBig.isError && afterBig.text.contains("workspace_locked")
                  && service.workspaceStore.record(UUID(uuidString: openedB) ?? UUID())?.lockReason == "disk_quota_exceeded",
                  "磁碟：指令後量工作區，超過上限就收掉並鎖住（之後不能再寫）", big.text + afterBig.text)
            let running = object(await onWS("job_start", ["command": "sleep 60", "timeout_s": 120]).text)["job_id"] as? String ?? ""
            service.auth.revokeGrant(grantA.grant)
            for _ in 0..<50 where service.jobs.job(running, grant: grantA.grant)?.finished == false {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let afterRevoke = await tool("tatwo_status", [:], token: tokenA)
            let runningState = service.jobs.job(running, grant: grantA.grant)?.state
            check(errorCode(afterRevoke.raw) == "unauthorized" && runningState == "cancelled" && service.workspaceStore.record(ws)?.isLocked == true
                  && fm.fileExists(atPath: repo + "/README.md"), "撤銷一個 grant：立刻拒絕、執行中的工作收掉、工作區鎖住（保留不刪）", "\(runningState ?? "nil")")
            // W183 R1b：撤銷前就通過授權、撤銷後才輪到啟動的工作（例如已經排進佇列）：啟動前最後一次檢查擋下，指令沒跑；發布也擋。
            func r1bLateStart() async throws {
                if let snapshot = try? service.workspaceSnapshot(ws3) {
                    let late = try? service.jobs.start(command: "touch late-revoke.txt", workspace: snapshot, timeout: 30, service: service)
                    let lateID = late?.0.id ?? ""
                    _ = await Task.detached { service.jobs.wait(lateID, seconds: 10) }.value
                    let lateState = service.jobs.job(lateID, grant: grantA.grant)
                    let published = (try? service.withPublication(grantID: grantA.grant, level: 2, projectID: projectID, workspaceID: ws3, forWrite: true,
                                                                  duringSubmit: true) { true }) ?? false
                    check(!lateID.isEmpty && lateState?.state == "cancelled" && lateState?.refusal == "grant_revoked"
                          && !fm.fileExists(atPath: snapshot.repo + "/late-revoke.txt") && !published,
                          "撤銷：撤銷後才輪到啟動的工作在啟動前被擋（指令沒跑）；撤銷後的發布（交件、開工作區）也擋", "\(lateState?.state ?? "nil") \(lateState?.refusal ?? "nil")")
                } else {
                    check(false, "撤銷：撤銷後才輪到啟動的工作（找不到工作區）")
                }
            }
            try await r1bLateStart()
            let openedB2 = object(await tool("open_workspace", ["project_id": projectID.uuidString, "title": "b2"], token: tokenB).text)["workspace_id"] as? String ?? ""
            _ = try service.updateSettings { $0.level = 1 }
            check(!openedB2.isEmpty && service.workspaceStore.record(UUID(uuidString: openedB2) ?? UUID())?.lockReason == "level_lowered", "降級：工作區鎖住")
            _ = try service.updateSettings { $0.level = 2 }
        }
        try await s11DiskRevoke()

        // ---------- 12. 房間：每次一列、看門狗、輸入框 ----------
        func s12Rooms() async throws {
            let rows = live.transcript(for: ws)
            let toolRows = rows.filter { $0.eventKind == .toolUse && $0.role == .assistant }
            check(toolRows.count >= 15 && toolRows.allSatisfy { ($0.status ?? "").hasPrefix("done|") || ($0.status ?? "").hasPrefix("error|") }
                  && toolRows.allSatisfy { $0.text.hasPrefix("〔外部資料・ChatGPT・") }, "房間：每次呼叫一列、都已結束、標外部資料與連線（\(toolRows.count) 列）")
            let allText = live.document.projects.flatMap(\.threads).flatMap { live.transcript(for: $0.id) }.map(\.text).joined(separator: "\n")
            check(!leaksCanary(allText) && !leaksCanary(allText.uppercased()) && !leaksPEM(allText) && !allText.contains(tokenA) && !allText.contains(tokenB),
                  "房間：紀錄裡沒有 canary、沒有私鑰內容、沒有 token")
            model.selectedThreadID = ws
            model.prompt = "幫我改一下"
            let composerLocked = !model.canSend && model.isSelectedHandsThread && model.isHandsRoom(ws)
            let sendRefused = !live.send(threadID: ws, text: "hi", model: nil)
            check(composerLocked && sendRefused, "房間：輸入框鎖住、send_message 也送不進去")
            model.prompt = ""
            let controlRoom = live.newThread(in: projectID, title: "control room")
            live.configureRoom(threadID: controlRoom, parentThreadID: live.threadRecord(ws)?.parentThreadID ?? UUID(), roomBrief: "x", engine: "claude", cwdOverride: project)
            let docURL = liveRoot.appendingPathComponent("document.json")
            if var document = (try? JSONSerialization.jsonObject(with: Data(contentsOf: docURL))) as? [String: Any],
               var threads = document["threads"] as? [[String: Any]] {
                let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7200))
                for index in threads.indices where [ws.uuidString, controlRoom.uuidString].contains(threads[index]["id"] as? String ?? "") {
                    threads[index]["subStatus"] = "running"; threads[index]["lastOutputAt"] = old
                }
                document["threads"] = threads
                try JSONSerialization.data(withJSONObject: document).write(to: docURL)
            }
            let reloaded = ChatLiveEngine(store: ChatLiveStore(root: liveRoot), environment: environment)
            let watchdog = DispatchWatchdog.attach(to: reloaded, environment: ["TATWO2_WATCHDOG_INTERVAL_SEC": "3600"])
            watchdog.tick()
            watchdog.stop()
            check(reloaded.threadRecord(ws)?.subStatus == "running" && reloaded.threadRecord(controlRoom)?.subStatus == "stalled",
                  "看門狗：ChatGPT 的房間不收（一般子房照收）")
            reloaded.shutdownAll()
        }
        try await s12Rooms()

        // ---------- W183 R6c：工作區放在入口的 chatgpt/（TAP 開關那一步就準備好）；HandsWorkspaceAcceptance.swift ----------
        try await HandsWorkspaceAcceptance.run(.init(
            service: service, base: base, entry: entry, project: project, projectID: projectID, token: tokenB, fallbackRepo: repo,
            check: { check($0, $1, $2) }, tool: { name, arguments, token in await tool(name, arguments, token: token) },
            git: { args, cwd in git(args, cwd: cwd) }))

        // ---------- W183 R1b：重送（request_id）不繞過後來縮小的授權（V12） ----------
        func r1bTail() async throws {
            let replayWS = object(await tool("open_workspace", ["project_id": projectID.uuidString, "title": "b-replay"], token: tokenB).text)["workspace_id"] as? String ?? ""
            let replayRID = "rq_" + HandsAuth.hex(bytes: 8)
            let replayFirst = await tool("run_command", ["workspace_id": replayWS, "command": "cat README.md"], token: tokenB, requestID: replayRID)
            // W183 R10：本機的 allowed_project_ids 不再當閘門（全部可見）；「專案不在了」改成 Coder 裡拿掉這個專案。
            let records = service.allProjectRecords()
            service.projectsOverride = { records.filter { $0.0 != projectID } }
            let replaySecond = await tool("run_command", ["workspace_id": replayWS, "command": "cat README.md"], token: tokenB, requestID: replayRID)
            service.projectsOverride = nil
            check(!replayFirst.isError && replayFirst.text.contains("base") && replaySecond.isError && replaySecond.text.contains("request_replay_refused")
                  && !replaySecond.text.contains("\nbase"), "request_id：專案後來不在了（Coder 裡拿掉），用同一個 request_id 重送也拿不到舊輸出", replaySecond.text)

            // ---------- W183 R1b：撤銷存不了檔（磁碟滿）＝全部停用、授權檔刪掉，重開也不會讀回舊的 grant ----------
            let activeBefore = auth.activeGrantIDs
            auth.failSavesForTesting = true
            let saveProblem = auth.revokeGrant(grantB.grant)
            let checkAfter = result(await call("hands_auth", ["op": "check", "access_token": tokenB]))
            auth.failSavesForTesting = false
            let reopened = HandsAuth(url: paths.authFile)
            check(!activeBefore.isEmpty && saveProblem != nil && auth.grant(forAccess: tokenB) == nil && auth.activeGrantIDs.isEmpty
                  && checkAfter["ok"] as? Bool == false && reopened.activeGrantIDs.isEmpty && reopened.grant(forAccess: tokenB) == nil,
                  "撤銷：存不了檔也不會讓舊授權復活（全部停用、授權檔刪掉、畫面拿得到錯誤說明）", saveProblem ?? "nil")

            // ---------- W183 R1b：request_id 帳本——同一個過期的鍵同時被重送，只有一個拿到占位 ----------
            let ledgerDir = base.appendingPathComponent("ledger-race", isDirectory: true)
            try HandsFiles.ensureDirectory(ledgerDir)
            let ledger = HandsRequestLedger(directory: ledgerDir)
            let ledgerKey = ledger.key(grant: "g_test", tool: "run_command", requestID: "rq_race")
            let staleEntry = HandsRequestLedger.Entry(fingerprint: HandsRequestLedger.fingerprint(tool: "run_command", arguments: ["command": "x"]), state: "done",
                                                 jobID: nil, text: "old", isError: false, createdAt: Date().addingTimeInterval(-2 * 86_400), instance: "old")
            let staleEncoder = JSONEncoder(); staleEncoder.dateEncodingStrategy = .iso8601
            try HandsFiles.writeAtomically(try staleEncoder.encode(staleEntry), to: ledgerDir.appendingPathComponent(ledgerKey + ".json"))
            let freshCount = Box(0)
            await Task.detached {
                DispatchQueue.concurrentPerform(iterations: 12) { _ in
                    if case .fresh? = try? ledger.reserve(grant: "g_test", tool: "run_command", requestID: "rq_race", arguments: ["command": "x"]) {
                        freshCount.update { $0 += 1 }
                    }
                }
            }.value
            check(freshCount.get() == 1, "request_id：同一個過期的鍵同時被重送，只有一個拿到占位（整段在同一把鎖裡）", "fresh=\(freshCount.get())")
        }
        // ---------- W183 R10 底線 B：交易實盤類專案最多 L0（主機照 Coder 的專案名與資料夾判斷，不信 ChatGPT 的參數） ----------
        func r10TradingFloor() async throws {
            let records = service.allProjectRecords()
            let floorWS = object(await tool("open_workspace", ["project_id": projectID.uuidString, "title": "floor"], token: tokenB).text)["workspace_id"] as? String ?? ""
            // 開好工作區之後，Coder 裡這個專案改名成交易實盤類（工作區紀錄記的舊名字不算數，主機即時查）。
            service.projectsOverride = { records.map { $0.0 == projectID ? ($0.0, "BTC 實盤 desk", $0.2) : $0 } }
            let listed = object(await tool("list_projects", [:], token: tokenB).text)["projects"] as? [[String: Any]] ?? []
            let flagged = listed.first { $0["id"] as? String == projectID.uuidString }?["read_only"] as? Bool == true
            var refused: [String: Bool] = [:]
            let floorCalls: [(String, [String: Any])] = [
                ("write_file", ["workspace_id": floorWS, "path": "floor.txt", "content": "x", "create_only": true]),
                ("run_command", ["workspace_id": floorWS, "command": "touch floor-ran.txt"]),
                ("job_start", ["workspace_id": floorWS, "command": "touch floor-job.txt"]),
                ("submit_workspace", ["workspace_id": floorWS, "summary": "x"]),
                ("write_report", ["workspace_id": floorWS, "text": "x"]),
                ("memory_inbox_save", ["title": "x", "content": "x", "workspace_id": floorWS]),
                ("open_workspace", ["project_id": projectID.uuidString, "title": "again"])]
            for (name, arguments) in floorCalls {
                let result = await tool(name, arguments, token: tokenB)
                refused[name] = result.isError && result.text.contains("project_read_only")
            }
            let read = await tool("read_file", ["workspace_id": floorWS, "path": "README.md"], token: tokenB)
            let status = await tool("git_status", ["workspace_id": floorWS], token: tokenB)
            let mainRead = await tool("read_file", ["project_id": projectID.uuidString, "path": "README.md"], token: tokenB)
            let floorRepo = UUID(uuidString: floorWS).flatMap { try? service.workspaceSnapshot($0).repo } ?? ""
            let untouched = !floorRepo.isEmpty && !fm.fileExists(atPath: floorRepo + "/floor.txt") && !fm.fileExists(atPath: floorRepo + "/floor-ran.txt")
                && !fm.fileExists(atPath: floorRepo + "/floor-job.txt")
            service.projectsOverride = nil
            check(flagged && refused.values.allSatisfy { $0 } && refused.count == 7 && !read.isError && !status.isError && !mainRead.isError && untouched,
                  "W183 R10 底線 B：交易實盤類專案（Coder 裡改名成含「實盤」的）——list_projects 標 read_only；寫檔、跑指令、長工作、交件、寫報告、收件匣（綁工作區）、開工作區一律拒；讀檔、git 狀態、讀主線照樣可以；工作區一個檔都沒多",
                  "flagged=\(flagged) refused=\(refused) read=\(read.isError) status=\(status.isError) main=\(mainRead.isError) untouched=\(untouched)")
        }
        // ---------- W183 R10 第二輪：底線 A 的覆蓋面、底線 B 的別名與執行中改名（GPT-6 4、5、6、7；主導裁決） ----------
        func r10Round2Floors() async throws {
            // 1. 依賴也是進工作區的來源：node_modules 裡的 .env、依賴裡的 .git（別人的 Git 物件庫）、.build/repositories 都不進來；依賴本身照樣在。
            let depEnv = fm.fileExists(atPath: repo + "/node_modules/dep/.env")
            let depGit = fm.fileExists(atPath: repo + "/node_modules/dep/.git")
            let checkoutGit = fm.fileExists(atPath: repo + "/.build/checkouts/pkg/.git")
            let repositories = fm.fileExists(atPath: repo + "/.build/repositories")
            let kept = fm.fileExists(atPath: repo + "/node_modules/dep/index.js") && fm.fileExists(atPath: repo + "/.build/checkouts/pkg/Sources/x.swift")
            check(!depEnv && !depGit && !checkoutGit && !repositories && kept,
                  "W183 R10 第二輪 底線 A：依賴也濾——node_modules 裡的 .env、依賴裡的 .git（別人的 Git 物件庫）、.build/repositories 都不進工作區；依賴本身照樣在",
                  "env=\(depEnv) git=\(depGit) checkoutGit=\(checkoutGit) repositories=\(repositories) kept=\(kept)")

            // 2. 沙盒規則擋（不是事後遮罩）：工作區裡金鑰類的檔，run_command 讀不到內容、寫不了；檔案小幫手也不給寫。
            let freshWS = object(await tool("open_workspace", ["project_id": projectID.uuidString, "title": "r10b"], token: tokenB).text)["workspace_id"] as? String ?? ""
            let freshRepo = UUID(uuidString: freshWS).flatMap { try? service.workspaceSnapshot($0).repo } ?? ""
            try fm.createDirectory(atPath: freshRepo + "/planted", withIntermediateDirectories: true)
            try (canary + "-planted\n").write(toFile: freshRepo + "/planted/.env", atomically: true, encoding: .utf8)   // 模擬舊工作區留下的
            let catRun = await tool("run_command", ["workspace_id": freshWS, "command": "cat planted/.env; echo after-cat"], token: tokenB)
            let writeRun = await tool("run_command", ["workspace_id": freshWS, "command": "echo x > .env; echo y > secrets.txt; mkdir .ssh; echo end"], token: tokenB)
            let writeFile = await tool("write_file", ["workspace_id": freshWS, "path": "config/api_key.json", "content": "{}", "create_only": true], token: tokenB)
            let sandboxed = !freshRepo.isEmpty && !catRun.text.contains(canary) && catRun.text.contains("after-cat") && writeRun.text.contains("end")
                && !fm.fileExists(atPath: freshRepo + "/.env") && !fm.fileExists(atPath: freshRepo + "/secrets.txt") && !fm.fileExists(atPath: freshRepo + "/.ssh")
                && writeFile.isError && writeFile.text.contains("secret_file_refused") && !fm.fileExists(atPath: freshRepo + "/config/api_key.json")
            try? fm.removeItem(atPath: freshRepo + "/planted")
            check(sandboxed, "W183 R10 第二輪 底線 A：沙盒規則擋——run_command 讀不到工作區裡金鑰類檔案的內容、建不出 .env／secrets*／.ssh；write_file 寫金鑰類路徑＝secret_file_refused",
                  "cat=\(catRun.text.prefix(200)) write=\(writeRun.text.prefix(200)) file=\(writeFile.text.prefix(120))")

            // 3. 舊工作區（R10 之前開的＝沒照現在的清單掃過）：第一次用到時，工作樹裡金鑰類的檔搬去隔離（沒刪、有還原說明）；
            //    git 歷史裡有＝鎖住（git show 讀得到舊 blob，不能再讓 ChatGPT 在這裡跑指令）。只在工作樹、歷史乾淨的＝搬走後照常用。
            let oldWS = object(await tool("open_workspace", ["project_id": projectID.uuidString, "title": "old"], token: tokenB).text)["workspace_id"] as? String ?? ""
            let oldID = UUID(uuidString: oldWS) ?? UUID()
            let oldSnapshot = try service.workspaceSnapshot(oldID)
            try fm.createDirectory(atPath: oldSnapshot.repo + "/cfg", withIntermediateDirectories: true)
            try (canary + "-old\n").write(toFile: oldSnapshot.repo + "/cfg/secrets.json", atomically: true, encoding: .utf8)
            _ = git(["add", "-A"], cwd: oldSnapshot.repo)
            commit("old secret", cwd: oldSnapshot.repo)
            try service.workspaceStore.update(oldID) { $0.secretScan = nil }
            let touched = await tool("list_dir", ["workspace_id": oldWS, "path": ""], token: tokenB)
            let oldRecord = service.workspaceStore.record(oldID)
            let quarantine = (try? fm.contentsOfDirectory(atPath: oldSnapshot.dir))?.first { $0.hasPrefix("quarantine-") }
            let moved = quarantine.map { fm.fileExists(atPath: oldSnapshot.dir + "/" + $0 + "/files/cfg/secrets.json")
                && fm.fileExists(atPath: oldSnapshot.dir + "/" + $0 + "/RESTORE.txt") } ?? false
            let showRun = await tool("run_command", ["workspace_id": oldWS, "command": "git show HEAD:cfg/secrets.json"], token: tokenB)
            check(!touched.isError && oldRecord?.isLocked == true && oldRecord?.lockReason == "secret_in_history" && oldRecord?.secretScan == HandsSecretFiles.scanVersion
                  && moved && !fm.fileExists(atPath: oldSnapshot.repo + "/cfg/secrets.json") && showRun.isError && !showRun.text.contains(canary),
                  "W183 R10 第二輪 底線 A：舊工作區第一次用到時掃一次——金鑰類檔案搬去 quarantine-*/（沒刪、有 RESTORE.txt）；git 歷史裡有＝鎖住，git show 叫不動",
                  "locked=\(String(describing: oldRecord?.lockReason)) moved=\(moved) show=\(showRun.text.prefix(160))")
            let cleanWS = object(await tool("open_workspace", ["project_id": projectID.uuidString, "title": "old-clean"], token: tokenB).text)["workspace_id"] as? String ?? ""
            let cleanID = UUID(uuidString: cleanWS) ?? UUID()
            let cleanSnapshot = try service.workspaceSnapshot(cleanID)
            try fm.createDirectory(atPath: cleanSnapshot.repo + "/notes", withIntermediateDirectories: true)
            try (canary + "-untracked\n").write(toFile: cleanSnapshot.repo + "/notes/api_key.txt", atomically: true, encoding: .utf8)
            try service.workspaceStore.update(cleanID) { $0.secretScan = nil }
            let cleanRun = await tool("run_command", ["workspace_id": cleanWS, "command": "ls notes; echo usable"], token: tokenB)
            let cleanRecord = service.workspaceStore.record(cleanID)
            check(!cleanRun.isError && cleanRun.text.contains("usable") && cleanRecord?.isLocked == false && !fm.fileExists(atPath: cleanSnapshot.repo + "/notes/api_key.txt"),
                  "W183 R10 第二輪 底線 A：舊工作區只有工作樹裡有（歷史乾淨）＝搬去隔離、工作區照常能用", "\(cleanRun.text.prefix(200))")

            // 4. 專案根目錄本身是金鑰類資料夾（credentials-backup）＝整個專案不納入範圍：列不到、讀不到。
            let credRoot = base.appendingPathComponent("credentials-backup").path
            try fm.createDirectory(atPath: credRoot, withIntermediateDirectories: true)
            try (canary + "-root\n").write(toFile: credRoot + "/config", atomically: true, encoding: .utf8)
            _ = git(["init", "-q", "-b", "main"], cwd: credRoot)
            _ = git(["add", "-A"], cwd: credRoot)
            commit("cred", cwd: credRoot)
            let credID = UUID()
            let before = service.allProjectRecords()
            service.projectsOverride = { before + [(credID, "Backup", credRoot)] }
            let credList = object(await tool("list_projects", [:], token: tokenB).text)["projects"] as? [[String: Any]] ?? []
            let credRead = await tool("read_file", ["project_id": credID.uuidString, "path": "config"], token: tokenB)
            service.projectsOverride = nil
            check(!credList.isEmpty && !credList.contains { $0["id"] as? String == credID.uuidString } && credRead.isError && !credRead.text.contains(canary),
                  "W183 R10 第二輪 底線 A：專案根目錄本身是金鑰類資料夾（credentials-backup）＝整個專案不納入範圍（列不到、讀不到）", "\(credRead.text.prefix(160))")

            // 5. 底線 B 的別名：同一個資料夾的另一個專案名命中（BTC 實盤）、捷徑、共用 Git 儲存庫的 worktree＝指向它的專案全部最多 L0。
            let records = service.allProjectRecords()
            let link = base.appendingPathComponent("desk-link").path
            try? fm.removeItem(atPath: link)
            try fm.createSymbolicLink(atPath: link, withDestinationPath: project)
            let tradingAlias = UUID(), linkAlias = UUID()
            service.projectsOverride = { records + [(tradingAlias, "BTC 實盤", link), (linkAlias, "Desk", link)] }
            let aliasList = object(await tool("list_projects", [:], token: tokenB).text)["projects"] as? [[String: Any]] ?? []
            let aliasFlag = aliasList.first { $0["id"] as? String == projectID.uuidString }?["read_only"] as? Bool == true
                && aliasList.first { $0["id"] as? String == linkAlias.uuidString }?["read_only"] as? Bool == true
            let aliasOpen = await tool("open_workspace", ["project_id": projectID.uuidString, "title": "alias"], token: tokenB)
            service.projectsOverride = nil
            let worktree = base.appendingPathComponent("desk-worktree").path
            _ = git(["worktree", "add", "-q", "--no-checkout", "--detach", worktree, "HEAD"], cwd: project)   // 不 checkout：正本的 filter 一個都不跑
            let shared = fm.fileExists(atPath: worktree) && !HandsTradingFloor.identityKeys(worktree).isDisjoint(with: HandsTradingFloor.identityKeys(project))
            _ = git(["worktree", "remove", "--force", worktree], cwd: project)
            check(aliasFlag && aliasOpen.isError && aliasOpen.text.contains("project_read_only") && shared,
                  "W183 R10 第二輪 底線 B：別名——同一個資料夾（捷徑）另一個名字命中「BTC 實盤」＝原本名字中性的專案也標只能看、開不了工作區；worktree 認得是同一個 Git 儲存庫",
                  "flag=\(aliasFlag) open=\(aliasOpen.text.prefix(120)) shared=\(shared)")

            // 6. 執行中改名（不先叫列表、不查狀態）：跑著的長工作在下一輪監看（約 2 秒）就被取消。
            let runWS = object(await tool("open_workspace", ["project_id": projectID.uuidString, "title": "rename"], token: tokenB).text)["workspace_id"] as? String ?? ""
            let started = object(await tool("job_start", ["workspace_id": runWS, "command": "sleep 20; echo finished-normally", "timeout_s": 60], token: tokenB).text)
            let jobID = started["job_id"] as? String ?? ""
            let renamed = service.allProjectRecords().map { $0.0 == projectID ? ($0.0, "BTC 實盤 renamed", $0.2) : $0 }
            let renamedAt = Date()
            service.projectsOverride = { renamed }
            var stopped = ""
            while Date().timeIntervalSince(renamedAt) < 10 {
                try await Task.sleep(nanoseconds: 250_000_000)
                if let job = service.jobs.job(jobID, grant: grantB.grant), job.state != "running" { stopped = job.state; break }
            }
            let took = Date().timeIntervalSince(renamedAt)
            service.projectsOverride = nil
            let output = UUID(uuidString: runWS).flatMap { _ in service.jobs.job(jobID, grant: grantB.grant) }.map { String(decoding: $0.stdoutCapture.head, as: UTF8.self) } ?? ""
            check(!jobID.isEmpty && !stopped.isEmpty && stopped != "exited" && took < 8 && !output.contains("finished-normally"),
                  "W183 R10 第二輪 底線 B：執行中改名成交易實盤類（沒叫列表）＝跑著的長工作在下一輪監看就被取消（分類換版本、受影響的工作當下收掉）",
                  "state=\(stopped) took=\(String(format: "%.1f", took))s")

            // 7. 沒有工作在跑、沒人讀清單：Coder 裡新增交易類專案＝手腳當下重算分類（版本加一）。正式 App 裡引擎一改就把文件交給畫面
            //（ChatPageModel 的 engine.onChange：document = live.document）；這個自測的畫面沒接引擎，照同一句交一次。
            let probeDir = try dir("probe-desk")
            let versionBefore = service.tradingVersion
            let probeID = live.newProject(name: "BTC 實盤 probe", workdir: probeDir)
            model.document = live.document
            var reclassified = false
            let watchStart = Date()
            while Date().timeIntervalSince(watchStart) < 5 {
                if service.tradingVersion != versionBefore && service.isTradingCached(probeID) { reclassified = true; break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            check(reclassified, "W183 R10 第二輪 底線 B：Coder 裡新增交易類專案（沒有工作在跑、沒叫列表）＝手腳當下重算分類、版本加一（清單一變就算）",
                  "version \(versionBefore)→\(service.tradingVersion) took=\(String(format: "%.1f", Date().timeIntervalSince(watchStart)))s")
        }
        // ---------- W183 R10 第三輪：舊工作區整理、暫存區也擋、執行前隔離、雙掃描＋捷徑、分類序號與交件（GPT-6 發現 4、5、6、8） ----------
        func r10Round3Floors() async throws {
            // 自己的一個 grant（每個 grant 最多 32 個工作區；前面的測試已經用掉 B 的大半）；做完撤銷（收尾那一條要看到沒有有效的 grant）。
            let grantC = await pair()
            let tokenC = grantC.access
            defer { service.auth.revokeGrant(grantC.grant) }
            func until(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline {
                    if condition() { return true }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                return condition()
            }
            func quarantines(_ dir: String) -> [String] {
                ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("quarantine-") }.sorted()
            }
            func openFresh(_ title: String) async throws -> (String, HandsWorkspace) {
                let raw = object(await tool("open_workspace", ["project_id": projectID.uuidString, "title": title], token: tokenC).text)["workspace_id"] as? String ?? ""
                guard let id = UUID(uuidString: raw) else { throw HandsToolError.invalid("fixture_open_failed:\(title)") }
                return (raw, try service.workspaceSnapshot(id))
            }

            // 1. 舊工作區（當成第三輪之前開的）：依賴的 Git 物件庫（.build/repositories，歷史有 .env）、依賴裡的 .git（歷史有 secrets.yml）、
            //    工作區自己的 .git 裡摸不到的 blob 與只在 reflog 的 commit（都帶 canary）。第一次用到＝整理：整包隔離、.git 封存後重建乾淨副本。
            let (oldWS, old) = try await openFresh("r10c-old")
            let bare = old.repo + "/.build/repositories/pkg-1"
            try fm.createDirectory(atPath: bare, withIntermediateDirectories: true)
            _ = git(["init", "-q", "--bare"], cwd: bare)
            let bareTree = try dir("r10c-bare-tree")
            try (canary + "-bare\n").write(toFile: bareTree + "/.env", atomically: true, encoding: .utf8)
            _ = git(["--git-dir=" + bare, "--work-tree=" + bareTree, "add", "-A"], cwd: bareTree)
            _ = git(["--git-dir=" + bare, "--work-tree=" + bareTree, "-c", "user.name=fixture", "-c", "user.email=hands-fixture@localhost",
                     "commit", "-q", "-m", "bare"], cwd: bareTree)
            let dep2 = old.repo + "/node_modules/dep2"
            try fm.createDirectory(atPath: dep2, withIntermediateDirectories: true)
            _ = git(["init", "-q"], cwd: dep2)
            try (canary + "-dep2\n").write(toFile: dep2 + "/secrets.yml", atomically: true, encoding: .utf8)
            _ = git(["add", "-A"], cwd: dep2)
            commit("dep2 secret", cwd: dep2)
            _ = git(["rm", "-q", "secrets.yml"], cwd: dep2)
            commit("dep2 clean", cwd: dep2)
            let blobFile = try dir("r10c-blob") + "/blob.txt"
            try (canary + "-dangling\n").write(toFile: blobFile, atomically: true, encoding: .utf8)
            let danglingSHA = git(["hash-object", "-w", blobFile], cwd: old.repo).1.trimmingCharacters(in: .whitespacesAndNewlines)
            try (canary + "-reflog\n").write(toFile: old.repo + "/leak.txt", atomically: true, encoding: .utf8)
            _ = git(["add", "leak.txt"], cwd: old.repo)
            commit("leak", cwd: old.repo)
            let leakCommit = git(["rev-parse", "HEAD"], cwd: old.repo).1.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = git(["reset", "-q", "--hard", "HEAD~1"], cwd: old.repo)
            let bareHadSecret = git(["--git-dir=" + bare, "log", "--all", "-p"], cwd: bareTree).1.contains(canary)
            try service.workspaceStore.update(old.record.id) { $0.secretScan = nil }
            let probe = await tool("run_command", ["workspace_id": oldWS, "command":
                "git -C .build/repositories/pkg-1 log --all -p 2>&1; git cat-file -p \(danglingSHA) 2>&1; git show \(leakCommit):leak.txt 2>&1; "
                + "git -C node_modules/dep2 log --all -p -- secrets.yml 2>&1; git reflog 2>&1; git status --short 2>&1; echo end-probe"], token: tokenC)
            let oldRecord = service.workspaceStore.record(old.record.id)
            let oldQuarantine = quarantines(old.dir)
            let q = oldQuarantine.first.map { old.dir + "/" + $0 } ?? "/nonexistent"
            let archived = git(["--git-dir=" + q + "/git-archive", "cat-file", "-e", danglingSHA], cwd: old.dir).0 == 0
            check(bareHadSecret && !probe.isError && probe.text.contains("end-probe") && !probe.text.contains(canary)
                  && oldRecord?.secretScan == HandsSecretFiles.scanVersion && oldRecord?.isLocked == false && oldQuarantine.count == 1 && archived
                  && fm.fileExists(atPath: q + "/files/.build/repositories/pkg-1") && fm.fileExists(atPath: q + "/files/node_modules/dep2/.git")
                  && fm.fileExists(atPath: q + "/RESTORE.txt") && !fm.fileExists(atPath: old.repo + "/.build/repositories")
                  && !fm.fileExists(atPath: dep2 + "/.git"),
                  "W183 R10 第三輪 舊工作區整理：依賴的 Git 物件庫（.build/repositories）與依賴裡的 .git 整包隔離；工作區自己的 .git 封存後重建乾淨副本（摸不到的物件、reflog 都不在，封存裡還在）；git show 叫不出任何舊秘密",
                  "locked=\(String(describing: oldRecord?.lockReason)) q=\(oldQuarantine) archived=\(archived) \(probe.text.prefix(400))")

            // 2. 暫存區也擋：長工作跑到一半才出現 planted2/.env（例如使用者照還原說明放回來）；工作把中性的上層資料夾搬到 $TMPDIR 再讀＝讀不到。
            let (tmpWS, tmpSnap) = try await openFresh("r10c-tmp")
            let job = object(await tool("job_start", ["workspace_id": tmpWS, "command":
                "sleep 2; mv planted2 \"$TMPDIR/p2\"; echo mv-$?; cat \"$TMPDIR/p2/.env\"; echo cat-$?", "timeout_s": 30], token: tokenC).text)
            let jobID = job["job_id"] as? String ?? ""
            try await Task.sleep(nanoseconds: 500_000_000)
            try fm.createDirectory(atPath: tmpSnap.repo + "/planted2", withIntermediateDirectories: true)
            try (canary + "-planted2\n").write(toFile: tmpSnap.repo + "/planted2/.env", atomically: true, encoding: .utf8)
            var jobState = ""
            for _ in 0..<80 where !["exited", "failed", "cancelled", "timed_out"].contains(jobState) {
                try await Task.sleep(nanoseconds: 250_000_000)
                jobState = object(await tool("job_status", ["job_id": jobID], token: tokenC).text)["state"] as? String ?? ""
            }
            let jobText = await tool("job_output", ["job_id": jobID, "offset": 0], token: tokenC).text
            check(!jobID.isEmpty && jobState == "exited" && jobText.contains("mv-0") && jobText.contains("cat-") && !jobText.contains("cat-0")
                  && !jobText.contains(canary),
                  "W183 R10 第三輪 暫存區也擋：長工作把放著 .env 的中性資料夾搬到 $TMPDIR 再讀＝讀不到（沙盒規則照整條路徑比，暫存區一樣）",
                  "state=\(jobState) \(jobText.prefix(300))")

            // 3. 執行前隔離：跑指令之前出現的 planted3/.env 先搬去隔離（有還原說明）才跑；指令讀不到它。
            try fm.createDirectory(atPath: tmpSnap.repo + "/planted3", withIntermediateDirectories: true)
            try (canary + "-planted3\n").write(toFile: tmpSnap.repo + "/planted3/.env", atomically: true, encoding: .utf8)
            let before = Set(quarantines(tmpSnap.dir))
            let pre = await tool("run_command", ["workspace_id": tmpWS, "command": "ls -a planted3; cat planted3/.env; echo end-pre"], token: tokenC)
            let fresh = Set(quarantines(tmpSnap.dir)).subtracting(before)
            let preMoved = fresh.contains { fm.fileExists(atPath: tmpSnap.dir + "/" + $0 + "/files/planted3/.env") && fm.fileExists(atPath: tmpSnap.dir + "/" + $0 + "/RESTORE.txt") }
            check(pre.text.contains("end-pre") && !pre.text.contains(canary) && preMoved && !fm.fileExists(atPath: tmpSnap.repo + "/planted3/.env"),
                  "W183 R10 第三輪 執行前隔離：工作區裡新出現的金鑰類檔先搬去隔離（有 RESTORE.txt）才跑指令；指令讀不到它",
                  "fresh=\(fresh) \(pre.text.prefix(200))")

            // 4. 雙掃描＋中間資料夾換成捷徑：兩個呼叫同時進舊工作區——第一個掃完、要搬之前停住（第二個排隊等工作區互斥）；這時候把 folder
            //    換成指到外面的捷徑（外面也有一個 .env）。放行＝搬不動（逐層不跟捷徑）→ 整次失敗、鎖住；外面的 .env 原封不動；只有一個隔離資料夾。
            let (raceWS, race) = try await openFresh("r10c-race")
            try fm.createDirectory(atPath: race.repo + "/folder", withIntermediateDirectories: true)
            try (canary + "-race\n").write(toFile: race.repo + "/folder/.env", atomically: true, encoding: .utf8)
            let outside = try dir("r10c-outside")
            try "outside-original\n".write(toFile: outside + "/.env", atomically: true, encoding: .utf8)
            try service.workspaceStore.update(race.record.id) { $0.secretScan = nil }
            let raceEntered = Box(false), raceArmed = Box(true)
            let raceRelease = DispatchSemaphore(value: 0)
            let raceID = race.record.id
            HandsQuarantine.beforeMoveGate = { id in
                guard id == raceID else { return }
                var take = false
                raceArmed.update { if $0 { $0 = false; take = true } }
                guard take else { return }
                raceEntered.update { $0 = true }
                raceRelease.wait()
            }
            async let raceFirst = tool("list_dir", ["workspace_id": raceWS, "path": ""], token: tokenC)
            let raceGated = await until(8) { raceEntered.get() }
            async let raceSecond = tool("list_dir", ["workspace_id": raceWS, "path": ""], token: tokenC)
            try await Task.sleep(nanoseconds: 400_000_000)
            try fm.moveItem(atPath: race.repo + "/folder", toPath: race.repo + "/folder-real")
            try fm.createSymbolicLink(atPath: race.repo + "/folder", withDestinationPath: outside)
            raceRelease.signal()
            let raceResults = await (raceFirst, raceSecond)
            HandsQuarantine.beforeMoveGate = nil
            let raceRecord = service.workspaceStore.record(raceID)
            let raceQuarantine = quarantines(race.dir)
            let outsideIntact = (try? String(contentsOfFile: outside + "/.env", encoding: .utf8)) == "outside-original\n"
            check(raceGated && raceResults.0.isError && raceResults.1.isError && raceRecord?.lockReason == "secret_migration_failed" && outsideIntact
                  && raceQuarantine.count == 1 && fm.fileExists(atPath: race.dir + "/" + (raceQuarantine.first ?? "-") + "/RESTORE.txt")
                  && fm.fileExists(atPath: race.repo + "/folder-real/.env"),
                  "W183 R10 第三輪 雙掃描＋中間資料夾換成捷徑：第二個等第一個（工作區互斥）；搬的那一步逐層不跟捷徑＝整次失敗、鎖住，外面的 .env 原封不動，只有一個隔離資料夾",
                  "gated=\(raceGated) lock=\(String(describing: raceRecord?.lockReason)) q=\(raceQuarantine) outside=\(outsideIntact) \(raceResults.0.text.prefix(120))")

            // 5. 雙掃描（沒有捷徑）：第二個等第一個做完、看到已經整理過就直接用；兩個都成功，只搬一次。
            let (calmWS, calm) = try await openFresh("r10c-calm")
            try fm.createDirectory(atPath: calm.repo + "/cfgs", withIntermediateDirectories: true)
            try (canary + "-calm\n").write(toFile: calm.repo + "/cfgs/.env", atomically: true, encoding: .utf8)
            try service.workspaceStore.update(calm.record.id) { $0.secretScan = nil }
            let calmEntered = Box(false), calmArmed = Box(true)
            let calmRelease = DispatchSemaphore(value: 0)
            let calmID = calm.record.id
            HandsQuarantine.beforeMoveGate = { id in
                guard id == calmID else { return }
                var take = false
                calmArmed.update { if $0 { $0 = false; take = true } }
                guard take else { return }
                calmEntered.update { $0 = true }
                calmRelease.wait()
            }
            async let calmFirst = tool("list_dir", ["workspace_id": calmWS, "path": ""], token: tokenC)
            let calmGated = await until(8) { calmEntered.get() }
            async let calmSecond = tool("list_dir", ["workspace_id": calmWS, "path": ""], token: tokenC)
            try await Task.sleep(nanoseconds: 300_000_000)
            calmRelease.signal()
            let calmResults = await (calmFirst, calmSecond)
            HandsQuarantine.beforeMoveGate = nil
            let calmRecord = service.workspaceStore.record(calmID)
            let calmQuarantine = quarantines(calm.dir)
            check(calmGated && !calmResults.0.isError && !calmResults.1.isError && calmRecord?.secretScan == HandsSecretFiles.scanVersion
                  && calmRecord?.isLocked == false && calmQuarantine.count == 1
                  && fm.fileExists(atPath: calm.dir + "/" + (calmQuarantine.first ?? "-") + "/files/cfgs/.env"),
                  "W183 R10 第三輪 雙掃描（沒有捷徑）：第二個等第一個整理完、看到版本已經是新的就直接用；兩個都成功、只搬一次",
                  "q=\(calmQuarantine) \(calmResults.1.text.prefix(120))")

            // 6. 分類的序號：舊清單的計算晚到（用 barrier 壓著）不蓋掉新的；版本不再變。
            let records = service.allProjectRecords()
            let listBox = Box(records)
            service.projectsOverride = { listBox.get() }
            _ = service.refreshTradingClassification()
            let staleEntered = Box(false), staleDone = Box(false)
            let staleRelease = DispatchSemaphore(value: 0)
            service.classifyGate = { _ in
                guard Thread.current.name == "r10c-stale-classify" else { return }
                staleEntered.update { $0 = true }
                staleRelease.wait()
            }
            let staleThread = Thread { _ = service.refreshTradingClassification(); staleDone.update { $0 = true } }
            staleThread.name = "r10c-stale-classify"
            staleThread.start()
            let staleGated = await until(8) { staleEntered.get() }
            listBox.update { list in list = list.map { $0.0 == projectID ? ($0.0, "BTC 實盤 barrier", $0.2) : $0 } }
            let versionNew = await Task.detached { service.refreshTradingClassification() }.value
            let tradingNow = service.isTradingCached(projectID)
            staleRelease.signal()
            let staleFinished = await until(8) { staleDone.get() }
            check(staleGated && staleFinished && tradingNow && service.isTradingCached(projectID) && service.tradingVersion == versionNew
                  && !service.classificationPending,
                  "W183 R10 第三輪 分類的序號：舊清單的計算晚到（barrier 壓著）不蓋掉新的（改名成交易類之後還是只能看）、版本不再變",
                  "gated=\(staleGated) trading=\(service.isTradingCached(projectID)) version=\(service.tradingVersion)/\(versionNew)")
            service.classifyGate = nil
            listBox.update { $0 = records }
            _ = await Task.detached { service.refreshTradingClassification() }.value

            // 7. 待分類：主執行緒看到清單變了、還沒算好＝會寫、會跑、交件的最後一道先拒；算好就放行。
            service.noteListRead("r10c-pending-probe")
            let pendingNow = service.classificationPending
            let admissionNow = service.admission(grantID: grantC.grant, level: 2, projectID: projectID, workspaceID: nil, forWrite: false)()
            _ = await Task.detached { service.refreshTradingClassification() }.value
            check(pendingNow && admissionNow == "classification_pending" && !service.classificationPending,
                  "W183 R10 第三輪 待分類：清單剛變、還沒算好＝寫入、執行、交件的最後一道檢查先拒（classification_pending）；算好就放行",
                  "pending=\(pendingNow) admission=\(String(describing: admissionNow))")

            // 8. 交件：分類檢查之後、發布之前改名成交易類（barrier 壓在中間）＝發布鎖裡看到、不交件，候選分支沒建出來。
            let (subWS, _) = try await openFresh("r10c-submit")
            _ = await tool("write_file", ["workspace_id": subWS, "path": "r10c-note.txt", "content": "r10c\n", "create_only": true], token: tokenC)
            let submitEntered = Box(false), submitArmed = Box(true)
            let submitRelease = DispatchSemaphore(value: 0)
            service.submitGate = {
                var take = false
                submitArmed.update { if $0 { $0 = false; take = true } }
                guard take else { return }
                submitEntered.update { $0 = true }
                submitRelease.wait()
            }
            async let submitted = tool("submit_workspace", ["workspace_id": subWS, "summary": "r10c barrier"], token: tokenC)
            let submitGated = await until(10) { submitEntered.get() }
            listBox.update { list in list = list.map { $0.0 == projectID ? ($0.0, "BTC 實盤 after guard", $0.2) : $0 } }
            _ = await Task.detached { service.refreshTradingClassification() }.value
            submitRelease.signal()
            let submitResult = await submitted
            service.submitGate = nil
            let candidateRef = "refs/heads/tatwo2-room-" + subWS.prefix(8)
            let refMade = git(["rev-parse", "--verify", "-q", candidateRef], cwd: project).0 == 0
            check(submitGated && submitResult.isError && !refMade
                  && (submitResult.text.contains("classification_changed") || submitResult.text.contains("project_read_only")),
                  "W183 R10 第三輪 交件：分類檢查之後、發布之前改名成交易類（barrier）＝發布鎖裡看到、不交件，候選分支沒建出來",
                  "gated=\(submitGated) ref=\(refMade) \(submitResult.text.prefix(200))")
            listBox.update { $0 = records }
            service.projectsOverride = nil
            _ = await Task.detached { service.refreshTradingClassification() }.value
        }
        // ---------- W183 R10 第四輪：還原之後重新整理、使用者的 Git 工作不被重建洗掉、清單修訂與交件同一個序列（GPT-6 發現 2、3、4） ----------
        func r10Round4Floors() async throws {
            let grantD = await pair()
            let tokenD = grantD.access
            defer { service.auth.revokeGrant(grantD.grant) }
            func until(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline {
                    if condition() { return true }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                return condition()
            }
            func quarantines(_ dir: String) -> [String] {
                ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("quarantine-") }.sorted()
            }
            func openFresh(_ title: String) async throws -> (String, HandsWorkspace) {
                let raw = object(await tool("open_workspace", ["project_id": projectID.uuidString, "title": title], token: tokenD).text)["workspace_id"] as? String ?? ""
                guard let id = UUID(uuidString: raw) else { throw HandsToolError.invalid("fixture_open_failed:\(title)") }
                return (raw, try service.workspaceSnapshot(id))
            }

            // 1. 遷移成功 → 照 RESTORE.txt 還原 → 再跑一次：bare 庫（.build/repositories）的舊歷史與根 .git 的舊 blob 都叫不出來
            //    （還原一被看到就先鎖住、整理認證失效、當場重新整理；歷史乾淨＝整理完解開、指令照跑）。
            let (restWS, rest) = try await openFresh("r10d-restore")
            let bare = rest.repo + "/.build/repositories/pkg-2"
            try fm.createDirectory(atPath: bare, withIntermediateDirectories: true)
            _ = git(["init", "-q", "--bare"], cwd: bare)
            let bareTree = try dir("r10d-bare-tree")
            try (canary + "-r10d-bare\n").write(toFile: bareTree + "/.env", atomically: true, encoding: .utf8)
            _ = git(["--git-dir=" + bare, "--work-tree=" + bareTree, "add", "-A"], cwd: bareTree)
            _ = git(["--git-dir=" + bare, "--work-tree=" + bareTree, "-c", "user.name=fixture", "-c", "user.email=hands-fixture@localhost",
                     "commit", "-q", "-m", "bare"], cwd: bareTree)
            let blobFile = try dir("r10d-blob") + "/blob.txt"
            try (canary + "-r10d-dangling\n").write(toFile: blobFile, atomically: true, encoding: .utf8)
            let danglingSHA = git(["hash-object", "-w", blobFile], cwd: rest.repo).1.trimmingCharacters(in: .whitespacesAndNewlines)
            try service.workspaceStore.update(rest.record.id) { $0.secretScan = nil }
            let firstRun = await tool("run_command", ["workspace_id": restWS, "command": "echo first-run"], token: tokenD)
            let firstQuarantine = quarantines(rest.dir).first.map { rest.dir + "/" + $0 } ?? "/nonexistent"
            let restoreNote = (try? String(contentsOfFile: firstQuarantine + "/RESTORE.txt", encoding: .utf8)) ?? ""
            // 照說明還原依賴的物件庫（files/.build/repositories 搬回 repo/.build/repositories）。
            try fm.moveItem(atPath: firstQuarantine + "/files/.build/repositories", toPath: rest.repo + "/.build/repositories")
            let bareRun = await tool("run_command", ["workspace_id": restWS, "command": "git -C .build/repositories/pkg-2 log --all -p 2>&1; echo end-bare"], token: tokenD)
            let afterBare = service.workspaceStore.record(rest.record.id)
            // 照說明還原根 .git：先把目前的 .git 搬進隔離資料夾（git-current），再把 git-archive 搬回 repo/.git。
            try fm.moveItem(atPath: rest.repo + "/.git", toPath: firstQuarantine + "/git-current")
            try fm.moveItem(atPath: firstQuarantine + "/git-archive", toPath: rest.repo + "/.git")
            let restoredHasBlob = git(["cat-file", "-e", danglingSHA], cwd: rest.repo).0 == 0
            let blobRun = await tool("run_command", ["workspace_id": restWS, "command": "git cat-file -p \(danglingSHA) 2>&1; echo end-blob"], token: tokenD)
            let afterBlob = service.workspaceStore.record(rest.record.id)
            check(!firstRun.isError && restoreNote.contains("先把目前的 repo/.git 搬進這個資料夾") && restoreNote.contains("重新整理")
                  && !restoreNote.contains("照樣讀不到")
                  && bareRun.text.contains("end-bare") && !bareRun.text.contains(canary) && afterBare?.isLocked == false
                  && !fm.fileExists(atPath: rest.repo + "/.build/repositories") && restoredHasBlob
                  && blobRun.text.contains("end-blob") && !blobRun.text.contains(canary) && afterBlob?.isLocked == false
                  && afterBlob?.secretScan == HandsSecretFiles.scanVersion && quarantines(rest.dir).count >= 3,
                  "W183 R10 第四輪 遷移成功→照 RESTORE.txt 還原→再跑：bare 庫的舊歷史、根 .git 的舊 blob 都叫不出來（還原一被看到就鎖住、重新整理，整理完解開）；還原說明照實寫（先封存目前的 .git、還原後會重新整理）",
                  "bare=\(bareRun.text.prefix(160)) blob=\(blobRun.text.prefix(160)) locked=\(String(describing: afterBlob?.lockReason)) q=\(quarantines(rest.dir).count)")

            // 2. 使用者的 Git 工作不被重建洗掉：只存在 index 的工作（只有暫存、部分暫存、衝突）＝暫停整理、鎖住、一句話說明；index 原樣留著。
            func pauseCase(_ title: String, _ prepare: (String) throws -> Void) async throws -> (paused: Bool, text: String, id: UUID, repo: String, dir: String) {
                let (ws, snap) = try await openFresh(title)
                try prepare(snap.repo)
                try service.workspaceStore.update(snap.record.id) { $0.secretScan = nil }
                let before = quarantines(snap.dir).count
                let listed = await tool("list_dir", ["workspace_id": ws, "path": ""], token: tokenD)
                let record = service.workspaceStore.record(snap.record.id)
                let paused = listed.isError && listed.text.contains(HandsService.migrationPausedReason)
                    && record?.lockReason == HandsService.migrationPausedReason && record?.secretScan != HandsSecretFiles.scanVersion
                    && quarantines(snap.dir).count == before && fm.fileExists(atPath: snap.repo + "/.git/index")
                return (paused, listed.text, snap.record.id, snap.repo, snap.dir)
            }
            let readme = "README.md"
            let stagedOnly = try await pauseCase("r10d-staged") { repo in
                let headVersion = git(["show", "HEAD:" + readme], cwd: repo).1
                try "staged version B\n".write(toFile: repo + "/" + readme, atomically: true, encoding: .utf8)
                _ = git(["add", readme], cwd: repo)
                try headVersion.write(toFile: repo + "/" + readme, atomically: true, encoding: .utf8)   // 工作樹改回 HEAD 的版本：B 只剩在 index
            }
            let stagedKept = git(["diff", "--cached", "--name-only"], cwd: stagedOnly.repo).1.contains(readme)
            let partial = try await pauseCase("r10d-partial") { repo in
                try "staged part\n".write(toFile: repo + "/" + readme, atomically: true, encoding: .utf8)
                _ = git(["add", readme], cwd: repo)
                try "staged part\nand an unstaged line\n".write(toFile: repo + "/" + readme, atomically: true, encoding: .utf8)
            }
            let partialKept = git(["diff", "--cached", "--name-only"], cwd: partial.repo).1.contains(readme)
                && git(["diff", "--name-only"], cwd: partial.repo).1.contains(readme)
            let conflict = try await pauseCase("r10d-conflict") { repo in
                let branch = git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: repo).1.trimmingCharacters(in: .whitespacesAndNewlines)
                _ = git(["checkout", "-q", "-b", "r10d-side"], cwd: repo)
                try "side change\n".write(toFile: repo + "/" + readme, atomically: true, encoding: .utf8)
                _ = git(["add", readme], cwd: repo)
                commit("side", cwd: repo)
                _ = git(["checkout", "-q", branch], cwd: repo)
                try "main change\n".write(toFile: repo + "/" + readme, atomically: true, encoding: .utf8)
                _ = git(["add", readme], cwd: repo)
                commit("main", cwd: repo)
                _ = git(["merge", "-q", "r10d-side"], cwd: repo)   // 衝突：留下 MERGE_HEAD 與 unmerged 的 index
            }
            let conflictKept = !git(["ls-files", "-u"], cwd: conflict.repo).1.isEmpty
            // 使用者處理完（這裡：取消暫存）＝下一次用到照常整理、解開。
            _ = git(["reset", "-q"], cwd: stagedOnly.repo)
            let resumed = await tool("list_dir", ["workspace_id": stagedOnly.id.uuidString, "path": ""], token: tokenD)
            let resumedRecord = service.workspaceStore.record(stagedOnly.id)
            check(stagedOnly.paused && stagedKept && partial.paused && partialKept && conflict.paused && conflictKept
                  && stagedOnly.text.contains("staged changes") && conflict.text.contains("merge in progress")
                  && !resumed.isError && resumedRecord?.isLocked == false && resumedRecord?.secretScan == HandsSecretFiles.scanVersion,
                  "W183 R10 第四輪 使用者的 Git 工作不被重建洗掉：只有暫存、部分暫存、衝突（merge 進行中）＝暫停整理、鎖住、工具回一句說明，index 原樣留著；處理完下一次照常整理、解開",
                  "staged=\(stagedOnly.paused)/\(stagedKept) partial=\(partial.paused)/\(partialKept) conflict=\(conflict.paused)/\(conflictKept) resumed=\(resumed.text.prefix(120))")

            // 3. 清單修訂與交件同一個序列：交件在鎖裡做完最後一次檢查之後、update-ref 之前（barrier）改名成交易類——這個修訂排在交件後面，
            //    交件做完之前不生效（不會在修訂生效之後才發布候選）；交件做完它才生效（之後的寫入被擋）。
            let (subWS, subSnap) = try await openFresh("r10d-submit")
            _ = await tool("write_file", ["workspace_id": subWS, "path": "r10d-note.txt", "content": "r10d\n", "create_only": true], token: tokenD)
            let records = service.allProjectRecords()
            let listBox = Box(records)
            service.projectsOverride = { listBox.get() }
            _ = await Task.detached { service.refreshTradingClassification() }.value
            let finalEntered = Box(false), finalArmed = Box(true)
            let finalRelease = DispatchSemaphore(value: 0)
            service.submitFinalGate = {
                var take = false
                finalArmed.update { if $0 { $0 = false; take = true } }
                guard take else { return }
                finalEntered.update { $0 = true }
                finalRelease.wait()
            }
            async let submitted = tool("submit_workspace", ["workspace_id": subWS, "summary": "r10d final barrier"], token: tokenD)
            let finalGated = await until(15) { finalEntered.get() }
            listBox.update { list in list = list.map { $0.0 == projectID ? ($0.0, "BTC 實盤 in final", $0.2) : $0 } }
            let renameDone = Box(false)
            let renamer = Thread { _ = service.refreshTradingClassification(); renameDone.update { $0 = true } }
            renamer.start()
            try await Task.sleep(nanoseconds: 400_000_000)
            let waitedDuringFinal = !renameDone.get() && !service.classificationPending && !service.isTradingCached(projectID)
            finalRelease.signal()
            let submitResult = await submitted
            service.submitFinalGate = nil
            let renameApplied = await until(8) { renameDone.get() && service.isTradingCached(projectID) }
            let candidateRef = "refs/heads/tatwo2-room-" + subWS.prefix(8)
            let published = git(["rev-parse", "--verify", "-q", candidateRef], cwd: project).0 == 0
            let laterWrite = await tool("write_file", ["workspace_id": subWS, "path": "after.txt", "content": "x\n", "create_only": true], token: tokenD)
            check(finalGated && waitedDuringFinal && !submitResult.isError && published && renameApplied && laterWrite.isError
                  && laterWrite.text.contains("project_read_only") && !fm.fileExists(atPath: subSnap.repo + "/after.txt"),
                  "W183 R10 第四輪 清單修訂與交件同一個序列：鎖裡最後檢查之後、update-ref 之前改名＝修訂排在交件後面（交件做完之前不生效，不會在修訂生效之後才發布候選）；做完才生效，之後的寫入被擋",
                  "gated=\(finalGated) waited=\(waitedDuringFinal) submit=\(submitResult.text.prefix(120)) published=\(published) applied=\(renameApplied)")
            listBox.update { $0 = records }
            service.projectsOverride = nil
            _ = await Task.detached { service.refreshTradingClassification() }.value
        }
        try await r10TradingFloor()
        try await r10Round2Floors()
        try await r10Round3Floors()
        try await r10Round4Floors()
        try await r1bTail()

        // ---------- 收尾 ----------
        OSSocketCaller.unregisterExternalAI()
        HandsSandbox.terminateAll()
        print("W183HANDS SUMMARY passed=\(passed) failures=\(failed)")
        if failed == 0 { print("W183HANDS ALL PASS") }
        return failed == 0
    }
}
#endif
