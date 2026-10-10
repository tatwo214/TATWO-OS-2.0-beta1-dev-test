import AppKit
import Foundation
import CoreFoundation
import Darwin
import os

/// App-local OS 派工橋（ultrawork 2.0 第 2 步）。跟 BrowserAgentBridge 同款寫法：0600 UNIX socket，
/// 只轉房間／討論串中繼資料（標題、引擎、活性、worktree 路徑），不帶任何密鑰。
final class OSAgentBridge: @unchecked Sendable {
    static let shared = OSAgentBridge()
    private let documentQueue = DispatchQueue(label: "tatwo2.bridge.document", qos: .utility)

    static func pullThreadFiles(threadID: UUID, artifactsRoot: URL, workdir: String) throws -> [RemoteThreadTransferFile] {
        let candidates = try RemoteThreadTransfer.candidates(
            threadID: threadID, artifactsRoot: artifactsRoot, workdir: workdir)
        let selected = candidates.filter(\.automatic)
        let paths = selected.map(\.path)
        guard !paths.isEmpty else { return [] }
        let baselines = try RemoteThreadTransfer.sourceBaselines(in: workdir, paths: paths)
        let observed = Dictionary(uniqueKeysWithValues: selected.compactMap { row in
            row.observedSHA256.map { (row.path, $0) }
        })
        return try RemoteThreadTransfer.changedFiles(
            in: workdir, paths: paths, baselines: baselines, observedHashes: observed)
    }

