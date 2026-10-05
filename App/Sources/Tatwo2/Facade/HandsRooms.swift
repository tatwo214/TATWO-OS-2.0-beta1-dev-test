import Darwin
import Foundation

// W183 R1／R1b：ChatGPT 手腳的工作區與施工房（接口 v2 §6、v3 V1–V7、V9、V10）。
//
// - 工作區＝獨立版本副本（不是正本的 worktree）：`<入口>/chatgpt/workspaces/<id>/repo`（W183 R6c；入口不能用、隔離環境＝
//   `<App Support>/TATWO OS Hands/workspaces/<id>/repo`，見 HandsWorkspaceRoot.swift）。
//   開工作區時 App 固定 base_sha（正本當下 HEAD），由「匯出小幫手」在沙盒裡 `git archive --format=tar <base_sha>`（乾淨設定的
//   影子 gitdir，只讀得到正本的物件）→ 解開 → `git init`＋中性作者基準 commit。工作區沒有正本任何歷史；ChatGPT 的指令碰不到正本 .git。
// - 依賴（V1）：只用 APFS 複製（`cp -c`）正本已經下載好的依賴資料夾，不跑任何安裝或解析；沒有就告訴 ChatGPT「請使用者在 OS 準備」。
// - 交件（V5）：確認沒有殘留寫入者 → 交件小幫手（只准寫工作區 .git 的規則）`add -A`＋commit → `diff --binary` →
//   App 在正本用暫存 index（read-tree、apply --cached、write-tree、commit-tree、update-ref）建候選 commit，全程不 checkout、hooks 關，
//   不會觸發 filter、hook。候選 SHA 固定：審查卡的 diff、合併都用它（HandsReview.swift）。
// - grant 管全部資源（V9）：工作區紀錄的 grant_id 由 App 寫；每個讀、寫、查都比對呼叫者的 grant。房間只是顯示。
// - 房間：每個專案一條「ChatGPT 手腳」根對話，工作區是它的子房（不啟動引擎、不改選取）；每次工具呼叫一列（遮蔽過的摘要、標外部資料）。

struct HandsProject: Equatable {
    let id: UUID
    let name: String
    let workdir: String
    let problem: String?
    /// W183 R10 底線 B：交易實盤類（ChatGPT 最多 L0：只能看）。主機照 Coder 的專案名與資料夾判斷（HandsService.tradingRecord）。
    var readOnly: Bool = false
}

/// 工作區紀錄（app/workspaces.json；沙盒讀寫不到）。grant_id、base_sha 由 App 寫，不信任工具參數。
struct HandsWorkspaceRecord: Codable, Equatable {
    var id: UUID
    var grantID: String
    var projectID: UUID
    var projectName: String
    var title: String
    /// 開工作區當下正本的 HEAD（V4）。
    var baseSHA: String
    /// 工作區裡的基準 commit（匯出後 git init 的那個）。
    var workspaceBase: String
    /// 上次交件時工作區的 HEAD。
    var workspaceHead: String?
    /// 候選 commit（正本的 refs/heads/tatwo2-room-<id8>）與它的基準。
    var candidateSHA: String?
    var submittedBaseSHA: String?
    /// open｜locked。
    var status: String
    var lockReason: String?
    var dependencies: [String]
    var baselineBytes: Int64
    var createdAt: Date
    var updatedAt: Date
    /// W183 R1b：開工作區時所有保護名稱的項目（依賴資料夾除外）：相對路徑 → 檔案 sha256／"dir"／"link:<目標>"。
    /// 之後多一個、少一個、內容變了＝有人繞過規則（例如整個上層資料夾搬走再搬回來）：鎖住工作區、不交件。
    var protectedManifest: [String: String]? = nil
    /// W183 R6c：工作區放在哪個 workspaces 資料夾（realpath；入口的 chatgpt/workspaces 或 App Support 的）。App 寫的；nil＝舊紀錄（App Support）。
    var workspacesRoot: String? = nil
    /// W183 R10 第二輪（GPT-6 4）：照哪一版金鑰清單掃過（HandsSecretFiles.scanVersion）。nil／舊版＝下一次用到時再掃一次（ensureSecretScan）。
    var secretScan: Int? = nil
    /// W183 R10 第四輪（GPT-6 發現 2）：整理（或 App 自己寫 .git）之後根 .git 的指紋（HandsQuarantine.gitFingerprint）。對不上＝
    /// 有人換過或還原過 .git：先鎖住、整理認證失效、下一次用到重新整理。nil＝還沒記過（一樣重新整理一次）。
    var gitFingerprint: String? = nil

    var branch: String { "tatwo2-room-" + id.uuidString.prefix(8) }
    var isLocked: Bool { status == "locked" }
}

/// 驗過的工作區（grant 對、專案仍被允許、資料夾在規定的位置）。
struct HandsWorkspace: Equatable {
    let record: HandsWorkspaceRecord
    /// workspaces/<id>（realpath）、repo、scratch。
    let dir: String
    let repo: String
    let scratch: String
    var id: UUID { record.id }
    var title: String { record.title }
    var branch: String { record.branch }

    var summary: [String: Any] { record.summary }
}

enum HandsTarget {
    case workspace(HandsWorkspace)
    case project(HandsProject)
}

/// 主機端 git：固定參數、加固旗標、不讀使用者全域與系統設定、清掉 GIT_*、有逾時與輸出上限。
/// 子模組一律不進：status／diff 另加 --ignore-submodules=all。
enum HandsGit {
    static let hardening = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false",
                            "-c", "tag.gpgSign=false", "-c", "core.untrackedCache=false", "-c", "core.splitIndex=false",
                            "-c", "diff.ignoreSubmodules=all", "-c", "submodule.recurse=false", "-c", "status.submoduleSummary=false",
                            "-c", "protocol.file.allow=never", "--no-pager"]
    static let author = "ChatGPT 手腳"
    static let authorEmail = "chatgpt-hands@localhost"
    static var identity: [String: String] {
        ["GIT_AUTHOR_NAME": author, "GIT_AUTHOR_EMAIL": authorEmail, "GIT_COMMITTER_NAME": author, "GIT_COMMITTER_EMAIL": authorEmail]
    }

    /// 加固旗標＋（status／diff）--ignore-submodules=all。呼叫端自己的 -c 放在子指令前面，這裡跳過它們找子指令。
    static func arguments(_ args: [String]) -> [String] {
        var result = args
        var index = 0
        while index < result.count, result[index] == "-c" { index += 2 }
        if index < result.count, ["status", "diff"].contains(result[index]) {
            result.insert("--ignore-submodules=all", at: index + 1)
        }
        return hardening + result
    }

    /// 給 ChatLiveEngine.gitSummary 用（手腳房間的工作區是沙盒寫的）：跟 TurnArtifactsGit.run 同樣的回傳（失敗＝nil），
    /// 但走加固旗標、清掉 GIT_*、不讀使用者全域設定、不進子模組；5 秒、256 KiB 上限。
    static func hostRead(_ args: [String], cwd: String) -> String? {
        guard let result = try? run(args, cwd: cwd, timeout: 5, cap: 256 * 1024), result.status == 0, !result.truncated else { return nil }
        return result.out
    }

    static func environment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("GIT_") { env[key] = nil }
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        for (key, value) in extra { env[key] = value }
        return env
    }

    static func run(_ args: [String], cwd: String, extraEnvironment: [String: String] = [:], stdin: Data? = nil,
                    timeout: TimeInterval = 60, cap: Int = 4 * 1024 * 1024) throws -> (status: Int32, out: String, truncated: Bool) {
        precondition(!Thread.isMainThread, "git must run off the main thread")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments(args)
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = environment(extra: extraEnvironment)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let input: Pipe? = stdin == nil ? nil : Pipe()
        if let input { process.standardInput = input } else { process.standardInput = FileHandle.nullDevice }
        try process.run()
        if let input, let stdin {
            let writer = input.fileHandleForWriting
            DispatchQueue.global(qos: .utility).async {
                _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
                _ = HandsFiles.writeAll(writer.fileDescriptor, stdin)
                try? writer.close()
            }
        }
        let lock = NSLock()
        var data = Data(), truncated = false
        let drained = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            while let chunk = try? reader.read(upToCount: 65_536), !chunk.isEmpty {
                lock.lock()
                let room = max(0, cap - data.count)
                data.append(chunk.prefix(room))
                if chunk.count > room { truncated = true }
                lock.unlock()
            }
            drained.signal()
        }
        if drained.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate(); kill(process.processIdentifier, SIGKILL)
            try? reader.close()
            throw HandsToolError.invalid("git_timeout")
        }
        process.waitUntilExit()
        lock.lock(); defer { lock.unlock() }
        return (process.terminationStatus, String(decoding: data, as: UTF8.self), truncated)
    }

    /// 結束碼 0、而且輸出沒被截斷才算（W183 R1b：安全檢查用的輸出一旦截斷就拒絕，不拿前段當完整結果）。
    static func checked(_ args: [String], cwd: String, extraEnvironment: [String: String] = [:], stdin: Data? = nil,
                        cap: Int = 4 * 1024 * 1024) throws -> String {
        let result = try run(args, cwd: cwd, extraEnvironment: extraEnvironment, stdin: stdin, cap: cap)
        guard result.status == 0 else { throw HandsToolError.invalid("git_failed: \(HandsRedactor.redactedPrefix(result.out, 300))") }
        guard !result.truncated else { throw HandsToolError.invalid("git_output_too_large: \(args.prefix(2).joined(separator: " "))") }
        return result.out
    }

    static func isObjectID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }
}

/// app/workspaces.json 的存取（0600、原子寫入）。
final class HandsWorkspaceStore: @unchecked Sendable {
    let url: URL
    private let mutex = NSRecursiveLock()
    private var cache: [HandsWorkspaceRecord]?

    init(url: URL) { self.url = url }

    func all() -> [HandsWorkspaceRecord] {
        mutex.lock(); defer { mutex.unlock() }
        if let cache { return cache }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let loaded = HandsFiles.readSecure(url, limit: 16 * 1024 * 1024).flatMap { try? decoder.decode([HandsWorkspaceRecord].self, from: $0) } ?? []
        cache = loaded
        return loaded
    }

    func record(_ id: UUID) -> HandsWorkspaceRecord? { all().first { $0.id == id } }

    func insert(_ record: HandsWorkspaceRecord) throws {
        mutex.lock(); defer { mutex.unlock() }
        var list = all()
        list.removeAll { $0.id == record.id }
        list.append(record)
        try save(list)
    }

    @discardableResult
    func update(_ id: UUID, _ change: (inout HandsWorkspaceRecord) -> Void) throws -> HandsWorkspaceRecord? {
        mutex.lock(); defer { mutex.unlock() }
        var list = all()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return nil }
        change(&list[index])
        list[index].updatedAt = Date()
        try save(list)
        return list[index]
    }

    /// 符合條件的全部鎖住（撤銷、降級、移除專案、磁碟超過）。回傳鎖到的 id。
    @discardableResult
    func lock(where matches: (HandsWorkspaceRecord) -> Bool, reason: String) -> [UUID] {
        mutex.lock(); defer { mutex.unlock() }
        var list = all()
        var locked: [UUID] = []
        for index in list.indices where matches(list[index]) && !list[index].isLocked {
            list[index].status = "locked"
            list[index].lockReason = reason
            list[index].updatedAt = Date()
            locked.append(list[index].id)
        }
        if !locked.isEmpty { try? save(list) }
        return locked
    }

    private func save(_ list: [HandsWorkspaceRecord]) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try HandsFiles.writeAtomically(try encoder.encode(list), to: url)
        cache = list
    }
}

extension HandsService {
    // MARK: - 專案（設定允許 ∩ grant 核准）

    /// W183 R10：有效設定是「全部可見」（HandsSettings.centralized）＝這台 Coder 裡所有的專案（能不能當專案另外看 folderProblem）；
    /// grant 核准「全部」（新的連線）＝同上，舊 grant＝它自己的清單。本機的 allowed_project_ids 不再當閘門。會回主執行緒讀專案清單。
    func allowedProjectIDs(_ grant: HandsGrantAccess, _ settings: HandsSettings) -> Set<String> {
        let host = Set(visibleProjectRecords().map { $0.0.uuidString })
        let setting = settings.allProjects ? host : Set(settings.allowedProjectIDs)
        let granted = grant.allProjects ? host : Set(grant.projectIDs)
        return setting.intersection(granted)
    }

