import AppKit
import Combine
import Darwin
import Foundation

// W183 R1／R1b：ChatGPT 手腳在 App 這一端的入口（os.sock 的 hands_auth／hands_tools／hands_call，呼叫者一定是 `.externalAI`）。
//
// - 關口身分不綁對話（接口 v2 §1）：誰能碰什麼一律看 token 對應的 grant（v2 §4、v3 V9）；任何 thread 參數都忽略。
// - 每次呼叫都重查：開關、這台是不是指定的那台、token→grant、等級（grant 核准的跟設定上限取小）、允許的專案（設定 ∩ grant）。
// - 回傳照 fixtures/wire.json：成功 `result`；錯誤 `{code, message}`（OAuth／協定錯誤）；工具錯誤是 `isError: true` 的結果。
// - 每個 grant 有速率與同時數上限；每個工作區一次只做一件會改東西的事；指令另有每 grant 2 個、全域 3 個上限（HandsJobs）。
// - 每次工具呼叫在房間記一列（只存遮蔽過的摘要、標「外部資料」與 grant）。
// - 撤銷、關開關、降級、移除專案：取消執行中的工作、鎖住工作區（保留不刪）（v2 §4、v3 V10）。
// - 不開放派工、設備、終端機、對話寫入、直接寫正式記憶；W225 只加授權對話讀取與新專案建立。

/// 沙盒、保護路徑、小幫手要用的位置（測試可以換成暫存資料夾）。
struct HandsRuntime {
    var paths: HandsPaths
    var home: String
    var entryRoot: String?
    /// ~/Library/Application Support/tatwo2（App 自己的資料；沙盒一律拒）。
    var appSupport: String
    var fsopPath: String?
    var nodePath: String?
    /// node 是 App 內附的（單一執行檔）：沙盒裡的指令也能用。Homebrew 的（只有 DEBUG 自測）只給檔案小幫手（V2）。
    var nodeBundled: Bool
    var extraDeniedDirectories: [String] = []
    var environment: [String: String]
    /// W183 R6c：ChatGPT 的工作區要放的入口（`<入口>/chatgpt/workspaces`，見 HandsWorkspaceRoot.swift）。nil＝放 App Support（照舊）：
    /// 自測、staging、source test 一律 nil；外接碟沒掛上、不可寫就在用的當下退回 App Support。
    var workspaceEntry: String? = nil

    static func current(paths: HandsPaths = .default, environment: [String: String] = ProcessInfo.processInfo.environment) -> HandsRuntime {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let entry = TatwoEntry(environment: environment).root.path
        let live = environment["TATWO2_LIVE_ROOT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/tatwo2/live")
        let node = nodeExecutable(environment: environment)
        return HandsRuntime(paths: paths, home: HandsPath.realpath(home) ?? home, entryRoot: HandsPath.realpath(entry) ?? entry,
                            appSupport: HandsPath.canonical(live.deletingLastPathComponent().path), fsopPath: fsopScript(),
                            nodePath: node?.path, nodeBundled: node?.bundled ?? false, environment: environment,
                            workspaceEntry: ChatGPTHandsService.allowedToRun(environment: environment) ? entry : nil)   // W183 R6c
    }

    /// 打包版：App 裡的 Resources/chatgpt-hands/fsop.mjs。開發與自測（DEBUG）：原始碼樹裡的同一支。
    static func fsopScript() -> String? {
        if let resources = Bundle.main.resourcePath {
            let bundled = resources + "/chatgpt-hands/fsop.mjs"
            if FileManager.default.fileExists(atPath: bundled) { return HandsPath.realpath(bundled) }
        }
        #if DEBUG
        var source = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { source = source.deletingLastPathComponent() }
        let candidate = source.appendingPathComponent("Engines/chatgpt-hands/fsop.mjs").path
        if FileManager.default.fileExists(atPath: candidate) { return HandsPath.realpath(candidate) }
        #endif
        return nil
    }

    /// V2：App 內附的 node。只有 DEBUG（自測、原始碼跑）才退回 Homebrew 的，而且只給檔案小幫手。
    static func nodeExecutable(environment: [String: String]) -> (path: String, bundled: Bool)? {
        let bundled = EnginePaths(environment: environment).runtimeBinDirectory.appendingPathComponent("node").path
        if FileManager.default.isExecutableFile(atPath: bundled), let real = HandsPath.realpath(bundled) { return (real, true) }
        #if DEBUG
        for candidate in ["/opt/homebrew/bin/node", "/usr/local/bin/node"] where FileManager.default.isExecutableFile(atPath: candidate) {
            if let real = HandsPath.realpath(candidate) { return (real, false) }
        }
        #endif
        return nil
    }

    /// Homebrew 的 node 會載入 opt/ 底下的程式庫：開整個前綴（只給 DEBUG 自測的檔案小幫手）。
    static func brewRoot(forNode node: String) -> String {
        for prefix in ["/opt/homebrew", "/usr/local"] where node.hasPrefix(prefix + "/") { return prefix }
        return (node as NSString).deletingLastPathComponent
    }

    /// 沙盒裡一律拒絕的資料夾；也是「專案不能包含或位在這些裡面」的依據。
    var deniedDirectories: [String] {
        var list = [".ssh", "Library/Keychains", ".codex", ".claude", ".config/gh", ".cloudflared", ".aws", ".gnupg",
                    ".docker", ".kube", ".gcloud", ".config/gcloud", ".azure", ".password-store"].map { home + "/" + $0 }
        list.append(appSupport)
        if let entryRoot { list.append(entryRoot + "/memory") }
        for key in ["CODEX_HOME", "CLAUDE_CONFIG_DIR", "TATWO2_ENGINES_ROOT", "TATWO2_LIVE_ROOT"] {
            if let value = environment[key], value.hasPrefix("/") { list.append(value) }
        }
        list += paths.privateAreas.map(\.path)
        list += extraDeniedDirectories
        return Self.unique(list.map(HandsPath.canonical))
    }

    var deniedFiles: [String] {
        var list = [".netrc", ".git-credentials", ".npmrc", ".pypirc", ".claude.json", ".gitconfig"].map { home + "/" + $0 }
        if let entryRoot { list += [entryRoot + "/user.md", entryRoot + "/device.json"] }
        return Self.unique(list.map(HandsPath.canonical))
    }

    /// 專案能不能用：不能是（或包含）家目錄、入口資料夾、上面那些秘密、手腳自己的資料夾；不能在 ~/Library 或秘密資料夾裡；
    /// 不能在網路磁碟或雲端同步資料夾。
    func folderProblem(_ realPath: String) -> String? {
        let handsRoot = HandsPath.canonical(paths.root.path)
        let containsForbidden = deniedDirectories + deniedFiles + [home, handsRoot] + (entryRoot.map { [$0] } ?? [])
        if containsForbidden.contains(where: { HandsPath.isWithin($0, realPath) }) { return "folder_contains_protected_data" }
        // W183 R6c：入口的 chatgpt/（ChatGPT 自己的工作區）不能再被當成專案。
        let chatgptFolders = [entryRoot, workspaceEntry].compactMap { $0 }.map { (HandsPath.realpath($0) ?? $0) + "/" + HandsWorkspaceRoot.folderName }
        let insideForbidden = deniedDirectories + [home + "/Library", handsRoot] + chatgptFolders
        if insideForbidden.contains(where: { HandsPath.isWithin(realPath, $0) }) { return "folder_inside_protected_area" }
        // W183 R6c 審查：大小寫變體、別名也算（共用判定：真實路徑＋不分大小寫＋檔案系統身分）。
        if ExternalWorkspacePolicy.contains(realPath, entries: [entryRoot, workspaceEntry].compactMap { $0 }) { return "folder_inside_protected_area" }
        return HandsPath.storageProblem(realPath, home: home)
    }

    private static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }
}

final class HandsService: @unchecked Sendable {
    /// W183 R8c：正式的這一份接上 ChatGPT build（啟用許可、grant 綁定、範圍上限；HandsBuildSync.swift 的 attachBuild）。
    static let shared: HandsService = {
        let service = HandsService()
        service.attachBuild()
        return service
    }()

    /// W183 R8c（GPT-6 必改 2）：這台的 ChatGPT build 啟用許可。沒有（信封過期＝太久連不到主設備、或沒勾這台）＝安全暫停：
    /// 工具不收、配對不開；grant 不撤銷（明確關掉才撤銷）。nil＝不核（自測的單機世界）。
    var permitCheck: (() -> Bool)?
    /// W183 R8c：ChatGPT build 給這台的等級與專案。W183 R10：等級＝這台的有效等級（中央設定，不再跟本機取小）；
    /// 專案那一份不再用（全部可見）。nil＝沒接 ChatGPT build（自測的單機世界：等級照本機設定）。
    var scopeCap: (() -> (level: Int, projects: Set<String>)?)?

    let paths: HandsPaths
    let settings: HandsSettingsStore
    let auth: HandsAuth
    var runtime: HandsRuntime
    let workspaceStore: HandsWorkspaceStore
    let jobs: HandsJobs
    let requests: HandsRequestLedger
    let roomJournal: HandsRoomJournal
    /// 正式記憶與收件匣（自測換成 staging 的入口）。
    var memoryStore: TatwoMemoryStore = .shared
    /// 測試用：強制這台的設備 id（nil＝讀 device.json）。
    var deviceIDOverride: String?
    /// 測試用：交件的 Island 通知改成記錄。
    var noticeSink: (@MainActor (String, String) -> Void)?
    #if DEBUG
    @MainActor var computerUseForTesting: HandsComputerUse?
    /// W183 R7a 自測：主機上的專案（id、名稱、資料夾）；nil＝讀 Coder 的專案清單（HandsConnectScope.swift 的 allProjectRecords）。
    var projectsOverride: (() -> [(UUID, String, String)])?
    /// W183 R10 第三輪自測：分類算完、發布之前停一下（參數＝那一次讀清單的序號；自測用它讓舊的計算晚到）。
    var classifyGate: ((UInt64) -> Void)?
    /// W183 R10 第三輪自測：交件的分類檢查之後、發布（update-ref）之前停一下（自測在這時候改名）。
    var submitGate: (() -> Void)?
    /// W183 R10 第四輪自測：交件在提交序列裡做完最後一次檢查之後、update-ref 之前停一下（自測在這時候改名）。
    var submitFinalGate: (() -> Void)?
    /// W183 R11 最後一輪自測（GPT-6 R11c 審查 2）：待完成的封頂標記（level-cap-pending.json）寫不進去（不真的弄壞磁碟）。
    var failCapMarkerWritesForTesting = false
    var projectDirectoryGate: ((Int) -> Void)?
    #endif

