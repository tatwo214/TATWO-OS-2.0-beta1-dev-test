import CoreServices
import Darwin
import Foundation

/// W180 E1b：App 內動入口 memory/ 的 git 與檔案（commit、合併、寫檔）共用這一把鎖，
/// 自動同步、EngineMemoryWatcher（重產 Codex 摘要）、接上記憶才不會互撞。
/// Claude Code 在 App 外寫檔擋不住：所以每次先 commit 當下的狀態再合併，合併不成就停、留原狀、下一輪再試。
enum TatwoMemoryLock {
    static let shared = NSRecursiveLock()

    static func run<T>(_ body: () throws -> T) rethrows -> T {
        shared.lock()
        defer { shared.unlock() }
        return try body()
    }
}

/// 設定 › OS › 記憶 那一行（TatwoMemorySyncStatusRow）顯示的狀態。
struct TatwoMemorySyncStatus: Equatable, Sendable {
    enum State: String, Sendable {
        case starting, synced, offline, folderMissing, primaryFolderMissing, failed, held, disabled
    }

    var state: State = .starting
    /// nil＝還沒看過身分。主設備（或沒有配對的單機）只 commit、收件；副設備才送、拉。
    var isPrimary: Bool? = nil
    var lastSync: Date? = nil
    /// 這台還沒交給主設備的 commit 數（副設備）。
    var pending = 0
    /// 兩版並存（衝突副本）還有幾個檔。
    var conflicts = 0
    /// 一句話的錯誤；沒有就是 nil。
    var error: String? = nil
    /// 原始代碼，供分類與 audit；畫面只顯示白話錯誤。
    var detail: String? = nil
    /// 先不套用的刪除有幾條（state == .held）；heldOutgoing＝這台刪的、先不送到主設備，否則＝另一台刪的、先不套用到這台。
    var held = 0
    var heldOutgoing = false
    /// 先不套用的前幾個檔名（確認列用）。
    var heldNames = ""