    #if DEBUG
    // Inject only storage/dispatch dependencies; the production handle and caller checks still run.
    static func fleetFixtureBridge() -> OSAgentBridge { OSAgentBridge() }
    private var fleetTestDispatch: DeviceDispatch?
    private var fleetTestMemory: TatwoMemorySyncEngine?
    /// Replace only the model process launch after production permission/creator/parameter checks.
    static var fixtureJSON: (() -> Void)?
    var fixtureSend: ((UUID, String) -> Void)?
    func fixtureMemory(_ engine: TatwoMemorySyncEngine) { fleetTestMemory = engine }
    private final class FixtureResponse: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func put(_ data: Data) { lock.withLock { bytes = data } }
        func get() -> Data { lock.withLock { bytes } }
    }
    @MainActor func fixtureModel(_ model: ChatPageModel) { self.model = model }
    func fixtureHandle(dispatch: DeviceDispatch, method: String, params: [String: Any],
                       handshake: [String: Any]? = nil, fingerprint: String? = nil, caller: OSSocketCaller = .ssh) throws -> [String: Any] {
        fleetTestDispatch = dispatch
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw BridgeError.invalidParams }
        defer { close(pair[1]) }
        var request: [String: Any] = ["id": "fixture", "method": method, "params": params]
        if let handshake { request["deviceHandshake"] = handshake }
        let input = try JSONSerialization.data(withJSONObject: request)
        // A handoff response can exceed the socket buffer. Drain concurrently like a real client;
        // sequential write-then-read fixtures deadlock before testing the production checkpoint.
        let response = FixtureResponse(), complete = DispatchSemaphore(value: 0)
        let reader = FileHandle(fileDescriptor: pair[1], closeOnDealloc: false)
        DispatchQueue.global().async {
            response.put(reader.readDataToEndOfFile()); complete.signal()
        }
        handle(clientFD: pair[0], input: input, caller: caller, sshFingerprint: fingerprint,
               acceptedAt: ProcessInfo.processInfo.systemUptime, release: {})
        guard complete.wait(timeout: .now() + 60) == .success else { throw BridgeError.invalidParams }
        let result = response.get()
        return try JSONSerialization.jsonObject(with: result) as! [String: Any]
    }
    #endif
    private var requestDispatch: DeviceDispatch {
        #if DEBUG
        if let fleetTestDispatch { return fleetTestDispatch }
        #endif
        return DeviceDispatch.shared
    }
    private weak var model: ChatPageModel?
    private var botTestLibrary: BotLibrary?
    // In-process test fixture only; does not expose an environment-enabled confirmation bypass.
    func startBotCoreTest(library: BotLibrary) {
        botTestLibrary = library
        queue.async { [weak self] in self?.listen() }
    }
    /// W178 安全自測：在 TATWO2_OS_SOCKET 開真的 listener（不接 model），給測試從外部行程連進來驗呼叫者檢查。
    func startSecurityTestListener() {
        queue.async { [weak self] in self?.listen() }
    }
    /// Owned real-library acceptance seam; does not start or replace a socket.
    static func botCoreTestBridge(library: BotLibrary) -> OSAgentBridge {
        let bridge = OSAgentBridge()
        bridge.botTestLibrary = library
        return bridge
    }
    // App-only entrypoints. perform(method:) intentionally has no matching MCP cases.
    @MainActor func confirmBotMemory(botID: String, pendingID: String) async throws {
        guard let library = model?.botLibraryForBridge else { throw BotLibraryError.invalid("bot_library_unavailable") }
        try await BotMemory(library: library).confirm(botID: botID, pendingID: pendingID)
    }
    @MainActor func rejectBotMemory(botID: String, pendingID: String) async throws {
        guard let library = model?.botLibraryForBridge else { throw BotLibraryError.invalid("bot_library_unavailable") }
        try await BotMemory(library: library).reject(botID: botID, pendingID: pendingID)
    }
    @MainActor func forgetBotMemory(botID: String, memoryID: String) async throws {
        guard let library = model?.botLibraryForBridge else { throw BotLibraryError.invalid("bot_library_unavailable") }
        try await BotMemory(library: library).forget(botID: botID, memoryID: memoryID)
    }
    private func awaitBot<T>(_ operation: @escaping () async throws -> T) throws -> T {
        precondition(!Thread.isMainThread)
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?
        Task.detached { do { result = .success(try await operation()) } catch { result = .failure(error) }; semaphore.signal() }
        semaphore.wait()
        return try result!.get()
    }

    private let queue = DispatchQueue(label: "ai.tatwo.tatwo2.os-agent", qos: .userInitiated)
    // W178：接連線的迴圈不再自己讀請求。每條連線在 reader 佇列限時限量讀完，再排進 handler 佇列一次處理一個，
    // 一個不送完也不關的連線卡不住其他呼叫。
    private let readerQueue = DispatchQueue(label: "ai.tatwo.tatwo2.os-agent.reader", qos: .userInitiated, attributes: .concurrent)
    private let handlerQueue = DispatchQueue(label: "ai.tatwo.tatwo2.os-agent.handler", qos: .userInitiated)
    // 一條連線從讀、排隊、處理到寫回都占一格；滿了就回 busy，排隊的請求與 FD 不會無限累積。
    private let connectionSlots = DispatchSemaphore(value: 16)
    private let computerQueue = DispatchQueue(label: "ai.tatwo.tatwo2.computer", qos: .userInitiated, attributes: .concurrent)
    private let computerSlots = DispatchSemaphore(value: 2)
    private let stateLock = NSLock()
    private var listenerFD: Int32 = -1
    private var listenerStarting = false
    var isListening: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return listenerFD >= 0
    }
    private var chatGPTDispatcher: ChatGPTDispatch?
    private let chatGPTDispatchQueue = DispatchQueue(label: "ai.tatwo.tatwo2.chatgpt-dispatch", qos: .userInitiated, attributes: .concurrent)
    private var backgroundJobs: BackgroundJobManager?
    private var jobsTestThreads: Set<UUID> = []
    private var jobsTestArtifacts: TurnArtifacts?

    /// In-process acceptance seam only; never starts a socket or launches an engine.
    static func jobsTestBridge(manager: BackgroundJobManager, artifacts: TurnArtifacts, threads: Set<UUID>) -> OSAgentBridge {
        let bridge = OSAgentBridge()
        bridge.backgroundJobs = manager
        bridge.jobsTestArtifacts = artifacts
        bridge.jobsTestThreads = threads
        return bridge
    }

    private func jobsCaller(_ params: [String: Any], bound: UUID? = nil, allowSelected: Bool = true) throws -> (id: UUID, source: String) {
        let id: UUID
        let source: String
        if let raw = params["callerThreadID"] {
            guard let text = raw as? String, let parsed = UUID(uuidString: text) else { throw BridgeError.invalidParams }
            id = parsed; source = "caller"
        } else if let bound {
            // W178：綁定對話的引擎沒帶就用它自己的對話，不退回「目前選中的對話」。
            id = bound; source = "caller"
        } else {
            if !allowSelected || jobsTestArtifacts != nil { throw BridgeError.noParentThread }
            guard let selected = onMain({ [weak self] in self?.model?.selectedThreadID }) else { throw BridgeError.noParentThread }
            id = selected; source = "selected"
        }
        if jobsTestThreads.contains(id) { return (id, source) }
        let exists = onMain { [weak self] in self?.model?.live?.threadRecord(id) != nil }
        guard exists else { throw BridgeError.invalidParams }
        return (id, source)
    }

    /// Only expose the existing manager; Island must never create one.
    @MainActor func backgroundJobSnapshot(includeLastLine: Bool = true) async -> [BackgroundJobManager.Snapshot] {
        guard let manager = backgroundJobs else { return [] }
        return await manager.snapshot(includeLastLine: includeLastLine)
    }

    private init() {}

    /// W178：本機 socket 認人用的程序根——每個 sidecar 屬於哪條對話、每個背景工作屬於哪條對話。
    private func installProcessRoots() {
        OSSocketCaller.rootsProvider = { [weak self] in
            guard let self else { return [:] }
            var roots: [pid_t: OSSocketCaller.RootEntry] = [:]
            let engines: [pid_t: (thread: UUID, startTime: UInt64)] = self.onMain { [weak self] in
                self?.model?.live?.sidecarProcessOwners() ?? [:]
            }
            for (pid, owner) in engines { roots[pid] = .init(root: .engine(owner.thread), startTime: owner.startTime) }
            for (pid, owner) in self.backgroundJobs?.runningProcessOwners() ?? [:] {
                roots[pid] = .init(root: .job(owner.thread), startTime: owner.startTime)
            }
            return roots
        }
    }

    @MainActor func configureCallerTest(model: ChatPageModel, manager: BackgroundJobManager) {
        self.model = model
        installProcessRoots()
        ComputerUseController.shared.consentPolicyProvider = { [weak model] caller in
            guard let model, let thread = model.live?.threadRecord(caller) else { return .askOncePerSession }
            return .resolve(user: model.permissionPreset, bot: thread.botPermissionPreset,
                            readOnly: thread.roomReadOnly == true)
        }
        self.backgroundJobs = manager
    }

    var socketPath: String { Self.resolveSocketPath() }

    /// 這個 App 實際使用的 OS 橋位址（給 sidecar 傳進 MCP 子程序，MCP 才不會退回正式預設路徑）。
    static func resolveSocketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["TATWO2_OS_SOCKET"], !override.isEmpty {
            return override
        }
        if let root = environment["TATWO2_LIVE_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent("os.sock").path
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/tatwo2/live/os.sock").path
    }

    @MainActor
    func start(model: ChatPageModel) {
        self.model = model
        OSDocuments.secondaryWriter = { id, text, base in
            try DeviceInbox.shared.enqueue(id: id, text: text, base: base)
        }
        DeviceDispatch.shared.start()
        // W160：主設備啟動時先把 agents.md 對齊憲法；存檔提交後推到使用者自己的私人 GitHub（有同意才推）。
        Task.detached { _ = try? AgentsFile.refresh(role: try? DeviceDispatch.shared.identity().role) }
        OSDocuments.afterCommit = { Task { @MainActor in EntryBackup.shared.pushIfEnabled() } }
        DeviceStatusReader.engineStatus = {
            EngineLinks.scan().map { DeviceStatusEngine(id: $0.id, name: $0.name, state: "\($0.state)") }
        }
        EntryBackup.shared.pushIfEnabled()
        HandsService.shared.attach(model: model)   // W183 R1：ChatGPT 手腳用這台的 Coder 資料
        _ = HandsState.shared                       // W183 R1：配對碼要先有畫面狀態接著
        installProcessRoots()
        ComputerUseController.shared.consentPolicyProvider = { [weak model] caller in
            guard let model, let thread = model.live?.threadRecord(caller) else { return .askOncePerSession }
            return .resolve(user: model.permissionPreset, bot: thread.botPermissionPreset,
                            readOnly: thread.roomReadOnly == true)
        }
        if backgroundJobs == nil {
            let manager = BackgroundJobManager()
            manager.onCompletion = { [weak self] job in
                self?.model?.receiveLocalBackgroundCompletion(job)
            }
            backgroundJobs = manager
        }
        stateLock.lock()
        let alreadyStarted = listenerStarting || listenerFD >= 0
        if !alreadyStarted { listenerStarting = true }
        stateLock.unlock()
        guard !alreadyStarted else { return }
        queue.async { [weak self] in self?.listen() }
    }

    private func listen() {
        defer {
            stateLock.lock()
            listenerStarting = false
            stateLock.unlock()
        }
        let path = socketPath
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        do {
            try HandsFiles.ensureDirectory(directory)
        } catch {
            fputs("os_agent_bridge_error=create_directory_failed\n", stderr)
            return
        }
        _ = unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            fputs("os_agent_bridge_error=socket_failed\n", stderr)
            return
        }
        // PTYs must not inherit bridge listeners across exec.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: address.sun_path)
        let copied = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                strlcpy(destination, source, sunPathSize)
            }
        }
        guard copied < sunPathSize else {
            close(fd)
            fputs("os_agent_bridge_error=socket_path_too_long\n", stderr)
            return
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            close(fd)
            _ = unlink(path)
            fputs("os_agent_bridge_error=bind_or_listen_failed\n", stderr)
            return
        }
        guard chmod(path, S_IRUSR | S_IWUSR) == 0 else { close(fd); _ = unlink(path); return }
        stateLock.lock(); listenerFD = fd; stateLock.unlock()
        fputs("os_agent_bridge_socket=\(path)\n", stderr)
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            autoreleasepool { acceptClient(client) }
        }
    }

    private func acceptClient(_ client: Int32) {
            // cli_open may fork before this request returns; otherwise Node waits for the shell to close its inherited socket.
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            // 客戶端提早斷線時，寫回應不可以讓整個 App 吃 SIGPIPE 死掉（實機驗收 2026-09-04 踩到）
            var on: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var receiveTimeout = timeval(tv_sec: 10, tv_usec: 0)
            var sendTimeout = timeval(tv_sec: 30, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
            // 連線當下就認人：之後對方換掉或結束也不影響這次判斷。
            let acceptedAt = ProcessInfo.processInfo.systemUptime
            let caller = OSSocketCaller.classify(fd: client)
            let sshFingerprint = OSSocketCaller.sshFingerprint(fd: client, caller: caller)
            guard connectionSlots.wait(timeout: .now()) == .success else {
                let busy = FileHandle(fileDescriptor: client, closeOnDealloc: true)
                write(["id": NSNull(), "ok": false, "error": "os_bridge_busy"], to: busy)
                return
            }
            let release: @Sendable () -> Void = { [connectionSlots] in connectionSlots.signal() }
            readerQueue.async { [self] in
                let input = Self.readRequest(client)
                handlerQueue.async { [self] in
                    autoreleasepool {
                        handle(clientFD: client, input: input, caller: caller, sshFingerprint: sshFingerprint,
                               acceptedAt: acceptedAt, release: release)
                    }
                }
            }
    }

    /// 只讀第一行（請求只用第一行）；送完關寫端的舊客戶端照樣相容。每次讀最多等 10 秒、整體 30 秒、上限 16 MB。
    static func readRequest(_ fd: Int32, limit: Int = 16 * 1024 * 1024, deadline seconds: TimeInterval = 30) -> Data? {
        var input = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            // 每次最多等 10 秒，也不超過剩下的整體期限。
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            var timeout = timeval(tv_sec: Int(min(10, max(1, remaining.rounded(.up)))), tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let count = recv(fd, &chunk, chunk.count, 0)
            if count > 0 {
                input.append(contentsOf: chunk.prefix(count))
                if let newline = input.firstIndex(of: 0x0A) {
                    return newline <= limit ? input.prefix(upTo: newline) : nil
                }
                if input.count > limit { return nil }
                continue
            }
            if count == 0 { return input }
            if errno == EINTR { continue }
            return nil
        }
        return nil
    }

    /// W178：不是 TATWO OS 自己人（見 OSSocketCaller）也能用的方法——只回狀態、只成為待核准的提案，
    /// 或本來就要設備簽章。其餘會讀對話、送訊息、操作電腦、讓 App 結束的方法一律要自己人。
    /// These handlers always call DeviceDispatch.authenticate before using their payload.
    static let signedDeviceMethods: Set<String> = ["dispatch_fetch", "dispatch_ack", "document_propose",
        "document_inspect", "inbox_target", "inbox_receive", "memory_propose", "memory_list", "memory_decide",
        "memory_sync_target", "memory_sync_receive", "memory_sync_export", "memory_sync_import", "remote_hands_status", "remote_hands_action", "hands_build",
        "job_submit", "job_status"]

    /// Each socket handles one request. Its first frame is the signed handshake for that exact method/payload.
    /// Never infer a key from --device, a UUID, or a cached SSH tunnel.
    private func authenticateSSHRequest(method: String, params: [String: Any], handshake: [String: Any]?,
                                        fingerprint: String?) throws -> (params: [String: Any], fingerprint: String?) {
        if let handshake {
            let (_, payload) = try requestDispatch.authenticate(method: method, proof: handshake)
            guard let publicKey = handshake["publicKey"] as? String else { throw BridgeError.invalidParams }
            let verified = try DeviceRegistry.fingerprint(publicKey: publicKey)
            guard fingerprint == nil || fingerprint == verified else { throw BridgeError.invalidParams }
            // v2 signs a canonical parameter digest so a large frame is transmitted once.
            if payload["handshakeVersion"] as? Int == 2 {
                guard Set(payload.keys) == ["handshakeVersion", "paramsSHA256"],
                      let digest = payload["paramsSHA256"] as? String,
                      digest == DeviceDispatch.hash(try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])) else {
                    throw BridgeError.invalidParams
                }
                return (params, verified)
            }
            // Existing full-payload proofs remain compatible; dispatch only signed parameters.
            return (payload, verified)
        }
        if !Self.signedDeviceMethods.contains(method) { throw DeviceFleetError.capabilityDenied }
        return (params, fingerprint)
    }

    static let untrustedCallerMethods: Set<String> = [
        "device_status", "dispatch_wake", "user_remember",
        "dispatch_fetch", "dispatch_ack", "document_propose", "document_inspect", "inbox_target", "inbox_receive",
        "memory_propose", "memory_list", "memory_decide",
        "memory_sync_target", "memory_sync_receive", "memory_sync_export", "memory_sync_import", // W180 E1b：記憶自動同步，一樣要設備簽章
        "remote_hands_status", "remote_hands_action", // W183 R3：副設備看主機的 ChatGPT 手腳、遠端開始配對／撤銷，一樣要設備簽章
    ]

    /// 隔離的 staging 實例（乾淨安裝閘門、測試）裡沒有使用者的真資料：外部程式可以讀這幾個唯讀方法來驗空狀態。
    /// 會操作電腦、執行指令、送訊息的方法在 staging 也一樣擋（同一個簽章的 App 帶著系統權限）。
    static let stagingReadOnlyMethods: Set<String> = ["list_devices", "get_document", "bot_list", "os_binding_status"]

    /// 系統 sshd 轉進來（已配對設備遙控、派發）只能用遙控畫面實際會用到的方法；電腦操作、終端機、背景指令、
    /// 讓 App 結束一律不給——SSH 金鑰只證明是能登入這台的人，不代表要借 App 的系統權限。
    static let sshForwardMethods: Set<String> = [
        "get_document", "transcript", "new_thread", "send_message", "send_message_with_options", "stop_thread",
        "push_thread", "pull_thread", "list_rooms", "stop_room", "stop_all_rooms", "background_list",
        "background_status", "artifacts_list", "os_binding_status", "bot_list", "bot_pending_list", "whoami",
        "list_devices", "select_thread",
        // W180 E2：已配對設備讀全域狀態摘要（唯讀、只回白名單欄位；原本兩個狀態工具仍不給）
        "overview_snapshot",
        // W180 E4：/蒸餾 畫布（只碰指定那條的蒸餾畫布；寫入在這台跑、這台再檢查一次）。
        "distill_open", "distill_get", "distill_edit", "distill_write",
        // W180 E3b：副設備只能拿提案 id 核准／不要／復原（主設備自己照提案搬）；助理的兩個分類工具不給
        "project_proposal_decide",
        // W182 R5：副設備離線時那段助理問答，連回後補在這台助理那條最後（只收文字與時間、不觸發引擎、只寫助理那條）
        "assistant_append_offline",
    ]

    static func allowsUntrustedCaller(method: String, params: [String: Any], staging: Bool = false) -> Bool {
        if untrustedCallerMethods.contains(method) { return true }
        if staging && stagingReadOnlyMethods.contains(method) { return true }
        // 施工工作：帶設備簽章的才算（DeviceDispatch.authenticate 驗章）；沒簽章的本機呼叫會轉發給主設備，只給自己人。
        if method == "job_submit" || method == "job_status" {
            return params["signature"] is String && params["body"] is String
        }
        return false
    }

    static func allows(caller: OSSocketCaller, method: String, params: [String: Any], staging: Bool) -> Bool {
        if method == "sandbox_dispatch" { switch caller { case .app, .engine: return true; default: return false } }
        if ChatGPTDispatch.methods.contains(method) { return ChatGPTDispatch.allows(caller) }
        // W183 R1：ChatGPT 手腳的關口只准 HandsContract.externalAIMethods（不退回任何既有清單）；
        // 這三個方法也只給它——App 自己、引擎、背景工作、SSH 都不能拿來繞過 token 與開關。
        if case .externalAI = caller { return HandsContract.externalAIMethods.contains(method) }
        if HandsContract.externalAIMethods.contains(method) { return false }
        // W183 R3：ChatGPT 手腳的標準設定流程只給 App 與這台的引擎（不給外部 AI、SSH、背景指令、其他程式）。
        if HandsSetupTool.methods.contains(method) { return HandsSetupTool.allows(caller) }
        // W183 R8c（T12 改寫）：ChatGPT build 的設定與信箱只給已配對設備（SSH 轉進來＋設備簽章）；這台自己的 AI 引擎、背景工作、外部 AI 一律不能改。
        if method == HandsBuildRemote.method { return caller == .ssh }
        // W180 E4：/蒸餾 畫布只給已配對設備（SSH 轉進來）；這台自己的 AI 引擎、背景工作不能替人按「確認寫入」。
        if DistillRemoteRequest.methods.contains(method) { return caller == .ssh }
        // W182 R5：補回助理那條也只給已配對設備；這台自己的 AI 引擎、背景工作不能往助理那條塞字。
        if method == AssistantOfflineWire.method { return caller == .ssh }
        if AssistantFleetTools.methods.contains(method) { return AssistantFleetTools.allows(caller) }
        switch caller {
        case .app, .engine, .job, .helper:
            return true
        case .ssh:
            return sshForwardMethods.contains(method) || allowsUntrustedCaller(method: method, params: params, staging: staging)
        case .other:
            return allowsUntrustedCaller(method: method, params: params, staging: staging)
        case .externalAI:
            return false   // 上面已處理；這裡只為了列舉完整
        }
    }

    /// 只有隔離根在暫存目錄（/private/tmp、/private/var/folders）而且整組隔離設定有效，才算 staging 實例；
    /// 正式 App 就算被帶了 staging 變數冷啟動，只要根目錄不在暫存區，這四個唯讀方法照樣不對外。
    private static let isStagingInstance: Bool = {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment),
              NativeStagingIsolation.validationError(environment) == nil,
              let root = environment["TATWO_STAGING_ROOT"] else { return false }
        // 用 realpath 取真實路徑（Foundation 的 resolvingSymlinksInPath 會把 /private 拿掉）。
        guard let pointer = realpath(root, nil) else { return false }
        defer { free(pointer) }
        let resolved = String(cString: pointer)
        return resolved.hasPrefix("/private/tmp/") || resolved.hasPrefix("/private/var/folders/")
    }()

    private func handle(clientFD: Int32, input: Data?, caller: OSSocketCaller, sshFingerprint: String?,
                        acceptedAt: TimeInterval,
                        release: @escaping @Sendable () -> Void) {
        var releaseOnReturn = true
        defer { if releaseOnReturn { release() } }
        let handle = FileHandle(fileDescriptor: clientFD, closeOnDealloc: true)
        guard let input else {
            write(["id": NSNull(), "ok": false, "error": "request_incomplete_or_too_large"], to: handle)
            return
        }
        guard let line = String(data: input, encoding: .utf8)?
            .split(whereSeparator: \.isNewline).first,
              let data = String(line).data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            write(["id": NSNull(), "ok": false, "error": "bad_request"], to: handle)
            return
        }
        // 回應會原樣帶回 id：只收短字串、數字或 null，免得一個超大 id 把回寫卡住。
        let rawID = request["id"] ?? NSNull()
        let id: Any
        if rawID is NSNull || rawID is NSNumber || (rawID as? String).map({ $0.utf8.count <= 256 }) == true {
            id = rawID
        } else {
            write(["id": NSNull(), "ok": false, "error": "bad_request_id"], to: handle)
            return
        }
        guard let method = request["method"] as? String else {
            write(["id": id, "ok": false, "error": "missing_method"], to: handle)
            return
        }
        var params = request["params"] as? [String: Any] ?? [:]
        var verifiedFingerprint = sshFingerprint
        if caller == .ssh {
            do {
                let bound = try authenticateSSHRequest(method: method, params: params,
                    handshake: request["deviceHandshake"] as? [String: Any], fingerprint: sshFingerprint)
                params = bound.params; verifiedFingerprint = bound.fingerprint
                if let verifiedFingerprint,
                   !OSSocketCaller.sshMethodAllowed(fingerprint: verifiedFingerprint, method: method, registry: requestDispatch.registry) {
                    throw DeviceFleetError.capabilityDenied
                }
                // Missing fingerprint has no SSH authority. Only the explicitly signed handlers may proceed.
                if verifiedFingerprint == nil, !Self.signedDeviceMethods.contains(method) { throw DeviceFleetError.capabilityDenied }
            } catch {
                if (error as? DeviceDispatch.Failure)?.reason == "rpc_proof_expired" {
                    write(["id": id, "ok": false, "error": "rpc_proof_expired"], to: handle)
                } else { write(["id": id, "ok": false, "error": "fleet_capabilityDenied"], to: handle) }
                return
            }
        }
        guard Self.allows(caller: caller, method: method, params: params, staging: Self.isStagingInstance) else {
            write(["id": id, "ok": false, "error": "caller_not_trusted",
                   "message": "這個方法只接受 TATWO OS 裡的 AI 引擎，或經 SSH 轉進來的已配對設備"], to: handle)
            return
        }
        // W178：引擎與背景指令只能以自己那條對話的身分呼叫（連線當下就綁定，不看之後的程序家族）。
        guard Self.callerThreadMatches(bound: caller.boundThread, params: params) else {
            write(["id": id, "ok": false, "error": "caller_thread_mismatch"], to: handle)
            return
        }
        if case .externalAI = caller {
            // W183 R1／R1b：外部 AI 走自己的處理線（不卡共用序列佇列），同時最多 8 個；不綁對話，thread 參數一律拿掉（授權看 grant）。
            guard handsSlots.wait(timeout: .now()) == .success else {
                write(["id": id, "ok": false, "error": "hands_busy"], to: handle)
                return
            }
            releaseOnReturn = false
            handsQueue.async { [self, handle] in
                defer { handsSlots.signal(); release() }
                var response = Self.handsResponse(method: method, params: params)
                response["id"] = id
                write(response, to: handle)
            }
            return
        }
        let context = RequestContext(
            boundThread: caller.boundThread,
            isAppOrSSH: caller == .app || caller == .ssh,
            isSSH: caller == .ssh,
            controllerFingerprint: caller == .ssh ? verifiedFingerprint : nil,
            approvalDeadline: acceptedAt + Self.approvalWindow,
            clientAlive: { ComputerUseConnection.isAlive(handle.fileDescriptor) })
        if method == "chatgpt_dispatch" {
            // Waiting for TAP must leave the shared queue available for stop and MCP callbacks.
            releaseOnReturn = false
            chatGPTDispatchQueue.async { [self, handle] in
                defer { release() }
                do {
                    let result = try perform(method: method, params: params, context: context)
                    write(["id": id, "ok": true, "result": result], to: handle)
                } catch {
                    write(["id": id, "ok": false, "error": String(describing: error)], to: handle)
                }
            }
            return
        }
        if method == "computer_stop" {
            // Revocation must not compete with capture/action slots. Caller and
            // current scope still pass through the same native validation.
            let connected: @Sendable () -> Bool = {
                ComputerUseConnection.isAlive(handle.fileDescriptor)
            }
            do {
                let result = try perform(method: method, params: params, computerConnection: connected, context: context)
                write(["id": id, "ok": true, "result": result], to: handle)
            } catch {
                write(["id": id, "ok": false, "error": DeviceFleetReason.code(error) ?? String(describing: error)], to: handle)
            }
            return
        }
        if Self.approvalMethods.contains(method) {
            // 可能要等使用者在 Island 點頭（最多 40 秒），不能佔住一次只處理一個請求的佇列。
            guard backgroundApprovalSlots.wait(timeout: .now()) == .success else {
                write(["id": id, "ok": false, "error": "background_approval_busy"], to: handle)
                return
            }
            releaseOnReturn = false
            backgroundApprovalQueue.async { [self, handle] in
                defer { backgroundApprovalSlots.signal(); release() }
                do {
                    let result = try perform(method: method, params: params, context: context)
                    write(["id": id, "ok": true, "result": result], to: handle)
                } catch {
                    write(["id": id, "ok": false, "error": DeviceFleetReason.code(error) ?? String(describing: error)], to: handle)
                }
            }
            return
        }
        if method.hasPrefix("computer_") {
            // Native consent/capture must not occupy the shared OS accept loop.
            // Bound this lane independently; local UI stop uses neither queue.
            guard computerSlots.wait(timeout: .now()) == .success else {
                write(["id": id, "ok": false, "error": "computer_busy"], to: handle)
                return
            }
            releaseOnReturn = false
            computerQueue.async { [self, handle] in
                defer { computerSlots.signal(); release() }
                let connected: @Sendable () -> Bool = {
                    ComputerUseConnection.isAlive(handle.fileDescriptor)
                }
                do {
                    let result = try perform(method: method, params: params, computerConnection: connected, context: context)
                    write(["id": id, "ok": true, "result": result], to: handle)
                } catch {
                    write(["id": id, "ok": false, "error": DeviceFleetReason.code(error) ?? String(describing: error)], to: handle)
                }
            }
            return
        }
        if method == "distill_write" {
            // W180 E4：/蒸餾 寫入可能要等 GBrain（每步最多 45 秒）：不佔一次只處理一個請求的佇列，等待中其他呼叫照常。
            guard distillSlots.wait(timeout: .now()) == .success else {
                write(["id": id, "ok": false, "error": "distill_busy"], to: handle)
                return
            }
            releaseOnReturn = false
            distillQueue.async { [self, handle] in
                defer { distillSlots.signal(); release() }
                do {
                    let result = try perform(method: method, params: params, context: context)
                    write(["id": id, "ok": true, "result": result], to: handle)
                } catch {
                    write(["id": id, "ok": false, "error": DeviceFleetReason.code(error) ?? String(describing: error)], to: handle)
                }
            }
            return
        }
        let response: [String: Any]
        do {
            response = ["id": id, "ok": true, "result": try perform(method: method, params: params, context: context)]
        } catch {
            response = ["id": id, "ok": false, "error": DeviceFleetReason.code(error) ?? String(describing: error)]
        }
        write(response, to: handle)
    }

    private func write(_ value: [String: Any], to handle: FileHandle) {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        try? handle.write(contentsOf: Data(line.utf8))
    }

    private enum BridgeError: Error, CustomStringConvertible {
        case invalidParams, noParentThread, remoteAccessDisabled, unsupportedMethod
        case backgroundCommandReadOnly, backgroundCommandDeclined, backgroundCommandNeedsApproval
        case callerThreadMismatch, cliSessionNotOwned
        case backgroundCommandApprovalExpired, backgroundCommandCallerGone
        case commandTextRejected(String)
        case sendTurnRejected(String)
        /// W179 F：副設備送給這台助理那條被拒收的原因代碼（副設備換成白話）。
        case assistantTurnRejected(String)
        var description: String {
            switch self {
            case .invalidParams: "invalid_params"
            case .noParentThread: "no_parent_thread_selected"
            case .remoteAccessDisabled: "remote_access_disabled_no_paired_devices"
            case .unsupportedMethod: "unsupported_method"
            case .backgroundCommandReadOnly: "background_command_not_allowed_read_only"
            case .backgroundCommandDeclined: "background_command_declined_by_user"
            case .backgroundCommandNeedsApproval: "background_command_needs_approval"
            case .callerThreadMismatch: "caller_thread_mismatch"
            case .cliSessionNotOwned: "cli_session_not_owned_by_caller"
            case .backgroundCommandApprovalExpired: "background_command_approval_expired"
            case .backgroundCommandCallerGone: "background_command_caller_disconnected"
            case .commandTextRejected(let reason): reason
            case .sendTurnRejected(let reason): reason
            case .assistantTurnRejected(let reason): reason
            }
        }
    }

    /// W178：背景指令不受引擎沙盒限制，所以照對話的權限決定：完整存取權直接跑、唯讀副審一律拒絕、其他每一次都先問使用者。
    enum BackgroundCommandGate: Equatable {
        case run, ask, deny

        static func resolve(user: TatwoPermissionPreset?, bot: TatwoPermissionPreset?, readOnly: Bool) -> Self {
            guard !readOnly else { return .deny }
            let effective = bot == .configFile ? user : (bot ?? user)
            return effective == .fullAccess ? .run : .ask
        }
    }

    /// 要問使用者時怎麼問。正式 App 走 Island（沒有 Island 時是對話視窗上的確認框）；只在行程內可換（測試用），沒有環境變數開關。
    /// 40 秒內沒按就當拒絕——比 OS MCP 的 45 秒逾時短，引擎一定拿得到明確結果，不會「晚按允許卻已回報失敗」。
    var backgroundCommandApprover: @Sendable (_ title: String, _ detail: String, _ timeout: TimeInterval) async -> Bool = {
        title, detail, timeout in
        await IslandNotice.shared.ask(title: title, detail: detail, allowLabel: "允許執行", timeout: timeout,
                                      fullTextRequired: true) == .allow
    }

    /// 要給使用者核准的指令文字上限：再長就看不完，請 AI 縮短或寫成腳本檔。
    static let approvalTextLimit = 2000

    /// FE0F only after a visible emoji selects its presentation; standalone selectors remain invisible.
    static func hasInvisibleCharacters(_ text: String, allowLineBreaks: Bool = false) -> Bool {
        let scalars = Array(text.unicodeScalars)
        return scalars.enumerated().contains { index, scalar in
            if allowLineBreaks && (scalar == "\n" || scalar == "\t") { return false }
            if scalar.value == 0xFE0F, index > 0, scalars[index - 1].value > 0x7F, scalars[index - 1].properties.isEmoji { return false }
            return scalar.properties.isDefaultIgnorableCodePoint || scalar.value == 0x2800 || [.control, .format, .lineSeparator, .paragraphSeparator].contains(scalar.properties.generalCategory) || (scalar.properties.isWhitespace && scalar != " ")
        }
    }

    /// 指令文字能不能拿去給人核准／送進終端機：不能含看不見或會改變顯示順序的字元（使用者看到的必須就是要執行的）；
    /// 單行（終端機分頁）連換行、Tab、ESC 這些控制字元都不行——貼上時就會被當成按鍵執行。
    static func approvalTextProblem(_ text: String, singleLine: Bool) -> String? {
        guard text.unicodeScalars.count <= approvalTextLimit else { return "command_too_long_for_approval" }
        if text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && (singleLine || ($0 != "\n" && $0 != "\t")) }) {
            return singleLine ? "cli_send_single_line_without_control_characters" : "command_has_control_characters"
        }
        return hasInvisibleCharacters(text, allowLineBreaks: !singleLine) ? "command_has_invisible_characters" : nil
    }

    /// 從接到連線起算的核准期限；比 OS MCP 的 45 秒逾時短，排隊的時間也算在內。
    static let approvalWindow: TimeInterval = 40

    /// 一次請求的呼叫者資訊：綁定的對話、核准期限、呼叫端是否還連著。
    struct RequestContext {
        var boundThread: UUID?
        var isAppOrSSH = false // Full list_devices records only for App and paired-device protocol.
        var isSSH = false
        var controllerFingerprint: String?
        var approvalDeadline: TimeInterval?
        var clientAlive: (@Sendable () -> Bool)?
    }

    /// 綁定對話的呼叫者若自帶 callerThreadID（或舊別名 _threadID），必須跟綁定的一樣。
    static func callerThreadMatches(bound: UUID?, params: [String: Any]) -> Bool {
        guard let bound else { return true }
        for key in ["callerThreadID", "_threadID"] {
            guard let supplied = params[key] else { continue }
            guard (supplied as? String).flatMap(UUID.init(uuidString:)) == bound else { return false }
        }
        return true
    }

    /// 可能要等使用者點頭、不在序列佇列上處理的方法（都是 App 代為執行指令的入口）。
    static let approvalMethods: Set<String> = ["run_background", "cli_open", "cli_send"]

    /// 照這條對話的權限決定能不能代它執行指令：完整存取權直接過、唯讀副審拒絕、其他每次問使用者。
    private func commandAccess(owner: UUID?) throws -> (gate: BackgroundCommandGate, policy: ManagedEnginePolicy?)? {
        try onMainThrowing { [weak self] in
            guard let self, let model = self.model, let live = model.live, let owner,
                  let thread = live.threadRecord(owner) else { return nil }
            if let creator = thread.controllerCreatorFingerprint {
                do {
                    let policy = try ManagedEnginePolicy.forThread(owner, creator: creator, fleet: self.requestDispatch.fleet)
                    return (thread.roomReadOnly == true ? .deny : .ask, policy)
                } catch { throw DeviceDispatch.Failure(reason: ManagedEnginePolicy.refusal(error, fleet: self.requestDispatch.fleet)) }
            }
            return (BackgroundCommandGate.resolve(user: model.permissionPreset, bot: thread.botPermissionPreset,
                                                  readOnly: thread.roomReadOnly == true), nil)
        }
    }

    /// 真正執行前的最後確認：沒過期、呼叫端還連著。
    private func ensureStillWanted(_ context: RequestContext) throws {
        if let deadline = context.approvalDeadline, ProcessInfo.processInfo.systemUptime >= deadline {
            throw BridgeError.backgroundCommandApprovalExpired
        }
        guard context.clientAlive?() ?? true else { throw BridgeError.backgroundCommandCallerGone }
    }

    /// 真正執行前（開分頁、按 Enter、開背景程序）最後一次：沒過期、呼叫端還連著、對話還在且不是唯讀；
    /// 原本完整存取權不用問、等待期間被改成要問的，這次不執行（請它重新要求，才會問使用者）。
    @discardableResult
    private func ensureExecutable(owner: UUID?, approvedUnder: BackgroundCommandGate, context: RequestContext) throws -> ManagedEnginePolicy? {
        try ensureStillWanted(context)
        guard let current = try commandAccess(owner: owner), current.gate != .deny else { throw BridgeError.backgroundCommandReadOnly }
        if approvedUnder == .run && current.gate != .run { throw BridgeError.backgroundCommandNeedsApproval }
        // 讀權限要等主執行緒；等完再看一次期限與連線。
        try ensureStillWanted(context)
        return current.policy
    }

    /// 回傳這次是在哪種權限下放行的（完整存取權直接過＝.run；使用者點了允許＝.ask）。
    @discardableResult
    /// `shown`：要給人看的各段文字（指令、位置），逐段檢查；沒給就檢查整個 detail。
    private func requireCommandApproval(owner: UUID?, title: String, detail: String,
                                        shown: [(text: String, singleLine: Bool)]? = nil,
                                        gate: BackgroundCommandGate? = nil, context: RequestContext) throws -> BackgroundCommandGate {
        guard let gate = try gate ?? commandAccess(owner: owner)?.gate else { throw BridgeError.noParentThread }
        switch gate {
        case .run:
            try ensureStillWanted(context)
            return .run
        case .deny:
            throw BridgeError.backgroundCommandReadOnly
        case .ask:
            // 使用者看到的必須就是要執行的：太長或含看不見的字元就不問，直接退回給 AI。
            for part in shown ?? [(detail, false)] {
                if let problem = Self.approvalTextProblem(part.text, singleLine: part.singleLine) {
                    throw BridgeError.commandTextRejected(problem)
                }
            }
            // 主執行緒不能卡著等人點（Island 的按鈕也在主執行緒）；os.sock 的呼叫都在背景佇列，只有自測會從主執行緒來。
            guard !Thread.isMainThread else { throw BridgeError.backgroundCommandNeedsApproval }
            let deadline = context.approvalDeadline ?? (ProcessInfo.processInfo.systemUptime + Self.approvalWindow)
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining >= 2 else { throw BridgeError.backgroundCommandApprovalExpired }
            let approver = backgroundCommandApprover
            guard try awaitBot({ await approver(title, detail, remaining) }) else { throw BridgeError.backgroundCommandDeclined }
            // 點了允許之後再確認一次：沒過期、呼叫端還連著、對話還在而且權限沒在等待期間被改成唯讀。
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw BridgeError.backgroundCommandApprovalExpired }
            guard context.clientAlive?() ?? true else { throw BridgeError.backgroundCommandCallerGone }
            guard let latest = try commandAccess(owner: owner)?.gate, latest != .deny else { throw BridgeError.backgroundCommandReadOnly }
            return .ask
        }
    }
    private let backgroundApprovalQueue = DispatchQueue(
        label: "ai.tatwo.tatwo2.os-agent.background-approval", qos: .userInitiated, attributes: .concurrent)
    private let backgroundApprovalSlots = DispatchSemaphore(value: 4)
    // W180 E4：/蒸餾 寫入的請求與背景寫入（DistillWriter 自己一次只寫一份）。
    private let distillQueue = DispatchQueue(label: "ai.tatwo.tatwo2.os-agent.distill", qos: .userInitiated, attributes: .concurrent)
    private let distillSlots = DispatchSemaphore(value: 4)
    private let distillJobQueue = DispatchQueue(label: "ai.tatwo.tatwo2.os-agent.distill-job", qos: .userInitiated, attributes: .concurrent)
    // W183 R1：ChatGPT 手腳（.externalAI）自己的處理線與同時數上限。
    private let handsQueue = DispatchQueue(label: "ai.tatwo.tatwo2.os-agent.hands", qos: .userInitiated, attributes: .concurrent)
    private let handsSlots = DispatchSemaphore(value: 8)

    /// W183 R1b：外部 AI 的請求：關口不綁對話（接口 v2 §1），thread 參數一律拿掉，交給 HandsService（授權看 grant）。
    static func handsParams(_ params: [String: Any]) -> [String: Any] {
        var resolved = params
        resolved["_threadID"] = nil
        resolved["callerThreadID"] = nil
        return resolved
    }

    /// 回傳照 fixtures/wire.json：成功 `result`；錯誤 `error: {code, message}`（工具錯誤是 result 裡的 isError）。
    static func handsResponse(method: String, params: [String: Any], service: HandsService = .shared) -> [String: Any] {
        do {
            return ["ok": true, "result": try service.handle(method: method, params: handsParams(params))]
        } catch let error as HandsWireError {
            return ["ok": false, "error": error.wire]
        } catch {
            return ["ok": false, "error": ["code": "internal_error", "message": "internal error"]]
        }
    }

    private static let ownedMethods: Set<String> = [
        "whoami", "run_background", "background_status", "stop_background", "dispatch_rooms",
        "list_rooms", "stop_room", "stop_all_rooms", "merge_reports", "reclaim_room", "cli_open", "os_binding_status",
        "background_list", "artifacts_list",
        "cli_send", "cli_tail", "cli_close",
    ]

    private func perform(method: String, params: [String: Any],
                         computerConnection: (@Sendable () -> Bool)? = nil,
                         context: RequestContext = RequestContext()) throws -> [String: Any] {
        var context = context
        if let bound = context.boundThread {
            if let creator = onMain({ [weak self] in self?.model?.localLiveForBridge?.threadRecord(bound)?.controllerCreatorFingerprint }) {
                context.controllerFingerprint = creator
                // A remotely created engine cannot escape its creator's grants through local MCP tools.
                guard try requestDispatch.fleet.methodAllowed(fingerprint: creator, method: method) else { throw DeviceFleetError.capabilityDenied }
            }
        }
        var resolved = params
        guard Self.callerThreadMatches(bound: context.boundThread, params: params) else { throw BridgeError.callerThreadMismatch }
        if Self.ownedMethods.contains(method) {
            let owner: UUID
            if let supplied = params["callerThreadID"] {
                guard let raw = supplied as? String, let id = UUID(uuidString: raw) else { throw BridgeError.invalidParams }
                owner = id
            } else if let bound = context.boundThread {
                // W178：引擎沒帶就用它綁定的對話，不退回「目前選中的對話」。
                owner = bound
            } else {
                guard !context.isSSH else { throw BridgeError.noParentThread }
                guard let selected = onMain({ [weak self] in self?.model?.selectedThreadID }) else { throw BridgeError.noParentThread }
                owner = selected
            }
            // 無頭驗收（jobs-index 的 TurnArtifacts 測試）沒有 model；那時只信 callerThreadID，不進主執行緒查對話（合併時 Fable 加：dispatchMain 下 assumeIsolated 會炸）
            if model != nil {
                guard onMain({ [weak self] in self?.model?.live?.threadRecord(owner) != nil }) else { throw BridgeError.invalidParams }
            }
            if let fingerprint = context.controllerFingerprint,
               !DeviceFleetGate.ownerFallbackSafe(registry: requestDispatch.registry, fingerprint: fingerprint) {
                guard onMain({ [weak self] in Self.controllerThread(self?.model?.localLiveForBridge?.threadRecord(owner), fingerprint: fingerprint) })
                else { throw DeviceFleetError.capabilityDenied }
            }
            resolved["callerThreadID"] = owner.uuidString
            var result = try performResolved(method: method, params: resolved, context: context)
            result["ownerSource"] = params["callerThreadID"] == nil ? "selected" : "caller"
            return result
        }
        return try performResolved(method: method, params: params, computerConnection: computerConnection, context: context)
    }

    static func controllerThread(_ record: LiveThreadRecord?, fingerprint: String) -> Bool {
        record?.controllerCreatorFingerprint == fingerprint
    }

    private func performResolved(method: String, params: [String: Any],
                                 computerConnection: (@Sendable () -> Bool)? = nil,
                                 context: RequestContext = RequestContext()) throws -> [String: Any] {
        let owner = (params["callerThreadID"] as? String).flatMap(UUID.init(uuidString:))
        if let fingerprint = context.controllerFingerprint,
           !DeviceFleetGate.ownerFallbackSafe(registry: requestDispatch.registry, fingerprint: fingerprint),
           ["send_message", "send_message_with_options", "stop_thread"].contains(method) {
            guard let raw = params["threadID"] as? String, let id = UUID(uuidString: raw),
                  onMain({ [weak self] in
                      guard let live = self?.model?.localLiveForBridge, !live.doc.isAssistantThread(id) else { return false }
                      return Self.controllerThread(live.threadRecord(id), fingerprint: fingerprint)
                  }) else { throw DeviceFleetError.capabilityDenied }
        }
        if Self.remoteMethods.contains(method) {
            let allowed = onMain { [weak self] in
                !(self?.model?.deviceRecordsForBridge() ?? []).isEmpty
            }
            guard allowed else { throw BridgeError.remoteAccessDisabled }
        }
        switch method {
        case "fleet_overview", "fleet_open_card", "fleet_propose":
            guard let bound = context.boundThread else { throw AssistantFleetTools.Failure(reason: "fleet_assistant_required") }
            return try onMainThrowing { [weak self] in
                try AssistantFleetTools.perform(method, params: params, caller: .engine(bound),
                                                assistantThread: self?.model?.assistantThreadID, present: {
                    GlobalDMStore.shared.select(.assistant)
                    GlobalDMStore.shared.openDocked()
                })
            }
        case "sandbox_dispatch":
            guard let thread = context.boundThread ?? (context.isAppOrSSH && !context.isSSH ? (params["callerThreadID"] as? String).flatMap(UUID.init(uuidString:)) : nil), let device = params["device_id"] as? String, let instruction = params["instruction"] as? String,
                  let files = params["files"] as? [String], let artifacts = params["artifacts"] as? [String] else { throw BridgeError.noParentThread }
            let lane = try onMainThrowing { [self] in
                guard let model else { throw BridgeError.noParentThread }
                return HandsService.attached(to: model).sandboxLane
            }
            return ["job_id": try lane.queue(device, thread: thread, instruction: instruction, files: files, artifacts: artifacts)]
        case "chatgpt_dispatch", "chatgpt_dispatch_stop":
            guard let caller = context.boundThread else { throw ChatGPTDispatch.Failure("caller_required") }
            guard Self.callerThreadMatches(bound: caller, params: params) else { throw BridgeError.callerThreadMismatch }
            if method == "chatgpt_dispatch_stop" {
                guard Set(params.keys).isSubset(of: ["callerThreadID"]) else { throw ChatGPTDispatch.Failure("invalid_arguments") }
                return onMain { [weak self] in self?.chatGPTDispatcher?.stop(caller: caller, releasingEarlier: true) ?? ["stopped": false, "reason": "no_active_dispatch"] }
            }
            let request = try ChatGPTDispatch.Request.parse(params)
            let input = try onMainThrowing { [self] () -> (ChatGPTDispatch, URL, UUID, TapProjectContext?) in
                guard let live = model?.localLiveForBridge, let thread = live.threadRecord(caller),
                      !thread.isArchived, thread.roomReadOnly != true,
                      ["claude", "codex"].contains(thread.engine ?? ""), thread.deviceID == nil,
                      !ChatGPTTapModelCatalog.isRouteID(thread.requestedModel ?? thread.model ?? ""),
                      let project = live.projectRecord(thread.projectID) else {
                    throw ChatGPTDispatch.Failure("local_engine_room_required")
                }
                let cwd = thread.cwdOverride ?? project.workdir
                guard !cwd.isEmpty else { throw ChatGPTDispatch.Failure("room_unavailable") }
                var destination: TapProjectContext?
                if let projectID = request.projectID {
                    guard let target = live.projectRecord(projectID), !target.workdir.isEmpty else {
                        throw ChatGPTDispatch.Failure("project_not_found")
                    }
                    destination = TapProjectContext(id: target.id, name: target.name, folder: URL(fileURLWithPath: target.workdir))
                }
                if chatGPTDispatcher == nil {
                    chatGPTDispatcher = ChatGPTDispatch(tap: ChatGPTTap.shared,
                        mapper: live.tapMapper,
                        journal: HandsService.shared.roomJournal)
                }
                live.chatGPTDispatcher = chatGPTDispatcher
                return (chatGPTDispatcher!, URL(fileURLWithPath: cwd).standardizedFileURL, project.id, destination)
            }
            let receipt = try awaitBot { await input.0.dispatch(request, caller: caller, room: input.1, projectID: input.2, destination: input.3) }
            return receipt.wire
        case "dispatch_wake":
            // Notification only; no claimed sender, epoch, or content is trusted.
            let local = try requestDispatch.identity()
            if local.role == .secondary || (local.transfer?.to == local.deviceID && local.transfer?.constitution == false) {
                requestDispatch.align(targetDeviceID: nil)
            }
            return ["scheduled": true]
        case "job_submit", "job_status":
            // W95：施工工作只是 W78 通道上多一種 payload，用同一套簽章／信任／指紋驗證（authenticate），
            // 這裡沒有第二條通道。沒有簽章證明的呼叫是本機 os.sock 呼叫：副設備轉發、主設備只准查詢。
            do {
                if params["signature"] is String, params["body"] is String {
                    let (sender, payload) = try requestDispatch.authenticate(method: method, proof: params)
                    if method == "job_submit" { return try JobQueue.shared.receive(payload, sender: sender) }
                    return try JobQueue.shared.statusResponse(payload)
                }
                return try JobQueue.shared.localCall(method: method, params: params)
            } catch let error as JobQueue.Failure where error.invalidParams {
                throw BridgeError.invalidParams
            }
        case "dispatch_fetch", "dispatch_ack", "document_propose", "document_inspect", "inbox_target", "inbox_receive",
             "memory_propose", "memory_list", "memory_decide":
            let (sender, payload) = try requestDispatch.authenticate(method: method, proof: params)
            switch method {
            case "dispatch_fetch":
                if Set(payload.keys) == ["identityOnly"], payload["identityOnly"] as? Bool == true {
                    return try DeviceDispatch.object(requestDispatch.localFleetPresence())
                }
                guard payload.isEmpty else { throw BridgeError.invalidParams }
                return try DeviceDispatch.object(requestDispatch.offer(to: sender))
            case "dispatch_ack":
                try requestDispatch.recordACK(DeviceDispatch.decode(DeviceDispatch.Receipt.self, payload), sender: sender)
                return ["recorded": true]
            case "document_propose":
                return try DeviceInbox.shared.receiveDocument(payload, sender: sender)
            case "document_inspect":
                guard let id = payload["id"] as? String else { throw BridgeError.invalidParams }
                return ["text": try requestDispatch.inbox.inspectDocument(id)]
            case "inbox_target":
                return ["repository": DeviceDispatch.shared.entry.repoRoot.path]
            // W163：任一台都能提、能看、能核准使用者記憶；主設備才寫 user.md。
            case "memory_propose":
                var proposal = try DeviceDispatch.decode(UserMemoryProposal.self, payload)
                proposal.status = "pending"; proposal.decidedAt = nil
                return ["status": try UserMemoryStore.shared.receive(proposal).rawValue]
            case "memory_list":
                return ["items": try UserMemoryStore.shared.list().items.map { try DeviceDispatch.object($0) }]
            case "memory_decide":
                guard let id = payload["id"] as? String, let accept = payload["accept"] as? Bool else { throw BridgeError.invalidParams }
                try UserMemoryStore.shared.decide(id: id, accept: accept, isPublic: payload["isPublic"] as? Bool ?? false)
                return ["decided": true]
            default:
                return try DeviceInbox.shared.receiveBranch(payload, sender: sender)
            }
        case "memory_sync_target", "memory_sync_receive", "memory_sync_export", "memory_sync_import":
            let (sender, payload) = try requestDispatch.authenticate(method: method, proof: params)
            #if DEBUG
            if let fleetTestMemory { return try fleetTestMemory.handle(method: method, payload: payload, sender: sender) }
            #endif
            return try TatwoMemorySyncEngine.shared.handle(method: method, payload: payload, sender: sender)
        #if DEBUG
        // W183 R7a 審查：自測走同一條處理路徑（認人、驗章、HandsRemote），只是驗章與主機換成測試的（handsRemoteTestBridge）；正式沒有這一條。
        case "remote_hands_status" where handsRemoteSeam != nil, "remote_hands_action" where handsRemoteSeam != nil:
            guard let seam = handsRemoteSeam else { throw BridgeError.unsupportedMethod }
            let (sender, payload) = try seam.dispatch.authenticate(method: method, proof: params)
            return try HandsRemote.handle(method: method, payload: payload, sender: sender, host: seam.host)
        #endif
        // W183 R3：副設備看主機的 ChatGPT 手腳（狀態、待配對確認卡）、遠端按「開始配對」「撤銷」——設備簽章（照 memory_propose），
        // 只回畫面要的欄位；不經 transcript／overview_snapshot／任何 AI 工具。
        case "remote_hands_status", "remote_hands_action":
            let (sender, payload) = try DeviceDispatch.shared.authenticate(method: method, proof: params)
            return try HandsRemote.handle(method: method, payload: payload, sender: sender)
        // W183 R8c：ChatGPT build 多設備——副設備同步（信封、意圖、結果、全貌）、改設定（預期版本比對）、送意圖、交結果；設備簽章。
        case "hands_build":
            let (sender, payload) = try requestDispatch.authenticate(method: method, proof: params)
            return try HandsBuildRemote.handle(payload: payload, sender: sender)
        // W183 R3：標準設定流程給 OS 內的 AI（allows 已經只給 App 與這台的引擎）。
        case "hands_setup_status", "hands_setup_step":
            return try HandsSetupTool.handle(method: method, params: params)
        case "goal_list", "goal_propose", "goal_update":
            // W170：引擎看／提議／更新這串的目標。被派出去的 sub 只能動自己那一條子目標，而且最多到「待驗收」。
            guard let caller = owner else { throw BridgeError.noParentThread }
            let parentID: UUID? = onMain { [weak self] in self?.model?.live?.threadRecord(caller)?.parentThreadID }
            let parentList = parentID.map { ThreadGoalStore.shared.list($0) }
            let roomGoal = parentList?.goals.first { $0.roomThread?.lowercased() == caller.uuidString.lowercased() }
            let (thread, actor): (UUID, ThreadGoalRules.Actor) = roomGoal != nil ? (parentID!, .sub) : (caller, .lead)
            func render(_ list: ThreadGoalList) throws -> [[String: Any]] {
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                return try JSONSerialization.jsonObject(with: encoder.encode(list.goals)) as? [[String: Any]] ?? []
            }
            switch method {
            case "goal_list":
                let list = ThreadGoalStore.shared.list(thread)
                let (done, total) = ThreadGoalRules.progress(list)
                return ["goals": try render(list), "done": done, "total": total, "yours": roomGoal?.id as Any]
            case "goal_propose":
                guard let title = params["title"] as? String else { throw BridgeError.invalidParams }
                let goal = try ThreadGoalStore.shared.update(thread) {
                    try ThreadGoalRules.add(&$0, title: title, userWords: nil, proposed: true, parent: roomGoal?.parent)
                }
                return ["id": goal.id, "hint": "已成為 AI 提議；使用者按「加入主線」後才算主線"]
            default:
                let status = (params["status"] as? String).flatMap(ThreadGoal.Status.init(rawValue:))
                let hasDetails = ["progress", "etaMinutes", "queue", "doneSteps", "branch", "device"].contains { params[$0] != nil }
                guard (params["status"] == nil || status != nil), status != nil || hasDetails else { throw BridgeError.invalidParams }
                for key in ["progress", "etaMinutes"] where params[key] != nil {
                    guard let number = params[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue.isFinite else { throw BridgeError.invalidParams }
                }
                for key in ["queue", "doneSteps"] where params[key] != nil {
                    guard params[key] is [String] else { throw BridgeError.invalidParams }
                }
                for key in ["branch", "device"] where params[key] != nil {
                    guard params[key] is String else { throw BridgeError.invalidParams }
                }
                let id = roomGoal?.id ?? (params["id"] as? Int) ?? -1
                do {
                    if let roomGoal, let requested = params["id"] as? Int, requested != roomGoal.id { throw ThreadGoalRules.Failure.subOnlyOwnGoal }
                    try ThreadGoalStore.shared.update(thread) {
                        if let status { try ThreadGoalRules.setStatus(&$0, id: id, to: status, evidence: params["evidence"] as? String, actor: actor) }
                        if hasDetails {
                            try ThreadGoalRules.updateDetails(&$0, id: id, progress: (params["progress"] as? NSNumber)?.doubleValue,
                                etaMinutes: (params["etaMinutes"] as? NSNumber)?.doubleValue, queue: params["queue"] as? [String],
                                doneSteps: params["doneSteps"] as? [String], branch: params["branch"] as? String,
                                device: params["device"] as? String, actor: actor, ownGoalID: roomGoal?.id)
                        }
                    }
                } catch let failure as ThreadGoalRules.Failure { return ["ok": false, "reason": failure.description] }
                let now = ThreadGoalStore.shared.list(thread).goals.first { $0.id == id }
                return ["ok": true, "id": id, "status": now?.status.rawValue ?? "pending"]
            }
        case "memory_search", "memory_get", "memory_save":
            // W180 E1：記憶工具（只給 App 與 OS 裡的引擎；不在三份信任清單）。讀到的記進這輪的「用了 N 條記憶」。
            // 呼叫的那條是 Bot 一律拒絕、唯讀副審不能存（origin 在主執行緒查那條對話，TatwoMemoryTools 依它擋）。
            let caller = owner ?? context.boundThread
            let origin = onMain { [weak self] in self?.model?.memoryToolOrigin(caller) }
            return try TatwoMemoryTools.perform(method: method, params: params, caller: caller, origin: origin)
        case "user_remember":
            // W163：OS 內的 AI 提一條「關於使用者」的記憶；只進提案佇列，使用者在 設定 › OS › 文件 › 記憶提案 核准才寫入。
            guard Set(params.keys).isSubset(of: ["text", "isPublic", "callerThreadID"]),
                  let text = params["text"] as? String else { throw BridgeError.invalidParams }
            let outcome = try UserMemoryStore.shared.propose(text: text, isPublic: params["isPublic"] as? Bool ?? false, source: "AI 提案")
            return ["status": outcome.rawValue, "hint": "已成為提案；使用者核准後才會寫進 user.md"]
        case "device_status":
            // No model/live access: get_document can save, even when called as a probe.
            // The only parameter is a validated object ID for read-only commit distance.
            guard Set(params.keys).isSubset(of: ["primary_commit"]) else { throw BridgeError.invalidParams }
            let primaryCommit = params["primary_commit"] as? String
            if params["primary_commit"] != nil {
                guard let primaryCommit, DeviceStatusReader.validCommit(primaryCommit) else {
                    throw BridgeError.invalidParams
                }
            }
            return try DeviceStatusReader.read(primaryCommit: primaryCommit).jsonObject()
        case "bot_list", "bot_get", "bot_state_get", "bot_state_update", "bot_remember", "bot_profile", "bot_pending_list":
            let library = botTestLibrary ?? onMain { [weak self] in self?.model?.botLibraryForBridge }
            guard let library else { throw BotLibraryError.invalid("bot_library_unavailable") }
            try awaitBot { await library.ready() }
            if method == "bot_list" {
                let bots = library.list()
                let isolated = botTestLibrary != nil || onMain { [weak self] in
                    !(self?.model?.osBindingEnvironment["TATWO2_LIVE_ROOT"] ?? "").isEmpty
                }
                return ["bots": try Self.jsonObject(bots), "scope": [
                    "instance": isolated ? "isolated" : "app",
                    "libraryRoot": library.root.standardizedFileURL.pathComponents.filter { $0 != "/" }.suffix(2).joined(separator: "/"),
                    "reason": bots.isEmpty ? "no_bots_in_library" : ""
                ]]
            }
            let callerThread = ((params["callerThreadID"] ?? params["_threadID"]) as? String).flatMap(UUID.init(uuidString:))
                ?? context.boundThread
            let boundID: String? = callerThread.flatMap { thread in
                onMain { [weak self] in self?.model?.botIDForBridge(threadID: thread) }
                    ?? library.snapshot.sessions.first(where: { $0.value.contains(where: { $0.threadID == thread.uuidString }) })?.key
            }
            let id = params["id"] as? String ?? boundID
            if method == "bot_pending_list" {
                if id == nil {
                    return ["pending": [], "scope": ["threadIsBot": false, "boundBotID": NSNull(),
                        "canProceed": false, "hint": "這條對話不是 bot；帶 id 只能查自己綁定的 bot"]]
                }
                guard let boundID, boundID == id else { throw BotLibraryError.invalid("pending_requires_own_bot") }
            }
            guard let id else { throw BotLibraryError.invalid("這條對話不是 bot") }
            guard let bot = library.bot(id: id) else { throw BotLibraryError.invalid("bot_not_found") }
            let memory = BotMemory(library: library)
            switch method {
            case "bot_get": return ["bot": try Self.jsonObject(bot), "instructions": library.snapshot.instructions[id] ?? ""]
            case "bot_pending_list":
                guard let boundID, boundID == id else { throw BotLibraryError.invalid("pending_requires_own_bot") }
                return ["pending": try Self.jsonObject(memory.pendingList(botID: id))]
            case "bot_profile": return ["profile": try Self.jsonObject(memory.profile(botID: id))]
            case "bot_state_get": return ["state": try Self.jsonObject(memory.state(botID: id) ?? BotMemoryState())]
            case "bot_remember":
                guard let text = params["text"] as? String else { throw BridgeError.invalidParams }
                let pending = try awaitBot { try await memory.remember(botID: id, text: text, threadID: callerThread?.uuidString ?? "unknown") }
                return ["pendingID": pending, "status": "pending", "message": "待使用者在 App 確認；尚未寫入長期記憶"]
            default:
                if params["currentTask"] != nil && !(params["currentTask"] is String) { throw BridgeError.invalidParams }
                if params["nextSteps"] != nil && !(params["nextSteps"] is [String]) { throw BridgeError.invalidParams }
                if params["openQuestions"] != nil && !(params["openQuestions"] is [String]) { throw BridgeError.invalidParams }
                let patch = BotMemoryStatePatch(currentTask: params["currentTask"] as? String, nextSteps: params["nextSteps"] as? [String], openQuestions: params["openQuestions"] as? [String], lastThreadID: callerThread?.uuidString)
                var baseVersion: Int?
                if let raw = params["baseVersion"] {
                    guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                          n.doubleValue >= 0, n.doubleValue < Double(Int.max),
                          n.doubleValue.rounded(.towardZero) == n.doubleValue else { throw BridgeError.invalidParams }
                    baseVersion = n.intValue
                }
                let result = try awaitBot { try await memory.updateState(botID: id, patch: patch, baseVersion: baseVersion) }
                if result.conflict { return ["conflict": true, "current": try Self.jsonObject(result.current), "yours": try Self.jsonObject(patch)] }
                return ["state": try Self.jsonObject(result.current)]
            }
        case "cli_sessions_list":
            let records = onMain { [weak self] in self?.model?.cliSessionStore?.sessions ?? [] }
            return ["sessions": try Self.jsonObject(records)]
        case "os_binding_status":
            // Read-only（Goal #7 擴充點）：只回 metadata；不回 original／diff／規則全文；沒有 write／apply。
            // 只接受 bridge 注入的 callerThreadID；使用者帶任何參數（path／target／environment…）一律拒絕。
            guard Set(params.keys).isSubset(of: ["callerThreadID"]), owner != nil else { throw BridgeError.invalidParams }
            let environment: [String: String] = try onMainThrowing { [weak self] in
                guard let model = self?.model else { throw BridgeError.invalidParams }
                return model.osBindingEnvironment   // 只在主執行緒抓 env；讀檔在 bridge queue
            }
            let preview = OSUpstreamBinding.preview(environment: environment)
            return [
                "osRoot": preview.root,
                "upstreamHash": OSUpstreamBinding.upstreamHash(environment: environment),
                "seed": preview.seed,
                "error": preview.error ?? NSNull() as Any,
                "writable": false,
                "items": preview.items.map { item -> [String: Any] in
                    ["id": item.target.id, "label": item.target.label, "path": item.path, "state": item.state.rawValue,
                     "currentBlockHash": item.currentBlockHash ?? NSNull() as Any, "expectedHash": item.expectedHash,
                     "error": item.error ?? NSNull() as Any]
                }
            ]
        case "app_terminate_for_update":
            // W103：只接受本機 os.sock（同使用者）且明示 reason=update；用途是候選安裝的無人值守退出。
            guard Set(params.keys).isSubset(of: ["reason"]), params["reason"] as? String == "update" else {
                throw BridgeError.invalidParams
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)   // 先讓這個 RPC 的回應送出去
                TatwoTerminationCoordinator.bypassNextConfirmation = true
                NSApplication.shared.terminate(nil)
            }
            return ["terminating": true]
        case "ui_probe":
            // /goal 101 自測探針（UIProbe.swift）：只在「全權」時可用。
            return try onMainThrowing { [weak self] in
                guard self?.model?.permissionPreset == .fullAccess else { throw BridgeError.invalidParams }
                return UIProbe.run(params)
            }
        case "whoami":
            var result: [String: Any] = try onMainThrowing { [weak self] in
                guard let model = self?.model, let live = model.live, let owner,
                      let thread = live.threadRecord(owner) else { throw BridgeError.invalidParams }
                return [
                    "threadID": owner.uuidString,
                    "parentThreadID": thread.parentThreadID?.uuidString ?? NSNull() as Any,
                    "botID": model.botIDForBridge(threadID: owner) ?? NSNull() as Any,
                    "callerWorktree": thread.cwdOverride ?? NSNull() as Any,
                    "projectWorkdir": live.projectRecord(thread.projectID)?.workdir ?? NSNull() as Any,
                    "cwd": thread.cwdOverride ?? live.projectRecord(thread.projectID)?.workdir ?? NSNull() as Any,
                    "engine": thread.engine ?? NSNull() as Any,
                    "permissions": ["approval": thread.botPermissionPreset?.rawValue ?? NSNull() as Any,
                                    "mcp": thread.enabledMCP.isEmpty ? NSNull() : (thread.enabledMCP == ["__tatwo_none__"] ? [] : thread.enabledMCP) as Any]
                ]
            }
            result["upstream"] = CallerUpstream.identity()
            return result
        case "cli_open":
            var isDirectory: ObjCBool = false
            guard let cwd = params["cwd"] as? String, cwd.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else { throw BridgeError.invalidParams }
            // W178：終端機分頁跟背景指令一樣不受引擎沙盒限制，照同一個權限閘門。
            let approved = try requireCommandApproval(owner: owner, title: "允許 AI 開一個終端機分頁？", detail: "位置：" + cwd,
                                                      shown: [(cwd, true)], context: context)
            return try onMainThrowing { [weak self] in
                guard let self, let model = self.model else { throw BridgeError.invalidParams }
                // 等主執行緒的時間也算：開分頁前最後確認一次（期限、呼叫端、權限）。
                try self.ensureExecutable(owner: owner, approvedUnder: approved, context: context)
                guard let id = model.openCLITab(engine: .generic, workdir: cwd, callerThreadID: owner) else { throw BridgeError.invalidParams }
                if let title = params["title"] as? String { model.renameCLITab(id, title: title) }
                return ["id": id.uuidString, "readWith": "cli_tail"]
            }
        case "cli_send", "cli_tail", "cli_close":
            guard let raw = params["id"] as? String, let id = UUID(uuidString: raw) else { throw BridgeError.invalidParams }
            let cliModel: ChatPageModel = try onMainThrowing { [weak self] in
                guard let model = self?.model, model.cliSessionStore?.sessions.contains(where: { $0.id == id }) == true
                else { throw BridgeError.invalidParams }
                // W178：只能碰自己這條對話開的終端機分頁，不能往別條對話（或使用者自己）的分頁送指令。
                guard let owner, model.cliTabOwner[id] == owner else { throw BridgeError.cliSessionNotOwned }
                return model
            }
            var approved: BackgroundCommandGate = .run
            if method == "cli_send" {
                guard let text = params["text"] as? String else { throw BridgeError.invalidParams }
                // 一次只送一行：換行、Tab、ESC 等控制字元貼上時就會被當按鍵執行，繞過最後的確認。
                if let problem = Self.approvalTextProblem(text, singleLine: true) { throw BridgeError.commandTextRejected(problem) }
                approved = try requireCommandApproval(owner: owner, title: "允許 AI 在終端機執行這一行？", detail: text,
                                                      context: context)
            }
            return try awaitBot {
                if method == "cli_tail" {
                    let lines = max(0, min(params["lines"] as? Int ?? 80, 10000))
                    let text = await cliModel.cliWorkbenchTail(id)
                    return ["id": raw, "text": CLISessionStore.textTail(text, lines: lines)]
                }
                if method == "cli_send" {
                    guard let text = params["text"] as? String,
                          let session = await cliModel.cliTabPTYSession(for: id) else { throw BridgeError.invalidParams }
                    // 等 CLI 分頁準備好、tmux 排隊的時間也算：清空輸入列與貼上之前、按 Enter 之前各確認一次（期限、呼叫端、權限）；
                    // Enter 在 tmux 佇列裡真正送出的那一刻再看一次期限與連線（不等主執行緒）。
                    try await session.sendLineAwaited(text, confirm: {
                        try self.ensureExecutable(owner: owner, approvedUnder: approved, context: context)
                    }, enterPrecondition: {
                        try self.ensureStillWanted(context)
                    })
                    return Self.cliSendReceipt(id: raw)
                }
                try await cliModel.terminateCLIWorkbenchPane(id)
                return ["closed": true]
            }
        case "get_document":
            let snapshot: (LiveDocumentRecord, ChatLiveStore, [String], [String], PolicyFileStamp)? = onMain { [weak self] in
                guard let model = self?.model, let live = model.live else { return nil }
                let snapshot = Self.snapshot(live)
                let runningThreadIDs = snapshot.threads
                    .filter { live.isRunning($0.id) }
                    .map { $0.id.uuidString }
                // W184 H4 修正（審查 #9）：這台自己送不出的引擎（副設備的 Coder 走這台時，模型清單照這台的可用性標停用）。
                let blockedEngines = ClaudeSidecar.Kind.allCases.filter { model.isEngineDisabled($0) }.map(\.rawValue)
                return (snapshot, live.store, runningThreadIDs, blockedEngines, PolicyFileStamp(live.store.url))
            }
            guard let snapshot else { throw BridgeError.invalidParams }
            let finished = DispatchSemaphore(value: 0)
            let response = OSAllocatedUnfairLock<Result<[String: Any], Error>?>(initialState: nil)
            documentQueue.async {
                let result = Result<[String: Any], Error> {
                    snapshot.1.saveIfChanged(snapshot.0, expectedStamp: snapshot.4)
                    let attributes = try? FileManager.default.attributesOfItem(atPath: snapshot.1.url.path)
                    let modifiedAt = attributes?[.modificationDate] as? Date ?? .distantPast
                    return [
                        "document": try Self.jsonObject(snapshot.0),
                        "revision": Int64(modifiedAt.timeIntervalSince1970 * 1_000),
                        "runningThreadIDs": snapshot.2,
                        "blockedEngines": snapshot.3,
                        "engineModelCatalogs": EngineModelCatalog.wire(),
                    ]
                }
                response.withLock { $0 = result }
                finished.signal()
            }
            finished.wait()
            return try response.withLock { try $0!.get() }
        case "transcript":
            guard
                let rawThreadID = params["threadID"] as? String,
                let threadID = UUID(uuidString: rawThreadID)
            else { throw BridgeError.invalidParams }
            let messages: [LiveMessageRecord] = onMain { [weak self] in
                (self?.model?.live?.transcript(for: threadID) ?? []).map(LiveMessageRecord.init)
            }
            return ["messages": try Self.jsonObject(messages)]
        case "send_message", "send_message_with_options":
            guard
                let rawThreadID = params["threadID"] as? String,
                let threadID = UUID(uuidString: rawThreadID),
                let text = params["text"] as? String,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw BridgeError.invalidParams }
            let modelArgument = params["model"] as? String
            let reasoningEffort = params["reasoningEffort"] as? String
            let serviceTier = params["serviceTier"] as? String
            // Native catalogs own the supported values; this boundary validates
            // shape without freezing future model capabilities into an OS list.
            guard params["reasoningEffort"] == nil || reasoningEffort?.isEmpty == false,
                  params["serviceTier"] == nil || serviceTier?.isEmpty == false,
                  method != "send_message_with_options" || reasoningEffort != nil || serviceTier != nil else {
                throw BridgeError.invalidParams
            }
            let assistantRoute = params["assistantRoute"] as? String
            let requestedEngine = params["engine"] as? String
            guard requestedEngine == nil || requestedEngine.flatMap(ClaudeSidecar.Kind.init(rawValue:)) != nil else { throw BridgeError.invalidParams }
            // W180 E1：副設備在 chip 選的記憶強度（只收四檔之一；不收的當沒帶，這句照常送）。
            let mayUseMemory = try context.controllerFingerprint.map {
                try requestDispatch.fleet.methodAllowed(fingerprint: $0, method: "memory_sync_receive")
            } ?? true
            let memoryStrength = mayUseMemory ? TatwoMemoryStrength.accepting(params["memoryStrength"]) : .off
            // W184 H4 修正（審查 #2）：副設備這一輪的 ultrawork（檔位、主導、每一個副手；卡上的值）：帶進這台那一輪（接在那一句後面、
            // 記成那條的偏好）。認不得的當沒帶（這句照常送、照這台那條記住的）；舊版副設備沒帶也一樣。
            let ultrawork = UltraworkTurnSettings.accepting(params["ultrawork"])
            try onMainThrowing { [weak self] in
                guard let live = self?.model?.live, live.threadRecord(threadID) != nil else {
                    throw BridgeError.sendTurnRejected("thread_missing")
                }
                if let reason = ManagedConversationTAPPolicy.rejectionReason(model: modelArgument ?? live.threadRecord(threadID)?.requestedModel,
                    creator: live.threadRecord(threadID)?.controllerCreatorFingerprint ?? context.controllerFingerprint.flatMap {
                        DeviceFleetGate.ownerFallbackSafe(registry: self!.requestDispatch.registry, fingerprint: $0) ? nil : $0
                    }) {
                    live.appendSystemMessage(threadID: threadID, text: reason, status: "error|ChatGPT TAP")
                    throw BridgeError.sendTurnRejected("managed_chatgpt_tap_forbidden")
                }
                // W180 E1：先把記憶強度記在那條（助理那條與一般的都是），這句就照它帶記憶。
                if let memoryStrength { (live as? ChatLiveEngine)?.setMemoryStrength(threadID: threadID, memoryStrength) }
                #if DEBUG
                if let fixtureSend = self?.fixtureSend { fixtureSend(threadID, text); return }
                #endif
                // W179 F：副設備交給這台助理那條的一句：照這台自己的助理規則送（模型、登入檢查、人設），跳過這台停用的引擎。
                if let model = self?.model,
                   Self.routesToAssistant(isAssistantThread: live.doc.isAssistantThread(threadID),
                                          modelArgument: modelArgument, assistantRoute: assistantRoute,
                                          reasoningEffort: reasoningEffort, serviceTier: serviceTier) {
                    if let problem = model.receiveAssistantTurnFromSecondary(threadID: threadID, text: text,
                                                                             routeID: assistantRoute) {
                        throw BridgeError.assistantTurnRejected(problem)
                    }
                    live.store.save(Self.snapshot(live))
                    return
                }
                let engine = Self.sendMessageEngine(modelArgument: modelArgument, requested: requestedEngine,
                                                    threadEngine: live.threadRecord(threadID)?.engine)
                guard !live.isRunning(threadID) else { throw BridgeError.sendTurnRejected("thread_busy") }
                guard engine == .codex || engine == .claude || (reasoningEffort == nil && serviceTier == nil) else {
                    throw BridgeError.sendTurnRejected("engine_options_unsupported")
                }
                let priorRows = Set(live.transcript(for: threadID).map(\.id))
                guard live.send(
                    threadID: threadID,
                    text: text,
                    model: modelArgument,
                    engine: engine,
                    systemPrompt: nil,
                    attachments: [],
                    reasoningEffort: reasoningEffort,
                    serviceTier: serviceTier,
                    ultrawork: ultrawork) else {
                    let refusal = live.transcript(for: threadID).last {
                        !priorRows.contains($0.id) && $0.role == .system && $0.status?.hasPrefix("error|") == true
                    }
                    throw BridgeError.sendTurnRejected(RemoteSendRejection.code(for: refusal?.status))
                }
                live.store.save(Self.snapshot(live))
            }
            return ["sent": true]
        case "distill_open", "distill_get", "distill_edit", "distill_write":
            // W180 E4：已配對設備看這台一條 session 的 /蒸餾 畫布。參數先在這裡驗成 Sendable 再進主執行緒；
            // 寫入（檔案、GBrain）在這條背景執行緒跑，前後各進主執行緒一次（先存「確認寫入」的界線，再存結果）。
            // 寫入在自己的背景佇列跑完再存回；這裡最多等幾秒：寫好就回結果，還沒好（GBrain 慢）先回「寫入中」，對方用 status 查。
            let request = try DistillRemoteRequest.parse(method: method, params: params)
            let begun: DistillRemoteReply = try onMainThrowing { [weak self] in
                guard let model = self?.model else { throw BridgeError.invalidParams }
                return try model.distillRemoteBegin(request)
            }
            guard let job = begun.job else { return try begun.object() }
            let box = DistillReplyBox()
            distillJobQueue.async { [weak self] in
                let outcome = DistillWriter.perform(job)
                // 寫完之後存回畫布失敗也要把寫入結果交回去（檔案已經寫了）。
                let finished = (try? self?.onMainThrowing { [weak self] () throws -> DistillRemoteReply in
                    guard let model = self?.model else { throw BridgeError.invalidParams }
                    return try model.distillRemoteFinish(job, outcome)
                }) ?? DistillRemoteReply(result: DistillHost.result(job.mode, outcome))
                box.finish(finished)
            }
            if let finished = box.wait(DistillWire.replyWait) { return try finished.object() }
            var pending = begun
            pending.job = nil
            pending.result = DistillWriteResult(status: "writing", lines: [job.mode == .apply ? "寫入中…" : "還原中…"],
                                                archivePath: nil, mode: job.mode.rawValue)
            return try pending.object()
        case "new_thread":
            let projectID: UUID?
            if let rawProjectID = params["projectID"] as? String {
                guard let parsed = UUID(uuidString: rawProjectID) else { throw BridgeError.invalidParams }
                projectID = parsed
            } else {
                projectID = nil
            }
            let rawTitle = (params["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let threadID: UUID = try onMainThrowing { [weak self] in
                guard let live = self?.model?.live else { throw BridgeError.invalidParams }
                if let projectID, live.projectRecord(projectID) == nil { throw BridgeError.invalidParams }
                let id = live.newThread(in: projectID, title: rawTitle?.isEmpty == false ? rawTitle! : "新聊天")
                if let fingerprint = context.controllerFingerprint,
                   !DeviceFleetGate.ownerFallbackSafe(registry: self!.requestDispatch.registry, fingerprint: fingerprint) {
                    guard let engine = live as? ChatLiveEngine else { throw BridgeError.invalidParams }
                    engine.markControllerThread(id, fingerprint: fingerprint)
                }
                return id
            }
            return ["threadID": threadID.uuidString]
        case "stop_thread":
            guard
                let rawThreadID = params["threadID"] as? String,
                let threadID = UUID(uuidString: rawThreadID)
            else { throw BridgeError.invalidParams }
            let stopped: Bool = try onMainThrowing { [weak self] in
                guard let live = self?.model?.live, live.threadRecord(threadID) != nil else {
                    throw BridgeError.invalidParams
                }
                live.stop(threadID: threadID)
                return !live.isRunning(threadID)
            }
            return ["stopRequested": true, "stopped": stopped]
        case "push_thread":
            // Baseline reads use the existing paired push_thread route, no new sync channel.
            if params["phase"] as? String == "baseline" {
                guard let paths = params["paths"] as? [String] else { throw BridgeError.invalidParams }
                let hashes: [String: String] = try onMainThrowing { [weak self] in
                    guard let live = self?.model?.live as? ChatLiveEngine else { throw BridgeError.invalidParams }
                    let project = try live.transferProject(named: params["projectName"] as? String, requiresFiles: true)
                    return try RemoteThreadTransfer.baselines(paths: paths, in: project.workdir)
                }
                return ["baselines": hashes]
            }
            guard
                let title = params["title"] as? String,
                let rawMessages = params["messages"]
            else { throw BridgeError.invalidParams }
            let messages: [RemoteThreadTransferMessage] = try Self.decode(rawMessages)
            let files: [RemoteThreadTransferFile]
            if let rawFiles = params["files"] {
                files = try Self.decode(rawFiles)
            } else {
                files = []
            }
            let threadID: UUID = try onMainThrowing { [weak self] in
                guard let live = self?.model?.live as? ChatLiveEngine else {
                    throw BridgeError.invalidParams
                }
                return try live.importTransferredThread(
                    projectName: params["projectName"] as? String,
                    title: title,
                    messages: messages,
                    files: files)
            }
            return ["threadID": threadID.uuidString]
        case "pull_thread":
            guard
                let rawThreadID = params["threadID"] as? String,
                let threadID = UUID(uuidString: rawThreadID)
            else { throw BridgeError.invalidParams }
            let transfer: (
                projectName: String?,
                title: String,
                messages: [RemoteThreadTransferMessage],
                files: [RemoteThreadTransferFile]
            ) = try onMainThrowing { [weak self] in
                guard
                    let live = self?.model?.live as? ChatLiveEngine,
                    let thread = live.threadRecord(threadID),
                    let project = live.projectRecord(thread.projectID)
                else { throw BridgeError.invalidParams }
                let workdir = thread.cwdOverride ?? project.workdir
                // Same provenance and committed source baseline as push_thread. Uncertain
                // observations are not thread edits; the receiver atomically rejects conflicts.
                let files = try Self.pullThreadFiles(
                    threadID: threadID, artifactsRoot: live.turnArtifacts.root, workdir: workdir)
                live.appendSystemMessage(
                    threadID: threadID,
                    text: "另一台設備已索取這條討論串的副本；檔案仍須通過接收端衝突檢查，這裡的原件不變。",
                    status: "info|設備搬移")
                return (
                    project.name,
                    thread.title,
                    live.transcript(for: threadID).map(RemoteThreadTransferMessage.init),
                    files)
            }
            return [
                "projectName": transfer.projectName ?? NSNull(),
                "title": transfer.title,
                "messages": try Self.jsonObject(transfer.messages),
                "files": try Self.jsonObject(transfer.files),
            ]
        case "dispatch_rooms":
            guard let rawRooms = params["rooms"] as? [[String: Any]], !rawRooms.isEmpty else { throw BridgeError.invalidParams }
            let specs: [RoomSpec] = try rawRooms.map { row in
                guard let title = row["title"] as? String, let engine = row["engine"] as? String, let brief = row["brief"] as? String else {
                    throw BridgeError.invalidParams
                }
                if let value = row["readOnly"],
                   !(value is NSNumber) || CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() {
                    throw BridgeError.invalidParams
                }
                return RoomSpec(title: title, engine: engine, model: row["model"] as? String, brief: brief,
                                device: row["device"] as? String, readOnly: row["readOnly"] as? Bool ?? false)
            }
            let dispatched: [DispatchedRoom] = try awaitBot { @MainActor [weak self] in
                guard let self, let model = self.model, let parent = owner else {
                    throw BridgeError.noParentThread
                }
                return try await model.dispatchChecked(rooms: specs, parent: parent)
            }
            guard !dispatched.isEmpty else { throw BridgeError.noParentThread }
            // W170：每一件派出去的工作是主導那條目前「進行中」目標底下的子目標；sub 只能把它標到「待驗收」。
            if let parent = owner {
                try? ThreadGoalStore.shared.update(parent) { list in
                    let active = list.goals.first(where: { $0.status == .active && $0.parent == nil })?.id
                    for (spec, room) in zip(specs, dispatched) {
                        var goal = try ThreadGoalRules.add(&list, title: spec.title, userWords: nil, proposed: false, parent: active)
                        goal.roomThread = room.threadID
                        goal.status = .active
                        if let i = list.goals.firstIndex(where: { $0.id == goal.id }) { list.goals[i] = goal }
                    }
                }
            }
            return ["rooms": dispatched.map { room -> [String: Any] in
                ["roomID": room.roomID, "threadID": room.threadID, "worktree": room.worktree,
                 "branch": room.branch, "readOnly": room.readOnly, "cwd": room.workingDirectory ?? room.worktree]
            }]
        case "list_rooms":
            // Capture only in-memory fields on the main actor; no filesystem or du here.
            let captured: [(DispatchRoom, String?, String?, String?, Bool)] = onMain { [weak self] in
                guard let model = self?.model else { return [] }
                return model.document.projects.lazy.flatMap(\.threads).filter { $0.parentThreadID == owner }.prefix(1000).map { t in
                    (DispatchRoom(id: t.id, title: t.title, engineLabel: t.engineLabel ?? "",
                                  liveness: t.liveness ?? .idle, lastOutputAt: t.lastOutputAt,
                                  reportAvailable: t.liveness == .done, deviceLabel: model.live?.threadRecord(t.id)?.deviceID.flatMap { id in model.devices.first(where: { $0.id == id })?.name }),
                     model.live?.threadRecord(t.id)?.roomReadOnly == true ? nil : model.live?.threadRecord(t.id)?.cwdOverride,
                     model.live?.projectRecord(model.live?.threadRecord(t.id)?.projectID)?.workdir,
                     model.live?.threadRecord(t.id)?.requestedModel,
                     model.live?.threadRecord(t.id)?.roomReadOnly == true)
                }
            }
            var mergeChecks = 0
            // 整次請求共用時間預算：MCP 端 45 秒逾時，這裡最多花 8 秒查合併狀態；超過預算的列保留「未查」（checkedAt 空）。
            let mergeDeadline = ProcessInfo.processInfo.systemUptime + 8
            return ["rooms": captured.map { room, path, projectWorkdir, requestedModel, readOnly -> [String: Any] in
                let branch = Self.worktreeBranch(path)
                var merge: [String: Any] = ["merged": false, "commit": "", "checkedAt": ""]
                if room.liveness == .done, !branch.isEmpty, let projectWorkdir, mergeChecks < 50,
                   ProcessInfo.processInfo.systemUptime < mergeDeadline {
                    mergeChecks += 1
                    let work = DispatchWorkItem { merge = Self.mergeReceipt(branch: branch, workdir: projectWorkdir, deadline: mergeDeadline) }
                    Self.mergeQueue.async(execute: work)
                    work.wait()
                }
                let size = CallerDirectoryCache.shared.snapshot(path)
                return ["roomID": room.id.uuidString, "title": room.title, "engine": room.engineLabel,
                        "liveness": room.liveness.rawValue,
                        "lastOutputAt": room.lastOutputAt.map { Self.iso8601.string(from: $0) } ?? "",
                        "reportAvailable": room.reportAvailable,
                        "branch": branch, "merge": merge, "readOnly": readOnly,
                        // 派工時要求的模型（dispatch-hygiene 持久化欄位）；沒有就空字串，不拿目前可變的 model 冒充。
                        "requestedModel": requestedModel ?? "",
                        "dispatchedBy": owner?.uuidString ?? "",
                        "worktreeExists": path.map { FileManager.default.fileExists(atPath: $0) } ?? false,
                        // Timestamp belongs to the last successful measurement, never this query.
                        "sizeMeasuredAt": size.measuredAt.map { Self.iso8601.string(from: $0) } ?? "",
                        "worktreeSizeMB": size.megabytes, "sizeStale": size.isStale(), "device": room.deviceLabel ?? ""]
            }]
        case "select_thread":   // 自動化／驗收用：把畫面切到某條對話
            guard let raw = params["threadID"] as? String, let id = UUID(uuidString: raw) else { throw BridgeError.invalidParams }
            onMain { [weak self] in self?.model?.selectLocalThread(id) }
            return ["ok": true]
        case "github_import_from_gh":   // 本機自動化用：讓 App 自己建立 Keychain 項目，ACL 才會信任這個 App
            onMain { [weak self] in self?.model?.importGitHubAccountsFromGH() }
            return ["ok": true]
        case "goal_index":
            guard Set(params.keys).isSubset(of: ["callerThreadID", "includeDone"]) else { throw BridgeError.invalidParams }
            if let raw = params["includeDone"] {
                guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw BridgeError.invalidParams }
            }
            guard let doc = onMain({ [weak self] in self?.model?.localLiveForBridge?.doc }) else { throw BridgeError.unsupportedMethod }
            let projects = Dictionary(uniqueKeysWithValues: doc.projects.map { ($0.id, $0.name) })
            let includeDone = params["includeDone"] as? Bool ?? false
            // File reads stay on the bridge queue, not the UI actor. Never encode the full goal (userWords/evidence).
            let threads: [[String: Any]] = doc.threads.compactMap { thread in
                let list = ThreadGoalStore.shared.list(thread.id)
                let visible = list.goals.filter { includeDone || $0.status != .done }
                guard !visible.isEmpty else { return nil }
                var row = Self.threadMetadata(thread, projects: projects)
                let progress = ThreadGoalRules.progress(list)
                row["progress"] = ["done": progress.done, "total": progress.total]
                row["goals"] = visible.map { goal -> [String: Any] in
                    ["id": goal.id, "title": String(goal.title.prefix(200)), "status": goal.status.rawValue,
                     "proposed": goal.proposed, "parent": goal.parent as Any? ?? NSNull()]
                }
                return row
            }
            return ["device": "local", "threads": threads, "includeDone": includeDone]
        case "os_status":
            guard Set(params.keys).isSubset(of: ["callerThreadID"]) else { throw BridgeError.invalidParams }
            let input = onMain { [weak self] in
                guard let model = self?.model, let live = model.localLiveForBridge else { return nil as OSStatusInput? }
                return OSStatusInput(doc: live.doc, pending: live.pendingPermissionThreadIDs,
                    running: Set(live.doc.threads.filter { live.isRunning($0.id) }.map(\.id)),
                    bots: model.botLibraryForBridge?.snapshot ?? .init(),
                    sessions: model.cliSessionStore?.sessions ?? [], devices: model.devices,
                    requestTitles: IslandNotice.shared.pendingRequestTitles)
            }
            guard let input else { throw BridgeError.unsupportedMethod }
            let jobs = try awaitBot { await self.backgroundJobSnapshot(includeLastLine: false) }
            let deviceFleet = try? DeviceFleetStore(registry: DeviceRegistry(), environment: ProcessInfo.processInfo.environment).readGraph()
            let now = Date()
            let work = IslandWorkProvider.project(threads: input.doc.threads, pending: input.pending,
                running: input.running, bots: input.bots, jobs: jobs, now: now, limit: nil)
            return Self.statusMetadata(doc: input.doc, work: work, jobs: jobs, sessions: input.sessions,
                devices: input.devices, requestTitles: input.requestTitles, now: now, deviceFleet: deviceFleet)
        case "list_devices":
            let devices: [DeviceRecord] = onMain { [weak self] in
                self?.model?.deviceRecordsForBridge() ?? DeviceRegistry().list()
            }
            if !context.isAppOrSSH {
                let payload = try? DeviceFleetStore(registry: DeviceRegistry(), environment: ProcessInfo.processInfo.environment).readGraph()
                return ["devices": DeviceFleetStore.engineDeviceProjection(devices, payload: payload)]
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(devices),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { return ["devices": []] }
            return ["devices": rows]
        case "computer_list_apps", "computer_start", "computer_observe", "computer_action", "computer_batch", "computer_stop":
            // Unlike legacy room tools, this lane never infers caller identity
            // from the currently selected tab and is unavailable headlessly.
            guard let raw = params["callerThreadID"] as? String, let caller = UUID(uuidString: raw),
                  let computerConnection, computerConnection(),
                  let model = onMain({ [weak self] in self?.model }) else { throw BridgeError.invalidParams }
            return try awaitBot {
                try await model.performComputerTool(method, params: params, caller: caller, requestIsConnected: computerConnection)
            }
        case "ipad_prepare", "ipad_status", "ipad_screenshot", "ipad_open_app", "ipad_touch", "ipad_stop":
            guard let raw = params["callerThreadID"] as? String, let caller = UUID(uuidString: raw),
                  onMain({ [weak self] in self?.model?.live?.threadRecord(caller) != nil }) else { throw BridgeError.invalidParams }
            return try awaitBot {
                try await IPadUseController.shared.perform(method, params: params, caller: caller)
            }
        case "run_background":
            guard params["requestKey"] == nil || params["requestKey"] is String, params["cwd"] == nil || params["cwd"] is String, let command = params["cmd"] as? String else { throw BridgeError.invalidParams }
            let target: (UUID, LiveThreadRecord, LiveProjectRecord?)? = onMain { [weak self] in
                guard let model = self?.model, let live = model.live, let threadID = owner,
                      let thread = live.threadRecord(threadID) else { return nil }
                return (threadID, thread, live.projectRecord(thread.projectID))
            }
            guard let target else { throw BridgeError.noParentThread }
            guard let manager = backgroundJobs else { throw BridgeError.unsupportedMethod }
            guard let access = try commandAccess(owner: target.0) else { throw BridgeError.noParentThread }
            let cwd: String?
            do { cwd = try access.policy?.workDirectory(for: target.1, project: target.2, requested: params["cwd"] as? String)
                ?? (params["cwd"] as? String) ?? target.1.cwdOverride ?? target.2?.workdir }
            catch { throw DeviceDispatch.Failure(reason: ManagedEnginePolicy.refusal(error, fleet: requestDispatch.fleet)) }
            if let repeated = manager.existing(threadID: target.0, requestKey: params["requestKey"] as? String) {
                return manager.response(repeated)
            }
            let title = (params["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            // 排隊、建記錄檔的時間也算：manager 真正開程序前再看一次期限與連線（不等主執行緒，避免互等）。
            return manager.response(try manager.run(command: command, cwd: cwd, title: title?.isEmpty == false ? title! : command,
                                                    threadID: target.0, requestKey: params["requestKey"] as? String,
                                                    memoryPolicy: access.policy,
                                                    authorize: { cwd in
                                                        let place = (cwd as NSString).abbreviatingWithTildeInPath
                                                        let approved = try self.requireCommandApproval(owner: target.0, title: "允許 AI 在背景執行這個指令？",
                                                            detail: command + "\n位置：" + place, shown: [(command, false), (place, true)], gate: access.gate, context: context)
                                                        let current = try self.ensureExecutable(owner: target.0, approvedUnder: approved, context: context)
                                                        guard (current != nil) == (access.policy != nil) else { throw BridgeError.backgroundCommandNeedsApproval }
                                                        if let current {
                                                            let latest = try self.onMainThrowing { () throws -> String in
                                                                guard let live = self.model?.live, let thread = live.threadRecord(target.0) else { throw BridgeError.noParentThread }
                                                                return try current.workDirectory(for: thread, project: live.projectRecord(thread.projectID), requested: params["cwd"] as? String)
                                                            }
                                                            guard latest == cwd else { throw BridgeError.backgroundCommandNeedsApproval }
                                                        }
                                                    },
                                                    beforeSpawn: { [context] in try self.ensureStillWanted(context) }))
        case "background_list":
            let caller = try jobsCaller(params, bound: context.boundThread, allowSelected: !context.isSSH)
            guard let manager = backgroundJobs else { throw BridgeError.unsupportedMethod }
            return ["jobs": manager.list(threadID: caller.id), "ownerSource": caller.source]
        case "artifacts_list":
            let caller = try jobsCaller(params, bound: context.boundThread, allowSelected: !context.isSSH)
            if let raw = params["turnID"], !(raw is String) { throw BridgeError.invalidParams }
            let turn = params["turnID"] as? String
            guard turn == nil || (turn!.utf8.count <= 1024 && !turn!.isEmpty) else { throw BridgeError.invalidParams }
            let artifacts = jobsTestArtifacts ?? onMain { [weak self] in
                (self?.model?.live as? ChatLiveEngine)?.turnArtifacts
            }
            guard let artifacts else { throw BridgeError.unsupportedMethod }
            let index = try awaitBot { try await artifacts.list(threadID: caller.id, turnID: turn) }
            guard let index else { return ["artifacts": [], "turnID": turn as Any? ?? NSNull(), "ownerSource": caller.source] }
            var value = try Self.jsonObject(index) as? [String: Any] ?? [:]
            value["ownerSource"] = caller.source
            return value
        case "background_status":
            guard let text = params["jobID"] as? String, let id = UUID(uuidString: text),
                  let manager = backgroundJobs, let record = manager.status(jobID: id), record.threadID == owner else { throw BridgeError.invalidParams }
            if let raw = params["tailBytes"], !(raw is Int) { throw BridgeError.invalidParams }
            return manager.response(record, tailBytes: params["tailBytes"] as? Int ?? 8192)
        case "stop_background":
            guard let text = params["jobID"] as? String, let id = UUID(uuidString: text),
                  let manager = backgroundJobs, manager.status(jobID: id)?.threadID == owner, let record = manager.stop(jobID: id) else { throw BridgeError.invalidParams }
            return manager.response(record)
        case "reclaim_room":
            guard let roomIDText = params["roomID"] as? String, let roomID = UUID(uuidString: roomIDText) else { throw BridgeError.invalidParams }
            guard onMain({ [weak self] in self?.model?.live?.threadRecord(roomID)?.parentThreadID == owner }) else { throw BridgeError.invalidParams }
            let keepBranch = params["keepBranch"] as? Bool ?? true
            let reclaimed = try awaitBot { @MainActor [weak self] in
                guard let model = self?.model else { throw BridgeError.invalidParams }
                return try await model.reclaimRoom(roomID, keepBranch: keepBranch)
            }
            return [
                "roomID": reclaimed.roomID,
                "originalPath": reclaimed.originalPath,
                "archivedPath": reclaimed.archivedPath ?? NSNull(),
                "stash": reclaimed.stash ?? NSNull(),
                "branch": reclaimed.branch ?? NSNull(),
                "branchDeleted": reclaimed.branchDeleted,
            ]
        case "stop_room":
            guard let roomIDText = params["roomID"] as? String, let roomID = UUID(uuidString: roomIDText) else { throw BridgeError.invalidParams }
            guard onMain({ [weak self] in self?.model?.live?.threadRecord(roomID)?.parentThreadID == owner }) else { throw BridgeError.invalidParams }
            let stopped: Bool = onMain { [weak self] in
                self?.model?.stopDispatchRoom(roomID)
                return !(self?.model?.live?.isRunning(roomID) ?? true)
            }
            return ["stopRequested": true, "stopped": stopped]
        case "stop_all_rooms":
            let stopped: Bool = onMain { [weak self] in
                guard let model = self?.model, let live = model.live else { return false }
                model.stopAllDispatchRooms(parent: owner)
                return model.dispatchRooms(parent: owner).allSatisfy { !live.isRunning($0.id) }
            }
            return ["stopRequested": true, "stopped": stopped]
        case "merge_reports":
            let text: String = onMain { [weak self] in self?.model?.mergeDispatchReports(parent: owner) ?? "" }
            return ["text": text]
        case AssistantOfflineWire.method:   // W182 R5：見 AssistantOfflineHandoff.swift（只寫這台助理那條、不觸發引擎、請求 id 去重）
            let request = try AssistantOfflineWire.parse(params)
            return try onMainThrowing { [weak self] in
                guard let model = self?.model else { throw AssistantOfflineWire.Failure.unavailable }
                return try model.receiveAssistantOfflineAppend(request)
            }
        case "project_overview", "project_suggest", "project_proposal_decide":   // W180 E3b：見 projectClassification
            return try projectClassification(method: method, params: params, boundThread: context.boundThread)
        case "overview_snapshot":   // W180 E2：見檔尾 overviewSnapshot
            return try overviewSnapshot(params: params)
        default:
            throw BridgeError.unsupportedMethod
        }
    }

    private struct OSStatusInput {
        var doc: LiveDocumentRecord
        var pending: Set<UUID>
        var running: Set<UUID>
        var bots: BotLibrarySnapshot
        var sessions: [CLISessionStore.Record]
        var devices: [DeviceRecord]
        var requestTitles: [String]
    }

    private static func threadMetadata(_ thread: LiveThreadRecord, projects: [UUID: String]) -> [String: Any] {
        ["threadID": thread.id.uuidString, "title": String(thread.title.prefix(200)),
         "projectID": thread.projectID?.uuidString as Any? ?? NSNull(),
         "projectName": thread.projectID.flatMap { projects[$0] }.map { String($0.prefix(200)) } as Any? ?? NSNull()]
    }

    /// Explicit allowlist, not Codable records: no messages, brief, commands, cwd, logs, device endpoints or credentials.
    static func statusMetadata(doc: LiveDocumentRecord, work: IslandWorkSnapshot,
                               jobs: [BackgroundJobManager.Snapshot], sessions: [CLISessionStore.Record],
                               devices: [DeviceRecord], requestTitles: [String], now: Date, deviceFleet: DeviceFleetPayload? = nil) -> [String: Any] {
        let projects = Dictionary(uniqueKeysWithValues: doc.projects.map { ($0.id, $0.name) })
        let threads = Dictionary(uniqueKeysWithValues: doc.threads.map { ($0.id, $0) })
        func context(_ id: UUID?) -> [String: Any] {
            guard let id, let thread = threads[id] else {
                return ["threadID": id?.uuidString as Any? ?? NSNull(), "title": NSNull(),
                        "projectID": NSNull(), "projectName": NSNull()]
            }
            return threadMetadata(thread, projects: projects)
        }
        var groups: [String: [[String: Any]]] = [
            "running": [], "awaitingApproval": [], "stalled": [], "failed": [], "pendingMemories": [],
        ]
        var states: [UUID: String] = [:]
        for item in work.exceptions + work.normal where item.jobID == nil {
            let status: String
            switch item.kind {
            case .awaitingApproval: status = "awaitingApproval"
            case .pendingMemory: status = "pendingMemories"
            case .stalled: status = "stalled"
            case .failed: status = "failed"
            case nil:
                status = item.threadID.flatMap { threads[$0]?.subStatus } == "stalled" ? "stalled" : "running"
            }
            var row = context(item.threadID)
            row["status"] = status
            if let bot = item.botID {
                row["botID"] = bot; row["title"] = String(item.title.prefix(200))
            } else if let id = item.threadID { states[id] = status }
            groups[status, default: []].append(row)
        }
        // OS-only classifications must not make idle/error history appear on Island's work page.
        for thread in doc.threads where states[thread.id] == nil {
            let status: String
            if thread.subStatus == "stalled" { status = "stalled" }
            // 只算最近 7 天的錯誤；更早的舊討論串不當成「現在失敗」。
            else if thread.messages.last?.status?.hasPrefix("error") == true,
                    now.timeIntervalSince(thread.updatedAt) < 7 * 86_400 { status = "failed" }
            else { continue }
            var row = threadMetadata(thread, projects: projects)
            row["status"] = status
            states[thread.id] = status
            groups[status, default: []].append(row)
        }
        let rooms: [[String: Any]] = doc.threads.compactMap { thread in
            guard let parent = thread.parentThreadID else { return nil }
            var row = threadMetadata(thread, projects: projects)
            row["parentThreadID"] = parent.uuidString
            row["parentTitle"] = threads[parent].map { String($0.title.prefix(200)) } as Any? ?? NSNull()
            row["status"] = states[thread.id] ?? thread.subStatus ?? "idle"
            row["deviceID"] = thread.deviceID as Any? ?? NSNull()
            return row
        }
        let background: [[String: Any]] = jobs.map { job in
            var row = context(job.threadID)
            row["jobID"] = job.jobID.uuidString
            // Legacy job titles default to the entire command. Keep only the owning thread title here.
            row["status"] = job.state
            row["exitCode"] = job.exitCode as Any? ?? NSNull()
            return row
        }
        let cli: [[String: Any]] = sessions.map { session in
            ["id": session.id.uuidString, "title": String(session.title.prefix(200)),
             "status": session.status.rawValue, "threadID": session.threadID?.uuidString as Any? ?? NSNull(),
             "projectID": session.projectID?.uuidString as Any? ?? NSNull(),
             "projectName": session.projectID.flatMap { projects[$0] }.map { String($0.prefix(200)) } as Any? ?? NSNull()]
        }
        let deviceRows: [[String: Any]] = DeviceFleetStore.engineDeviceProjection(devices, payload: deviceFleet)
        var result: [String: Any] = groups
        result["device"] = "local"
        result["rooms"] = rooms
        result["backgroundJobs"] = background
        result["backgroundJobsLimit"] = 200 // Existing manager snapshot bound; not a promise of a complete job history.
        result["cliSessions"] = cli
        result["devices"] = deviceRows // Cached App inventory; do not refresh/mutate selection or probe SSH.
        result["pendingRequestTitles"] = requestTitles
        result["capturedAt"] = iso8601.string(from: now)
        return result
    }

    static func cliSendReceipt(id: String) -> [String: Any] {
        ["sent": true, "id": id, "readWith": "cli_tail"]
    }

    private static let mergeQueue = DispatchQueue(label: "ai.tatwo.tatwo2.os-agent.merge", qos: .utility)

    /// Read-only git commands; argument arrays (not shell), bounded time and output.
    /// 單次 git：上限 2 秒，且不超過整次請求的 deadline（絕對 systemUptime）；預算用完直接回 nil。
    private static func mergeGit(_ arguments: [String], workdir: String, deadline: TimeInterval) -> String? {
        precondition(!Thread.isMainThread)
        let budget = min(2, deadline - ProcessInfo.processInfo.systemUptime)
        guard budget > 0.05 else { return nil }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-pager", "-C", workdir] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Drain while git runs so a long merge history cannot fill the pipe.
        let drained = DispatchSemaphore(value: 0)
        var tail = Data()
        let drain = DispatchWorkItem {
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                tail.append(chunk)
                if tail.count > 8192 { tail = Data(tail.suffix(8192)) }
            }
            drained.signal()
        }
        DispatchQueue.global(qos: .utility).async(execute: drain)
        let stopAt = ProcessInfo.processInfo.systemUptime + budget
        while process.isRunning && ProcessInfo.processInfo.systemUptime < stopAt { Thread.sleep(forTimeInterval: 0.005) }
        if process.isRunning {
            process.terminate()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? pipe.fileHandleForReading.close()
            _ = drained.wait(timeout: .now() + 0.2)
            return nil
        }
        guard drained.wait(timeout: .now() + min(1, max(0.05, deadline - ProcessInfo.processInfo.systemUptime))) == .success, process.terminationStatus == 0 else { return nil }
        return String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// deadline＝整次請求的絕對 systemUptime 上限；預算內查不完就回「未查」（checkedAt 空），不寫成未合併。
    static func mergeReceipt(branch: String, workdir: String, deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 8) -> [String: Any] {
        precondition(!Thread.isMainThread)
        var result: [String: Any] = ["merged": false, "commit": "", "checkedAt": ""]
        // Fully qualified local ref prevents option/revision injection from branch text.
        let ref = "refs/heads/" + branch
        // 「有查到結論」才填 checkedAt：預算不足／git 起不來／逾時／非 0、1 的狀態一律保持「未查」（Codex round 3）。
        guard !branch.isEmpty else { result["checkedAt"] = ISO8601DateFormatter().string(from: Date()); return result }
        guard let refStatus = mergeGitStatus(["check-ref-format", ref], workdir: workdir, deadline: deadline) else { return result }
        guard refStatus == 0 else { result["checkedAt"] = ISO8601DateFormatter().string(from: Date()); return result }   // 名字不合法＝確定不是分支
        // is-ancestor：exit 0＝已合併、exit 1＝未合併、其他（缺 ref／壞 repo）或 nil（逾時／預算用完）＝未查
        let ancestor = mergeGitStatus(["merge-base", "--is-ancestor", ref, "HEAD"], workdir: workdir, deadline: deadline)
        guard let ancestor, ancestor == 0 || ancestor == 1 else { return result }
        if ancestor == 0,
           let history = mergeGit(["log", "--merges", "--ancestry-path", "--format=%H", ref + "..HEAD", "--"], workdir: workdir, deadline: deadline) {
            let commit = history.split(separator: "\n").last.map(String.init)
                ?? mergeGit(["rev-parse", "--verify", ref + "^{commit}"], workdir: workdir, deadline: deadline)
            guard let commit, !commit.isEmpty else { return result }
            result["merged"] = true; result["commit"] = commit
        } else if ancestor == 0 {
            return result   // 預算內取不到 commit → 未查
        }
        result["checkedAt"] = ISO8601DateFormatter().string(from: Date())
        return result
    }
    /// 同 mergeGit 但回 exit status（nil＝逾時／預算用完／起不來）。
    private static func mergeGitStatus(_ arguments: [String], workdir: String, deadline: TimeInterval) -> Int32? {
        precondition(!Thread.isMainThread)
        let budget = min(2, deadline - ProcessInfo.processInfo.systemUptime)
        guard budget > 0.05 else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-pager", "-C", workdir] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_OPTIONAL_LOCKS"] = "0"; environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let stopAt = ProcessInfo.processInfo.systemUptime + budget
        while process.isRunning && ProcessInfo.processInfo.systemUptime < stopAt { Thread.sleep(forTimeInterval: 0.005) }
        if process.isRunning { process.terminate(); kill(process.processIdentifier, SIGKILL); return nil }
        return process.terminationStatus
    }

    /// Read only this worktree's HEAD; never infer a parent's branch for an ordinary directory.
    /// Remote worktrees cannot be inspected using the local filesystem.
    static func worktreeBranch(_ path: String?) -> String {
        guard let path else { return "" }
        let dotGit = URL(fileURLWithPath: path).appendingPathComponent(".git")
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &directory) else { return "" }
        let gitDirectory: URL
        if directory.boolValue {
            gitDirectory = dotGit
        } else {
            guard let pointer = try? String(contentsOf: dotGit, encoding: .utf8),
                  pointer.hasPrefix("gitdir: ") else { return "" }
            let target = String(pointer.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDirectory = URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: path, isDirectory: true))
        }
        guard let head = try? String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8),
              head.hasPrefix("ref: refs/heads/") else { return "" }
        return String(head.dropFirst("ref: refs/heads/".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// W179 F：send_message 用哪一家引擎。有模型參數照名字判斷（跟以前一樣）；沒有時先看呼叫端帶的 engine
    /// （副設備送來、Claude 路由沒有 claude- 開頭的參數時），再退回那條上次用的，最後 Claude。
    static func sendMessageEngine(modelArgument: String?, requested: String?, threadEngine: String?) -> ClaudeSidecar.Kind {
        if let explicit = requested.flatMap(ClaudeSidecar.Kind.init(rawValue:)) { return explicit }
        if let modelArgument {
            let lowered = modelArgument.lowercased()
            if lowered.contains("claude") || lowered.hasPrefix("sonnet") || lowered.hasPrefix("opus") || lowered.hasPrefix("fable") { return .claude }
            if lowered.contains("grok") { return .grok }
            return .codex
        }
        return requested.flatMap(ClaudeSidecar.Kind.init(rawValue:))
            ?? threadEngine.flatMap(ClaudeSidecar.Kind.init(rawValue:)) ?? .claude
    }

    /// W179 F：send_message 給這台助理那條、沒指定模型（或帶了副設備在選單明確選的路由）、也沒帶思考強度／速度時，
    /// 交給這台自己的助理規則；其他照舊直接送。
    static func routesToAssistant(isAssistantThread: Bool, modelArgument: String?, assistantRoute: String?,
                                  reasoningEffort: String?, serviceTier: String?) -> Bool {
        isAssistantThread && reasoningEffort == nil && serviceTier == nil && (modelArgument == nil || assistantRoute != nil)
    }

    func callForSelfTest(method: String, params: [String: Any]) throws -> [String: Any] {
        try perform(method: method, params: params)
    }

    #if DEBUG
    /// W183 R7a 審查（Claude）：自測用——remote_hands_* 用測試的驗章（DeviceDispatch）與主機（不開 socket、不碰真的設備金鑰）。
    private var handsRemoteSeam: (dispatch: DeviceDispatch, host: HandsRemote.Host)?
    static func handsRemoteTestBridge(dispatch: DeviceDispatch, host: HandsRemote.Host) -> OSAgentBridge {
        let bridge = OSAgentBridge()
        bridge.handsRemoteSeam = (dispatch, host)
        return bridge
    }

    @MainActor static func chatGPTDispatchTestBridge(model: ChatPageModel, dispatcher: ChatGPTDispatch) -> OSAgentBridge {
        let bridge = OSAgentBridge()
        bridge.model = model
        bridge.chatGPTDispatcher = dispatcher
        return bridge
    }

    /// W180 E4 自測：接到指定 ChatPageModel 的橋（不開 socket）。
    static func distillTestBridge(model: ChatPageModel) -> OSAgentBridge {
        let bridge = OSAgentBridge()
        bridge.model = model
        return bridge
    }

    /// W180 E4 自測：跟 socket 上同一套——認人、處理、錯誤用 `String(describing:)` 轉字串——回一整個回應，只是不經過 socket。
    /// 要在背景執行緒呼叫（寫入完要回主執行緒存結果）。
    func respondForSelfTest(caller: OSSocketCaller, request: Data) -> Data {
        let object = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any] ?? [:]
        let method = object["method"] as? String ?? ""
        let params = object["params"] as? [String: Any] ?? [:]
        let response: [String: Any]
        if !Self.allows(caller: caller, method: method, params: params, staging: false) {
            response = ["ok": false, "error": "caller_not_trusted"]
        } else if case .externalAI = caller {   // W183 R1b：跟 socket 上一樣走 HandsService（不綁對話）
            response = Self.handsResponse(method: method, params: params)
        } else {
            do { response = ["ok": true, "result": try perform(method: method, params: params,
                context: method == "sandbox_dispatch" ? RequestContext(boundThread: caller.boundThread, isAppOrSSH: caller == .app || caller == .ssh, isSSH: caller == .ssh) : ChatGPTDispatch.methods.contains(method) ? RequestContext(boundThread: caller.boundThread) : RequestContext())] }
            catch { response = ["ok": false, "error": DeviceFleetReason.code(error) ?? String(describing: error)] }
        }
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
    }
    #endif

    func stopBackgroundJobs() { backgroundJobs?.stopAll() }

    private static let remoteMethods: Set<String> = [
        "distill_open", "distill_get", "distill_edit", "distill_write",   // W180 E4
        "assistant_append_offline",   // W182 R5
        "get_document",
        "transcript",
        "send_message",
        "send_message_with_options",
        "new_thread",
        "stop_thread",
        "push_thread",
        "pull_thread",
    ]
    private static let iso8601: ISO8601DateFormatter = ISO8601DateFormatter()

    private static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        #if DEBUG
        Self.fixtureJSON?()
        #endif
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }

    private static func decode<T: Decodable>(_ value: Any) throws -> T {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw BridgeError.invalidParams
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            T.self,
            from: JSONSerialization.data(withJSONObject: value))
    }

    private static let documentFingerprintLock = NSLock()
    private static var documentFingerprints: [(document: LiveDocumentRecord, hash: String)] = []
    static func documentsEqual(
        _ lhs: LiveDocumentRecord,
        _ rhs: LiveDocumentRecord
    ) -> Bool {
        documentFingerprintLock.lock(); defer { documentFingerprintLock.unlock() }
        if lhs == rhs { return true }
        // The persisted ISO dates omit fractions; structural equality alone would rewrite every poll.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        func fingerprint(_ document: LiveDocumentRecord) -> String? {
            if let cached = documentFingerprints.first(where: { $0.document == document }) { return cached.hash }
            guard let data = try? encoder.encode(document) else { return nil }
            let hash = DeviceDispatch.hash(data)
            documentFingerprints.append((document, hash))
            if documentFingerprints.count > 2 { documentFingerprints.removeFirst() }
            return hash
        }
        guard let left = fingerprint(lhs), let right = fingerprint(rhs) else { return false }
        return left == right
    }

    @MainActor
    private static func snapshot(_ live: any LiveEngineAPI) -> LiveDocumentRecord {
        var snapshot = live.doc
        for index in snapshot.threads.indices {
            snapshot.threads[index].messages = live
                .transcript(for: snapshot.threads[index].id)
                .map(LiveMessageRecord.init)
        }
        return snapshot
    }

    private func onMain<T>(_ body: @escaping @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    private func onMainThrowing<T>(_ body: @escaping @MainActor () throws -> T) throws -> T {
        if Thread.isMainThread { return try MainActor.assumeIsolated(body) }
        return try DispatchQueue.main.sync { try MainActor.assumeIsolated(body) }
    }
}