    private weak var model: ChatPageModel?
    private let projectCreationLock = NSLock()
    private var projectCreationTimes: [String: [TimeInterval]] = [:]
    /// W183 R10 底線 B：最近一次讀 Coder 專案清單時看到的交易實盤類專案（id 大寫）。發布、啟動前的最後一次檢查在鎖裡、不准碰主執行緒，
    /// 就看這一份；工具入口另外每次都即時讀（HandsTools.floorProblem）。
    private let floorLock = NSLock()
    private var tradingProjectIDs: Set<String> = []
    /// W183 R10 第二輪（GPT-6 7）：分類的版本（變了就加一；交件前核對）。
    private var tradingVersionValue: UInt64 = 0
    /// W183 R10 第三輪（GPT-6 6）：專案清單每讀一次（或主執行緒看到它變了）就發一個遞增的序號；分類只在它算的那一份比已經發布的新時
    /// 才發布（晚到的舊計算不發布）。最新讀到的那一份跟已經發布的不一樣＝待分類（受影響的寫入先拒，classificationPending）。
    private var listSeq: UInt64 = 0
    private var latestListDigest: String?
    private var publishedSeq: UInt64 = 0
    private var publishedListDigest: String?
    /// DEBUG 的專案清單替身：讀與發序號排成一條（正式版在主執行緒讀，本來就是一條）。
    private let listReadLock = NSLock()
    /// W183 R10 第四輪（GPT-6 發現 3）：清單修訂（發序號、記最新的一份＝待分類）與交件的最後一次檢查＋update-ref 排在同一個序列裡。
    /// 鎖的順序：publicationLock → commitSequence → floorLock。拿著它的人不等主執行緒（交件那一段只跑 git 與寫紀錄）。
    private let commitSequence = NSLock()
    private let limiterLock = NSLock()
    private var inFlight: [String: Int] = [:]
    private var callTimes: [String: [TimeInterval]] = [:]
    private var workspaceBusy: Set<String> = []
    /// W183 R1b：工作區用量的快取（寫檔前的上限檢查用；指令跑完會重量）。
    private var usage: [UUID: (bytes: Int64, at: TimeInterval, pending: Int64)] = [:]
    /// W183 R1b：正在交件的工作區（交件期間任何新的寫入者都不准啟動，已經排隊的在啟動前也會被擋）。
    private var workspaceSubmitting: Set<String> = []
    /// W183 R1b：「最後一次授權檢查＋發布」（交件的 update-ref、開工作區的紀錄）與撤銷收尾互斥：
    /// 撤銷要嘛先發生（發布前的檢查就拒），要嘛等發布做完再鎖工作區。裡面不准碰主執行緒。
    private let publicationLock = NSRecursiveLock()
    private var bursts: [UUID: (turn: String, at: TimeInterval)] = [:]
    /// 每個工作區進行中的呼叫（只在主執行緒碰：狀態的計算和寫入一起在主執行緒做，不會被別的呼叫插隊）。
    private var roomActivity: [UUID: RoomActivity] = [:]
    private var terminationObserver: NSObjectProtocol?
    /// W183 R10 第二輪（GPT-6 7）：盯著 Coder 的專案清單（只在主執行緒碰）：上一次看到的（id、名稱、資料夾）。
    private var projectWatch: AnyCancellable?
    private var lastProjectDigest: String?

    static let perGrantConcurrency = 4
    static let perGrantPerMinute = 60
    static let projectCreationLimits: [(window: TimeInterval, count: Int)] = [(3600, 10), (86400, 30)]
    var projectCreationNow: () -> TimeInterval = { HandsMonotonic.now() }
    /// 每個 grant 每分鐘最多幾次工具呼叫（自測可以調）。
    var callsPerMinute = HandsService.perGrantPerMinute
    /// V10：工作區＋暫存區比開的時候多出這麼多就收掉並鎖住（自測可以調小）。
    var diskQuotaBytes: Int64 = HandsService.diskQuota
    /// W183 R1b：手腳資料夾所在的磁碟剩不到這麼多＝不開工作區、不寫檔、不跑指令；跑到一半低於一半＝收掉（自測可以調大）。
    var diskLowWaterBytes: Int64 = HandsService.diskLowWater
    static let diskLowWater: Int64 = 2 * 1024 * 1024 * 1024

    /// 工作區房間 → 用哪個 HandsService（自測用自己的；畫面的施工卡照它找候選版本）。
    private static let attachmentLock = NSLock()
    private static var attachments: [ObjectIdentifier: WeakService] = [:]
    private final class WeakService { weak var value: HandsService?; init(_ value: HandsService) { self.value = value } }

    init(paths: HandsPaths = .default, auth: HandsAuth? = nil, runtime: HandsRuntime? = nil) {
        self.paths = paths
        self.settings = HandsSettingsStore(paths: paths)
        self.auth = auth ?? HandsAuth(url: paths.authFile)
        self.runtime = runtime ?? HandsRuntime.current(paths: paths)
        self.workspaceStore = HandsWorkspaceStore(url: paths.workspacesFile)
        self.jobs = HandsJobs(paths: paths)
        self.requests = HandsRequestLedger(directory: paths.requestsDir)
        self.roomJournal = HandsRoomJournal(url: paths.appDir.appendingPathComponent("chatgpt-room.json"))
        self.auth.onGrantsRevoked = { [weak self] ids, reason in self?.grantsRevoked(ids, reason: reason) }
    }