    var line: String {
        let time = lastSync.map { " " + Self.clock($0) } ?? ""
        let both = conflicts > 0 ? "・兩版並存 \(conflicts) 條" : ""
        let waiting = pending > 0 ? "・待送 \(pending) 個變動" : ""
        switch state {
        case .disabled: return ""
        case .starting: return "記憶同步準備中"
        case .folderMissing: return "記憶資料夾沒接上"
        case .primaryFolderMissing:
            return "主設備的記憶資料夾沒接上" + (pending > 0 ? "・\(pending) 個變動先留在這台" : "")
        case .offline:
            return "連不上主設備" + (pending > 0 ? "・\(pending) 個變動先留在這台，連上再送" : "・下一輪再試")
        case .failed:
            if detail == "rpc_parameters_too_large" || detail == "memory_bundle_too_large" {
                return DeviceFleetReason.plain(DeviceDispatch.Failure(reason: detail!), context: .memory(pushing: false, offline: false))
            }
            return "同步沒成功：" + (error ?? "原因不明") + "・下一輪再試"
        case .held:
            return heldOutgoing ? "這台刪了 \(held) 條記憶，先不送到主設備" : "另一台刪了 \(held) 條記憶，先不套用到這台"
        case .synced:
            return (isPrimary == true ? "主設備・已記下" : "已同步") + time + waiting + both
        }
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// 入口 memory/ 的主副自動同步（設計：docs/plans/W179-通用記憶設計.md「主設備與副設備」；實作地圖 W180 E1 第 7 步）。
/// - 副設備：先 commit → 用配對時 pin 住的主機金鑰從主設備 fetch → 合併（兩版都留）→ pushPinned 到主設備的
///   `refs/heads/inbox/<設備id>/memory` → 有設備簽章的 `memory_sync_receive`。
/// - 主設備：定時 commit（Claude 一直在寫）；收件時先 commit 本機 → 驗 ref 與樹（只准一般檔、不帶金鑰）→ 同一套規則合併 → commit。
/// - 60 秒一次；memory/ 有變動 3 秒後再跑一次。全部在自己的背景佇列，不在主執行緒跑 git；
///   絕不 reset --hard；同步要拿掉的檔先封存到入口的 archive/；一次拿掉太多先不套用、等使用者確認；連不上就留在本機 git，連上再送。
final class TatwoMemorySyncEngine: @unchecked Sendable {
    enum Reason: Sendable { case timer, change, manual }

    struct Failure: LocalizedError, CustomStringConvertible {
        enum Kind: Sendable { case general, held, blocked }
        let reason: String
        var kind: Kind = .general
        /// held：先不套用要拿掉的檔；blocked：擋住合併的檔。
        var paths: [String] = []
        var errorDescription: String? { reason }
        /// OSAgentBridge 回錯時用 String(describing:)：只給原因那句話，不帶型別名。
        var description: String { reason }
    }

    struct Outcome: Sendable {
        var kind: String
        var copies = 0
    }

    /// 合併算好、還沒放進工作樹的結果。
    struct Prepared: Sendable {
        var kind: String
        var head: String?
        /// 要放進工作樹的 commit；nil＝這台已經包含另一邊（up_to_date）。
        var target: String?
        /// 這台 HEAD 有、放進去之後就沒有的檔（會從這台的工作樹拿掉）。
        var removed: [String] = []
        /// 這台 HEAD 原本有幾個檔（算「拿掉太多」的比例）。
        var total = 0
        var copies = 0
    }

    struct GitResult {
        var status: Int32
        var output: Data
        var text: String { String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static let shared = TatwoMemorySyncEngine(paths: { EngineMemoryPaths() }, dispatch: DeviceDispatch.shared)
    static let interval: TimeInterval = 60
    static let changeDelay: TimeInterval = 3
    static let primaryRef = "refs/tatwo/sync/primary"
    static let ackedRef = "refs/tatwo/sync/acked"

    static func inboxRef(_ deviceID: String) -> String { "refs/heads/inbox/\(deviceID)/memory" }

    let paths: @Sendable () -> EngineMemoryPaths
    let dispatch: DeviceDispatch
    let queue = DispatchQueue(label: "ai.tatwo.tatwo2.memory-sync", qos: .utility)
    /// 只有自測會注入（照 DeviceDispatch 的 rpc／push 注入法）；沒有任何環境變數或 RPC 能打開。
    private let fetchOverride: ((EngineMemoryPaths, String) throws -> Void)?
    private let pushOverride: ((EngineMemoryPaths, String, String, String) throws -> Void)?

    private let stateLock = NSLock()
    private var current = TatwoMemorySyncStatus()
    private var statusHandler: (@Sendable (TatwoMemorySyncStatus) -> Void)?
    /// 這輪先不套用的刪除（stateLock）；使用者在狀態列確認後放進 approved，下一輪照樣套用／照樣送出。
    private var heldPaths: [String] = []
    private var approved: Set<String> = []
    private static let counterLock = NSLock()
    nonisolated(unsafe) private static var gitOnMain = 0
    nonisolated(unsafe) private static var refusedOnMain = 0

    // 以下只在 queue 上動。
    private var started = false
    private var timer: DispatchSourceTimer?
    private var stream: FSEventStreamRef?
    private var watchedPath: String?
    private var pendingChange: DispatchWorkItem?

    init(paths: @escaping @Sendable () -> EngineMemoryPaths, dispatch: DeviceDispatch,
         fetch: ((EngineMemoryPaths, String) throws -> Void)? = nil,
         push: ((EngineMemoryPaths, String, String, String) throws -> Void)? = nil) {
        self.paths = paths
        self.dispatch = dispatch
        fetchOverride = fetch
        pushOverride = push
    }

    var status: TatwoMemorySyncStatus {
        stateLock.lock(); defer { stateLock.unlock() }
        return current
    }

    func setStatusHandler(_ handler: (@Sendable (TatwoMemorySyncStatus) -> Void)?) {
        stateLock.lock(); defer { stateLock.unlock() }
        statusHandler = handler
    }

    /// 狀態列「照樣套用／照樣送出」確認之後叫：這次先不套用的那些刪除放行（拿掉的檔照樣先封存），馬上再跑一輪。
    func approveHeld() {
        stateLock.lock()
        approved.formUnion(heldPaths)
        stateLock.unlock()
        trigger(.manual)
    }

    private func approvedPaths() -> Set<String> {
        stateLock.lock(); defer { stateLock.unlock() }
        return approved
    }

    private func setHeld(_ paths: [String]) {
        stateLock.lock(); defer { stateLock.unlock() }
        heldPaths = paths
    }

    private func clearApprovals() {
        stateLock.lock(); defer { stateLock.unlock() }
        approved = []
    }

    /// 自測用：有沒有人想在主執行緒跑 git（應該永遠是 0）、主執行緒叫 runOnce 被擋了幾次。
    static var gitAttemptsOnMainThread: Int {
        counterLock.lock(); defer { counterLock.unlock() }
        return gitOnMain
    }
    static var runsRefusedOnMainThread: Int {
        counterLock.lock(); defer { counterLock.unlock() }
        return refusedOnMain
    }

    private static func count(onMain refused: Bool) {
        counterLock.lock(); defer { counterLock.unlock() }
        if refused { refusedOnMain += 1 } else { gitOnMain += 1 }
    }

    // MARK: 排程

    /// 開始：先跑一輪，之後每 60 秒一輪；memory/ 有變動（FSEvents）3 秒後再跑一輪。
    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            let tick = DispatchSource.makeTimerSource(queue: queue)
            tick.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .seconds(5))
            tick.setEventHandler { [weak self] in self?.scheduledRound(.timer) }
            tick.resume()
            timer = tick
            scheduledRound(.timer)
        }
    }

    /// 停掉定時與檔案監看（自測用；App 不會叫）。
    func stop() {
        queue.sync {
            started = false
            timer?.cancel()
            timer = nil
            pendingChange?.cancel()
            pendingChange = nil
            detachWatcher()
        }
    }

    /// 任何執行緒都能叫，立刻回來；真正的同步在背景佇列。
    func trigger(_ reason: Reason = .manual) {
        queue.async { [weak self] in self?.scheduledRound(reason) }
    }

    /// 同步跑一輪（自測與背景呼叫用）。主執行緒叫會被擋下、不跑任何 git。
    @discardableResult
    func runOnce(_ reason: Reason = .manual) -> TatwoMemorySyncStatus {
        guard !Thread.isMainThread else {
            Self.count(onMain: true)
            return status
        }
        let next = queue.sync { round(reason) }
        publish(next)
        return next
    }

    private func scheduledRound(_ reason: Reason) {
        if started { attachWatcher(paths().memory.path) }
        publish(round(reason))
    }

    private func publish(_ next: TatwoMemorySyncStatus) {
        stateLock.lock()
        current = next
        let handler = statusHandler
        stateLock.unlock()
        handler?(next)
    }

    // MARK: 一輪

    private func round(_ reason: Reason) -> TatwoMemorySyncStatus {
        guard !Thread.isMainThread else {
            Self.count(onMain: false)
            return status
        }
        let paths = self.paths()
        let memory = paths.memory
        let identity = try? dispatch.identity()
        if identity?.role == .secondary {
            do {
                if let trust = try dispatch.fleet.trust() {
                    guard trust.kind == .owner, let roster = try dispatch.fleet.current()?.roster,
                          try roster.capabilities(from: trust.localID, to: trust.primaryID).contains("memory") else {
                        return TatwoMemorySyncStatus(state: .disabled, isPrimary: false)
                    }
                }
            } catch { return TatwoMemorySyncStatus(state: .disabled, isPrimary: false) }
        }
        // 外接卷沒掛上、還沒接上記憶：安靜略過，不影響其他功能。
        guard FileManager.default.fileExists(atPath: memory.appendingPathComponent(".git").path) else {
            return TatwoMemorySyncStatus(state: .folderMissing, isPrimary: status.isPrimary)
        }
        if let identity, identity.role == .secondary {
            return secondaryRound(paths, identity: identity, reason: reason)
        }
        return primaryRound(memory)
    }

    private func primaryRound(_ memory: URL) -> TatwoMemorySyncStatus {
        let notes = TatwoMemoryLock.run { EngineMemoryLinks.commit(memory, message: commitMessage("自動記下")) }
        var next = TatwoMemorySyncStatus(state: .synced, isPrimary: true, lastSync: Date(), pending: 0,
                                         conflicts: conflictCount(memory))
        if let failure = notes.first(where: Self.isFailureNote) { next.state = .failed; next.error = failure }
        return next
    }

    private func secondaryRound(_ paths: EngineMemoryPaths, identity: DeviceIdentity, reason: Reason) -> TatwoMemorySyncStatus {
        let memory = paths.memory
        var next = TatwoMemorySyncStatus(state: .synced, isPrimary: false, lastSync: status.lastSync)
        func finish(_ state: TatwoMemorySyncStatus.State, _ error: String? = nil, detail: String? = nil,
                    held: [String] = [], outgoing: Bool = false) -> TatwoMemorySyncStatus {
            next.state = state
            next.error = error
            next.detail = detail
            next.held = held.count
            next.heldOutgoing = outgoing
            next.heldNames = held.isEmpty ? "" : TatwoMemorySyncMerge.names(held)
            setHeld(held)
            next.pending = pendingCount(memory)
            next.conflicts = conflictCount(memory)
            return next
        }
        func failed(_ error: Error, pushing: Bool = false) -> TatwoMemorySyncStatus {
            dispatch.fleet.audit(Self.raw(error))
            if Self.raw(error) == "primary_transferred" { return finish(.disabled) }
            return Self.isTransport(error) ? finish(.offline, detail: Self.raw(error))
                : finish(.failed, Self.short(error, pushing: pushing), detail: Self.raw(error))
        }
        // 1. 先 commit 這台的變動（Claude 可能正在寫）。
        let before = revParse(memory, "HEAD")
        let notes = TatwoMemoryLock.run { EngineMemoryLinks.commit(memory, message: commitMessage("自動記下")) }
        if let failure = notes.first(where: Self.isFailureNote) { return finish(.failed, failure) }
        let committed = revParse(memory, "HEAD")
        // 檔案變動觸發、卻沒有新東西要送：不連網（自己合併寫檔也會觸發）。
        if reason == .change, before == committed, pendingCount(memory) == 0, status.state != .starting {
            var same = status
            same.conflicts = conflictCount(memory)
            return same
        }
        // 2. 問主設備記憶資料夾在哪、有沒有接上。連不上才算離線；主設備回了錯（例如 App 還沒更新）要照實說。
        let target: [String: Any]
        do { target = try dispatch.callPrimary(method: "memory_sync_target", payload: [:]) } catch { return failed(error) }
        guard let repository = target["repository"] as? String, repository.hasPrefix("/"),
              !repository.contains("\n"), !repository.contains("\0") else {
            return finish(.failed, "主設備回的記憶位置看不懂")
        }
        guard target["available"] as? Bool == true else { return finish(.primaryFolderMissing) }
        // 3. 用 pin 住主機金鑰的 SSH 拉主設備的記憶；問完位置後也可能失聯。
        do { try fetchPrimary(paths, repository: repository) } catch {
            return failed(error)
        }
        guard let primaryTip = revParse(memory, Self.primaryRef) else { return finish(.failed, "拉不到主設備的記憶") }
        if let problem = treeProblem(memory, commit: primaryTip, reference: committed) {
            return finish(.failed, "主設備的記憶" + problem + "，這輪不合併")
        }
        // 4. 合併（主設備版留原名，這台的另存一份）。合併前再 commit 一次。
        //    放進這台的工作樹不成（有檔擋住、另一台刪太多先不套用）：這台留原狀，但合併好的版本照樣送給主設備，上傳不停。
        let allowed = approvedPaths()
        var localIssue: Failure?
        let outgoingCommit: String?
        do {
            let label = Self.label(identity.name)
            let prepared = try TatwoMemoryLock.run { () throws -> Prepared in
                let late = EngineMemoryLinks.commit(memory, message: commitMessage("自動記下"))
                if let failure = late.first(where: Self.isFailureNote) { throw Failure(reason: failure) }
                let planned = try prepare(memory: memory, other: primaryTip, otherIsPrimary: true, label: label,
                                          day: EngineMemoryLinks.dayStamp(Date()))
                do {
                    try apply(planned, memory: memory, local: "這台", allowRemoving: allowed)
                } catch let failure as Failure where failure.kind != .general {
                    localIssue = failure
                }
                return planned
            }
            outgoingCommit = prepared.target ?? revParse(memory, "HEAD")
        } catch {
            return finish(.failed, Self.short(error))
        }
        // 5. 有主設備還沒有的 commit：推到收件分支，再用設備簽章請主設備收。
        guard let outgoing = outgoingCommit else { return finish(.failed, "讀不到這台的記憶版本") }
        if !isAncestor(memory, outgoing, of: primaryTip) {
            if let problem = treeProblem(memory, commit: outgoing, reference: primaryTip) {
                return finish(.failed, "這台的記憶" + problem + "，這輪不送")
            }
            // 這次會讓主設備少掉的檔（像這台的資料夾被清空）：太多就先不送，等使用者在狀態列確認。
            let removing: [String], primaryCount: Int
            do {
                let primaryFiles = Array(try tree(memory, primaryTip).keys)
                removing = TatwoMemorySyncMerge.removed(from: primaryFiles, to: Array(try tree(memory, outgoing).keys))
                primaryCount = primaryFiles.count
            } catch { return finish(.failed, Self.short(error)) }
            let massive = TatwoMemorySyncMerge.massRemoval(removed: removing.count, total: primaryCount)
            if massive, !Set(removing).isSubset(of: allowed) {
                return finish(.held, held: removing, outgoing: true)
            }
            let ref = Self.inboxRef(identity.deviceID)
            do { try pushPrimary(paths, repository: repository, commit: outgoing, ref: ref) } catch {
                return failed(error, pushing: true)
            }
            var payload: [String: Any] = ["ref": ref, "commit": outgoing]
            if massive { payload["allowRemoving"] = removing }
            do {
                let reply = try dispatch.callPrimary(method: "memory_sync_receive", payload: payload)
                guard reply["status"] is String else { throw Failure(reason: "主設備的回覆看不懂") }
            } catch {
                return failed(error)
            }
            git(["update-ref", Self.ackedRef, outgoing], in: memory)
        }
        if let localIssue {
            return localIssue.kind == .held ? finish(.held, held: localIssue.paths, outgoing: false)
                : finish(.failed, localIssue.reason)
        }
        // 第一次同步成功：「等主設備同步」的標記拿掉（只是 App 自己放在 .git 裡的標記檔）。
        try? FileManager.default.removeItem(at: memory.appendingPathComponent(".git/" + EngineMemoryLinks.awaitingPrimaryMarker))
        clearApprovals()
        next.lastSync = Date()
        return finish(.synced)
    }

    // MARK: 主設備收件（OSAgentBridge 驗過設備簽章後呼叫）

    func handle(method: String, payload: [String: Any], sender: String) throws -> [String: Any] {
        let memory = paths().memory
        let available = FileManager.default.fileExists(atPath: memory.appendingPathComponent(".git").path)
        switch method {
        case "memory_sync_target":
            guard payload.isEmpty else { throw Failure(reason: "invalid_memory_sync_target") }
            return ["repository": memory.path, "available": available]
        case "memory_sync_export":
            guard payload.isEmpty || Set(payload.keys) == ["base"], (try? dispatch.identity().role) == .primary, available,
                  let commit = revParse(memory, "HEAD") else { throw Failure(reason: "memory_bundle_unavailable") }
            if let raw = payload["base"] {
                guard let base = raw as? String, DeviceStatusReader.validCommit(base) else { throw Failure(reason: "invalid_memory_bundle") }
            }
            return try exportBundle(memory: memory, commit: commit, base: payload["base"] as? String)
        case "memory_sync_import":
            guard Set(payload.keys) == ["bundle", "commit", "ref"],
                  let ref = payload["ref"] as? String, ref == Self.inboxRef(sender),
                  (try? dispatch.identity().role) == .primary, available else { throw Failure(reason: "invalid_memory_bundle") }
            try importBundle(payload, memory: memory, ref: ref)
            return ["received": true]
        case "memory_sync_receive":
            // allowRemoving：送件那台的使用者確認過的刪除（一次拿掉很多檔時才帶）。
            let keys = Set(payload.keys)
            guard keys == ["ref", "commit"] || keys == ["ref", "commit", "allowRemoving"],
                  let ref = payload["ref"] as? String,
                  let commit = (payload["commit"] as? String)?.lowercased(),
                  ref == Self.inboxRef(sender), DeviceStatusReader.validCommit(commit) else {
                throw Failure(reason: "invalid_memory_sync_receipt")
            }
            var allowed: Set<String> = []
            if let raw = payload["allowRemoving"] {
                guard let list = raw as? [String], list.count <= TatwoMemorySyncMerge.maxEntries else {
                    throw Failure(reason: "invalid_memory_sync_receipt")
                }
                allowed = Set(list)
            }
            guard (try? dispatch.identity().role) == .primary else { throw Failure(reason: "not_primary") }
            guard available else { throw Failure(reason: "主設備的記憶資料夾沒接上") }
            let name = dispatch.registry.list().first { $0.id == sender }?.name ?? ""
            let label = Self.label(name)
            return try TatwoMemoryLock.run {
                // 1. 先 commit 本機（Claude 可能正在寫）。
                let notes = EngineMemoryLinks.commit(memory, message: commitMessage("自動記下"))
                if let failure = notes.first(where: Self.isFailureNote) { throw Failure(reason: "主設備：" + failure) }
                // 2. 收件分支真的指到這個 commit。
                guard revParse(memory, ref) == commit else { throw Failure(reason: "branch_not_received") }
                // 3. 樹裡只准一般檔（連結檔、子模組、memory/ 以外的路徑一律拒收）、帶進來的東西不能像含金鑰；
                //    可疑的 commit 留在收件分支當證據。
                let head = revParse(memory, "HEAD")
                if let problem = treeProblem(memory, commit: commit, reference: head) {
                    throw Failure(reason: "主設備拒收：" + problem)
                }
                // 4. 同一套規則合併（hooks 關掉），commit。錯誤都用主設備的角度說（副設備會原樣顯示）。
                let prepared: Prepared
                do {
                    prepared = try prepare(memory: memory, other: commit, otherIsPrimary: false, label: label,
                                           day: EngineMemoryLinks.dayStamp(Date()))
                    try apply(prepared, memory: memory, local: "主設備", allowRemoving: allowed)
                } catch let failure as Failure where failure.kind == .held {
                    throw Failure(reason: "主設備先不套用：這次會刪掉主設備 \(failure.paths.count) 條記憶，要在送出的那台確認",
                                  kind: .held, paths: failure.paths)
                } catch let failure as Failure {
                    throw Self.onPrimary(failure)
                }
                // 5. 收完清掉收件分支（內容已經在主設備的歷史裡）。
                git(["update-ref", "-d", ref, commit], in: memory)
                return ["status": prepared.kind, "head": revParse(memory, "HEAD") ?? "", "copies": prepared.copies]
            }
        default:
            throw Failure(reason: "unknown_memory_sync_method")
        }
    }

    // MARK: 合併

    /// other＝另一邊的 commit；otherIsPrimary：副設備合併主設備的＝true、主設備收副設備的＝false。
    /// 結果是一個有兩個 parent 的 commit，再用 `merge --ff-only --no-overwrite-ignore` 放進工作樹：
    /// 這台剛好有檔在改、會被蓋掉時 git 會拒絕，就停在原狀，下一輪再試。
    @discardableResult
    func merge(memory: URL, other: String, otherIsPrimary: Bool, label: String, day: String,
               allowRemoving: Set<String> = []) throws -> Outcome {
        let prepared = try prepare(memory: memory, other: other, otherIsPrimary: otherIsPrimary, label: label, day: day)
        try apply(prepared, memory: memory, local: otherIsPrimary ? "這台" : "主設備", allowRemoving: allowRemoving)
        return Outcome(kind: prepared.kind, copies: prepared.copies)
    }

    /// 算出合併後的 commit（不動這台的工作樹與 index）。
    func prepare(memory: URL, other: String, otherIsPrimary: Bool, label: String, day: String) throws -> Prepared {
        guard let head = revParse(memory, "HEAD") else { return Prepared(kind: "fast_forward", head: nil, target: other) }
        if head == other || isAncestor(memory, other, of: head) { return Prepared(kind: "up_to_date", head: head, target: nil) }
        let headTree = try tree(memory, head)
        if isAncestor(memory, head, of: other) {
            let otherTree = try tree(memory, other)
            return Prepared(kind: "fast_forward", head: head, target: other,
                            removed: TatwoMemorySyncMerge.removed(from: Array(headTree.keys), to: Array(otherTree.keys)),
                            total: headTree.count)
        }
        let base = mergeBase(memory, head, other)
        let otherTree = try tree(memory, other)
        let baseTree = try base.map { try tree(memory, $0) } ?? [:]
        let primaryTree = otherIsPrimary ? otherTree : headTree
        let secondaryTree = otherIsPrimary ? headTree : otherTree
        var result: [String: TatwoMemorySyncMerge.Entry] = [:]
        var keepBoth: [String] = []
        let paths = Set(primaryTree.keys).union(secondaryTree.keys).union(baseTree.keys).sorted()
        for path in paths {
            switch TatwoMemorySyncMerge.resolve(base: baseTree[path], primary: primaryTree[path],
                                                secondary: secondaryTree[path], path: path) {
            case .take(let entry):
                if let entry { result[path] = entry }
            case .union:
                guard let primary = primaryTree[path], let secondary = secondaryTree[path],
                      let primaryText = String(data: try blob(memory, primary.id), encoding: .utf8),
                      let secondaryText = String(data: try blob(memory, secondary.id), encoding: .utf8) else {
                    result[path] = primaryTree[path]
                    keepBoth.append(path)
                    continue
                }
                let baseText = try baseTree[path].flatMap { String(data: try blob(memory, $0.id), encoding: .utf8) }
                let merged = TatwoMemorySyncMerge.unionLines(base: baseText, primary: primaryText, secondary: secondaryText)
                result[path] = TatwoMemorySyncMerge.Entry(mode: primary.mode, id: try writeBlob(memory, Data(merged.utf8)))
            case .both:
                result[path] = primaryTree[path]
                keepBoth.append(path)
            }
        }
        // 另存的名字不能撞到已經有的檔或資料夾（不分大小寫）。
        var taken = Set(result.keys)
        for path in result.keys {
            var prefix = ""
            for part in path.split(separator: "/").dropLast() {
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + String(part)
                taken.insert(prefix)
            }
        }
        var copies = 0
        func keepCopy(of entry: TatwoMemorySyncMerge.Entry, path: String) throws {
            let marked = TatwoMemorySyncMerge.markConflict(try blob(memory, entry.id), path: path)
            let id = try writeBlob(memory, marked)
            // 同一版已經另存過（不管哪一天、哪一邊存的）：不再產生第二份。
            if result.values.contains(where: { $0.id == id }) { return }
            let copy = TatwoMemorySyncMerge.copyPath(for: path, label: label, day: day, taken: taken)
            taken.insert(copy)
            result[copy] = TatwoMemorySyncMerge.Entry(mode: entry.mode, id: id)
            copies += 1
        }
        for path in keepBoth {
            guard let secondary = secondaryTree[path] else { continue }
            try keepCopy(of: secondary, path: path)
        }
        // macOS 檔名不分大小寫：Foo.md 和 foo.md 放進工作樹只剩一個。主設備那版留原名，其他的另存一份（內容一樣就不用存）。
        for group in TatwoMemorySyncMerge.caseGroups(Array(result.keys)) {
            let keep = group.first { primaryTree[$0] != nil && primaryTree[$0] == result[$0] } ?? group[0]
            for path in group where path != keep {
                guard let entry = result.removeValue(forKey: path) else { continue }
                if entry.id == result[keep]?.id { continue }
                try keepCopy(of: entry, path: path)
            }
        }
        // 資料夾只差大小寫、檔和資料夾同名：放進工作樹 git 會默默丟掉一邊，這輪不合併、說清楚。
        if let problem = TatwoMemorySyncMerge.layoutProblem(Array(result.keys)) {
            throw Failure(reason: problem + "，改個名字才能同步")
        }
        let treeID = try writeTree(memory, result)
        var message = otherIsPrimary ? "TATWO OS：合併主設備的記憶" : "TATWO OS：收到 \(label) 的記憶"
        if copies > 0 { message += "（\(copies) 條兩邊都改過，兩版都留）" }
        let made = git(["commit-tree", treeID, "-p", head, "-p", other, "-m", message], in: memory)
        guard made.status == 0, DeviceStatusReader.validCommit(made.text) else { throw Failure(reason: "合併的 commit 做不出來") }
        return Prepared(kind: "merged", head: head, target: made.text,
                        removed: TatwoMemorySyncMerge.removed(from: Array(headTree.keys), to: Array(result.keys)),
                        total: headTree.count, copies: copies)
    }

    /// 放進這台的工作樹。local＝「這台」或「主設備」（錯誤那句話用誰的角度說）。
    /// 會被擋住就先說是哪個檔；一次拿掉太多先不套用（使用者確認過的除外）；要拿掉的檔先封存再放。
    func apply(_ prepared: Prepared, memory: URL, local: String, allowRemoving: Set<String>) throws {
        guard let target = prepared.target else { return }
        let blockers = blockingFiles(memory, head: prepared.head, target: target)
        if !blockers.isEmpty {
            throw Failure(reason: "\(local)的 \(TatwoMemorySyncMerge.names(blockers)) 還沒收進 git（正在寫或像含金鑰），先不合併",
                          kind: .blocked, paths: blockers)
        }
        if TatwoMemorySyncMerge.massRemoval(removed: prepared.removed.count, total: prepared.total),
           !Set(prepared.removed).isSubset(of: allowRemoving) {
            throw Failure(reason: "另一台刪了 \(prepared.removed.count) 條記憶，先不套用", kind: .held, paths: prepared.removed)
        }
        if let head = prepared.head, !prepared.removed.isEmpty {
            try archiveRemoved(memory, paths: prepared.removed, from: head)
        }
        try fastForward(memory, to: target, local: local)
    }

    private func fastForward(_ memory: URL, to commit: String, local: String) throws {
        let result = git(["merge", "--ff-only", "--no-overwrite-ignore", "-q", commit], in: memory)
        guard result.status == 0 else { throw Failure(reason: "\(local)有檔正在改，合併先停", kind: .blocked) }
        // W180 E1a＋E1b 合併：同步拉進來的記憶要馬上進候選快取（不用等 20 秒的自動重讀）。
        TatwoMemoryIndex.shared.invalidate()
    }

    /// 合併會改到、這台卻還沒收進 git 的檔（改過沒 commit、新檔、被忽略的檔——例如看起來含金鑰而留在這台的）。
    func blockingFiles(_ memory: URL, head: String?, target: String) -> [String] {
        let changed = head.map { git(["diff", "--name-only", "-z", "--no-renames", $0, target], in: memory) }
            ?? git(["ls-tree", "-r", "-z", "--name-only", "--full-tree", target], in: memory)
        let changedPaths = changed.output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard !changedPaths.isEmpty else { return [] }
        let status = git(["status", "--porcelain=v1", "-z", "--ignored=matching", "--untracked-files=all", "--no-renames"],
                         in: memory)
        let dirty = status.output.split(separator: 0).compactMap { record -> String? in
            record.count > 3 ? String(decoding: record.dropFirst(3), as: UTF8.self) : nil
        }
        return TatwoMemorySyncMerge.blocking(changed: changedPaths, dirty: dirty)
    }

    /// 同步要從這台拿掉的檔：先複製到入口的 archive/memory-sync-deleted-<日期>/（同一版不重複存），附還原說明，再放進工作樹。
    func archiveRemoved(_ memory: URL, paths removed: [String], from commit: String) throws {
        let fm = FileManager.default
        let known = try tree(memory, commit)
        let day = EngineMemoryLinks.dayStamp(Date())
        let folder = memory.deletingLastPathComponent().appendingPathComponent("archive", isDirectory: true)
            .appendingPathComponent("memory-sync-deleted-" + day, isDirectory: true)
        var lines: [String] = []
        for path in removed.sorted() {
            guard let entry = known[path], TatwoMemorySyncMerge.safePath(path) else { continue }
            let data = try blob(memory, entry.id)
            var relative = path
            var n = 2
            var already = false
            while fm.fileExists(atPath: folder.appendingPathComponent(relative).path) {
                if fm.contents(atPath: folder.appendingPathComponent(relative).path) == data { already = true; break }
                relative = TatwoMemorySyncMerge.numbered(path, n)
                n += 1
            }
            if already { continue }
            let destination = folder.appendingPathComponent(relative)
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .withoutOverwriting)
            } catch {
                throw Failure(reason: "要拿掉的記憶封存不進 archive，這輪先不合併")
            }
            lines.append("- `\(relative)` → 記憶資料夾的 `\(path)`")
        }
        guard !lines.isEmpty else { return }
        let readme = folder.appendingPathComponent("還原.md")
        var text = (try? String(contentsOf: readme, encoding: .utf8))
            ?? "# 同步時從記憶資料夾拿掉的檔\n\n另一台刪掉、同步時跟著從這台拿掉的記憶，先複製到這裡。\n"
            + "要放回去：把檔複製回入口的 memory/ 同一個位置（下一輪會自動同步到另一台）；也可以從記憶的 git 歷史找回。\n"
        text += "\n## \(EngineMemoryLinks.timeStamp(Date()))\n" + lines.joined(separator: "\n") + "\n"
        do { try Data(text.utf8).write(to: readme, options: .atomic) } catch {
            throw Failure(reason: "要拿掉的記憶封存不進 archive，這輪先不合併")
        }
    }

    // MARK: 傳輸（副設備）

    private func fetchPrimary(_ paths: EngineMemoryPaths, repository: String) throws {
        if let fetchOverride { return try fetchOverride(paths, repository) }
        let peer = try dispatch.primary()
        if try RemoteHostLink(environment: dispatch.environment).requiresFleetGate(peer) {
            let base = revParse(paths.memory, Self.primaryRef)
            let packet = try dispatch.callPrimary(method: "memory_sync_export", payload: base.map { ["base": $0] } ?? [:])
            try importBundle(packet, memory: paths.memory, ref: Self.primaryRef)
            return
        }
        var failures: [Error] = []
        let fetched = EngineMemoryLinks.withPinnedPrimaryGit(paths: paths, environment: dispatch.environment) { pinned -> Bool? in
            let arguments = ["-c", "core.hooksPath=/dev/null", "fetch", "-q", "--no-tags", "--", "\(pinned.destination):\(repository)", "+HEAD:" + Self.primaryRef]
            #if DEBUG
            let result = fixtureFetchGit?(arguments, pinned.environment) ?? EngineMemoryLinks.run("/usr/bin/git", arguments, in: paths.memory, environment: pinned.environment, timeout: 90, captureDiagnostics: true)
            #else
            let result = EngineMemoryLinks.run("/usr/bin/git", arguments, in: paths.memory, environment: pinned.environment, timeout: 90, captureDiagnostics: true)
            #endif
            if result.status == 0 { return true }
            // git exits 128 after an SSH failure; only explicit SSH network diagnostics prove offline.
            failures.append(DeviceFleetGate.isSSHUnreachable(status: 255, diagnostics: result.output)
                ? DeviceFleetGate.CallError.unreachable : Failure(reason: "fetch_failed"))
            return nil
        }
        guard fetched == true else { throw DeviceFleetGate.rpcFailure(failures.isEmpty ? [Failure(reason: "fetch_failed")] : failures) }
    }

    /// 跟 DeviceDispatch.pushSubmission 同一套：同一條 pin 住主機金鑰的連線先問位置，再只推這個 commit 到收件分支。
    /// 問位置那一下自己簽章、自己送：包在 serializedRPC 裡，跟其他對主設備的簽章呼叫排成一列（序號才不會被當成重送）。
    #if DEBUG
    var fixturePushLink: (() -> RemoteHostLink)?
    var fixtureFetchGit: (([String], [String: String]) -> (status: Int32, output: String))?
    #endif
    private func pushPrimary(_ paths: EngineMemoryPaths, repository: String, commit: String, ref: String) throws {
        if let pushOverride { return try pushOverride(paths, repository, commit, ref) }
        let peer = try dispatch.primary()
        var link = RemoteHostLink(environment: dispatch.environment)
        #if DEBUG
        link = fixturePushLink?() ?? link
        #endif
        let target = try dispatch.callPrimary(method: "memory_sync_target", payload: [:])
        guard target["repository"] as? String == repository else { throw Failure(reason: "primary_memory_moved") }
        if try link.requiresFleetGate(peer) {
            // This exact tip was fetched and authenticated in the same round. Never
            // exclude an unconfirmed local commit merely to make a smaller packet.
            var packet = try exportBundle(memory: paths.memory, commit: commit, base: revParse(paths.memory, Self.primaryRef)); packet["ref"] = ref
            _ = try dispatch.callPrimary(method: "memory_sync_import", payload: packet)
            return
        }
        try link.pushPinned(device: peer, repository: repository, localRepository: paths.memory, commit: commit, ref: ref)
    }

    /// Restricted rows exchange one bounded Git bundle through authenticated memory RPC.
    /// No remote command, repository path or arbitrary ref is supplied by a peer.
    private func exportBundle(memory: URL, commit: String, base: String? = nil) throws -> [String: Any] {
        let verifiedBase = base.flatMap { DeviceStatusReader.validCommit($0) && isAncestor(memory, $0, of: commit) ? $0 : nil }
        if verifiedBase == commit { return ["unchanged": true, "commit": commit] }
        guard DeviceStatusReader.validCommit(commit), treeProblem(memory, commit: commit, reference: verifiedBase) == nil else {
            throw Failure(reason: "invalid_memory_bundle_tree")
        }
        return try TatwoMemoryLock.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("memory-bundle-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("memory.bundle"), ref = "refs/tatwo/export/" + UUID().uuidString
            guard git(["update-ref", ref, commit], in: memory).status == 0 else { throw Failure(reason: "memory_bundle_export_failed") }
            defer { _ = git(["update-ref", "-d", ref], in: memory) }
            let exclusions = verifiedBase.map { ["^" + $0] } ?? []
            guard git(["bundle", "create", file.path, ref] + exclusions, in: memory).status == 0 else { throw Failure(reason: "memory_bundle_export_failed") }
            guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 2 * 1024 * 1024 else { throw Failure(reason: "memory_bundle_too_large") }
            let bytes = try DeviceDispatchSafeFile.read(file, limit: 2 * 1024 * 1024)
            return ["bundle": bytes.base64EncodedString(), "commit": commit]
        }
    }
    private func importBundle(_ packet: [String: Any], memory: URL, ref: String) throws {
        if packet["unchanged"] as? Bool == true {
            guard Set(packet.keys) == ["unchanged", "commit"], let commit = packet["commit"] as? String,
                  DeviceStatusReader.validCommit(commit), revParse(memory, ref) == commit else { throw Failure(reason: "invalid_memory_bundle") }
            return
        }
        guard let commit = packet["commit"] as? String, DeviceStatusReader.validCommit(commit),
              let encoded = packet["bundle"] as? String, encoded.utf8.count <= 3 * 1024 * 1024,
              let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= 2 * 1024 * 1024 else {
            throw Failure(reason: "invalid_memory_bundle")
        }
        try TatwoMemoryLock.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("memory-bundle-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("memory.bundle")
            try bytes.write(to: file)
            let heads = git(["bundle", "list-heads", file.path], in: memory)
            let fields = heads.text.split(whereSeparator: \.isWhitespace)
            guard heads.status == 0, fields.count == 2, fields[0] == commit,
                  fields[1].hasPrefix("refs/tatwo/export/"), UUID(uuidString: String(fields[1].dropFirst("refs/tatwo/export/".count))) != nil,
                  git(["bundle", "verify", file.path], in: memory).status == 0 else { throw Failure(reason: "invalid_memory_bundle") }
            let quarantine = "refs/tatwo/quarantine/" + UUID().uuidString
            defer { _ = git(["update-ref", "-d", quarantine], in: memory) }
            guard git(["fetch", "-q", "--no-tags", "--no-write-fetch-head", "--", file.path, "+" + fields[1] + ":" + quarantine], in: memory).status == 0,
                  revParse(memory, quarantine) == commit,
                  treeProblem(memory, commit: commit, reference: revParse(memory, "HEAD")) == nil,
                  git(["update-ref", ref, commit], in: memory).status == 0 else { throw Failure(reason: "invalid_memory_bundle_tree") }
        }
    }

    // MARK: git 小工具（不在主執行緒跑；hooks 關掉；作者固定 TATWO OS）

    @discardableResult
    func git(_ arguments: [String], in directory: URL, input: Data? = nil,
             environment extra: [String: String] = [:], timeout: TimeInterval = 60) -> GitResult {
        Self.runGit(arguments, in: directory, input: input, environment: extra, timeout: timeout)
    }

    @discardableResult
    static func runGit(_ arguments: [String], in directory: URL, input: Data? = nil,
                       environment extra: [String: String] = [:], timeout: TimeInterval = 60) -> GitResult {
        guard !Thread.isMainThread else {
            count(onMain: false)
            return GitResult(status: -2, output: Data())
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=TATWO OS",
                             "-c", "user.email=tatwo-os@localhost", "-c", "core.quotepath=false"] + arguments
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_TERMINAL_PROMPT"] = "0"
        for (key, value) in extra { env[key] = value }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // 標準輸入用暫存檔（不用 pipe：git 提早結束時寫端不會卡住或吃 SIGPIPE）。
        var inputFile: URL?
        var inputHandle: FileHandle?
        defer {
            try? inputHandle?.close()
            if let inputFile { try? FileManager.default.removeItem(at: inputFile) }
        }
        if let input {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("w180-memsync-" + UUID().uuidString)
            guard FileManager.default.createFile(atPath: url.path, contents: input, attributes: [.posixPermissions: 0o600]),
                  let handle = try? FileHandle(forReadingFrom: url) else { return GitResult(status: -1, output: Data()) }
            inputFile = url
            inputHandle = handle
            process.standardInput = handle
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        do { try process.run() } catch { return GitResult(status: -1, output: Data()) }
        let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        deadline.schedule(deadline: .now() + timeout)
        deadline.setEventHandler { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
        deadline.resume()
        defer { deadline.cancel() }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return GitResult(status: process.terminationStatus, output: output)
    }

    func revParse(_ memory: URL, _ name: String) -> String? {
        let result = git(["rev-parse", "--verify", "-q", name + "^{commit}"], in: memory)
        return result.status == 0 && DeviceStatusReader.validCommit(result.text) ? result.text : nil
    }

    func isAncestor(_ memory: URL, _ ancestor: String, of descendant: String) -> Bool {
        git(["merge-base", "--is-ancestor", ancestor, descendant], in: memory).status == 0
    }

    private func mergeBase(_ memory: URL, _ a: String, _ b: String) -> String? {
        let result = git(["merge-base", a, b], in: memory)
        return result.status == 0 && DeviceStatusReader.validCommit(result.text) ? result.text : nil
    }

    private func listTree(_ memory: URL, _ commit: String) throws -> [TatwoMemorySyncMerge.TreeEntry] {
        let result = git(["ls-tree", "-r", "-z", "-l", "--full-tree", commit], in: memory)
        guard result.status == 0, let entries = TatwoMemorySyncMerge.parseTree(result.output) else {
            throw Failure(reason: "讀不到記憶的內容")
        }
        return entries
    }

    private func tree(_ memory: URL, _ commit: String) throws -> [String: TatwoMemorySyncMerge.Entry] {
        TatwoMemorySyncMerge.entries(try listTree(memory, commit))
    }

    /// 一句不安全的原因；nil＝可以合併。reference＝對方已經有的那一邊（送出時是主設備的版本、收件時是自己的 HEAD）。
    func treeProblem(_ memory: URL, commit: String, reference: String?) -> String? {
        guard let entries = try? listTree(memory, commit) else { return "讀不到內容" }
        let known = reference.flatMap { try? tree(memory, $0) } ?? [:]
        if let problem = TatwoMemorySyncMerge.problem(in: entries, reference: known) { return problem }
        return secretProblem(memory, commit: commit, reference: reference)
    }

    /// W180 E1b 審查：金鑰檢查不能只靠來源端的 EngineMemoryLinks.commit（手動 git commit 會繞過）。
    /// 這次會送出／收進來、對方還沒有的東西（含整段歷史，推送會一起帶過去）逐一檢查：看起來含金鑰或權杖的檔、commit 說明都不收不送。
    func secretProblem(_ memory: URL, commit: String, reference: String?) -> String? {
        var arguments = ["rev-list", "--objects", commit]
        if let reference { arguments += ["--not", reference] }
        let listed = git(arguments, in: memory)
        guard listed.status == 0 else { return "讀不到內容" }
        var names: [String: String] = [:]
        var ids: [String] = []
        for line in listed.output.split(separator: 0x0A) {
            let text = String(decoding: line, as: UTF8.self)
            let id = String(text.prefix(40))
            guard DeviceStatusReader.validCommit(id) else { continue }
            ids.append(id)
            if text.count > 41 { names[id] = String(text.dropFirst(41)) }
        }
        guard !ids.isEmpty else { return nil }
        let request = Data((ids.joined(separator: "\n") + "\n").utf8)
        let checked = git(["cat-file", "--batch-check"], in: memory, input: request)
        guard checked.status == 0, let kinds = TatwoMemorySyncMerge.parseBatch(checked.output, withContent: false) else {
            return "讀不到內容"
        }
        // 跟 EngineMemoryLinks.hasSecret 一樣只看 8 MB 以內的（最新版超過 8 MB 的檔本來就不收）。
        let wanted = kinds.filter { ($0.type == "blob" || $0.type == "commit") && $0.size <= TatwoMemorySyncMerge.maxFileBytes }
        guard !wanted.isEmpty else { return nil }
        let content = git(["cat-file", "--batch"], in: memory, input: Data((wanted.map(\.id).joined(separator: "\n") + "\n").utf8))
        guard content.status == 0, let objects = TatwoMemorySyncMerge.parseBatch(content.output, withContent: true) else {
            return "讀不到內容"
        }
        for object in objects where Self.looksSecret(object.data) {
            if object.type == "commit" { return "有 commit 說明看起來含金鑰或權杖" }
            return "有檔看起來含金鑰或權杖：" + TatwoMemorySyncMerge.display(names[object.id] ?? object.id)
        }
        return nil
    }

    /// 跟 EngineMemoryLinks.hasSecret 同一組樣式；內容不寫進任何紀錄，只回有沒有。
    static func looksSecret(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        return EngineMemoryLinks.secretPatterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private func blob(_ memory: URL, _ id: String) throws -> Data {
        let result = git(["cat-file", "blob", id], in: memory)
        guard result.status == 0 else { throw Failure(reason: "讀不到記憶的內容") }
        return result.output
    }

    private func writeBlob(_ memory: URL, _ data: Data) throws -> String {
        let result = git(["hash-object", "-w", "--no-filters", "--stdin"], in: memory, input: data)
        guard result.status == 0, DeviceStatusReader.validCommit(result.text) else { throw Failure(reason: "記憶寫不進 git") }
        return result.text
    }

    /// 用一個暫存的 index 組出合併後的樹；不碰這台的 index 與工作樹。
    private func writeTree(_ memory: URL, _ entries: [String: TatwoMemorySyncMerge.Entry]) throws -> String {
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("w180-memsync-index-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: index) }
        var input = Data()
        for (path, entry) in entries.sorted(by: { $0.key < $1.key }) {
            input.append(Data("\(entry.mode) \(entry.id)\t\(path)".utf8))
            input.append(0)
        }
        let environment = ["GIT_INDEX_FILE": index.path]
        guard git(["update-index", "-z", "--index-info"], in: memory, input: input, environment: environment).status == 0 else {
            throw Failure(reason: "合併的內容組不起來")
        }
        let written = git(["write-tree"], in: memory, environment: environment)
        guard written.status == 0, DeviceStatusReader.validCommit(written.text) else { throw Failure(reason: "合併的內容組不起來") }
        return written.text
    }

    /// 這台還沒交給主設備的 commit 數（主設備的最新版與上次主設備收下的都不算）。
    func pendingCount(_ memory: URL) -> Int {
        guard revParse(memory, "HEAD") != nil else { return 0 }
        var arguments = ["rev-list", "--count", "HEAD"]
        let exclude = [Self.primaryRef, Self.ackedRef].filter { revParse(memory, $0) != nil }
        if !exclude.isEmpty { arguments += ["--not"] + exclude }
        return Int(git(arguments, in: memory).text) ?? 0
    }

    func conflictCount(_ memory: URL) -> Int {
        let listed = git(["ls-files", "-z"], in: memory)
        guard listed.status == 0 else { return 0 }
        return listed.output.split(separator: 0).filter {
            TatwoMemorySyncMerge.isConflictCopy(String(decoding: $0, as: UTF8.self))
        }.count
    }

    private func commitMessage(_ what: String) -> String {
        "TATWO OS：\(what)（\(EngineMemoryLinks.dayStamp(Date())) \(EngineMemoryLinks.timeStamp(Date()))）"
    }

    static func label(_ name: String) -> String {
        let safe = EngineMemoryLinks.safeName(name)
        return safe.isEmpty ? "device" : safe
    }

    /// EngineMemoryLinks.commit 的回覆裡哪些是「這次沒 commit」（其他是提醒，例如擋下含金鑰的檔）。
    static func isFailureNote(_ note: String) -> Bool {
        note.contains("失敗") || note.contains("沒有 commit")
    }

    // MARK: 錯誤變成一句白話

    /// 連線本身不通（SSH 隧道、socket、逾時、沒有可用的位址）才算離線；主設備回了話的錯誤不算。
    static func isTransport(_ error: Error) -> Bool {
        if let gate = error as? DeviceFleetGate.CallError { return gate == .unreachable || gate == .appUnavailable }
        guard let link = error as? RemoteHostLinkError else { return false }
        switch link {
        case .remoteError(let detail): return detail == "no_active_endpoints"
        case .invalidResponse, .socketPathTooLong: return false
        default: return true
        }
    }

    /// 錯誤的原始字樣，只供分類與 audit。
    static func raw(_ error: Error) -> String {
        DeviceFleetReason.code(error) ?? String(describing: error)
    }

    /// 錯誤變成一句短的白話：主設備回的中文原因直接用；英文代碼換成中文；`Failure(reason: "…")` 這種型別字樣拿掉。
    static func short(_ error: Error, pushing: Bool = false) -> String {
        DeviceFleetReason.plain(error, context: .memory(pushing: pushing, offline: isTransport(error)))
    }

    /// 主設備收件時的錯誤：中文的話用主設備的角度說（副設備會原樣顯示，才不會以為是自己的檔）。
    static func onPrimary(_ failure: Failure) -> Failure {
        let chinese = failure.reason.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
        guard chinese, !failure.reason.hasPrefix("主設備") else { return failure }
        return Failure(reason: "主設備：" + failure.reason, kind: failure.kind, paths: failure.paths)
    }

    // MARK: 檔案變動（FSEvents，連子資料夾、原地改檔都看得到；.git 裡的不算）

    private func attachWatcher(_ path: String) {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let exists = EngineMemoryLinks.directoryExists(resolved)
        if stream != nil, watchedPath == resolved, exists { return }
        detachWatcher()
        guard exists else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let engine = Unmanaged<TatwoMemorySyncEngine>.fromOpaque(info).takeUnretainedValue()
            let changed = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray) as? [String] ?? []
            engine.filesChanged(changed)
        }, &context, [resolved] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
        watchedPath = resolved
    }

    private func detachWatcher() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        watchedPath = nil
    }

    /// 在 queue 上被叫（FSEventStreamSetDispatchQueue）。
    private func filesChanged(_ changed: [String]) {
        guard started, changed.isEmpty || changed.contains(where: { !$0.contains("/.git/") && !$0.hasSuffix("/.git") }) else { return }
        pendingChange?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scheduledRound(.change) }
        pendingChange = work
        queue.asyncAfter(deadline: .now() + Self.changeDelay, execute: work)
    }
}

/// 畫面用的同步狀態（@Published）；真正的工作在 TatwoMemorySyncEngine.shared 的背景佇列。
@MainActor
final class TatwoMemorySync: ObservableObject {
    static let shared = TatwoMemorySync()
    @Published private(set) var status: TatwoMemorySyncStatus
    private var started = false

    private init() {
        status = TatwoMemorySyncEngine.shared.status
        TatwoMemorySyncEngine.shared.setStatusHandler { [weak self] next in
            Task { @MainActor in self?.status = next }
        }
    }

    /// App 啟動時叫一次（AppShell）；重複叫沒有影響。
    func start() {
        guard !started else { return }
        started = true
        TatwoMemorySyncEngine.shared.start()
    }

    func syncNow() { TatwoMemorySyncEngine.shared.trigger(.manual) }

    /// 狀態列確認列按了「刪掉」：這次先不套用的刪除放行（拿掉的檔先封存到入口的 archive/）。
    func approveHeld() { TatwoMemorySyncEngine.shared.approveHeld() }
}