    /// 專案 id → 名稱與資料夾（主執行緒讀 Coder 的專案清單）。
    func projectRecords(_ ids: Set<String>) -> [(UUID, String, String)] {
        allProjectRecords().filter { ids.contains($0.0.uuidString) }   // W183 R7a：跟［連線］卡的專案清單同一個來源（HandsConnectScope.swift）
    }

    func allowedProjects(_ grant: HandsGrantAccess, _ settings: HandsSettings) -> [HandsProject] {
        projectRecords(allowedProjectIDs(grant, settings)).map { id, name, workdir in
            // W183 R10 底線 B：交易實盤類（專案名、設定的資料夾、真實路徑的資料夾；主機自己看）。W183 R10 第二輪：含別名（同一個資料夾）。
            let trading = isTradingCached(id)
            guard let real = HandsPath.realpath(workdir) else {
                return HandsProject(id: id, name: name, workdir: workdir, problem: "folder_missing", readOnly: trading)
            }
            return HandsProject(id: id, name: name, workdir: real, problem: runtime.folderProblem(real), readOnly: trading)
        }
    }

    func project(_ id: UUID, grant: HandsGrantAccess, settings: HandsSettings) throws -> HandsProject {
        guard let project = allowedProjects(grant, settings).first(where: { $0.id == id }) else {
            // W183 R10：全部可見時，政策上不能當專案的（入口、家目錄、秘密資料夾…）不在清單裡：講清楚是哪一種（不是「沒核准」）。
            if settings.allProjects, grant.allProjects || grant.projectIDs.contains(id.uuidString),
               let record = allProjectRecords().first(where: { $0.0 == id }), let real = HandsPath.realpath(record.2),
               let problem = runtime.folderProblem(real) {
                throw HandsToolError.invalid("project_refused:\(problem)")
            }
            throw HandsToolError.invalid("project_not_allowed")
        }
        if let problem = project.problem { throw HandsToolError.invalid("project_refused:\(problem)") }
        return project
    }

    /// 這個 grant 的工作區（只含自己的；V9）。
    func workspaceRecords(for grant: HandsGrantAccess) -> [HandsWorkspaceRecord] {
        workspaceStore.all().filter { $0.grantID == grant.grantID }
    }

    /// 工作區 id → 驗過的工作區：grant 對（別的 grant 的一律當作找不到）、專案仍被允許、資料夾在規定的位置。
    /// forWrite：鎖住的不給改、不給跑、不給交件（讀可以）。
    func workspace(_ raw: String, grant: HandsGrantAccess, settings: HandsSettings, forWrite: Bool = false) throws -> HandsWorkspace {
        guard let id = UUID(uuidString: raw), let record = workspaceStore.record(id), record.grantID == grant.grantID else {
            throw HandsToolError.invalid("workspace_not_found")
        }
        guard allowedProjectIDs(grant, settings).contains(record.projectID.uuidString) else {
            // 專案被移出允許清單：鎖住（保留不刪），之後一律拒。
            workspaceStore.lock(where: { $0.id == id }, reason: "project_removed")
            throw HandsToolError.invalid("workspace_locked: project is no longer allowed")
        }
        // W183 R6c：紀錄記著工作區放在哪個 workspaces（入口的 chatgpt/ 或 App Support）；只認現在合法的位置。
        guard let realWorkspaces = workspacesBase(of: record), let realDir = HandsPath.realpath(realWorkspaces + "/" + id.uuidString),
              let realRepo = HandsPath.realpath(realDir + "/repo"),
              realRepo == realDir + "/repo", realDir == realWorkspaces + "/" + id.uuidString else {
            throw HandsToolError.invalid("workspace_missing_or_moved")
        }
        var info = stat()
        guard lstat(realRepo, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw HandsToolError.invalid("workspace_missing") }
        let scratch = try HandsSandbox.prepareScratch(URL(fileURLWithPath: realDir + "/scratch", isDirectory: true))
        // W183 R10 第四輪（GPT-6 發現 2）：照 RESTORE.txt 還原了（根 .git 換過、.build/repositories 搬回來）＝先鎖住、整理認證失效，
        // 這一次就重新整理（任何一次用到都看：讀的工具也一樣）。
        var current = record
        if current.secretScan == HandsSecretFiles.scanVersion, Self.needsRecheck(repo: realRepo, record: current) {
            invalidateSecretScan(id)
            current = workspaceStore.record(id) ?? current
        }
        // W183 R10 第二輪（GPT-6 4）：還沒照現在的清單掃過的舊工作區：先掃（工作樹的金鑰類檔搬去隔離、歷史裡有＝鎖住），才給用。
        let workspace = try ensureSecretScan(HandsWorkspace(record: current, dir: realDir, repo: realRepo, scratch: scratch))
        if forWrite, workspace.record.isLocked { throw HandsToolError.invalid("workspace_locked: \(workspace.record.lockReason ?? "locked")") }
        return workspace
    }

    /// W183 R10 第三輪（GPT-6 發現 4、8；主導裁決）：舊工作區（還沒照現在的規則整理過：R10 之前開的、或規則改過）第一次用到時整理一次，
    /// 整理完才給用：
    /// 1. 工作樹裡金鑰類的檔或資料夾、依賴裡的 .git（別人的 Git 物件庫）、舊的 .build/repositories：整包搬到工作區資料夾裡的
    ///    quarantine-<時間>/files/（沙盒讀不到；有 RESTORE.txt；沒有刪）；
    /// 2. 工作區自己的 .git 整個搬到 quarantine-<時間>/git-archive，用它重建乾淨的副本（只有 ref 摸得到的物件：沒有 reflog、沒有摸不到的
    ///    物件；index 照 HEAD 重建、工作樹不動）——不再只靠 git log --all；
    /// 3. 重建後的歷史（所有 ref）碰過金鑰類路徑＝鎖住（secret_in_history：git show 讀得到舊 blob；使用者照樣看、合併）。
    /// 還原說明在搬任何東西之前先寫（寫不成＝整次失敗）；搬移從驗證過的資料夾 descriptor 逐層不跟捷徑（HandsQuarantine）。任何一步失敗＝
    /// 鎖住（secret_migration_failed）、不記版本、不再自動重試（使用者照 RESTORE.txt 還原）。
    /// 同一個工作區一次只有一個在整理（工作區專用互斥；雙掃描＝後到的等前一個做完、看到版本已經是新的就直接用）；整理的時候拿著寫入鎖
    /// （不准新的 worker），還有工作在跑＝先不整理（workspace_busy）。會跑 git（沙盒）：不要在主執行緒叫。
    func ensureSecretScan(_ workspace: HandsWorkspace) throws -> HandsWorkspace {
        guard workspace.record.secretScan != HandsSecretFiles.scanVersion else { return workspace }
        return try HandsQuarantine.withWorkspaceMutex(workspace.id) { () throws -> HandsWorkspace in
            guard let record = workspaceStore.record(workspace.id) else { throw HandsToolError.invalid("workspace_not_found") }
            let current = HandsWorkspace(record: record, dir: workspace.dir, repo: workspace.repo, scratch: workspace.scratch)
            if record.secretScan == HandsSecretFiles.scanVersion { return current }   // 前一個剛整理完（雙掃描）
            if record.lockReason == "secret_migration_failed" {
                throw HandsToolError.invalid("workspace_locked: secret_migration_failed — the user has to check it (RESTORE.txt in its quarantine folder)")
            }
            guard lockWorkspace(workspace.id.uuidString) else {
                throw HandsToolError.invalid("workspace_busy: the workspace is being checked; try again in a moment")
            }
            defer { unlockWorkspace(workspace.id.uuidString) }
            guard !HandsSandbox.isRunning(where: { $0.workspace == workspace.id.uuidString }) else {
                throw HandsToolError.invalid("workspace_busy: work is still running; the workspace is checked before its next use")
            }
            // W183 R10 第四輪（GPT-6 發現 4；二選一＝暫停）：整理會重建 .git（index 照 HEAD）——有只存在 index 的工作（暫存、部分暫存、
            // 衝突）或進行中的 Git 操作（merge、rebase…）就先不整理：鎖住、一句話說明；使用者處理完，下一次用到再整理。
            if let pending = try pendingGitWork(current) {
                lockForSecrets(workspace.id, reason: Self.migrationPausedReason)
                throw HandsToolError.invalid("workspace_locked: \(Self.migrationPausedReason) — this workspace has \(pending); TATWO did not tidy it "
                    + "(the tidy rebuilds .git). Commit, unstage or finish it in the workspace, then use the workspace again")
            }
            do {
                try migrate(current)
            } catch {
                lockForSecrets(workspace.id, reason: "secret_migration_failed")
                throw HandsToolError.invalid("workspace_locked: secret_migration_failed (\(error))")
            }
            let fingerprint = HandsQuarantine.gitFingerprint(repo: workspace.repo)
            try workspaceStore.update(workspace.id) {
                $0.secretScan = HandsSecretFiles.scanVersion
                $0.gitFingerprint = fingerprint
                // 為了重新整理、或暫停整理而鎖的，整理好就解開（別的原因鎖的照舊；歷史裡有金鑰類＝上面已經換成 secret_in_history）。
                if $0.lockReason == "secret_recheck_needed" || $0.lockReason == Self.migrationPausedReason {
                    $0.status = "open"
                    $0.lockReason = nil
                }
            }
            guard let fresh = workspaceStore.record(workspace.id) else { throw HandsToolError.invalid("workspace_not_found") }
            return HandsWorkspace(record: fresh, dir: workspace.dir, repo: workspace.repo, scratch: workspace.scratch)
        }
    }

    static let migrationPausedReason = "secret_migration_paused"

    /// W183 R10 第四輪（GPT-6 發現 2）：還原過（或有人換過）＝要重新整理：repo 裡又出現 .build/repositories，或根 .git 的指紋對不上
    ///（沒記過也算）。
    static func needsRecheck(repo: String, record: HandsWorkspaceRecord) -> Bool {
        var info = stat()
        if lstat(repo + "/.build/repositories", &info) == 0 { return true }
        guard let known = record.gitFingerprint else { return true }
        return HandsQuarantine.gitFingerprint(repo: repo) != known
    }

    /// 鎖住；「等重新整理」「暫停整理」這兩種暫時的鎖換成更準的原因；別的原因鎖著的不動（不覆蓋、整理好也不解開）。
    func lockForSecrets(_ id: UUID, reason: String) {
        _ = try? workspaceStore.update(id) {
            guard !$0.isLocked || $0.lockReason == "secret_recheck_needed" || $0.lockReason == Self.migrationPausedReason else { return }
            $0.status = "locked"
            $0.lockReason = reason
        }
    }

    /// 整理認證失效：還沒鎖的先鎖（secret_recheck_needed），記的版本清掉——下一次用到重新整理，整理好才解開。別的原因鎖的保留原因。
    func invalidateSecretScan(_ id: UUID) {
        if workspaceStore.record(id)?.isLocked == false {
            workspaceStore.lock(where: { $0.id == id }, reason: "secret_recheck_needed")
        }
        _ = try? workspaceStore.update(id) { $0.secretScan = nil }
    }

    /// W183 R10 第四輪（GPT-6 發現 4）：只存在 index 的工作或進行中的 Git 操作（有＝回一句說明；沒有＝nil）。讀不出來＝當作有（不整理）。
    private func pendingGitWork(_ workspace: HandsWorkspace) throws -> String? {
        let gitDir = workspace.repo + "/.git"
        var info = stat()
        for (name, what) in [("MERGE_HEAD", "a merge in progress"), ("CHERRY_PICK_HEAD", "a cherry-pick in progress"),
                             ("REVERT_HEAD", "a revert in progress"), ("rebase-merge", "a rebase in progress"),
                             ("rebase-apply", "a rebase or am in progress"), ("sequencer", "a sequence of picks in progress")]
            where lstat(gitDir + "/" + name, &info) == 0 {
            return what
        }
        guard lstat(gitDir, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }   // 沒有 .git＝整理那一步自己會失敗
        let unmerged = try workspaceGitRun(workspace, ["ls-files", "-u", "-z"])
        guard unmerged.exitCode == 0 else { return "a Git state TATWO could not read" }
        if !unmerged.stdout.head.isEmpty { return "conflicted (unmerged) files in the index" }
        let staged = try workspaceGitRun(workspace, ["diff", "--cached", "--quiet", "--no-ext-diff", "--ignore-submodules=none"])
        if staged.exitCode == 1 { return "staged changes that are not committed" }
        guard staged.exitCode == 0 else { return "a Git state TATWO could not read" }
        return nil
    }