    @MainActor func attach(model: ChatPageModel) {
        self.model = model
        Self.attachmentLock.lock(); Self.attachments[ObjectIdentifier(model)] = WeakService(self); Self.attachmentLock.unlock()
        // W183 R10 第二輪（GPT-6 7；主導裁決「專案改名或新增時立刻更新分類版本，受影響的執行中工作取消」）：引擎一改（ChatPageModel 的
        // engine.onChange 把文件交給畫面）就看專案清單變了沒；變了（改名、新增、換資料夾）＝背景重算交易分類——新變成交易類的專案，
        // 跑著的長工作與 run_command 當下取消。不等下一次有人讀清單（長工作的監看、工具入口、交件前另外還會重讀）。
        lastProjectDigest = nil
        projectWatch = model.$document.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.projectListMayHaveChanged() }
        }
        guard terminationObserver == nil else { return }
        // App 結束：手腳還在跑的全部收掉（沙盒行程是 App 直接開的，不在 sidecar 的收尾清單）。
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            HandsSandbox.terminateAll()
        }
        // 上次 App 結束（或當掉）留下的手腳行程：照 marks/hands 收掉。
        let marks = paths.marksDir.path
        DispatchQueue.global(qos: .utility).async { _ = HandsSandbox.sweepLeftovers(marksDirectory: marks) }
    }

    /// 專案清單（id、名稱、資料夾）跟上一次不一樣＝背景重算分類（重算會回主執行緒讀清單、可能收掉行程：不在主執行緒同步做）。
    @MainActor private func projectListMayHaveChanged() {
        guard let engine else { return }
        let list = engine.doc.projects.filter { $0.id != engine.doc.assistantProjectID }.map { ($0.id, $0.name, $0.workdir) }
        let digest = Self.projectListDigest(list)
        guard digest != lastProjectDigest else { return }
        lastProjectDigest = digest
        // W183 R10 第三輪（GPT-6 6）：變了的那一刻就記成最新的一份（待分類：受影響的寫入先拒），背景算完、比已經發布的新才發布。
        noteListRead(digest)
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.refreshTradingClassification() }
    }

    static func attached(to model: ChatPageModel) -> HandsService {
        attachmentLock.lock(); defer { attachmentLock.unlock() }
        return attachments[ObjectIdentifier(model)]?.value ?? .shared
    }

    // MARK: - os.sock 入口

    @MainActor lazy var sandboxLane = HandsSandboxLane(service: self)

    func handle(method: String, params raw: [String: Any]) throws -> [String: Any] {
        var params = raw
        params["callerThreadID"] = nil   // 接口 v2 §1：關口不綁對話，thread 參數一律忽略
        params["_threadID"] = nil
        // W183 R10：工具清單、呼叫、授權都照有效設定（中央設定的等級＋這台全部專案；再 ∩ grant）。取代 W183 R8 整合審查的
        //「本機核准 ∩ 中央上限」：不用到主機再核准，面板一改、信封一到就生效；中央收窄照樣立刻生效（跟之前一樣不看本機存沒存成）。
        let current = effectiveSettings()
        switch method {
        case "hands_auth":
            guard let op = params["op"] as? String else { throw HandsWireError.invalidRequest("op") }
            if op == "check" {
                // check：關掉、不是這台＝token 一律無效（fixtures：result_invalid）。W183 R8c：暫停（沒有啟用許可）也一樣。
                guard current.enabled, deviceAllowed(current), permitCheck?() ?? true else { return ["ok": false] }
            } else {
                guard current.enabled, permitCheck?() ?? true else { throw HandsWireError.disabled }
                guard deviceAllowed(current) else { throw HandsWireError.wrongDevice }
            }
            // W183 R6b（審查）：開交易、送配對碼、換 token 之前都核一次進行中 attempt 的世代、範圍、期限；變了＝這個 attempt 先取消（這一步就做不成）。
            if ["authorize_begin", "authorize_submit", "token"].contains(op) { HandsConnectHost.attached(to: self)?.validateBeforeAuthorize() }
            let scope = op == "authorize_begin" ? grantScope(current) : HandsGrantScope(level: current.level, projects: [], memory: "")
            // W183 R8c（GPT-6 必改 5）：App 端精確核 resource＝這台的 `https://<網址>/mcp`。
            let resource = HandsGatewayLaunch.validHost(current.publicHost).map { "https://\($0)/mcp" }
            let result = try auth.handle(op: op, params: params, context: .init(callbacks: current.effectiveCallbacks, levelCap: current.level,
                                                                                scope: scope, resource: resource))
            if op == "register_client" { HandsConnectHost.attached(to: self)?.noteRegistered() }   // W183 R6b：卡在哪段的診斷
            return result
        case "hands_tools":
            guard Set(params.keys).isSubset(of: ["access_token"]) else { throw HandsWireError.invalidRequest("unexpected field") }
            let grant = try authorized(params, current)
            // W183 R6b 審查：進行中 attempt 的 grant 用 /mcp 之前再核世代、範圍、期限（不對＝取消並撤銷，這一次就不給工具）。
            guard HandsConnectHost.attached(to: self)?.admit(grantID: grant.grantID) ?? true else { throw HandsWireError.unauthorized }
            let level = min(grant.grantLevel, current.level)
            defer { HandsConnectHost.attached(to: self)?.noteMCP(grantID: grant.grantID) }   // W183 R6b：這個 grant 的 /mcp 成功（連線意圖的成功證據）
            return ["level": level, "tools": (grant.sandboxDeviceID == nil ? HandsTools.catalog(level: level) : HandsSandboxLane.tools).map(\.descriptor)]
        case "hands_call":
            guard Set(params.keys).isSubset(of: ["access_token", "name", "arguments", "request_id"]) else {
                throw HandsWireError.invalidRequest("unexpected field")
            }
            let grant = try authorized(params, current)
            // W183 R6b 審查：擁有者還沒確認（核對 Pod 帳號）的暫時 grant 不能呼叫工具（只能拿工具清單）；請它稍後再試。
            if grant.provisional {
                // W333：重連沿用舊連接器時 ChatGPT 帶著舊工具清單直接呼叫、不再拿清單；這次 grant 的呼叫（核過世代、範圍、期限）
                // 一樣算「ChatGPT 拿著這次的 token 來了」。工具照樣不給，轉正仍要擁有者的 Pod 確認。
                guard HandsConnectHost.attached(to: self)?.admit(grantID: grant.grantID) ?? true else { throw HandsWireError.unauthorized }
                HandsConnectHost.attached(to: self)?.noteMCP(grantID: grant.grantID)
                throw HandsWireError.rateLimited
            }
            guard let name = params["name"] as? String, name.utf8.count <= 64 else { throw HandsWireError.invalidRequest("name") }
            if params["arguments"] != nil, params["arguments"] as? [String: Any] == nil, !(params["arguments"] is NSNull) {
                throw HandsWireError.invalidRequest("arguments")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            var requestID: String?
            if let raw = params["request_id"], !(raw is NSNull) {
                guard let value = raw as? String, HandsRequestLedger.validID(value) else { throw HandsWireError.invalidRequest("request_id") }
                requestID = value
            }
            try admit(grant.grantID)
            defer { release(grant.grantID) }
            if grant.sandboxDeviceID != nil || HandsSandboxLane.names.contains(name) {
                let access = params["access_token"] as? String ?? ""
                let key = try onMain { Result { try self.sandboxLane.reserve(name, arguments, requestID: requestID, access: access, authorized: grant) } }.get()
                defer { self.requests.complete(key, text: "沙盒請求已使用", isError: false) }
                var checked: [ChangeProposalStore.File]?, sent = arguments
                if grant.sandboxDeviceID != nil, name == "sandbox_post_result", let patch = arguments["patch"] as? String, !patch.isEmpty {
                    do { let cwd = try onMain { Result { try self.sandboxLane.patchTarget(access, arguments) } }.get(); checked = try ChangeProposalStore.check(patch, cwd: cwd) }
                    catch HandsToolError.invalid(let reason) where reason.hasPrefix("patch_does_not_apply") {
                        // W348：沙盒工作時專案改了、補丁套不上，不算拒絕（拒絕會讓沙盒停機、這串什麼都看不到）：改成只有報告的交件，補丁原文附在報告裡。
                        let report = arguments["report"] as? String ?? "", note = "\n\n（補丁套不上目前的專案，沒有套用；原文附在下面，只供參考。）\n"
                        sent["patch"] = ""
                        sent["report"] = report + note + String(decoding: Data(patch.utf8.prefix(max(0, 204_000 - report.utf8.count - note.utf8.count))), as: UTF8.self)
                    }
                    catch { return mcp(String(describing: error), isError: true) }
                }
                let text = name == "sandbox_post_result" ? HandsSandboxLane.resultText(report: sent["report"] as? String ?? "", artifacts: sent["artifacts"] as? [String: String] ?? [:]) : nil
                return try onMain { Result { try self.sandboxLane.call(name, sent, access: access, checked: checked, authorized: grant, text: text) } }.get()
            }
            return try call(name: name, arguments: arguments, requestID: requestID, grant: grant, settings: current)
        default:
            throw HandsWireError.invalidRequest("method")
        }
    }

    private func authorized(_ params: [String: Any], _ current: HandsSettings) throws -> HandsGrantAccess {
        guard current.enabled, deviceAllowed(current), permitCheck?() ?? true else { throw HandsWireError.unauthorized }   // W183 R8c：暫停＝不收
        guard let access = params["access_token"] as? String, let grant = auth.grant(forAccess: access) else {
            throw HandsWireError.unauthorized
        }
        if let device = grant.sandboxDeviceID, !onMain({ self.sandboxLane.allowed(device) }) { throw HandsWireError.unauthorized }
        return grant
    }

    /// W183 R10：這台實際生效的設定＝中央設定（ChatGPT build 給這台的等級；scopeCap）＋這台所有能當專案的（allProjects）。
    /// 不再 ∩ 本機的 allowed_project_ids（HandsSettings.centralized）。
    /// W183 R11（GPT-6 R11 審查 1，高：「自動遷移會讓曾經被降級的舊 L2 grant 恢復」）：中央等級一變，先把現有的 grant 封頂再讓它生效
    ///（levelGuard）——收窄：grant 本身也降（寫進授權檔；之後再調高也回不去）；調高：現有的 grant 封頂在調高前的等級，只有之後按［連線］、
    /// 看過確認卡核准的新 grant 拿新的等級。工具清單、呼叫、授權、啟動、發布、回報都先經這裡，所以封頂一定在任何呼叫用到新等級之前。
    /// 只管中央設定（scopeCap 有值）：沒接 ChatGPT build 的單機世界（自測）照舊。
    func effectiveSettings() -> HandsSettings {
        let local = settings.load()
        let cap = scopeCap?()
        let effective = local.centralized(by: cap)
        if cap != nil { levelGuard(central: effective.level, local: local.level) }
        return effective
    }

    /// 這台上一次生效的中央等級（`app/level-watermark.json`，0600）。R11 之前沒有這個檔＝照本機設定裡的等級（reconcile 每次把中央等級
    /// 寫進本機：就是更新前最後套用的那一個；R10 的收窄只停工作、鎖工作區，grant 紀錄還是原本的等級）。
    private let watermarkLock = NSLock()
    private var watermarkLevel: Int?
    /// W183 R11 第二輪（GPT-6 R11b 審查 2，高）：封頂還沒真的做完（存不進去、授權檔也刪不掉）的上限。有值＝一律不收（授權檔記著存檔失敗）、
    /// 不記下新的等級、本機設定的等級不往上改；`app/level-cap-pending.json` 跨重啟記著，下一次（包括重開 App 之後）先照它封頂，存好了才清掉。
    private var capPendingLevel: Int?
    var levelWatermarkURL: URL { paths.appDir.appendingPathComponent("level-watermark.json") }
    var levelCapPendingURL: URL { paths.appDir.appendingPathComponent("level-cap-pending.json") }

    private func levelGuard(central: Int, local: Int) {
        watermarkLock.lock()
        let settled = watermarkLevel == central && capPendingLevel == nil
        watermarkLock.unlock()
        guard !settled else { return }
        // 別的呼叫在這之前看到「還沒定」就會在這裡等：封頂做完、記下新的等級之前，沒有人拿得到新的等級。
        // 不拿 publicationLock：這裡會在 HandsSandbox 的鎖裡被叫（admission）；鎖裡只碰授權檔（capGrants 的撤銷收尾丟到背景）。
        watermarkLock.lock(); defer { watermarkLock.unlock() }
        guard watermarkLevel != central || capPendingLevel != nil else { return }
        // 要封到多低：待完成的上限（跨重啟）、第一次沒有封頂檔＝這台上一次套用的等級（R10 收窄過的 L2 grant 在這裡降成 L1）、
        // 等級變了＝收窄照新的、調高照調高前的。
        var ceiling = capPendingLevel ?? Self.readLevel(levelCapPendingURL)
        let localLevel = min(max(local, 0), HandsSettings.maxLevel)
        let last: Int
        if let known = Self.readLevel(levelWatermarkURL) {
            last = known
            // W183 R11 最後一輪（GPT-6 R11c 審查 2a）：已經有封頂檔、本機設定的等級卻比它低（上一次收窄寫進了本機設定，封頂、刪授權檔、
            // 待完成標記卻都沒存成；重開 App 之後就是這個樣子）＝先照較低的那個封頂：本機設定當補救。
            if localLevel < known { ceiling = min(ceiling ?? localLevel, localLevel) }
        } else {
            last = localLevel
            ceiling = min(ceiling ?? last, last)
        }
        if central != last { ceiling = min(ceiling ?? HandsSettings.maxLevel, min(central, last)) }
        if let ceiling {
            let outcome = auth.capGrants(maxLevel: ceiling)
            guard outcome.safeAcrossRestart else {
                // 存不進去、授權檔也刪不掉：磁碟上還是封頂前的樣子。不記下新的等級（重開 App 會再封頂一次）、留下待完成的上限（跨重啟），
                // 這段期間一律不收（授權檔記著存檔失敗：token 一律不認）。
                // W183 R11 最後一輪（GPT-6 R11c 審查 2a）：待完成標記也寫不進去＝這一輪照樣一律不收（記憶體裡的上限、授權檔的存檔失敗都留著），
                // 磁碟上既有的封頂檔不清（重開 App 時拿它跟本機設定比，照較低的封頂）；記下來給狀態看。
                capPendingLevel = ceiling
                watermarkLevel = nil
                capMarkerProblemValue = writeLevel(ceiling, to: levelCapPendingURL, marker: true)
                    ? nil : "封頂沒存成、待完成的標記也寫不進去：這段期間 ChatGPT 的連線一律不收；磁碟好了會自動再封頂一次"
                return
            }
            if capPendingLevel != nil || FileManager.default.fileExists(atPath: levelCapPendingURL.path) {
                try? FileManager.default.removeItem(at: levelCapPendingURL)
            }
            capPendingLevel = nil
            capMarkerProblemValue = nil
        }
        watermarkLevel = central
        // 封頂已經寫進授權檔（或授權檔已刪）：封頂檔寫不進去只會讓重開 App 時多封一次（照較低的），不會多給；照樣記下這一輪（不重封新的連線）。
        _ = writeLevel(central, to: levelWatermarkURL, marker: false)
    }

    /// W183 R11 最後一輪（GPT-6 R11c 審查 2a）：待完成的封頂標記寫不進去（nil＝沒有這回事；在 watermarkLock 裡改）。
    private var capMarkerProblemValue: String?
    var capMarkerProblem: String? {
        watermarkLock.lock(); defer { watermarkLock.unlock() }
        return capMarkerProblemValue
    }

    /// 封頂還沒做完（跨重啟的標記也算）：updateSettings 不把本機等級往上改。
    var levelCapPending: Int? {
        watermarkLock.lock(); defer { watermarkLock.unlock() }
        return capPendingLevel ?? Self.readLevel(levelCapPendingURL)
    }

    private static func readLevel(_ url: URL) -> Int? {
        guard let data = HandsFiles.readSecure(url, limit: 4096),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let level = (object["level"] as? NSNumber)?.intValue else { return nil }
        return min(max(level, 0), HandsSettings.maxLevel)
    }

    /// W183 R11 最後一輪（GPT-6 R11c 審查 2a）：寫 `{"level": N}`，回有沒有寫成（不再吞掉錯誤）。marker＝待完成的封頂標記（自測可以讓它寫不進去）。
    private func writeLevel(_ level: Int, to url: URL, marker: Bool) -> Bool {
        #if DEBUG
        if marker, failCapMarkerWritesForTesting { return false }
        #endif
        guard let data = try? JSONSerialization.data(withJSONObject: ["level": level]) else { return false }
        do { try HandsFiles.writeAtomically(data, to: url); return true } catch { return false }
    }

    /// 跑著的工作（HandsJobs 每 2 秒看一次）還准不准。nil＝准。W183 R10：等級看中央設定（收窄＝收掉）；專案不再有上限（全部可見），
    /// 換成底線 B——專案變成交易實盤類（例如改了名字）＝會寫會跑的工作收掉。
    func capProblem(level: Int, projectID: UUID?) -> String? {
        if let cap = scopeCap?(), level > cap.level { return "level_lowered" }
        if level > HandsTradingFloor.maxLevel, let projectID, isTradingCached(projectID) { return "project_read_only" }
        return nil
    }

    // MARK: - W183 R10 底線 B（交易實盤類專案最多 L0）

    /// 專案清單的樣子（id、名稱、資料夾；分類只看這些）。主執行緒的觀察與讀清單用同一個算法。
    static func projectListDigest(_ records: [(UUID, String, String)]) -> String {
        records.map { $0.0.uuidString + "\u{1F}" + $0.1 + "\u{1F}" + $0.2 }.joined(separator: "\u{1E}")
    }

    /// 讀到（或主執行緒看到）一份專案清單：發序號、記成最新的一份。回序號。
    @discardableResult
    func noteListRead(_ digest: String) -> UInt64 {
        // W183 R10 第四輪：跟交件的最後一段排在同一個序列：交件做完最後一次檢查之後、update-ref 之前，新的修訂等它做完才生效。
        commitSequence.lock(); defer { commitSequence.unlock() }
        floorLock.lock(); defer { floorLock.unlock() }
        listSeq &+= 1
        latestListDigest = digest
        return listSeq
    }

    /// W183 R10 第四輪：交件的最後一次檢查＋update-ref 在這裡面做（清單修訂排在前或排在後，不會插在中間）。body 不准碰主執行緒。
    func withCommitSequence<T>(_ body: () throws -> T) rethrows -> T {
        commitSequence.lock(); defer { commitSequence.unlock() }
        return try body()
    }

    /// W183 R10 第三輪（GPT-6 6）：最新看到的專案清單還沒有分類結果（剛改名、剛新增、剛換資料夾）：專案的寫入、執行、交件先拒。
    var classificationPending: Bool {
        floorLock.lock(); defer { floorLock.unlock() }
        return latestListDigest != publishedListDigest
    }

    /// DEBUG 的專案清單替身：讀一次並發序號（排成一條）。
    func readOverride(_ source: () -> [(UUID, String, String)]) -> ([(UUID, String, String)], UInt64) {
        listReadLock.lock(); defer { listReadLock.unlock() }
        let list = source()
        return (list, noteListRead(Self.projectListDigest(list)))
    }

    /// 讀到 Coder 的專案清單之後更新分類（HandsConnectScope.allProjectRecords 叫；seq／digest＝那一次讀的序號與樣子）。
    /// W183 R10 第二輪（GPT-6 6、7）：照資料夾的實際身分彙整別名（HandsTradingFloor.classify）；分類變了版本加一；新變成交易類的專案，
    /// 它們工作區裡跑著的工作（長工作、run_command）當下取消。
    /// W183 R10 第三輪（GPT-6 6）：只有比已經發布的新（序號大）才發布——晚到的舊計算丟掉；發布跟交件的 update-ref 用同一把鎖
    ///（publicationLock：分類發布與最後交件排成一條）。
    func noteProjectRecords(_ records: [(UUID, String, String)], seq: UInt64, digest: String) {
        let trading = HandsTradingFloor.classify(records)
        #if DEBUG
        classifyGate?(seq)
        #endif
        publicationLock.lock()
        floorLock.lock()
        guard seq > publishedSeq else {
            floorLock.unlock()
            publicationLock.unlock()
            return
        }
        publishedSeq = seq
        publishedListDigest = digest
        let newly = trading.subtracting(tradingProjectIDs)
        if trading != tradingProjectIDs {
            tradingProjectIDs = trading
            tradingVersionValue &+= 1
        }
        floorLock.unlock()
        publicationLock.unlock()
        if !newly.isEmpty { cancelWork(forProjects: newly) }
    }

    /// W183 R10 第二輪：分類的版本（交件前核對：變了＝不交件）。
    var tradingVersion: UInt64 {
        floorLock.lock(); defer { floorLock.unlock() }
        return tradingVersionValue
    }

    /// W183 R10 第二輪：重新讀一次專案清單（更新分類、取消受影響的工作；會回主執行緒讀清單：不要在鎖裡叫）。回現在的版本。
    @discardableResult
    func refreshTradingClassification() -> UInt64 {
        _ = allProjectRecords()
        return tradingVersion
    }

    /// 這些專案的工作區裡跑著的工作一律取消、行程收掉（工作區不鎖：之後的寫入與執行本來就被底線 B 擋）。
    private func cancelWork(forProjects ids: Set<String>) {
        let affected = Set(workspaceStore.all().filter { ids.contains($0.projectID.uuidString) }.map(\.id))
        guard !affected.isEmpty else { return }
        let marks = HandsPath.realpath(paths.marksDir.path)
        jobs.cancel(where: { affected.contains($0.workspaceID) }, marksDirectory: marks)
        HandsSandbox.terminate(where: { $0.workspace.flatMap(UUID.init(uuidString:)).map(affected.contains) ?? false },
                               workspaces: affected.map(\.uuidString), marksDirectory: marks)
    }

    /// 鎖裡用的（不碰主執行緒）：最近一次看到的清單裡，這個專案是不是交易實盤類。
    func isTradingCached(_ projectID: UUID) -> Bool {
        floorLock.lock(); defer { floorLock.unlock() }
        return tradingProjectIDs.contains(projectID.uuidString)
    }

    /// 專案名、設定的資料夾、真實路徑的資料夾任何一個含關鍵字（只看這一筆；別名彙整看 HandsTradingFloor.classify）。
    static func tradingRecord(_ record: (UUID, String, String)) -> Bool { HandsTradingFloor.matches(record) }

    /// 即時讀（工具入口；會回主執行緒讀專案清單：不要在鎖裡叫）：這個專案是不是交易實盤類（W183 R10 第二輪：含別名——同一個資料夾的
    /// 任一個名字命中都算）。主機自己看 Coder 的清單，不信 ChatGPT 的參數。
    func isTradingProject(_ projectID: UUID) -> Bool {
        refreshTradingClassification()
        return isTradingCached(projectID)
    }

    /// 通道只在一台跑：設定了主機設備，就只有那台收（T12）。
    func deviceAllowed(_ current: HandsSettings) -> Bool {
        guard let host = current.hostDeviceID, !host.isEmpty else { return true }
        let local = deviceIDOverride ?? (try? DeviceIdentityStore.readLocal(entry: TatwoEntry(environment: runtime.environment)))?.deviceID
        return local == host
    }

    /// 開交易當下的範圍（確認卡顯示、grant 拿到的就是這份）。W183 R10：全部可見＝grant 記「全部專案」（新專案自動包含）；
    /// projects 只是當下的清單（給卡片顯示、交易類另外標）。
    func grantScope(_ current: HandsSettings) -> HandsGrantScope {
        let records = current.allProjects ? buildProjectRecords() : projectRecords(Set(current.allowedProjectIDs))
        let projects = records.map { HandsProjectRef(id: $0.0.uuidString, name: $0.1) }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        let readOnly = records.filter { isTradingCached($0.0) }.map { $0.0.uuidString }.sorted()   // W183 R10 第二輪：含別名（上面讀清單時更新過）
        return HandsGrantScope(level: current.level, projects: projects, memory: HandsGrantScope.memoryText(level: current.level),
                               allProjects: current.allProjects, readOnlyProjectIDs: readOnly)
    }

    // MARK: - 速率與同時數（T11）

    private func admit(_ grant: String) throws {
        limiterLock.lock(); defer { limiterLock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        var times = (callTimes[grant] ?? []).filter { now - $0 < 60 }
        guard times.count < callsPerMinute else { callTimes[grant] = times; throw HandsWireError.rateLimited }
        guard (inFlight[grant] ?? 0) < Self.perGrantConcurrency else { throw HandsWireError.rateLimited }
        times.append(now)
        callTimes[grant] = times
        inFlight[grant, default: 0] += 1
    }

    private func release(_ grant: String) {
        limiterLock.lock(); defer { limiterLock.unlock() }
        inFlight[grant] = max((inFlight[grant] ?? 1) - 1, 0)
    }

    // MARK: - W183 R1b：授權檢查（啟動、發布之前的最後一次）

    /// 現在還准不准（每次都重讀：grant 有效、開關開著、這台是主機、等級、專案、工作區沒鎖、沒在交件）。回 nil＝准；否則是原因。
    /// 會在 HandsSandbox 的鎖裡被呼叫：不准碰主執行緒、不准呼叫 HandsSandbox。
    func admissionProblem(grantID: String, level: Int, projectID: UUID?, workspaceID: UUID?, forWrite: Bool,
                          duringSubmit: Bool = false) -> String? {
        // W183 R11（GPT-6 R11 審查 1）：先拿有效設定（中央等級變了＝先封頂），再讀 grant——讀到的一定是封頂之後的等級。
        let current = effectiveSettings()   // W183 R10：啟動、發布前也照有效設定（中央設定的等級＋全部專案）
        guard let grant = auth.grantRecord(grantID), grant.isActive, auth.revocationProblem == nil else { return "grant_revoked" }
        guard current.enabled else { return "hands_off" }
        guard deviceAllowed(current) else { return "wrong_device" }
        if permitCheck?() == false { return "build_paused" }   // W183 R8c：信封過期或沒勾這台＝啟動與發布前也擋
        guard min(grant.level, current.level) >= level else { return "level_lowered" }
        if let projectID {
            // W183 R10：專案全部可見（有效設定不再有清單）；grant 還是只給它自己核准的（舊 grant 的清單照舊、新 grant＝全部）。
            let settingAllows = current.allProjects || current.allowedProjectIDs.contains(projectID.uuidString)
            let grantAllows = grant.allProjects == true || grant.projectIDs.contains(projectID.uuidString)
            guard settingAllows, grantAllows else { return "project_not_allowed" }
            // W183 R10 底線 B：交易實盤類最多 L0（會寫、會跑的啟動與發布一律擋；工具入口已經擋過，這裡是最後一道）。
            if level > HandsTradingFloor.maxLevel, isTradingCached(projectID) { return "project_read_only" }
            // W183 R10 第三輪（GPT-6 6）：專案清單剛變、分類還沒算好＝會寫、會跑的啟動與發布（交件）先拒。
            if level > HandsTradingFloor.maxLevel, classificationPending { return "classification_pending" }
        }
        if forWrite, let workspaceID {
            guard let record = workspaceStore.record(workspaceID), record.grantID == grantID else { return "workspace_not_found" }
            if record.isLocked { return "workspace_locked" }
            if !duringSubmit {
                limiterLock.lock(); let submitting = workspaceSubmitting.contains(workspaceID.uuidString); limiterLock.unlock()
                if submitting { return "workspace_submitting" }
            }
        }
        return nil
    }

    /// 給 HandsSandbox.run 的 admit：啟動前最後一次檢查（跟登記群組同一把鎖）。
    func admission(grantID: String, level: Int, projectID: UUID?, workspaceID: UUID?, forWrite: Bool,
                   duringSubmit: Bool = false) -> () -> String? {
        { [weak self] in
            guard let self else { return "service_gone" }
            return self.admissionProblem(grantID: grantID, level: level, projectID: projectID, workspaceID: workspaceID,
                                         forWrite: forWrite, duringSubmit: duringSubmit)
        }
    }

    /// 發布（交件的 update-ref、開工作區的紀錄）：先重查授權，跟撤銷收尾互斥。body 裡不准碰主執行緒。
    func withPublication<T>(grantID: String, level: Int, projectID: UUID?, workspaceID: UUID?, forWrite: Bool,
                            duringSubmit: Bool = false, _ body: () throws -> T) throws -> T {
        publicationLock.lock(); defer { publicationLock.unlock() }
        if let problem = admissionProblem(grantID: grantID, level: level, projectID: projectID, workspaceID: workspaceID,
                                          forWrite: forWrite, duringSubmit: duringSubmit) {
            throw HandsToolError.invalid("not_authorized_anymore: \(problem)")
        }
        return try body()
    }

    /// 交件期間：禁止新的寫入者（admission 會擋），交件做完（成功或失敗）才解除。
    func beginSubmitting(_ id: UUID) {
        limiterLock.lock(); workspaceSubmitting.insert(id.uuidString); limiterLock.unlock()
    }

    func endSubmitting(_ id: UUID) {
        limiterLock.lock(); workspaceSubmitting.remove(id.uuidString); limiterLock.unlock()
    }

    // MARK: - W183 R1b：磁碟（低水位、每個工作區的上限）

    /// 手腳資料夾所在磁碟的可用空間（讀不到＝0，當作不夠）。
    func freeDiskBytes() -> Int64 {
        var fs = statfs()
        let root = HandsPath.realpath(paths.root.path) ?? paths.root.deletingLastPathComponent().path
        guard statfs(root, &fs) == 0 else { return 0 }
        var free = Int64(fs.f_bavail) * Int64(fs.f_bsize)
        // W183 R6c：工作區在入口的 chatgpt/（mini 是外接碟）：那顆碟也要夠，取小的。
        if case .entry(_, let folder, _) = workspaceLocation(), statfs(folder, &fs) == 0 || statfs((folder as NSString).deletingLastPathComponent, &fs) == 0 {
            free = min(free, Int64(fs.f_bavail) * Int64(fs.f_bsize))
        }
        return free
    }

    /// 磁碟低水位：剩不到 diskLowWaterBytes（加上這次要寫的）就不准。
    func requireDiskRoom(adding bytes: Int64 = 0) throws {
        let free = freeDiskBytes()
        guard free - bytes >= diskLowWaterBytes else {
            throw HandsToolError.invalid("disk_low: the Mac has less than \(diskLowWaterBytes / 1_048_576) MiB free; nothing more is written until the user frees space")
        }
    }

    /// 工作區目前用了多少（上次量的＋之後寫檔的估計）。量一次要走整棵樹：30 秒內、估計的增量不到 64 MiB 就用上次的。
    func quotaCheck(_ workspace: HandsWorkspace, adding bytes: Int64) throws {
        limiterLock.lock(); let cached = usage[workspace.id]; limiterLock.unlock()
        let now = ProcessInfo.processInfo.systemUptime
        var measured: Int64
        var pending: Int64
        if let cached, now - cached.at < 30, cached.pending < 64 * 1024 * 1024 {
            measured = cached.bytes; pending = cached.pending
        } else {
            measured = HandsSandbox.diskUsage([workspace.repo, workspace.scratch]); pending = 0
            limiterLock.lock(); usage[workspace.id] = (measured, now, 0); limiterLock.unlock()
        }
        guard measured != Int64.max, measured + pending + bytes - workspace.record.baselineBytes <= diskQuotaBytes else {
            workspaceStore.lock(where: { $0.id == workspace.id }, reason: "disk_quota_exceeded")
            throw HandsToolError.invalid("workspace_locked: disk_quota_exceeded (more than \(diskQuotaBytes / 1_048_576) MiB over the starting size)")
        }
    }

    func noteWritten(_ workspace: HandsWorkspace, bytes: Int64) {
        limiterLock.lock(); defer { limiterLock.unlock() }
        if var entry = usage[workspace.id] { entry.pending += bytes; usage[workspace.id] = entry }
    }

    func noteMeasured(_ id: UUID, bytes: Int64) {
        limiterLock.lock(); usage[id] = (bytes, ProcessInfo.processInfo.systemUptime, 0); limiterLock.unlock()
    }

    /// 同一個工作區一次只做一件會改東西的事。
    func lockWorkspace(_ id: String) -> Bool {
        limiterLock.lock(); defer { limiterLock.unlock() }
        return workspaceBusy.insert(id).inserted
    }

    func unlockWorkspace(_ id: String) {
        limiterLock.lock(); defer { limiterLock.unlock() }
        workspaceBusy.remove(id)
    }

    // MARK: - 工具呼叫＋房間紀錄

    struct ToolOutput {
        var text: String
        var isError: Bool
        /// 房間那一列的結果摘要（會再遮蔽一次）。
        var summary: String
        /// 這一列要記在哪條（工作區）；nil＝根對話。
        var roomThread: UUID?
        /// 成功改了東西之後房間該是什麼狀態（nil＝idle；交件＝done）。
        var finalStatus: String?
        /// 工作區可能被改過（寫檔成功、指令真的跑了——結束碼不是 0 也算）。沒改到東西的失敗＝false，已交件的房間維持待審。
        var mutated: Bool = false
        var image: [String: Any]? = nil
    }

    /// 這次呼叫的身分與範圍（每次重查）。
    struct CallContext {
        let grant: HandsGrantAccess
        let settings: HandsSettings
        let level: Int
        let landing: HandsProjectLanding
        /// V12：job 一開始就記進 request_id 的占位（進行中重試回 job id）。
        var onJobStarted: ((String) -> Void)?
    }

    /// 房間狀態的事件（呼叫進行中 running、之間 idle；交件 done）。
    enum RoomEvent {
        case begin
        case mutationStarted
        case end(mutated: Bool, final: String?)
    }

    private struct RoomActivity {
        var calls = 0
        var restore = "idle"
        var result: String?
    }

    private func call(name: String, arguments: [String: Any], requestID: String?, grant: HandsGrantAccess,
                      settings current: HandsSettings) throws -> [String: Any] {
        let level = min(grant.grantLevel, current.level)
        guard let tool = HandsTools.tool(named: name), tool.level <= level else { throw HandsWireError.toolNotAllowed }
        do { try HandsTools.check(arguments, tool) }
        catch { return mcp("\(error)", isError: true) }
        // 跨配對的工作區一律視為不存在；先驗擁有者，不能讓落點檢查覆蓋這個錯誤。
        if let raw = arguments["workspace_id"] as? String {
            guard let id = UUID(uuidString: raw), let record = workspaceStore.record(id), record.grantID == grant.grantID else {
                return mcp("workspace_not_found", isError: true)
            }
        }
        let landing: HandsProjectLanding
        do {
            landing = try self.landing(arguments: arguments, grant: grant, settings: current)
            if name.hasPrefix("computer_"), name != "computer_request" {
                let leased = onMain { self.computerUse.landing(grant: grant.grantID, service: self) }
                if let projectID = landing.projectID, projectID != leased.projectID {
                    throw HandsToolError.invalid("project_lease_mismatch")
                }
            }
        } catch {
            return mcp(String(describing: error), isError: true)
        }
        if let problem = admissionProblem(grantID: grant.grantID, level: ["job_status", "job_output", "job_cancel", "computer_stop"].contains(name) ? 0 : tool.level, projectID: landing.projectID,
                                          workspaceID: landing.workspaceID, forWrite: tool.mutates) {
            return mcp(problem, isError: true)
        }
        // V12：（grant、工具名、request_id）原子占位。W183 R1b：只讀的工具不重播舊結果（每次重讀，照現在的授權與「不給 ChatGPT」標記）；
        // 會改東西的工具重播之前，照現在的設定重查參數裡的工作區、專案（範圍縮了就不回舊內容）。
        var ledgerKey: String?
        if let requestID, !tool.readOnly, !name.hasPrefix("computer_") {
            switch try requests.reserve(grant: grant.grantID, tool: name, requestID: requestID, arguments: arguments) {
            case .fresh(let key): ledgerKey = key
            case .done(let text, let isError):
                journal(tool: name, summary: "重試：回傳先前結果", landing: landing, grant: grant.grantID)
                if let problem = replayProblem(arguments: arguments, grant: grant, settings: current) {
                    return mcp("request_replay_refused: \(problem) (access changed since the first attempt)", isError: true)
                }
                return mcp(text, isError: isError)
            case .running(let job):
                journal(tool: name, summary: "重試：工作仍在執行", landing: landing, grant: grant.grantID)
                var status: [String: Any] = ["status": "running"]
                if let job { status["job_id"] = job }
                return mcp(HandsTools.json(status), isError: false)
            case .interrupted:
                journal(tool: name, summary: "先前呼叫已被重啟中斷；未重新執行", landing: landing, grant: grant.grantID)
                return mcp("request_interrupted: the earlier attempt with this request_id was interrupted (TATWO restarted). Check the state, then retry with a new request_id.", isError: true)
            case .conflict:
                throw HandsWireError.requestConflict
            }
        }
        // The project's room gets every call, including calls also linked to a workspace child room.
        let workspace = (arguments["workspace_id"] as? String).flatMap { try? self.workspace($0, grant: grant, settings: current) }
        let target = rootThread(projectID: landing.projectID)
        let callID = UUID(), calledAt = Date()
        let rowID = "hands:" + callID.uuidString
        let auditReady = journal(tool: name, summary: "呼叫中", landing: landing, grant: grant.grantID, id: callID, at: calledAt)
        if !auditReady, name != "computer_stop" {
            let text = "chatgpt_room_unavailable: nothing was done; the host must restore audit storage"
            if let ledgerKey { requests.complete(ledgerKey, text: text, isError: true) }
            return mcp(text, isError: true)
        }
        let context = redactionContext(workspace: workspace)
        // 參數摘要：每個值先遮蔽再截短（先截會把秘密切成規則比不中的半截）。
        let argsSummary = HandsRedactor.clip(HandsTools.summarize(arguments: arguments, tool: name) { HandsRedactor.redact($0, context: context) },
                                             limit: 300)
        let grantTag = String(grant.grantID.prefix(8))
        if let target {
            record(thread: target, rowID: rowID, turn: burstTurn(target), text: rowText(name, argsSummary, "…", grant: grantTag),
                   status: "running-command|\(name)", subStatus: nil, room: workspace.map { ($0.id, RoomEvent.begin) })
        }
        var callContext = CallContext(grant: grant, settings: current, level: level, landing: landing)
        if let ledgerKey { callContext.onJobStarted = { [weak self] job in self?.requests.attachJob(ledgerKey, jobID: job) } }
        var output: ToolOutput
        do {
            output = try HandsTools.run(tool: tool, arguments: arguments, service: self, context: callContext)
        } catch {
            output = ToolOutput(text: "error: \(error)", isError: true, summary: "錯誤：\(error)", roomThread: nil, finalStatus: nil)
        }
        // 清單與讀取回覆維持原本 JSON 格式；只有非唯讀工具才需要未分類提醒。
        let text = HandsRedactor.clip(HandsRedactor.redact(output.text, context: context), limit: 120_000)
            + (tool.readOnly || name == "create_project" ? "" : (landing.reminder.map { "\n" + $0 } ?? ""))
        let summary = HandsRedactor.clip(HandsRedactor.redact(output.summary, context: context), limit: 900)
        let doneStatus = (output.isError ? "error|" : "done|") + name
        if let target {
            let inRoom = output.roomThread == nil || output.roomThread == target
            record(thread: target, rowID: rowID, turn: burstTurn(target), text: rowText(name, argsSummary, summary, grant: grantTag), status: doneStatus,
                   subStatus: nil, room: workspace.map { ($0.id, RoomEvent.end(mutated: inRoom && output.mutated, final: output.finalStatus)) })
        }
        if let room = output.roomThread, room != target {
            // 例：開工作區——根對話記一列，新開的房間也記一列。
            record(thread: room, rowID: rowID + ":room", turn: burstTurn(room), text: rowText(name, argsSummary, summary, grant: grantTag),
                   status: doneStatus, subStatus: output.finalStatus)
        }
        journal(tool: name, summary: summary,
                landing: HandsProjectLanding(projectID: landing.projectID, workspaceID: output.roomThread ?? landing.workspaceID, reminder: nil),
                grant: grant.grantID, approval: name == "computer_request" && !output.isError ? "pending" : nil,
                id: callID, at: calledAt)
        // CU results can contain a screenshot/AX data, and their validity is ephemeral: never persist/replay.
        if let ledgerKey { requests.complete(ledgerKey, text: text, isError: output.isError) }
        return mcp(text, isError: output.isError, image: output.image)
    }

    /// V12 重播前重查（W183 R1b）：參數裡的工作區要還是自己 grant 的、專案還在允許清單；不符就不回舊內容。
    func replayProblem(arguments: [String: Any], grant: HandsGrantAccess, settings current: HandsSettings) -> String? {
        if let raw = arguments["workspace_id"] as? String {
            do { _ = try workspace(raw, grant: grant, settings: current) } catch { return "\(error)" }
        }
        if let raw = arguments["project_id"] as? String {
            guard let id = UUID(uuidString: raw) else { return "project_id" }
            guard allowedProjectIDs(grant, current).contains(id.uuidString) else { return "project_not_allowed" }
        }
        return nil
    }

    /// 算房間該是什麼狀態（主執行緒）：
    /// - 開始：第一個進行中的呼叫記下原狀態；沒交件的房間標 running；已交件（done）的先不動。
    /// - 真的開始改（拿到工作區的鎖）：running。
    /// - 結束：還有別的呼叫在跑就先不動；最後一個結束時，這段期間有改到東西＝最後那次的結果（idle，或交件的 done），
    ///   沒改到東西（失敗、只讀）＝回到原狀態（已交件的維持待審）。
    @MainActor private func roomStatus(_ room: UUID, _ event: RoomEvent, current: String?) -> String? {
        var activity = roomActivity[room] ?? RoomActivity()
        var next: String?
        switch event {
        case .begin:
            if activity.calls == 0 { activity.restore = current == "done" ? "done" : "idle"; activity.result = nil }
            activity.calls += 1
            next = current == "done" ? nil : "running"
        case .mutationStarted:
            next = activity.calls > 0 ? "running" : nil   // 沒有對應的呼叫（不該發生）就不動，免得卡在 running
        case .end(let mutated, let final):
            activity.calls = max(activity.calls - 1, 0)
            if mutated { activity.result = final ?? "idle" }
            next = activity.calls == 0 ? (activity.result ?? activity.restore) : nil
        }
        roomActivity[room] = activity.calls > 0 ? activity : nil
        return next
    }

    /// 工具在沙盒外拿到工作區的鎖時呼叫（withWorkspaceLock）。
    func markRoom(_ room: UUID, _ event: RoomEvent) {
        onMain { [weak self] in
            guard let self, let engine = self.engine else { return }
            if let status = self.roomStatus(room, event, current: engine.threadRecord(room)?.subStatus) {
                engine.handsSetStatus(threadID: room, subStatus: status)
            }
        }
    }

    func mcp(_ text: String, isError: Bool, image: [String: Any]? = nil) -> [String: Any] {
        var content: [[String: Any]] = [["type": "text", "text": HandsRedactor.clip(text, limit: 120_000)]]
        if let image, !isError { content.append(image) }
        return ["content": content, "isError": isError]
    }

    private func rowText(_ tool: String, _ args: String, _ result: String, grant: String) -> String {
        "〔外部資料・ChatGPT・\(grant)〕\(tool)：\(args.isEmpty ? "（無參數）" : args) → \(result)"
    }

    func redactionContext(workspace: HandsWorkspace?) -> HandsRedactor.Context {
        var list: [(String, String)] = [(runtime.home, "~")]
        if runtime.home != NSHomeDirectory() { list.append((NSHomeDirectory(), "~")) }
        if let real = HandsPath.realpath(NSHomeDirectory()), real != NSHomeDirectory() { list.append((real, "~")) }
        if let workspace {
            list.append((workspace.repo, "<workspace>"))
            list.append((workspace.scratch, "<scratch>"))
            list.append((workspace.dir, "<workspace-dir>"))
        }
        // W183 R6c：工作區在入口的 chatgpt/ 底下：入口路徑（可能帶外接碟的名字）也換成代稱。
        for entry in Set([runtime.entryRoot, runtime.workspaceEntry].compactMap { $0 }) {
            list.append((entry, "<entry>"))
            if let real = HandsPath.realpath(entry), real != entry { list.append((real, "<entry>")) }
        }
        // 手腳自己的資料夾（工作區、輸出、標記都在這底下；沙盒裡的 env 看得到）。
        let root = paths.root.path
        list.append((root, "<hands>"))
        if let real = HandsPath.realpath(root), real != root { list.append((real, "<hands>")) }
        return HandsRedactor.Context(paths: list)
    }

    /// 同一條在兩分鐘內的呼叫算同一波（共用 turnID，時間軸會收在一起）。
    private func burstTurn(_ thread: UUID) -> String {
        limiterLock.lock(); defer { limiterLock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = bursts[thread], now - last.at < 120 {
            bursts[thread] = (last.turn, now)
            return last.turn
        }
        let turn = "hands-" + UUID().uuidString
        bursts[thread] = (turn, now)
        return turn
    }

    func record(thread: UUID, rowID: String, turn: String, text: String, status: String, subStatus: String?,
                role: ChatMessageRole = .assistant, eventKind: TatwoNativeChatEventKind = .toolUse,
                room: (UUID, RoomEvent)? = nil) {
        let safe = HandsRedactor.redact(text, context: redactionContext(workspace: nil))
        onMain { [weak self] in
            guard let self, let engine = self.engine else { return }
            let row = ChatMessage(id: rowID, role: role, text: safe, status: status, eventKind: eventKind, turnID: turn)
            var next = subStatus
            if let room { next = self.roomStatus(room.0, room.1, current: engine.threadRecord(room.0)?.subStatus) }
            engine.handsRecord(threadID: thread, row: row, subStatus: next)
        }
    }

    // MARK: - 主執行緒

    @MainActor var engine: ChatLiveEngine? { model?.localLiveForBridge }

    func createProject(name raw: String, folder: String?, grant: HandsGrantAccess) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120, ![".", ".."].contains(name), !name.contains("/"), !name.contains("\\"), raw.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil, !TatwoMemoryStore.containsSecret(name) else { throw HandsToolError.invalid("invalid_project_name") }
        projectCreationLock.lock(); defer { projectCreationLock.unlock() }
        guard let names = onMain({ self.engine?.doc.projects.map(\.name) }), let entry = runtime.entryRoot.flatMap(HandsPath.realpath) else { throw HandsToolError.invalid("project_storage_unavailable") }
        var unique = name, suffix = 2
        while names.contains(where: { $0.caseInsensitiveCompare(unique) == .orderedSame }) { unique = "\(name) \(suffix)"; suffix += 1 }
        let relative = folder ?? unique
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relative.hasPrefix("/"), relative.utf8.count <= 1024, relative.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil, !relative.contains("\\"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), !HandsSecretFiles.isSecret(path: relative) else { throw HandsToolError.invalid("invalid_project_folder: use a relative folder below the OS projects directory") }
        let now = projectCreationNow()
        let times = (projectCreationTimes[grant.grantID] ?? []).filter { now - $0 < Self.projectCreationLimits[1].window }
        projectCreationTimes[grant.grantID] = times
        guard Self.projectCreationLimits.allSatisfy({ limit in times.filter { now - $0 < limit.window }.count < limit.count }) else {
            throw HandsToolError.invalid("建立太多專案，請稍後再試或在 TATWO 裡手動建立")
        }
        // Pin each directory. Reuse existing directories; never follow a symlink or open a file for writing.
        var fd = open(entry, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw HandsToolError.invalid("project_storage_unavailable") }
        var opened = [fd], created: [Int32] = [], published = false
        defer {
            if !published { for child in created.reversed() {
                var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                guard fcntl(child, F_GETPATH, &path) == 0 else { continue }
                let real = String(cString: path), leaf = (real as NSString).lastPathComponent
                let parent = open((real as NSString).deletingLastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard parent >= 0 else { continue }; defer { close(parent) }
                var own = stat(), current = stat()
                if fstat(child, &own) == 0, fstatat(parent, leaf, &current, AT_SYMLINK_NOFOLLOW) == 0, own.st_dev == current.st_dev, own.st_ino == current.st_ino { _ = unlinkat(parent, leaf, AT_REMOVEDIR) }
            } }
            opened.forEach { close($0) }
        }
        func confined(_ directory: Int32, _ root: String) throws {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(directory, F_GETPATH, &path) == 0, HandsPath.isWithin(String(cString: path), root) else { throw HandsToolError.invalid("project_folder_denied") }
        }
        for (depth, part) in (["projects"] + parts).enumerated() {
            try confined(fd, depth == 0 ? entry : entry + "/projects")
            let made = mkdirat(fd, part, 0o700) == 0
            guard made || errno == EEXIST else { throw HandsToolError.invalid("project_folder_create_failed") }
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw HandsToolError.invalid("project_folder_denied") }
            opened.append(next); if made { created.append(next) }; fd = next
            #if DEBUG
            projectDirectoryGate?(depth)
            #endif
            try confined(fd, entry + "/projects")
        }
        let workdir = entry + "/projects/" + parts.joined(separator: "/")
        var pinned = stat(), current = stat()
        guard fstat(fd, &pinned) == 0, stat(workdir, &current) == 0, pinned.st_dev == current.st_dev, pinned.st_ino == current.st_ino,
              HandsPath.realpath(workdir)?.hasPrefix(entry + "/projects/") == true else { throw HandsToolError.invalid("project_folder_denied") }
        let project = try onMain { Result { () throws -> LiveProjectRecord in
            guard let engine = self.engine else { throw HandsToolError.invalid("project_storage_unavailable") }
            return try engine.handsCreateProject(name: unique, workdir: workdir)
        } }.get()
        published = true
        projectCreationTimes[grant.grantID, default: []].append(now)
        return HandsTools.json(["project_id": project.id.uuidString, "name": project.name, "folder": project.workdir])
    }

    func readSession(_ raw: String, cursor: String?, grant: HandsGrantAccess, settings: HandsSettings) throws -> String {
        let allowed = Set(allowedProjects(grant, settings).map(\.id))
        guard let id = UUID(uuidString: raw), let snapshot = onMain({ () -> (LiveThreadRecord, LiveProjectRecord?, [ChatMessage], URL)? in
            guard self.engine?.threadRecord(id)?.controllerCreatorFingerprint == nil else { return nil }
            return self.engine?.handsSessionSnapshot(id)
        }),
              snapshot.1.map({ allowed.contains($0.id) }) ?? ((snapshot.0.projectID == nil || onMain({ self.engine?.doc.generalProjectID == snapshot.0.projectID })) && settings.allProjects && grant.allProjects) else {
            throw HandsToolError.invalid("session_not_found_or_not_allowed: conversation unavailable")
        }
        // Memory notes and system summaries may contain private memory; omit them before paging.
        let ordered = GroupSessionCursor.rows(snapshot.2)
        let prefix = id.uuidString + ":"
        var offset = 0
        if let cursor {
            guard cursor.hasPrefix(prefix), let value = Int(cursor.dropFirst(prefix.count)), value >= 0, value <= ordered.count else { throw HandsToolError.invalid("invalid_session_cursor") }
            offset = value
        }
        func safe(_ value: String) -> String {
            let masked = HandsSecretLines.maskText(value).components(separatedBy: "\n").map { TatwoMemoryStore.containsSecret($0) ? HandsSecretLines.masked : $0 }.joined(separator: "\n")
            return HandsRedactor.redact(masked, context: redactionContext(workspace: nil))
        }
        var rows: [[String: Any]] = [], state = HandsSecretLines.State(), fileCache: [String: [String]] = [:], incompleteTurns = Set<String>()
        func page(_ rows: [[String: Any]], _ next: Int) -> String {
            HandsTools.json(["project_name": snapshot.1.map { String(safe($0.name).prefix(256)) } ?? NSNull(),
                             "title": String(safe(snapshot.0.title).prefix(256)), "rows": rows,
                             "metadata_truncated": safe(snapshot.1?.name ?? "").count > 256 || safe(snapshot.0.title).count > 256,
                             "next_cursor": next < ordered.count ? prefix + String(next) : NSNull()])
        }
        for (index, row) in ordered.enumerated() {
            // Carry secret-line state across rows and pages before clipping anything.
            let text = row.text.hasSuffix("\n") ? String(row.text.dropLast()) : row.text
            let masked = text.components(separatedBy: "\n").map { HandsSecretLines.apply($0, HandsSecretLines.classify($0, state: &state)) }.joined(separator: "\n") + (row.text.hasSuffix("\n") ? "\n" : "")
            if index < offset { continue }
            if rows.count == 40 { break }
            let body = safe(masked)
            let identity = ((row.runtimeAdapterID ?? "") + " " + (row.modelID ?? snapshot.0.engine ?? snapshot.0.model ?? "")).lowercased()
            let speaker = row.role == .user ? "使用者" : row.role == .system ? "系統" : identity.contains("chatgpt") ? "ChatGPT"
                : ["claude", "fable", "opus", "sonnet", "haiku"].contains(where: identity.contains) ? "Claude" : identity.contains("grok") ? "Grok" : identity.contains("gpt") || identity.contains("codex") ? "Codex" : "其他引擎"
            var paths: [String] = []
            if let turn = row.turnID {
                if fileCache[turn] == nil {
                    let url = snapshot.3.appendingPathComponent("turn-artifacts/\(id.uuidString)/\(HandsAuth.sha256Hex(Data(turn.utf8))).json")
                    let handle = try? FileHandle(forReadingFrom: url); defer { try? handle?.close() }
                    let data = try? handle?.read(upToCount: TurnArtifacts.maxIndexBytes + 1)
                    let artifact = data.flatMap { $0.count <= TurnArtifacts.maxIndexBytes ? try? JSONDecoder().decode(TurnArtifactIndex.self, from: $0) : nil }
                    if artifact?.threadID == id, artifact?.turnID == turn, artifact?.truncated == true { incompleteTurns.insert(turn) }
                    fileCache[turn] = artifact.flatMap { $0.threadID == id && $0.turnID == turn ? $0.artifacts.filter { !$0.outside }.map(\.path) : nil } ?? []
                }
                paths = fileCache[turn] ?? []
            }
            var files: [String] = []
            for path in paths {
                let next = files + [String(safe(path).prefix(120))]
                if HandsTools.json(["files": next]).utf8.count > 4_000 { break }; files = next
            }
            let status = safe(row.status ?? "").components(separatedBy: "|")
            let result = (status.first ?? "") + ": " + (body.components(separatedBy: "\n").first ?? "")
            let steps: [[String: String]] = row.eventKind == .toolUse ? [["tool": String((status.last ?? "工具").prefix(120)), "result": String(result.prefix(240))]] : []
            let item: [String: Any] = ["speaker": speaker, "text": String(body.prefix(1500)), "steps": steps, "files": files,
                                     "created_at": ISO8601DateFormatter().string(from: row.createdAt), "truncated": body.count > 1500 || files.count < paths.count || incompleteTurns.contains(row.turnID ?? "") || (row.eventKind == .toolUse && (result.count > 240 || (status.last?.count ?? 0) > 120)) || zip(files, paths).contains { $0.count < safe($1).count }]
            if page(rows + [item], index + 1).utf8.count > 24 * 1024 { break }
            rows.append(item)
        }
        return page(rows, offset + rows.count)
    }

    /// 找或建「ChatGPT 手腳」根對話：每個專案一條（工作區是它的子房）；不屬於專案的呼叫記在「一般」那條。不啟動引擎、不改選取。
    func rootThread(projectID: UUID?) -> UUID? {
        onMain { [weak self] in
            self?.engine?.handsRootThread(title: projectID == nil ? "ChatGPT · 未分類" : "ChatGPT 房",
                                          intro: HandsTools.rootIntro, projectID: projectID)
        }
    }

    func onMain<T>(_ body: @escaping @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    /// Island 短通知（只放標題與一句話；不放內容）。
    func notify(title: String, detail: String) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                if let sink = self?.noticeSink { sink(title, detail) } else { SpaceNotice.post(space: "chatgpt", title: title, detail: detail) }
            }
        }
    }

    // MARK: - 撤銷與設定（只從 App 畫面）

    /// grant 被撤銷（refresh／授權碼重用、畫面撤銷、關開關）：它的 job 收掉、工作區鎖住（保留不刪）。
    func grantsRevoked(_ ids: [String], reason: String) {
        onMain { self.sandboxLane.abort(Set(ids)) }
        HandsComputerRevocations.shared.revoke(grants: Set(ids))
        publicationLock.lock(); defer { publicationLock.unlock() }   // W183 R1b：等進行中的發布做完再收尾
        let set = Set(ids)
        let marks = HandsPath.realpath(paths.marksDir.path)
        jobs.cancel(where: { set.contains($0.grantID) }, marksDirectory: marks)
        let workspaces = workspaceStore.all().filter { set.contains($0.grantID) }.map(\.id.uuidString)
        HandsSandbox.terminate(where: { $0.grant.map(set.contains) ?? false }, workspaces: workspaces, marksDirectory: marks)
        workspaceStore.lock(where: { set.contains($0.grantID) }, reason: "grant_revoked:" + reason)
    }

    /// 一鍵撤銷：全部 grant、token、授權碼、配對作廢，沙盒裡還在跑的全部收掉、工作區鎖住。
    /// 關口的登記不取消：token 全作廢、每次呼叫都重查，登記留著只是讓使用者可以馬上重新配對。
    @discardableResult
    func revokeEverything() -> String? {
        let problem = auth.revokeAll(reason: "user_revoked_all")
        HandsSandbox.terminateAll()
        return problem   // W183 R1b：撤銷沒能存檔（已全部停用、刪授權檔）＝畫面要顯示
    }

    /// 改設定（畫面都走這裡）：關掉開關＝撤銷全部 grant（重新打開要重新配對）；降級、移除專案＝收工作、鎖工作區。
    /// W183 R3b 審查：關掉＝**先**撤銷、收工作、鎖工作區、關配對窗口，並在記憶體強制關閉（HandsForcedOff），**再**存檔——
    /// 存檔失敗（磁碟滿）也不會繼續運作（丟 HandsSettingsFailure.offButNotSaved，不說「沒關」也不說「存好了」）。
    /// 讀到的「改之前」是有效值（記憶體強制關閉時就是關的）；之後任何一次存成功才解除強制關閉。
    @discardableResult
    func updateSettings(_ change: (inout HandsSettings) -> Void) throws -> HandsSettings {
        publicationLock.lock(); defer { publicationLock.unlock() }   // W183 R1b：跟發布互斥
        // W183 R11（GPT-6 R11 審查 1）：reconcile 把新的中央等級寫進本機之前，先照改之前的本機等級把封頂做好（沒有封頂檔的第一次）。
        _ = effectiveSettings()
        let old = settings.load()
        var proposed = old
        change(&proposed)
        let new = proposed.normalized
        if new.level < 2 || !new.enabled { HandsComputerRevocations.shared.stopCurrent() }
        // W183 R11 第二輪（GPT-6 R11b 審查 2，高）：封頂還沒做完（存不進去、授權檔也刪不掉）＝本機等級不往上改（reconcile 這一輪算沒套用，下一輪再試）。
        // W183 R11 最後一輪（GPT-6 R11c 審查 2b）：只豁免「單純關掉」（關掉不調高等級，本來就不會碰到這一道）；同一次改動裡又關掉又調高等級＝
        // 照調高的規則擋（整次不收，本機等級不會連帶存成較高的：重開 App 時的補救看的就是它）。
        if new.level > old.level, let pending = levelCapPending, new.level > pending {
            throw HandsSettingsFailure.levelCapNotSaved
        }
        let marks = HandsPath.realpath(paths.marksDir.path)
        var revocationProblem: String?
        let turningOff = old.enabled && !new.enabled
        if old.enabled && !new.enabled {
            revocationProblem = auth.revokeAll(reason: "switched_off")
            HandsForcedOff.shared.set(settings.settingsURL, true)   // W183 R3b 審查：存檔之前就先當成關的
            HandsSandbox.terminateAll()
            workspaceStore.lock(where: { _ in true }, reason: "switched_off")
            auth.closeWindow()
        }
        do {
            try settings.save(new)
        } catch {
            if turningOff { throw HandsSettingsFailure.offButNotSaved }   // 記憶體強制關閉留著
            throw error
        }
        HandsForcedOff.shared.set(settings.settingsURL, false)   // 檔案現在就是要的樣子
        if !turningOff {   // 關掉的收尾上面已經做完
            if new.level < old.level && new.level < 2 {
                jobs.cancel(where: { _ in true }, marksDirectory: marks)
                HandsSandbox.terminateAll()
                workspaceStore.lock(where: { _ in true }, reason: "level_lowered")
            }
            let removed = Set(old.allowedProjectIDs).subtracting(new.allowedProjectIDs)
            if !removed.isEmpty {
                let affected = workspaceStore.all().filter { removed.contains($0.projectID.uuidString) }
                let ids = Set(affected.map(\.id))
                jobs.cancel(where: { ids.contains($0.workspaceID) }, marksDirectory: marks)
                HandsSandbox.terminate(where: { $0.workspace.flatMap(UUID.init(uuidString:)).map(ids.contains) ?? false },
                                       workspaces: ids.map(\.uuidString), marksDirectory: marks)
                workspaceStore.lock(where: { ids.contains($0.id) }, reason: "project_removed")
            }
        }
        if !new.enabled || !deviceAllowed(new) { auth.closeWindow() }
        // W183 R6b 審查：設定一改（範圍、主機、開關）就核一次進行中的連線意圖（不等擁有者下一次輪詢）。在發布鎖外做（核對要讀專案名稱）。
        if let host = HandsConnectHost.attached(to: self) { DispatchQueue.global(qos: .userInitiated).async { host.validateBeforeAuthorize() } }
        if let revocationProblem { throw HandsToolError.invalid(revocationProblem) }   // W183 R1b：設定已存、撤銷沒存成＝明講
        return new
    }

    /// 關掉開關（畫面）。
    func setEnabled(_ enabled: Bool) throws { try updateSettings { $0.enabled = enabled } }

    /// W183 R8c 審查（GPT-6 高「離線許可到期只停 gateway，已啟動工作仍可繼續寫入」）：啟用許可沒了（信封過期＝太久連不到主設備、
    /// 或不再勾這台）＝安全暫停的收尾——跑著的工作全部收掉、配對窗口關掉；**grant 留著**（明確關掉才撤銷）、工作區不鎖。
    /// 新的操作本來就被 permitCheck 擋（工具、啟動、發布、配對）；長的工作在跑的時候也每 2 秒看一次許可（HandsJobs）。
    func suspendForPermit() {
        let marks = HandsPath.realpath(paths.marksDir.path)
        jobs.cancel(where: { _ in true }, marksDirectory: marks)
        HandsSandbox.terminateAll()
        auth.closeWindow()
    }

    /// 開始配對（畫面按鈕）：開關開著、這台是主機才開 10 分鐘窗口。
    func startPairing() throws {
        let current = settings.load()
        guard current.enabled else { throw HandsWireError.disabled }
        guard deviceAllowed(current) else { throw HandsWireError.wrongDevice }
        auth.openWindow()
    }

    /// 工作區目前的紀錄（不查 grant；只給 App 內部用：磁碟檢查）。
    func workspaceSnapshot(_ id: UUID) throws -> HandsWorkspace {
        // W183 R6c：照紀錄記的位置（入口的 chatgpt/ 或 App Support）。
        guard let record = workspaceStore.record(id), let base = workspacesBase(of: record),
              let dir = HandsPath.realpath(base + "/" + id.uuidString),
              let repo = HandsPath.realpath(dir + "/repo") else { throw HandsToolError.invalid("workspace_not_found") }
        // W183 R6c 審查：這裡在指令跑的時候也會被叫（磁碟監看）：只認已經在的暫存，不建、不改權限（HandsSandbox.existingScratch）。
        return HandsWorkspace(record: record, dir: dir, repo: repo,
                              scratch: try HandsSandbox.existingScratch(URL(fileURLWithPath: dir + "/scratch", isDirectory: true)))
    }
}