// MARK: - W180 E3b：助理提議專案分類（邏輯在 ProjectClassification.swift）
// project_overview（唯讀：標題、最後活動、訊息數）、project_suggest（只建立提案）只給 App 與引擎；
// project_proposal_decide 給已配對設備（SSH）用提案 id 決定，引擎不能決定（只有使用者能核准）。
extension OSAgentBridge {
    fileprivate func projectClassification(method: String, params: [String: Any], boundThread: UUID?) throws -> [String: Any] {
        switch method {
        case "project_overview":
            guard Set(params.keys).isSubset(of: ["callerThreadID"]) else { throw ProjectClassificationError.invalidParams }
            let input: (LiveDocumentRecord, Set<UUID>)? = onMain { [weak self] in
                guard let live = self?.model?.localLiveForBridge else { return nil }
                return (live.doc, ProjectClassification.running(live))
            }
            guard let input else { throw ProjectClassificationError.unavailable }
            return ProjectClassification.overview(doc: input.0, running: input.1)
        case "project_suggest":
            let caller = (params["callerThreadID"] as? String).flatMap(UUID.init(uuidString:)) ?? boundThread
            let input: (LiveDocumentRecord, Set<UUID>, URL)? = onMain { [weak self] in
                guard let live = self?.model?.localLiveForBridge else { return nil }
                return (live.doc, ProjectClassification.running(live), live.store.url.deletingLastPathComponent())
            }
            guard let input else { throw ProjectClassificationError.unavailable }
            // 寫提案檔在 bridge 佇列上（有鎖），不在主執行緒。
            return try ProjectClassification.suggest(params: params, caller: caller, doc: input.0, running: input.1,
                                                     store: ProjectClassificationStore(root: input.2))
        default:
            guard boundThread == nil else { throw ProjectClassificationError.enginesCannotDecide }
            return try onMainThrowing { [weak self] in
                guard let live = self?.model?.localLiveForBridge else { throw ProjectClassificationError.unavailable }
                return try ProjectClassification.decide(params: params, boundThread: boundThread, engine: live)
            }
        }
    }
}