    /// 整理一個舊工作區（ensureSecretScan 在互斥與寫入鎖裡叫）。丟錯＝失敗（呼叫端鎖住）。
    private func migrate(_ workspace: HandsWorkspace) throws {
        let repoFD = try HandsQuarantine.openDirectory(workspace.repo)
        let scanned: [String]
        do { scanned = try HandsQuarantine.scan(repoFD, nestedGit: true) } catch { close(repoFD); throw error }
        let repositories = ".build/repositories"
        let hasRepositories = HandsQuarantine.entryType(repoFD, repositories) != nil
        let rootGitType = HandsQuarantine.entryType(repoFD, ".git")
        close(repoFD)
        // 根的 .git 不是資料夾（例如指到別處的 gitdir 檔）＝不自動整理（失敗、鎖住）。
        if let rootGitType, rootGitType != S_IFDIR { throw HandsQuarantine.Failure("root_git_not_a_directory") }
        let rootGit = rootGitType == S_IFDIR
        // .build/repositories 整包搬（它底下找到的就不另外搬）。
        var items = hasRepositories ? [repositories] : []
        items += scanned.filter { !hasRepositories || !$0.lowercased().hasPrefix(repositories + "/") }
        let folder = try HandsQuarantine.quarantine(workspaceID: workspace.id, dir: workspace.dir, repo: workspace.repo, items: items,
                                                    rootGit: rootGit, reason: "舊工作區整理（金鑰類、依賴的 Git 物件庫、工作區自己的 .git 重建）")
        if rootGit { try rebuildGit(workspace, archive: folder + "/git-archive") }
        let history = try workspaceGitRun(workspace, ["log", "--all", "--no-renames", "--name-only", "--format=", "-z"], cap: 32 * 1024 * 1024)
        let paths = history.stdout.head.split(separator: 0).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        let historyHasSecret = history.exitCode != 0 || history.stdout.truncated || paths.contains { HandsSecretFiles.isSecret(path: $0) }
        if historyHasSecret { lockForSecrets(workspace.id, reason: "secret_in_history") }
    }

    /// 用隔離起來的舊 .git（archive）重建工作區的 .git：git clone --mirror --no-local（只帶 ref 摸得到的物件；沒有 reflog），
    /// 設回非 bare、拿掉 remote、帶回 info/exclude（依賴排除），index 照 HEAD 重建；HEAD 要跟舊的一樣。在沙盒裡跑（只准寫 repo/.git、只讀 archive）。
    private func rebuildGit(_ workspace: HandsWorkspace, archive: String) throws {
        let (paths, developer) = sandboxPaths(mode: .commit, workspace: workspace, scratch: workspace.scratch, readOnly: [archive], forHelper: true)
        let script = """
            setopt errexit
            old=$("$3" --git-dir="$1" -c core.fsmonitor=false rev-parse --verify HEAD)
            "$3" -c core.hooksPath=/dev/null -c core.fsmonitor=false -c protocol.file.allow=always clone --mirror --no-local --no-hardlinks --template= -q "$1" "$2/.git"
            "$3" --git-dir="$2/.git" config core.bare false
            "$3" --git-dir="$2/.git" config --remove-section remote.origin
            if [[ -f "$1/info/exclude" ]]; then mkdir -p "$2/.git/info"; cat "$1/info/exclude" > "$2/.git/info/exclude"; fi
            cd "$2"
            "$3" -c core.hooksPath=/dev/null -c core.fsmonitor=false read-tree HEAD
            new=$("$3" -c core.fsmonitor=false rev-parse --verify HEAD)
            [[ "$old" == "$new" ]]
            print -r -- "$new"
            """
        let result = HandsSandbox.run(profile: HandsSandbox.profile(paths),
                                      command: ["/bin/zsh", "-f", "-c", script, "tatwo-rebuild-git", archive, workspace.repo, sandboxGitExecutable(developer)],
                                      environment: sandboxEnvironment(scratch: workspace.scratch, developer: developer), cwd: workspace.scratch,
                                      timeout: 300, cpuSeconds: 300, fileSizeMB: 4096, keep: 16 * 1024,
                                      tag: .init(workspace: workspace.id.uuidString, job: nil, grant: workspace.record.grantID),
                                      admit: admission(grantID: workspace.record.grantID, level: 0, projectID: workspace.record.projectID,
                                                       workspaceID: workspace.id, forWrite: false))
        guard result.spawnError == nil, result.exitCode == 0 else { throw HandsQuarantine.Failure("git_rebuild_failed") }
        var info = stat()
        guard lstat(workspace.repo + "/.git", &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw HandsQuarantine.Failure("git_rebuild_missing") }
    }

    /// W183 R10 第三輪（GPT-6 發現 5；主導裁決「工作區裡新出現的秘密檔在允許執行前先隔離」）：run_command／job_start 之前（呼叫端拿著
    /// 工作區的寫入鎖）把工作區裡新出現的金鑰類檔、別人的 .git（例如使用者照還原說明放回來的）先搬去隔離，才准執行。
    /// 搬不成＝鎖住、不跑；看不完（項目太多）＝不跑。
    func quarantineNewSecrets(_ workspace: HandsWorkspace) throws {
        try HandsQuarantine.withWorkspaceMutex(workspace.id) { () throws -> Void in
            // W183 R10 第四輪（GPT-6 發現 2）：跑之前又出現 .build/repositories、根 .git 被換過（還原）＝先鎖住、整理認證失效，這一次不跑；
            // 下一次用到會重新整理（這裡拿著寫入鎖，不能當場整理）。
            if let record = workspaceStore.record(workspace.id), Self.needsRecheck(repo: workspace.repo, record: record) {
                invalidateSecretScan(workspace.id)
                throw HandsToolError.invalid("workspace_rechecking: restored Git data or old dependencies were found; TATWO locked the workspace "
                    + "and re-checks it on the next call — nothing was run, try again")
            }
            let repoFD = try HandsQuarantine.openDirectory(workspace.repo)
            let found: [String]
            do { found = try HandsQuarantine.scan(repoFD, nestedGit: true) } catch {
                close(repoFD)
                throw HandsToolError.invalid("workspace_too_large_to_verify: \(error)")
            }
            close(repoFD)
            guard !found.isEmpty else { return }
            do {
                _ = try HandsQuarantine.quarantine(workspaceID: workspace.id, dir: workspace.dir, repo: workspace.repo, items: found, rootGit: false,
                                                   reason: "執行前發現新的金鑰類檔或 .git")
            } catch {
                lockForSecrets(workspace.id, reason: "secret_quarantine_failed")
                throw HandsToolError.invalid("workspace_locked: secret_quarantine_failed (\(error))")
            }
        }
    }

    /// 工作樹裡最上層的金鑰類項目（相對路徑；金鑰類資料夾整個算一個、不往裡面看；.git 不看；捷徑不跟）。
    static func secretEntries(in repo: String) -> [String] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: repo, isDirectory: true)
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return [] }
        var out: [String] = []
        let prefix = root.standardizedFileURL.path + "/"
        for case let url as URL in walker {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            if relative == ".git" { walker.skipDescendants(); continue }
            if HandsSecretFiles.isSecret(name: url.lastPathComponent) {
                out.append(relative)
                walker.skipDescendants()
            }
        }
        return out
    }

    /// W183 R10 第二輪（GPT-6 4）：複製進工作區的依賴（node_modules、.build/checkouts）再濾一次：裡面的 .git（別人的 Git 物件庫）與
    /// 金鑰類檔案一律拿掉。在 export 規則的沙盒裡跑（只寫這個工作區）；沒做成＝false（呼叫端整個不帶）。
    func sanitizeDependency(_ target: String, workspace: HandsWorkspace, scratch: String, admit: @escaping () -> String?) -> Bool {
        let (paths, developer) = sandboxPaths(mode: .export, workspace: workspace, scratch: scratch, forHelper: true)
        let script = """
            setopt errexit
            /usr/bin/find "$1" -mindepth 1 -iname '.git' -prune -exec /bin/rm -rf -- {} +
            /usr/bin/find "$1" -mindepth 1 \(HandsSecretFiles.findExpression) -prune -exec /bin/rm -rf -- {} +
            """
        let result = HandsSandbox.run(profile: HandsSandbox.profile(paths), command: ["/bin/zsh", "-f", "-c", script, "tatwo-sanitize", target],
                                      environment: sandboxEnvironment(scratch: scratch, developer: developer), cwd: scratch,
                                      timeout: 180, cpuSeconds: 180, fileSizeMB: 64, keep: 8 * 1024,
                                      tag: .init(workspace: workspace.id.uuidString, job: nil, grant: workspace.record.grantID), admit: admit)
        guard result.spawnError == nil, result.exitCode == 0 else { return false }
        return Self.secretEntries(in: target).isEmpty
    }

    /// read_file／list_dir／search：`workspace_id`（自己的工作區）或 `project_id`（正本目前 commit 的檔案樹），兩個只能給一個。
    func target(workspaceID: String?, projectID: String?, grant: HandsGrantAccess, settings: HandsSettings) throws -> HandsTarget {
        switch (workspaceID, projectID) {
        case (let ws?, nil): return .workspace(try workspace(ws, grant: grant, settings: settings))
        case (nil, let raw?):
            guard let id = UUID(uuidString: raw) else { throw HandsToolError.invalid("project_id") }
            return .project(try project(id, grant: grant, settings: settings))
        default: throw HandsToolError.invalid("give exactly one of workspace_id or project_id")
        }
    }

    // MARK: - 沙盒

    /// 規則的共同部分。forHelper＝App 的固定小幫手（檔案小幫手、git 小幫手）；只有它在 DEBUG 自測時可以用 Homebrew 的 node。
    func sandboxPaths(mode: HandsSandbox.Paths.Mode, workspace: HandsWorkspace?, scratch: String, readOnly extra: [String] = [],
                      forHelper: Bool) -> (HandsSandbox.Paths, String) {
        // W183 R6c：工作區可能在入口的 chatgpt/workspaces 或 App Support 的 workspaces；兩處別的工作區都拒、入口其他東西都拒。
        let roots = workspacesRoots()
        let ownRoot = workspace.map { ($0.dir as NSString).deletingLastPathComponent } ?? roots[0]
        var paths = HandsSandbox.Paths(mode: mode, workspace: workspace?.repo, workspaceDir: workspace?.dir,
                                       workspacesRoot: ownRoot, scratch: scratch)
        paths.otherWorkspacesRoots = roots.filter { $0 != ownRoot }
        paths.entryRoots = sandboxEntryRoots()
        var reads = extra
        if forHelper, let helper = runtime.fsopPath { reads.append((helper as NSString).deletingLastPathComponent) }
        if let node = runtime.nodePath {
            if runtime.nodeBundled {
                reads.append((node as NSString).deletingLastPathComponent)
            } else if forHelper {
                // 只有 DEBUG 自測會走到這裡（正式版只用內附 node）：Homebrew 的 node 要讀它自己的程式庫。
                reads.append(HandsRuntime.brewRoot(forNode: node))
                paths.allowHomebrew = true
            }
        }
        paths.readOnly = reads
        if mode == .worker, let workspace {   // W183 R1b（V7）：保護項目的上層資料夾不准改名、刪除
            paths.protectedAncestors = Self.protectedAncestors(workspace.record.protectedManifest, root: workspace.repo)
        }
        paths.deniedDirectories = runtime.deniedDirectories
        paths.deniedFiles = runtime.deniedFiles
        let developer = HandsSandbox.developerDirectory()
        paths.developerRoot = developer?.root
        try? HandsFiles.ensureDirectory(self.paths.marksDir)
        paths.marksDirectory = HandsPath.realpath(self.paths.marksDir.path)
        paths.workspaceMark = workspace?.id.uuidString
        return (paths, developer?.developer ?? "")
    }

    func sandboxEnvironment(scratch: String, developer: String) -> [String: String] {
        let nodeBin = runtime.nodeBundled ? runtime.nodePath.map { ($0 as NSString).deletingLastPathComponent } : nil
        return HandsSandbox.environment(scratch: scratch, marker: UUID().uuidString,
                                        developerDir: developer.isEmpty ? nil : developer, nodeBin: nodeBin)
    }

    func readonlyScratch() throws -> String {
        try HandsSandbox.prepareScratch(paths.scratchDir.appendingPathComponent("readonly", isDirectory: true))
    }

    /// 開發者資料夾裡真的 git（不經 /usr/bin 的 xcrun 轉接）。
    func sandboxGitExecutable(_ developer: String) -> String {
        let git = developer.isEmpty ? "/usr/bin/git" : developer + "/usr/bin/git"
        return FileManager.default.isExecutableFile(atPath: git) ? git : "/usr/bin/git"
    }

    /// 檔案小幫手：在沙盒裡跑 fsop.mjs（stdin 一個 JSON、stdout 一個 JSON）。writable＝false 時工作區在沙盒裡也只給讀。
    func fsop(_ request: [String: Any], workspace: HandsWorkspace, writable: Bool = false) throws -> [String: Any] {
        guard let script = runtime.fsopPath, let node = runtime.nodePath else { throw HandsToolError.invalid("file_helper_unavailable") }
        let (paths, developer) = sandboxPaths(mode: writable ? .worker : .readOnly, workspace: workspace, scratch: workspace.scratch,
                                              forHelper: true)
        let env = sandboxEnvironment(scratch: workspace.scratch, developer: developer)
        guard JSONSerialization.isValidJSONObject(request),
              let body = try? JSONSerialization.data(withJSONObject: request) else { throw HandsToolError.invalid("request") }
        let result = HandsSandbox.run(profile: HandsSandbox.profile(paths), command: [node, "--no-warnings", script], environment: env,
                                      cwd: workspace.repo, stdin: body, timeout: 60, cpuSeconds: 60, fileSizeMB: 64, keep: 8 * 1024 * 1024,
                                      tag: .init(workspace: workspace.id.uuidString, job: nil, grant: workspace.record.grantID),
                                      admit: admission(grantID: workspace.record.grantID, level: writable ? 2 : 0, projectID: workspace.record.projectID,
                                                       workspaceID: workspace.id, forWrite: writable))
        if let error = result.spawnError { throw HandsToolError.invalid(error.hasPrefix("refused:") ? "not_authorized_anymore: \(error.dropFirst(8))" : "helper_\(error)") }
        if result.timedOut { throw HandsToolError.invalid("helper_timeout") }
        guard !result.stdout.truncated else { throw HandsToolError.invalid("helper_output_too_large") }
        guard let reply = try? JSONSerialization.jsonObject(with: result.stdout.head) as? [String: Any] else {
            let context = redactionContext(workspace: workspace)
            let detail = result.stderr.redactedText { HandsRedactor.redact($0, context: context) }
            throw HandsToolError.invalid("helper_failed: \(detail.prefix(300))")
        }
        guard reply["ok"] as? Bool == true else {
            let detail = reply["detail"].map { " (\($0))" } ?? ""
            throw HandsToolError.invalid("\(reply["error"] as? String ?? "helper_error")\(detail)")
        }
        var clean = reply
        clean["ok"] = nil
        return clean
    }

    /// 寫檔前 App 端先驗（第一道）：路徑在工作區內、中間沒有捷徑、已存在的檔是一般檔且連結數 1、不是保護路徑。
    func preflightWrite(workspace: HandsWorkspace, path: String) throws {
        let parts = try HandsPath.components(path, forWrite: true)
        _ = try HandsPath.resolve(root: workspace.repo, components: parts, expect: .absentOrFile)
    }

    /// 讀之前 App 端也先驗一次（第一道）：不出工作區、中間沒有捷徑、檔案用 O_NOFOLLOW 開得起來且連結數 1。
    func preflightRead(workspace: HandsWorkspace, path: String, expect: HandsPath.Expect) throws {
        let parts = try HandsPath.components(path, forWrite: false)
        if parts.first?.lowercased() == ".git" { throw HandsPathError.invalid("protected_path:.git") }
        // W183 R10 底線 A：金鑰類檔案（讀、列、搜尋都不給；檔案小幫手 fsop.mjs 再擋一次）。
        if HandsSecretFiles.isSecret(components: parts) { throw HandsToolError.invalid(HandsSecretFiles.refusal) }
        _ = try HandsPath.resolve(root: workspace.repo, components: parts, expect: expect)
    }

    /// apply_patch 會碰到的每個路徑（新增、刪除、修改、改名的目的地）都先照寫檔的規則驗過。
    func preflightPatch(workspace: HandsWorkspace, patch: String) throws {
        guard patch.utf8.count <= 2 * 1024 * 1024 else { throw HandsToolError.invalid("patch_too_large") }
        var touched = 0
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            for marker in ["*** Add File: ", "*** Delete File: ", "*** Update File: ", "*** Move to: "] where line.hasPrefix(marker) {
                let path = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                if marker == "*** Delete File: " || marker == "*** Update File: " {
                    let parts = try HandsPath.components(path, forWrite: true)
                    _ = try HandsPath.resolve(root: workspace.repo, components: parts, expect: .file)
                } else {
                    try preflightWrite(workspace: workspace, path: path)
                }
                touched += 1
            }
        }
        guard touched > 0 else { throw HandsToolError.invalid("patch_missing_markers") }
    }

    /// 同一個工作區一次只做一件會改東西的事；拿到鎖＝真的要開始改了，房間這時才標 running（已交件的房間也是這時才離開 done）。
    func withWorkspaceLock<T>(_ workspace: HandsWorkspace, _ body: () throws -> T) throws -> T {
        guard lockWorkspace(workspace.id.uuidString) else { throw HandsToolError.invalid("workspace_busy") }
        defer { unlockWorkspace(workspace.id.uuidString) }
        markRoom(workspace.id, .mutationStarted)
        return try body()
    }

    // MARK: - 讀專案主線（沙盒裡的 git 小幫手，只讀得到正本的物件）

    /// 正本的 git 資料：共用 gitdir 與物件資料夾（realpath）。有 alternates（物件在別處）就不收（沙盒讀不到，不放寬）。
    func projectGit(_ project: HandsProject) throws -> (common: String, objects: String) {
        let raw = try HandsGit.checked(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: project.workdir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let common = HandsPath.realpath(raw), let objects = HandsPath.realpath(common + "/objects") else {
            throw HandsToolError.invalid("project_git_unreadable")
        }
        if FileManager.default.fileExists(atPath: objects + "/info/alternates") { throw HandsToolError.invalid("project_uses_git_alternates") }
        return (common, objects)
    }

    /// 影子 gitdir：乾淨的 config（只留格式相關的鍵：沒有遠端、帳密、filter、hook、include）＋ objects 捷徑（指到正本的物件）＋空的 refs。
    /// 放在 <Hands>/scratch/shadows/<一次性 id>（App 寫；沙盒只讀）；用完刪掉。
    func makeShadow(common: String, objects: String) throws -> String {
        let root = paths.scratchDir.appendingPathComponent("shadows", isDirectory: true)
        try HandsFiles.ensureDirectory(root)
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true).path
        guard mkdir(dir, 0o700) == 0, mkdir(dir + "/refs", 0o700) == 0, symlink(objects, dir + "/objects") == 0 else {
            removeShadow(dir); throw HandsToolError.invalid("shadow_failed")
        }
        let pattern = "^(core\\.(repositoryformatversion|precomposeunicode)|extensions\\.(objectformat|refstorage))$"
        let found = (try? HandsGit.run(["config", "--file", common + "/config", "--get-regexp", pattern], cwd: "/", timeout: 10, cap: 64 * 1024))?.out ?? ""
        var core = ["\tbare = true"], extensions: [String] = []
        for line in found.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[1].range(of: "^[A-Za-z0-9_.-]{1,40}$", options: .regularExpression) != nil else { continue }
            let key = parts[0].split(separator: ".", maxSplits: 1)
            guard key.count == 2, key[1] != "refstorage" else { continue }
            if key[0] == "core" { core.append("\t\(key[1]) = \(parts[1])") } else { extensions.append("\t\(key[1]) = \(parts[1])") }
        }
        var config = "[core]\n" + core.joined(separator: "\n") + "\n"
        if !extensions.isEmpty { config += "[extensions]\n" + extensions.joined(separator: "\n") + "\n" }
        do {
            try HandsFiles.writeAtomically(Data(config.utf8), to: URL(fileURLWithPath: dir + "/config"))
            try HandsFiles.writeAtomically(Data("ref: refs/heads/tatwo-shadow\n".utf8), to: URL(fileURLWithPath: dir + "/HEAD"))
        } catch { removeShadow(dir); throw HandsToolError.invalid("shadow_failed") }
        guard let real = HandsPath.realpath(dir) else { removeShadow(dir); throw HandsToolError.invalid("shadow_failed") }
        return real
    }

    func removeShadow(_ dir: String) {
        // 只有 App 寫得到這裡；removeItem 不跟隨裡面的捷徑（objects 捷徑只刪捷徑本身）。
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// 正本目前的 commit（不讀未追蹤檔；只讀這個 commit 的檔案樹）。
    func projectHead(_ project: HandsProject) throws -> String {
        let head = try HandsGit.checked(["rev-parse", "--verify", "HEAD^{commit}"], cwd: project.workdir).trimmingCharacters(in: .whitespacesAndNewlines)
        guard HandsGit.isObjectID(head) else { throw HandsToolError.invalid("project_head_unreadable") }
        return head
    }

    /// 在沙盒裡對正本的物件跑一個固定的 git 讀指令（GIT_DIR＝影子 gitdir）。
    func projectGitRun(_ project: HandsProject, grant: HandsGrantAccess, _ args: [String], stdin: Data? = nil,
                       cap: Int = 8 * 1024 * 1024) throws -> HandsSandbox.RunResult {
        let git = try projectGit(project)
        let shadow = try makeShadow(common: git.common, objects: git.objects)
        defer { removeShadow(shadow) }
        let scratch = try readonlyScratch()
        let (paths, developer) = sandboxPaths(mode: .readOnly, workspace: nil, scratch: scratch, readOnly: [shadow, git.objects], forHelper: true)
        var env = sandboxEnvironment(scratch: scratch, developer: developer)
        env["GIT_DIR"] = shadow
        let command = [sandboxGitExecutable(developer), "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "--no-pager"] + args
        let result = HandsSandbox.run(profile: HandsSandbox.profile(paths), command: command, environment: env, cwd: scratch,
                                      stdin: stdin, timeout: 60, cpuSeconds: 60, fileSizeMB: 64, keep: cap,
                                      admit: admission(grantID: grant.grantID, level: 0, projectID: project.id, workspaceID: nil, forWrite: false))
        if let error = result.spawnError, error.hasPrefix("refused:") { throw HandsToolError.invalid("not_authorized_anymore: \(error.dropFirst(8))") }
        return result
    }

    func projectRead(_ tool: String, project: HandsProject, grant: HandsGrantAccess, arguments: [String: Any]) throws -> [String: Any] {
        let path = arguments["path"] as? String ?? ""
        let parts = try HandsPath.components(path, forWrite: false)
        let joined = parts.joined(separator: "/")
        // W183 R10 底線 A：金鑰類檔案（任何一段）一律不讀、不列、不搜。
        if HandsSecretFiles.isSecret(components: parts) { throw HandsToolError.invalid(HandsSecretFiles.refusal) }
        let head = try projectHead(project)
        switch tool {
        case "read_file":
            guard !parts.isEmpty else { throw HandsToolError.invalid("path_required") }
            let result = try projectGitRun(project, grant: grant, ["cat-file", "--batch"], stdin: Data((head + ":" + joined + "\n").utf8))
            guard result.exitCode == 0, !result.stdout.truncated else { throw HandsToolError.invalid("read_failed") }
            let data = result.stdout.head
            guard let newline = data.firstIndex(of: 0x0A) else { throw HandsToolError.invalid("not_found") }
            let header = String(decoding: data[data.startIndex..<newline], as: UTF8.self).split(separator: " ")
            guard header.count == 3, header[1] == "blob", let size = Int(header[2]) else {
                throw HandsToolError.invalid(header.count >= 2 && header[1] == "tree" ? "is_a_directory" : "not_found")
            }
            guard size <= 8 * 1024 * 1024 else { throw HandsToolError.invalid("file_too_large") }
            let body = data[(newline + 1)...].prefix(size)
            guard !body.prefix(8192).contains(0) else { throw HandsToolError.invalid("binary_file") }
            var reply = HandsTextSlice.slice(Data(body), offsetLine: arguments["offset_line"] as? Int, limitLines: arguments["limit_lines"] as? Int)
            reply["path"] = joined
            reply["commit"] = String(head.prefix(12))
            return reply
        case "list_dir":
            let spec = joined.isEmpty ? [] : ["--", joined + "/"]
            let result = try projectGitRun(project, grant: grant, ["ls-tree", "-z", "--long", head] + spec)
            guard result.exitCode == 0 else { throw HandsToolError.invalid("not_found") }
            var entries: [[String: Any]] = []
            for record in result.stdout.head.split(separator: 0) {
                let text = String(decoding: record, as: UTF8.self)
                let fields = text.split(separator: "\t", maxSplits: 1)
                guard fields.count == 2 else { continue }
                let meta = fields[0].split(separator: " ", omittingEmptySubsequences: true)
                let type = meta.count > 1 ? String(meta[1]) : "blob"
                // W183 R10 底線 A：金鑰類的在翻頁之前就拿掉（總數也不算它們）。
                guard !HandsSecretFiles.isSecret(path: String(fields[1])) else { continue }
                var entry: [String: Any] = ["path": String(fields[1]), "type": type == "tree" ? "dir" : type == "blob" ? "file" : type]
                if meta.count > 3, let size = Int(meta[3]) { entry["size"] = size }
                entries.append(entry)
            }
            entries.sort { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
            var page = HandsPaging.page(entries, cursor: arguments["cursor"] as? String, size: 500)
            page["truncated_at_source"] = result.stdout.truncated
            page["commit"] = String(head.prefix(12))
            return page
        default:
            guard let query = arguments["query"] as? String, !query.isEmpty, query.utf8.count <= 1000 else {
                throw HandsToolError.invalid("query")
            }
            var args = ["grep", "-n", "--column", "-I", "--no-color", "--full-name", "--no-textconv", "-z", "-C", "2"]
            if (arguments["case_sensitive"] as? Bool) == false { args.append("-i") }
            args.append((arguments["regex"] as? Bool) == true ? "-E" : "-F")
            args += ["-e", query, head, "--"]
            if let glob = arguments["glob"] as? String, !glob.isEmpty {
                guard glob.utf8.count <= 200, !glob.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                    throw HandsToolError.invalid("glob")
                }
                args.append(":(glob)" + (joined.isEmpty ? "" : joined + "/") + glob)
            } else if !joined.isEmpty {
                args.append(":(literal)" + joined)
            }
            args += HandsSecretFiles.gitExcludePathspecs   // W183 R10 底線 A：git 先不去碰金鑰類檔案（下面照樣再濾一次路徑）
            let result = try projectGitRun(project, grant: grant, args, cap: 2 * 1024 * 1024)
            guard result.exitCode == 0 || result.exitCode == 1 else { throw HandsToolError.invalid("search_failed") }
            // W183 R1b：含私鑰區段的檔整個不給搜（不能拿搜尋一個字一個字猜）；其他檔的比對行、前後文照秘密行規則遮。
            let keyFiles = try projectGitRun(project, grant: grant, ["grep", "-l", "-z", "-I", "--no-color", "--full-name", "--no-textconv", "-E",
                                                                     "-e", "-----(BEGIN|END) [A-Z0-9 ]*PRIVATE KEY-----", head, "--"],
                                             cap: 1024 * 1024)
            guard (keyFiles.exitCode == 0 || keyFiles.exitCode == 1), !keyFiles.stdout.truncated else { throw HandsToolError.invalid("search_failed") }
            let excluded = Set(keyFiles.stdout.head.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
                .map { $0.hasPrefix(head + ":") ? String($0.dropFirst(head.count + 1)) : $0 })
            let matches = HandsSearchParse.gitGrep(result.stdout.head, treePrefix: head + ":")
                .filter { !excluded.contains($0["path"] as? String ?? "") }
                .filter { !HandsSecretFiles.isSecret(path: $0["path"] as? String ?? "") }   // W183 R10 底線 A
                .compactMap(HandsSearchParse.maskSecrets)
            var page = HandsPaging.page(matches, cursor: arguments["cursor"] as? String, size: 100)
            if result.stdout.truncated || matches.count >= HandsSearchParse.maxMatches { page["complete"] = false; page["truncated_at_source"] = true }
            page["commit"] = String(head.prefix(12))
            return page
        }
    }

    // MARK: - 沙盒裡的 git status／diff

    /// 在工作區裡跑一個固定的 git 讀指令（readOnly：工作區與它自己的 .git 只讀）。
    func workspaceGitRun(_ workspace: HandsWorkspace, _ args: [String], cap: Int = 2 * 1024 * 1024) throws -> HandsSandbox.RunResult {
        let (paths, developer) = sandboxPaths(mode: .readOnly, workspace: workspace, scratch: workspace.scratch, forHelper: true)
        let env = sandboxEnvironment(scratch: workspace.scratch, developer: developer)
        let command = [sandboxGitExecutable(developer), "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "--no-pager"] + args
        let result = HandsSandbox.run(profile: HandsSandbox.profile(paths), command: command, environment: env, cwd: workspace.repo,
                                      timeout: 60, cpuSeconds: 60, fileSizeMB: 64, keep: cap,
                                      tag: .init(workspace: workspace.id.uuidString, job: nil, grant: workspace.record.grantID),
                                      admit: admission(grantID: workspace.record.grantID, level: 0, projectID: workspace.record.projectID,
                                                       workspaceID: workspace.id, forWrite: false))
        if let error = result.spawnError { throw HandsToolError.invalid(error.hasPrefix("refused:") ? "not_authorized_anymore: \(error.dropFirst(8))" : "git_\(error)") }
        return result
    }

    func gitStatus(_ workspace: HandsWorkspace) throws -> [String: Any] {
        let result = try workspaceGitRun(workspace, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--find-renames", "--ignore-submodules=all"])
        guard result.exitCode == 0 else { throw HandsToolError.invalid("git_status_failed") }
        // W183 R10 底線 A：金鑰類檔案不列（連名字都不給）。
        let entries = HandsSearchParse.statusEntries(result.stdout.head).filter { entry in
            !["path", "from"].contains { HandsSecretFiles.isSecret(path: entry[$0] as? String ?? "") }
        }
        return ["entries": entries, "count": entries.count, "truncated": result.stdout.truncated,
                "base_commit": String(workspace.record.workspaceBase.prefix(12))]
    }

    /// mode＝worktree：跟上次交件（或基準）比；base：跟開工作區時的基準比。列改名、刪除、二進位、未追蹤；截斷要標。
    func gitDiff(_ workspace: HandsWorkspace, mode: String, path: String?) throws -> [String: Any] {
        try requireNoOutsideLinks(workspace)   // W183 R6c 審查：diff 會印出內容；連到外面的硬連結不給看
        let rev: String
        switch mode {
        case "worktree": rev = "HEAD"
        case "base": rev = workspace.record.workspaceBase
        default: throw HandsToolError.invalid("mode must be worktree or base")
        }
        var spec: [String] = []
        if let path, !path.isEmpty {
            let parts = try HandsPath.components(path, forWrite: false)
            if HandsSecretFiles.isSecret(components: parts) { throw HandsToolError.invalid(HandsSecretFiles.refusal) }   // W183 R10 底線 A
            spec = ["--", ":(literal)" + parts.joined(separator: "/")]
        }
        // W183 R10 底線 A：金鑰類檔案的差異不給看（名字與內容都不出現）。
        spec = (spec.isEmpty ? ["--", "."] : spec) + HandsSecretFiles.gitExcludePathspecs
        let common = ["--no-ext-diff", "--no-textconv", "--no-color", "--find-renames", "--ignore-submodules=all"]
        let names = try workspaceGitRun(workspace, ["diff", "--name-status", "-z"] + common + [rev] + spec)
        let patch = try workspaceGitRun(workspace, ["diff"] + common + [rev] + spec, cap: 512 * 1024)
        guard names.exitCode == 0, patch.exitCode == 0 else { throw HandsToolError.invalid("git_diff_failed") }
        let status = try gitStatus(workspace)
        let untracked = (status["entries"] as? [[String: Any]] ?? []).filter { $0["status"] as? String == "??" }.compactMap { $0["path"] as? String }
        let context = redactionContext(workspace: workspace)
        // W183 R1b：hunk 可能從私鑰中間開始（看不到 BEGIN）：像金鑰內文的檔段整段遮掉，再做一般遮蔽。
        var text = patch.stdout.redactedText { HandsRedactor.redact(HandsSecretLines.maskDiff($0), context: context) }
        if patch.stdout.truncated { text += "\n（diff 太長，已截斷；用 path 分開看）" }
        return ["mode": mode, "files": HandsSearchParse.nameStatus(names.stdout.head), "untracked": untracked,
                "patch": text, "truncated": patch.stdout.truncated || names.stdout.truncated]
    }

    // MARK: - L2 開工作區（V1–V4）

    static let maxOpenWorkspacesPerGrant = 8
    /// 含鎖住的（保留不刪、仍佔磁碟）：每個 grant、全部。
    static let maxWorkspacesPerGrant = 32
    static let maxWorkspacesTotal = 128
    /// V1：可以帶進工作區的依賴（只複製、不執行）。W183 R10 第二輪（GPT-6 4）：不帶 .build/repositories（沒清過的 Git 物件庫，
    /// git show 讀得到舊檔）；帶進來的依賴一律再濾一次（金鑰類檔案、.git 拿掉：sanitizeDependency）。
    static let dependencyCandidates = [".build/checkouts", "node_modules"]

    func openWorkspace(projectID: UUID, title rawTitle: String, grant: HandsGrantAccess, settings: HandsSettings) throws -> (HandsWorkspace, [String: Any]) {
        let project = try self.project(projectID, grant: grant, settings: settings)
        // W183 R10 底線 B：交易實盤類專案不開工作區（工具入口已經擋過；這裡再擋一次）。
        if project.readOnly { throw HandsToolError.invalid(HandsTradingFloor.refusal) }
        let title = String(rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !title.isEmpty, !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw HandsToolError.invalid("title")
        }
        let mine = workspaceRecords(for: grant)
        guard mine.filter({ !$0.isLocked }).count < Self.maxOpenWorkspacesPerGrant else { throw HandsToolError.invalid("too_many_open_workspaces") }
        // W183 R1b：鎖住的也佔磁碟（保留不刪）：每個 grant、全部加起來都有上限；磁碟快滿就不開。
        guard mine.count < Self.maxWorkspacesPerGrant, workspaceStore.all().count < Self.maxWorkspacesTotal else {
            throw HandsToolError.invalid("too_many_workspaces: ask the user to clean up old ChatGPT workspaces in TATWO")
        }
        try requireDiskRoom()
        let top = try HandsGit.checked(["rev-parse", "--show-toplevel"], cwd: project.workdir).trimmingCharacters(in: .whitespacesAndNewlines)
        guard HandsPath.realpath(top) == project.workdir else { throw HandsToolError.invalid("project_must_be_git_top_level") }
        let base = try projectHead(project)
        let git = try projectGit(project)
        let id = UUID()
        // W183 R6c：放在入口的 chatgpt/workspaces（入口不能用、隔離環境＝App Support，照舊）；位置記進紀錄。
        let wsRoot = try workspacesBaseForNewWorkspace()
        let dir = URL(fileURLWithPath: wsRoot, isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
        try HandsFiles.ensureDirectory(dir)
        try HandsFiles.ensureDirectory(dir.appendingPathComponent("repo", isDirectory: true))
        guard let realDir = HandsPath.realpath(dir.path), realDir == wsRoot + "/" + id.uuidString,
              let repo = HandsPath.realpath(realDir + "/repo") else {
            throw HandsToolError.invalid("workspace_create_failed")
        }
        // 規則用 regex 比對整條路徑：工作區自己的路徑不能踩到保護名稱（否則整個工作區都寫不了）。
        guard !HandsSandbox.pathClashesWithRules(repo) else { throw HandsToolError.invalid("workspace_path_clashes_with_protected_names") }
        let scratch = try HandsSandbox.prepareScratch(dir.appendingPathComponent("scratch", isDirectory: true))
        var record = HandsWorkspaceRecord(id: id, grantID: grant.grantID, projectID: project.id, projectName: project.name, title: title,
                                          baseSHA: base, workspaceBase: "", workspaceHead: nil, candidateSHA: nil, submittedBaseSHA: nil,
                                          status: "open", lockReason: nil, dependencies: [], baselineBytes: 0,
                                          createdAt: Date(), updatedAt: Date())
        record.workspacesRoot = wsRoot
        record.secretScan = HandsSecretFiles.scanVersion   // W183 R10 第二輪：匯出與依賴都濾過（下面）＝照現在的清單掃過了
        let workspace = HandsWorkspace(record: record, dir: realDir, repo: repo, scratch: scratch)
        // 依賴：正本裡真的有（不是捷徑、在專案裡）才帶；先寫進 info/exclude，交件的 add -A 不會收它們。
        let dependencies = Self.dependencyCandidates.filter { candidate in
            var info = stat()
            let source = project.workdir + "/" + candidate
            guard lstat(source, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  let real = HandsPath.realpath(source), real == source else { return false }
            return true
        }
        let excludes = Set(dependencies.map { "/" + ($0.split(separator: "/").first.map(String.init) ?? $0) + "/" }).sorted()
        let shadow = try makeShadow(common: git.common, objects: git.objects)
        defer { removeShadow(shadow) }
        let (sandbox, developer) = sandboxPaths(mode: .export, workspace: workspace, scratch: scratch, readOnly: [shadow, git.objects], forHelper: true)
        let env = sandboxEnvironment(scratch: scratch, developer: developer)
        let script = """
            setopt errexit pipefail
            shadow=$1; sha=$2; ws=$3; shift 3
            git --git-dir="$shadow" -c core.fsmonitor=false -c core.hooksPath=/dev/null archive --format=tar "$sha" | /usr/bin/tar -x -f - -C "$ws"
            /usr/bin/find "$ws" -mindepth 1 \(HandsSecretFiles.findExpression) -prune -exec /bin/rm -rf -- {} +
            cd "$ws"
            git -c init.defaultBranch=tatwo-hands init -q --template= .
            mkdir -p .git/info
            : > .git/info/exclude
            for line in "$@"; do print -r -- "$line" >> .git/info/exclude; done
            git -c core.fsmonitor=false -c core.hooksPath=/dev/null add -A .
            git -c core.fsmonitor=false -c core.hooksPath=/dev/null -c commit.gpgSign=false -c gc.auto=0 -c user.name='\(HandsGit.author)' -c user.email=\(HandsGit.authorEmail) commit -q --no-verify --allow-empty -m "TATWO 基準 $sha"
            git rev-parse HEAD
            """
        let admit = admission(grantID: grant.grantID, level: 2, projectID: project.id, workspaceID: nil, forWrite: false)
        let exported = HandsSandbox.run(profile: HandsSandbox.profile(sandbox),
                                        command: ["/bin/zsh", "-f", "-c", script, "tatwo-export", shadow, base, repo] + excludes,
                                        environment: env, cwd: scratch, timeout: 300, cpuSeconds: 300, fileSizeMB: 2048, keep: 64 * 1024,
                                        tag: .init(workspace: id.uuidString, job: nil, grant: grant.grantID), admit: admit)
        let wsBase = String(decoding: exported.stdout.head, as: UTF8.self).split(separator: "\n").last.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard exported.spawnError == nil, exported.exitCode == 0, HandsGit.isObjectID(wsBase) else {
            archiveWorkspaceFolder(id, base: wsRoot, reason: "export_failed")
            let context = redactionContext(workspace: workspace)
            throw HandsToolError.invalid("export_failed: \(exported.stderr.redactedText { HandsRedactor.redact($0, context: context) }.prefix(300))")
        }
        // V1：APFS 複製依賴（cp -c＝clonefile，不跑任何程式；跨磁碟複製不了就不帶）。在 export 規則的沙盒裡跑（只讀那個依賴資料夾）。
        var copied: [String] = [], missing: [String] = []
        for candidate in dependencies {
            let source = project.workdir + "/" + candidate
            let target = repo + "/" + candidate
            try? FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let (copyPaths, copyDeveloper) = sandboxPaths(mode: .export, workspace: workspace, scratch: scratch, readOnly: [source], forHelper: true)
            let copy = HandsSandbox.run(profile: HandsSandbox.profile(copyPaths), command: ["/bin/cp", "-c", "-R", "--", source, target],
                                        environment: sandboxEnvironment(scratch: scratch, developer: copyDeveloper), cwd: scratch,
                                        timeout: 180, cpuSeconds: 180, fileSizeMB: 4096, keep: 8 * 1024,
                                        tag: .init(workspace: id.uuidString, job: nil, grant: grant.grantID), admit: admit)
            // W183 R10 第二輪（GPT-6 4）：依賴也是進工作區的來源——複製完先拿掉裡面的 .git（別人的 Git 物件庫）與金鑰類檔案，濾不成＝不帶。
            if copy.exitCode == 0, sanitizeDependency(target, workspace: workspace, scratch: scratch, admit: admit) { copied.append(candidate) } else {
                missing.append(candidate)
                try? FileManager.default.removeItem(atPath: target)
            }
        }
        let fm = FileManager.default
        var expected: [String] = []
        if fm.fileExists(atPath: repo + "/Package.swift") && !copied.contains(".build/checkouts") { expected.append("SwiftPM (.build/checkouts)") }
        if fm.fileExists(atPath: repo + "/package.json") && !copied.contains("node_modules") { expected.append("npm (node_modules)") }
        record.workspaceBase = wsBase
        record.dependencies = copied
        record.gitFingerprint = HandsQuarantine.gitFingerprint(repo: repo)   // W183 R10 第四輪：剛建好的 .git
        record.baselineBytes = HandsSandbox.diskUsage([repo, scratch])
        do {
            record.protectedManifest = try Self.protectedEntries(in: repo, skipping: copied)
        } catch {
            archiveWorkspaceFolder(id, base: wsRoot, reason: "manifest_failed")
            throw error
        }
        // W183 R1b：發布前最後一次授權檢查（跟撤銷收尾互斥）：撤銷在這之前＝不登記、資料夾封存。
        do {
            try withPublication(grantID: grant.grantID, level: 2, projectID: project.id, workspaceID: nil, forWrite: false) {
                try workspaceStore.insert(record)
            }
        } catch {
            archiveWorkspaceFolder(id, base: wsRoot, reason: "not_authorized")
            throw error
        }
        let brief = "ChatGPT 手腳的工作區：\(title)（外部資料；合併只有使用者能按；grant \(grant.grantID)）"
        let parent = rootThread(projectID: project.id)
        onMain { [weak self] in
            guard let parent else { return }
            self?.engine?.handsInsertWorkspace(id: id, projectID: project.id, parent: parent, title: "ChatGPT：" + title, brief: brief, worktree: repo)
        }
        var dependencyNote: [String: Any] = ["copied": copied]
        if !missing.isEmpty || !expected.isEmpty {
            dependencyNote["missing"] = missing + expected
            dependencyNote["note"] = "Dependencies are not available in this workspace. Network is blocked; ask the user to prepare them in TATWO OS."
        }
        return (HandsWorkspace(record: record, dir: realDir, repo: repo, scratch: scratch), dependencyNote)
    }

    /// 開不起來的工作區資料夾搬到同一處的 archive（<Hands>/archive 或入口的 chatgpt/archive；封存，可以看；不直接刪）。
    func archiveWorkspaceFolder(_ id: UUID, base: String? = nil, reason: String) {
        let workspaces = base.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? paths.workspacesDir
        let archive = workspaces.deletingLastPathComponent().appendingPathComponent("archive", isDirectory: true)
        try? HandsFiles.ensureDirectory(archive)
        try? FileManager.default.moveItem(at: workspaces.appendingPathComponent(id.uuidString, isDirectory: true),
                                          to: archive.appendingPathComponent("\(id.uuidString)-\(reason)"))
    }

    // MARK: - L2 交件（V5、V10）

    /// 交件時要特別看的「會被執行的設定檔」（T9）：審查卡上醒目標出。
    static func riskyPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        let exact: Set<String> = ["package.swift", "package.json", "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml",
                                  "package.resolved", "makefile", "gnumakefile", ".envrc", "podfile", "podfile.lock", "gemfile", "gemfile.lock",
                                  "rakefile", "setup.py", "pyproject.toml", "build.gradle", "build.gradle.kts", "cargo.toml", "cargo.lock",
                                  "build.rs", "dockerfile", ".pre-commit-config.yaml", ".npmrc", ".yarnrc", ".yarnrc.yml", "justfile",
                                  "taskfile.yml", "tox.ini", "noxfile.py"]
        if exact.contains(name) { return true }
        for prefix in [".github/", ".husky/", ".githooks/", "scripts/", ".circleci/", ".buildkite/", ".gitlab-ci"] where lower.hasPrefix(prefix) {
            return true
        }
        return lower.hasSuffix(".sh") || lower.hasSuffix(".command") || lower.hasSuffix(".plist") || lower.hasSuffix(".gitlab-ci.yml")
    }

    /// 交件前在沙盒外逐層 lstat 走一遍（不跟隨捷徑、不跑 git）：除了最上層的 .git，任何一層叫 .git 的東西都回報
    ///（Seatbelt 本來就建不起來；這是第二道）。App 帶進來的依賴資料夾（info/exclude 排除）跳過。讀不了、名字不是 UTF-8、項目太多都不通過。
    static func nestedGitEntry(in root: String, skipping skipped: [String] = [], limit: Int = 500_000) throws -> String? {
        var pending = [""]
        var seen = 0
        let skip = Set(skipped)
        while let relative = pending.popLast() {
            let path = relative.isEmpty ? root : root + "/" + relative
            guard let directory = opendir(path) else { throw HandsToolError.invalid("workspace_unreadable:\(relative)") }
            defer { closedir(directory) }
            while let entry = readdir(directory) {
                let bytes = try HandsHardLinks.entryName(UnsafePointer(entry)).map { UInt8(bitPattern: $0) }
                guard let name = String(bytes: bytes, encoding: .utf8) else { throw HandsToolError.invalid("workspace_name_not_utf8") }
                if name == "." || name == ".." { continue }
                seen += 1
                guard seen <= limit else { throw HandsToolError.invalid("workspace_too_large_to_verify") }
                let child = relative.isEmpty ? name : relative + "/" + name
                if name.lowercased() == ".git" {
                    if relative.isEmpty { continue }   // 工作區自己的 .git（App 建的）
                    return child
                }
                if skip.contains(child) { continue }
                var info = stat()
                guard lstat(root + "/" + child, &info) == 0 else { throw HandsToolError.invalid("workspace_unreadable:\(child)") }
                if (info.st_mode & S_IFMT) == S_IFDIR { pending.append(child) }
            }
        }
        return nil
    }

    /// W183 R1b（V7）：工作區裡所有保護名稱的項目（最上層的 .git 是 App 的、依賴資料夾跳過）：相對路徑 → 內容指紋。
    /// 在沙盒外逐層 lstat（不跟隨捷徑、不跑任何程式）；讀不了、名字不是 UTF-8、項目太多都丟錯（呼叫端當作不安全）。
    static func protectedEntries(in root: String, skipping skipped: [String] = [], limit: Int = 500_000) throws -> [String: String] {
        var pending: [(String, [String])] = [("", [])]
        var seen = 0
        let skip = Set(skipped)
        var entries: [String: String] = [:]
        while let next = pending.popLast() {
            let (relative, parts) = next
            let path = relative.isEmpty ? root : root + "/" + relative
            guard let directory = opendir(path) else { throw HandsToolError.invalid("workspace_unreadable:\(relative)") }
            defer { closedir(directory) }
            while let entry = readdir(directory) {
                let bytes = try HandsHardLinks.entryName(UnsafePointer(entry)).map { UInt8(bitPattern: $0) }
                guard let name = String(bytes: bytes, encoding: .utf8) else { throw HandsToolError.invalid("workspace_name_not_utf8") }
                if name == "." || name == ".." { continue }
                seen += 1
                guard seen <= limit else { throw HandsToolError.invalid("workspace_too_large_to_verify") }
                let child = relative.isEmpty ? name : relative + "/" + name
                if relative.isEmpty, name == ".git" { continue }   // 工作區自己的 .git（App 建的、會隨交件變）
                if skip.contains(child) { continue }
                let childParts = parts + [name]
                var info = stat()
                guard lstat(root + "/" + child, &info) == 0 else { throw HandsToolError.invalid("workspace_unreadable:\(child)") }
                let type = info.st_mode & S_IFMT
                if HandsSandbox.isProtected(components: childParts) {
                    switch type {
                    case S_IFDIR: entries[child] = "dir"
                    case S_IFLNK:
                        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
                        let count = readlink(root + "/" + child, &buffer, buffer.count - 1)
                        entries[child] = "link:" + (count >= 0 ? String(cString: buffer) : "?")
                    case S_IFREG:
                        let fd = Darwin.open(root + "/" + child, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                        guard fd >= 0 else { throw HandsToolError.invalid("workspace_unreadable:\(child)") }
                        defer { close(fd) }
                        var data = Data()
                        var buffer = [UInt8](repeating: 0, count: 65_536)
                        while true {
                            let n = Darwin.read(fd, &buffer, buffer.count)
                            if n < 0 { throw HandsToolError.invalid("workspace_unreadable:\(child)") }
                            if n == 0 { break }
                            data.append(contentsOf: buffer.prefix(n))
                            guard data.count <= 64 * 1024 * 1024 else { throw HandsToolError.invalid("protected_file_too_large:\(child)") }
                        }
                        entries[child] = HandsAuth.sha256Hex(data) + ":\(info.st_mode & 0o777)"
                    default: entries[child] = "other"
                    }
                }
                if type == S_IFDIR { pending.append((child, childParts)) }
            }
        }
        return entries
    }

    /// 工作區的保護項目跟開的時候比：回第一個不一樣的路徑（nil＝一樣）。讀不了也算不一樣（回原因）。
    func protectedDrift(_ workspace: HandsWorkspace) -> String? {
        let expected = workspace.record.protectedManifest ?? [:]
        let current: [String: String]
        do { current = try Self.protectedEntries(in: workspace.repo, skipping: workspace.record.dependencies) } catch { return "\(error)" }
        if current == expected { return nil }
        let changed = Set(current.keys).union(expected.keys).sorted().first { current[$0] != expected[$0] }
        return changed ?? "?"
    }

    /// Seatbelt 用：保護項目的每一層上層資料夾（不含工作區根；根本來就不能刪、改名）。這些資料夾本身不准改名、刪除
    ///（擋「把整個上層資料夾搬到暫存區、改完裡面的 AGENTS.md 再搬回來」）。最多 512 個（其餘靠 protectedDrift 抓）。
    static func protectedAncestors(_ manifest: [String: String]?, root: String) -> [String] {
        var ancestors = Set<String>()
        for path in (manifest ?? [:]).keys {
            var parts = path.split(separator: "/").map(String.init)
            parts.removeLast()
            while !parts.isEmpty {
                ancestors.insert(root + "/" + parts.joined(separator: "/"))
                parts.removeLast()
            }
        }
        return Array(ancestors.sorted().prefix(512))
    }

    struct CandidateCheck {
        var files: [String] = []
        var flagged: [String] = []
    }

    /// 候選 commit 的最後檢查（正本這邊、只讀物件）：保護路徑（新增、修改、刪除、改名都算）、gitlink、指到外面的捷徑、大檔一律不收；
    /// 執行位元變更、會被執行的設定檔醒目標出。
    func validateCandidate(workdir: String, base: String, candidate: String) throws -> CandidateCheck {
        // W183 R1b：輸出截斷＝拒絕（checked 會丟錯）；每一筆紀錄都要完整、格式對，不對就整份不收（不跳過）。
        let raw = try HandsGit.checked(["diff-tree", "-r", "-z", "--no-renames", "--raw", base, candidate], cwd: workdir, cap: 16 * 1024 * 1024)
        guard raw.isEmpty || raw.hasSuffix("\0") else { throw HandsToolError.invalid("candidate_listing_incomplete") }
        var fields = raw.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)[...]
        if fields.last == "" { fields.removeLast() }
        var check = CandidateCheck()
        var blobs: [(String, String)] = []
        while let meta = fields.popFirst() {
            guard meta.hasPrefix(":"), let path = fields.popFirst(), !path.isEmpty else {
                throw HandsToolError.invalid("candidate_listing_malformed")
            }
            let parts = meta.dropFirst().split(separator: " ")
            guard parts.count == 5, HandsGit.isObjectID(String(parts[3])), parts[4].count == 1 else {
                throw HandsToolError.invalid("candidate_listing_malformed")
            }
            guard check.files.count < 5000 else { throw HandsToolError.invalid("too_many_changed_files") }
            let oldMode = String(parts[0]), newMode = String(parts[1]), newSHA = String(parts[3]), status = String(parts[4])
            check.files.append(path)
            if HandsSandbox.isProtected(path: path) { throw HandsToolError.invalid("protected_path_in_changes:\(path)") }
            if oldMode == "160000" || newMode == "160000" { throw HandsToolError.invalid("gitlink_refused:\(path)") }
            if newMode == "120000" {
                let target = try HandsGit.checked(["cat-file", "blob", newSHA], cwd: workdir)
                let resolved = URL(fileURLWithPath: "/ws/" + path).deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL.path
                if target.hasPrefix("/") || !HandsPath.isWithin(resolved, "/ws") { throw HandsToolError.invalid("symlink_outside_workspace:\(path)") }
                check.flagged.append(path + "（捷徑）")
            }
            if newMode == "100755" && (oldMode != "100755" || status == "A") { check.flagged.append(path + "（可執行）") }
            if status != "D", newMode != "160000" { blobs.append((newSHA, path)) }
            if Self.riskyPath(path) { check.flagged.append(path) }
        }
        if !blobs.isEmpty {
            let sizes = try HandsGit.checked(["cat-file", "--batch-check"], cwd: workdir, stdin: Data(blobs.map { $0.0 + "\n" }.joined().utf8))
            let lines = sizes.split(separator: "\n", omittingEmptySubsequences: true)
            guard lines.count == blobs.count else { throw HandsToolError.invalid("candidate_sizes_incomplete") }
            for (line, blob) in zip(lines, blobs) {
                let parts = line.split(separator: " ")
                guard parts.count == 3, String(parts[0]) == blob.0, let size = Int(parts[2]) else { throw HandsToolError.invalid("candidate_sizes_malformed") }
                if size > 50 * 1024 * 1024 { throw HandsToolError.invalid("file_too_large:\(blob.1)") }
            }
        }
        var seen = Set<String>()
        check.flagged = check.flagged.filter { seen.insert($0).inserted }
        return check
    }

    func submitWorkspace(_ workspace: HandsWorkspace, summary rawSummary: String, grant: HandsGrantAccess, settings: HandsSettings) throws -> [String: Any] {
        let summary = HandsRedactor.redact(rawSummary.trimmingCharacters(in: .whitespacesAndNewlines), context: redactionContext(workspace: workspace))
        guard !summary.isEmpty, summary.count <= 4000 else { throw HandsToolError.invalid("summary") }
        let project = try self.project(workspace.record.projectID, grant: grant, settings: settings)
        // W183 R1b（V5、V10）：交件期間禁止新的寫入者（還沒啟動的 job、寫檔在啟動前會被擋），交件做完才解除。
        beginSubmitting(workspace.id)
        defer { endSubmitting(workspace.id) }
        // V10：先確認沒有殘留寫入者（收掉手腳的；別的程式開著就不交件；無法完整掃描＝無法證明＝鎖住、不交件）。
        switch HandsSandbox.quiesce(workspace: workspace.id.uuidString, roots: [workspace.dir],
                                    marksDirectory: HandsPath.realpath(paths.marksDir.path)) {
        case .clear:
            break
        case .remaining(let remaining):
            throw HandsToolError.invalid("workspace_writers_remain: \(remaining.prefix(5).map(\.name).joined(separator: ", ")) — close them and submit again")
        case .unknown(let reason):
            workspaceStore.lock(where: { $0.id == workspace.id }, reason: "writers_unverifiable")
            throw HandsToolError.invalid("cannot_verify_no_writers: \(reason) — the workspace is locked; nothing was submitted")
        }
        if let nested = try Self.nestedGitEntry(in: workspace.repo, skipping: workspace.record.dependencies) {
            throw HandsToolError.invalid("nested_git_refused:\(nested)")
        }
        try requireNoOutsideLinks(workspace)   // W183 R6c 審查：連到外面的硬連結不交件（交件小幫手的 git add 會把外面那個檔收進候選）
        // V7：保護項目（AGENTS.md、.gitattributes…）跟開的時候不一樣＝有人繞過規則（例如搬走上層資料夾再搬回來）：鎖住、不交件。
        if let drift = protectedDrift(workspace) {
            workspaceStore.lock(where: { $0.id == workspace.id }, reason: "protected_tree_changed")
            throw HandsToolError.invalid("protected_tree_changed:\(drift) — the workspace is locked; nothing was submitted")
        }
        // 交件小幫手：只准寫工作區的 .git（ChatGPT 的指令始終碰不到 .git）。
        let firstLine = String(summary.split(separator: "\n").first.map(String.init)?.prefix(60) ?? "交件")
        let message = "ChatGPT 手腳：\(firstLine)\n\n\(String(summary.prefix(2000)))\n\n（外部資料：由 ChatGPT 透過 TATWO OS 沙盒產生；合併前請審查）"
        let (commitPaths, developer) = sandboxPaths(mode: .commit, workspace: workspace, scratch: workspace.scratch, forHelper: true)
        let script = """
            setopt errexit
            cd "$1"
            git -c core.fsmonitor=false -c core.hooksPath=/dev/null add -A .
            if ! git -c core.fsmonitor=false diff --cached --quiet --no-ext-diff; then
              git -c core.fsmonitor=false -c core.hooksPath=/dev/null -c commit.gpgSign=false -c gc.auto=0 -c user.name='\(HandsGit.author)' -c user.email=\(HandsGit.authorEmail) commit -q --no-verify -m "$2"
            fi
            git rev-parse HEAD
            """
        let committed = HandsSandbox.run(profile: HandsSandbox.profile(commitPaths), command: ["/bin/zsh", "-f", "-c", script, "tatwo-commit", workspace.repo, message],
                                         environment: sandboxEnvironment(scratch: workspace.scratch, developer: developer), cwd: workspace.repo,
                                         timeout: 180, cpuSeconds: 180, fileSizeMB: 2048, keep: 64 * 1024,
                                         tag: .init(workspace: workspace.id.uuidString, job: nil, grant: grant.grantID),
                                         admit: admission(grantID: grant.grantID, level: 2, projectID: project.id, workspaceID: workspace.id,
                                                          forWrite: true, duringSubmit: true))
        if let error = committed.spawnError, error.hasPrefix("refused:") { throw HandsToolError.invalid("not_authorized_anymore: \(error.dropFirst(8))") }
        // W183 R10 第四輪：App 自己剛寫過 .git（交件的 commit）：記下新的指紋（不然下一次用到會被當成還原過）。
        let committedFingerprint = HandsQuarantine.gitFingerprint(repo: workspace.repo)
        _ = try? workspaceStore.update(workspace.id) { $0.gitFingerprint = committedFingerprint }
        let wsHead = String(decoding: committed.stdout.head, as: UTF8.self).split(separator: "\n").last.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard committed.exitCode == 0, HandsGit.isObjectID(wsHead) else {
            let context = redactionContext(workspace: workspace)
            throw HandsToolError.invalid("commit_failed: \(committed.stderr.redactedText { HandsRedactor.redact($0, context: context) }.prefix(300))")
        }
        if wsHead == workspace.record.workspaceBase { throw HandsToolError.invalid("nothing_to_submit") }
        if wsHead == workspace.record.workspaceHead, let candidate = workspace.record.candidateSHA {
            return ["candidate_commit": String(candidate.prefix(12)), "status": "already submitted; waiting for the user's review",
                    "no_new_changes": true]
        }
        let diff = try workspaceGitRun(workspace, ["diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", "--no-renames",
                                                   "--no-color", "--ignore-submodules=none", workspace.record.workspaceBase, wsHead], cap: 32 * 1024 * 1024)
        guard diff.exitCode == 0 else { throw HandsToolError.invalid("diff_failed") }
        guard !diff.stdout.truncated else { throw HandsToolError.invalid("changes_too_large") }
        let patch = diff.stdout.head
        guard !patch.isEmpty else { throw HandsToolError.invalid("nothing_to_submit") }
        // 正本：只動暫存 index、不 checkout（不會觸發 filter、hook）。
        try HandsFiles.ensureDirectory(paths.tmpDir)
        let index = paths.tmpDir.appendingPathComponent("index-" + UUID().uuidString).path
        let patchFile = paths.tmpDir.appendingPathComponent("patch-" + UUID().uuidString)
        defer { unlink(index); unlink(patchFile.path) }
        try HandsFiles.writeAtomically(patch, to: patchFile)
        let base = workspace.record.baseSHA
        let indexEnv = ["GIT_INDEX_FILE": index]
        _ = try HandsGit.checked(["read-tree", base], cwd: project.workdir, extraEnvironment: indexEnv)
        _ = try HandsGit.checked(["apply", "--cached", "--binary", "--whitespace=nowarn", patchFile.path], cwd: project.workdir, extraEnvironment: indexEnv)
        let tree = try HandsGit.checked(["write-tree"], cwd: project.workdir, extraEnvironment: indexEnv).trimmingCharacters(in: .whitespacesAndNewlines)
        guard HandsGit.isObjectID(tree) else { throw HandsToolError.invalid("write_tree_failed") }
        let candidate = try HandsGit.checked(["commit-tree", "--no-gpg-sign", tree, "-p", base, "-m", message], cwd: project.workdir,
                                             extraEnvironment: HandsGit.identity).trimmingCharacters(in: .whitespacesAndNewlines)
        guard HandsGit.isObjectID(candidate) else { throw HandsToolError.invalid("commit_tree_failed") }
        let check = try validateCandidate(workdir: project.workdir, base: base, candidate: candidate)
        let ref = "refs/heads/" + workspace.branch
        let current = (try? HandsGit.run(["rev-parse", "--verify", "-q", ref], cwd: project.workdir))?.out.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !current.isEmpty, current != workspace.record.candidateSHA { throw HandsToolError.invalid("branch_already_exists:\(workspace.branch)") }
        // W183 R10 第二輪（GPT-6 7）：交件前重讀專案清單、記下分類版本；發布那一刻（鎖裡）版本變了或這個專案成了交易實盤類＝不交件。
        let classification = refreshTradingClassification()
        if isTradingCached(project.id) { throw HandsToolError.invalid(HandsTradingFloor.refusal) }
        #if DEBUG
        submitGate?()   // W183 R10 第三輪自測：檢查之後、發布之前改名（發布鎖裡要看到）
        #endif
        // W183 R10 第三輪（GPT-6 6）：分類發布跟下面的 update-ref 同一把鎖（publicationLock）；鎖裡另外看「待分類」（admission）與版本。
        // W183 R1b：發布（update-ref＋紀錄）前最後一次授權檢查，跟撤銷收尾互斥。
        try withPublication(grantID: grant.grantID, level: 2, projectID: project.id, workspaceID: workspace.id, forWrite: true, duringSubmit: true) {
            // W183 R10 第四輪（GPT-6 發現 3）：清單修訂（noteListRead）與交件排在同一個提交序列（commitSequence）：鎖裡最後一次檢查之後、
            // update-ref 之前，改名、新增的修訂插不進來（排在交件後面，不會在修訂生效之後才發布候選）；修訂先到＝這裡看到待分類，不交件。
            try withCommitSequence {
                guard !classificationPending, tradingVersion == classification, !isTradingCached(project.id) else {
                    throw HandsToolError.invalid("classification_changed: the project list changed while submitting; nothing was submitted")
                }
                #if DEBUG
                submitFinalGate?()   // 自測：鎖裡最後檢查之後、update-ref 之前改名
                #endif
                _ = try HandsGit.checked(["update-ref", "-m", "ChatGPT 手腳交件", ref, candidate, current], cwd: project.workdir)
                try workspaceStore.update(workspace.id) {
                    $0.candidateSHA = candidate
                    $0.submittedBaseSHA = base
                    $0.workspaceHead = wsHead
                }
            }
        }
        let mainNow = (try? projectHead(project)) ?? base
        // 【注意】放在摘要前面：施工卡的「看報告」只顯示前幾行。
        var report = "〔外部資料・ChatGPT 交件・grant \(grant.grantID)〕\(workspace.title)"
        if !check.flagged.isEmpty {
            report += "\n【注意】改到會被執行的設定、腳本、捷徑或執行位元（合併前請特別看）：" + check.flagged.prefix(20).joined(separator: "、")
        }
        if mainNow != base { report += "\n【注意】主線已前進（基準 \(base.prefix(8))、現在 \(mainNow.prefix(8))）：合併結果會跟審查的版本不同" }
        report += "\n候選 commit \(candidate.prefix(8))（基準 \(base.prefix(8))）・\(check.files.count) 個檔案\n\n\(summary)"
        record(thread: workspace.id, rowID: "hands-submit:" + UUID().uuidString, turn: "hands-submit-" + UUID().uuidString,
               text: report, status: "done", subStatus: nil, role: .assistant, eventKind: .message)
        notify(title: "ChatGPT 交件：\(workspace.title)", detail: "到 Coder 的「ChatGPT 手腳」看 diff；合併要你按")
        return ["candidate_commit": String(candidate.prefix(12)), "base_commit": String(base.prefix(12)), "files": check.files.count,
                "flagged_for_review": check.flagged, "main_advanced": mainNow != base,
                "status": "submitted; the user reviews and merges"]
    }

    /// V10 磁碟：每次指令後量工作區＋暫存區；比開工作區時多 2 GB 以上＝收掉並鎖住。回傳有沒有鎖。
    @discardableResult
    func enforceDiskQuota(_ workspace: HandsWorkspace) -> Bool {
        let used = HandsSandbox.diskUsage([workspace.repo, workspace.scratch])
        noteMeasured(workspace.id, bytes: used)
        guard used == Int64.max || used - workspace.record.baselineBytes > diskQuotaBytes else { return false }
        HandsSandbox.terminate(where: { $0.workspace == workspace.id.uuidString }, workspaces: [workspace.id.uuidString],
                               marksDirectory: HandsPath.realpath(paths.marksDir.path))
        workspaceStore.lock(where: { $0.id == workspace.id }, reason: "disk_quota_exceeded")
        return true
    }

    static let diskQuota: Int64 = 2 * 1024 * 1024 * 1024
}

/// 讀檔的回傳：行號、總行數、整個檔的 sha256（fixtures/wire.json 的 read_file）。
enum HandsTextSlice {
    static func slice(_ data: Data, offsetLine: Int?, limitLines: Int?) -> [String: Any] {
        let text = String(decoding: data, as: UTF8.self)
        var raw = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { raw.removeLast() }
        // W183 R1b：整個檔一起算秘密行，再切頁（頁從私鑰中間開始也遮得住）。
        let kinds = HandsSecretLines.mask(raw)
        let lines = zip(raw, kinds).map { HandsSecretLines.apply($0, $1) }
        let start = max(1, offsetLine ?? 1)
        let count = min(max(1, limitLines ?? 2000), 2000)
        let chosen = Array(lines.dropFirst(start - 1).prefix(count))
        var body = ""
        var shown = 0
        for (index, line) in chosen.enumerated() {
            let numbered = "\(start + index)\t\(line)\n"
            if body.utf8.count + numbered.utf8.count > 200_000 { break }
            body += numbered
            shown += 1
        }
        return ["total_lines": lines.count, "sha256": HandsAuth.sha256Hex(data), "start_line": start,
                "end_line": start - 1 + shown, "lines": body, "truncated": start - 1 + shown < lines.count]
    }
}

/// 固定排序的清單分頁：cursor 是不透明字串（其實是起點），回 complete。
enum HandsPaging {
    static func page(_ items: [[String: Any]], cursor: String?, size: Int) -> [String: Any] {
        let start = cursor.flatMap { raw -> Int? in
            guard raw.hasPrefix("c"), let value = Int(raw.dropFirst()), value >= 0 else { return nil }
            return value
        } ?? 0
        let slice = Array(items.dropFirst(start).prefix(size))
        let next = start + slice.count
        var result: [String: Any] = ["items": slice, "complete": next >= items.count, "total": items.count]
        if next < items.count { result["cursor"] = "c\(next)" }
        return result
    }
}

/// git 輸出解析（-z 格式）。
enum HandsSearchParse {
    static let maxMatches = 2000

    /// `git grep -n --column -z -C N <commit> --`：比對到的行 `<commit>:<path>\0<行>\0<欄>\0<字>`（git 2.x 在 -z 時行號、欄號後面也是 \0），
    /// 前後文 `<commit>:<path>\0<行>\0<字>`；群組之間是 `--`。回 path:line:col＋前後文。
    static func gitGrep(_ data: Data, treePrefix: String) -> [[String: Any]] {
        var matches: [[String: Any]] = []
        var context: [(String, Int, String)] = []
        var lastIndexByPath: [String: Int] = [:]
        for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let fields = rawLine.split(separator: 0, maxSplits: 3, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            guard fields.count >= 3 else { context.removeAll(); continue }
            var path = fields[0]
            if path.hasPrefix(treePrefix) { path = String(path.dropFirst(treePrefix.count)) }
            guard let line = Int(fields[1]) else { continue }
            if fields.count == 4, let column = Int(fields[2]) {
                guard matches.count < maxMatches else { break }
                var match: [String: Any] = ["path": path, "line": line, "col": column, "text": String(fields[3].prefix(400)),
                                            "location": "\(path):\(line):\(column)"]
                match["before"] = context.filter { $0.0 == path && $0.1 < line }.suffix(2).map { "\($0.1): \(String($0.2.prefix(400)))" }
                matches.append(match)
                lastIndexByPath[path] = matches.count - 1
                context.removeAll()
            } else {
                let text = fields.count >= 3 ? fields[2...].joined(separator: " ") : ""
                if let index = lastIndexByPath[path], let previous = matches[index]["line"] as? Int, line > previous, line - previous <= 2 {
                    var after = matches[index]["after"] as? [String] ?? []
                    after.append("\(line): \(String(text.prefix(400)))")
                    matches[index]["after"] = after
                }
                context.append((path, line, text))
                if context.count > 4 { context.removeFirst(context.count - 4) }
            }
        }
        return matches
    }

    /// W183 R1b：一筆比對（含前後文）照秘密行規則處理：比對到的那行本身是金鑰內容＝整筆不給；前後文逐行遮。
    static func maskSecrets(_ match: [String: Any]) -> [String: Any]? {
        func split(_ entry: String) -> (String, String) {
            guard let range = entry.range(of: ": ") else { return ("", entry) }
            return (String(entry[..<range.lowerBound]), String(entry[range.upperBound...]))
        }
        let before = (match["before"] as? [String] ?? []).map(split)
        let after = (match["after"] as? [String] ?? []).map(split)
        let text = match["text"] as? String ?? ""
        var state = HandsSecretLines.State()
        let beforeKinds = before.map { HandsSecretLines.classify($0.1, state: &state) }
        let own = HandsSecretLines.classify(text, state: &state)
        let afterKinds = after.map { HandsSecretLines.classify($0.1, state: &state) }
        if own == .all { return nil }
        var result = match
        result["text"] = HandsSecretLines.apply(text, own)
        if !before.isEmpty { result["before"] = zip(before, beforeKinds).map { "\($0.0.0): \(HandsSecretLines.apply($0.0.1, $0.1))" } }
        if !after.isEmpty { result["after"] = zip(after, afterKinds).map { "\($0.0.0): \(HandsSecretLines.apply($0.0.1, $0.1))" } }
        return result
    }

    /// `git status --porcelain=v1 -z`。
    static func statusEntries(_ data: Data) -> [[String: Any]] {
        var fields = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }[...]
        var entries: [[String: Any]] = []
        while let entry = fields.popFirst() {
            guard entry.count > 3 else { continue }
            let code = String(entry.prefix(2))
            var item: [String: Any] = ["status": code, "path": String(entry.dropFirst(3))]
            if code.contains("R") || code.contains("C"), let original = fields.popFirst() { item["from"] = original }
            entries.append(item)
        }
        return entries
    }

    /// `git diff --name-status -z`。
    static func nameStatus(_ data: Data) -> [[String: Any]] {
        var fields = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }[...]
        var entries: [[String: Any]] = []
        while let status = fields.popFirst() {
            guard let first = status.first else { continue }
            if first == "R" || first == "C" {
                guard let from = fields.popFirst(), let to = fields.popFirst() else { break }
                entries.append(["status": status, "from": from, "path": to])
            } else if let path = fields.popFirst() {
                entries.append(["status": status, "path": path])
            }
        }
        return entries
    }
}