// MARK: - W180 E2：overview_snapshot
// 已配對設備（SSH 轉進來）讀這台的全域狀態摘要：待核准的討論串、每條串的 W170 目標進度、背景工作、
// 終端機分頁、Island 請求標題。唯讀，只回白名單欄位（AssistantOverviewWire）：沒有訊息內容、cwd、路徑、
// 主機、使用者、指紋。os_status／goal_index 維持不給 SSH（W179 C1）。
extension OSAgentBridge {
    fileprivate func overviewSnapshot(params: [String: Any]) throws -> [String: Any] {
        guard Set(params.keys).isSubset(of: ["callerThreadID"]) else { throw BridgeError.invalidParams }
        let input: (LiveDocumentRecord, Set<UUID>, [OverviewCLI], [String])? = onMain { [weak self] in
            guard let model = self?.model, let live = model.localLiveForBridge else { return nil }
            return (live.doc, live.pendingPermissionThreadIDs,
                    (model.cliSessionStore?.sessions ?? []).map(OverviewCLI.from),
                    IslandNotice.shared.pendingRequestTitles)
        }
        guard let input else { throw BridgeError.unsupportedMethod }
        let (doc, pending, cli, requestTitles) = input
        let jobs = try awaitBot { await self.backgroundJobSnapshot(includeLastLine: false) }
        // 目標逐檔讀：在 bridge 佇列上跑，不在主執行緒；只取摘要（不帶原話、證據）。
        var goals: [UUID: OverviewGoalSummary] = [:]
        for thread in doc.threads where !thread.isArchived {
            if let summary = OverviewGoalSummary.from(ThreadGoalStore.shared.list(thread.id)) { goals[thread.id] = summary }
        }
        let titles = Dictionary(doc.threads.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        var snapshot = AssistantOverviewWire.snapshot(doc: doc, pending: pending, goals: goals,
                                              jobs: jobs.map { OverviewJob.from($0, threadTitles: titles) },
                                              cli: cli, requestTitles: requestTitles, now: Date())
        // W180 E3b：分類建議（白名單：提案 id、討論串標題、目標名、理由）；提案檔在 bridge 佇列上讀。
        let classification: (URL, Set<UUID>)? = onMain { [weak self] in
            guard let live = self?.model?.localLiveForBridge else { return nil }
            return (live.store.url.deletingLastPathComponent(), ProjectClassification.running(live))
        }
        if let classification {
            snapshot[ProjectClassificationWire.key] = ProjectClassificationWire.rows(ProjectClassification.cards(
                store: ProjectClassificationStore(root: classification.0), doc: doc, running: classification.1))
        }
        return snapshot
    }
}
