import Darwin
import Foundation

// W183 R1b：ChatGPT 手腳的指令與長工作（接口 v2 §7、v3 V9–V12）。
//
// - run_command：45 秒內同步回；更長的用 job_start／job_status／job_output(offset)／job_cancel。
// - 每個 grant 同時最多 2 個、全域 3 個在跑（沒有排隊：超過就拒）。
// - V11 輸出證據：App 從 pipe 收輸出，寫進 App 管理、沙盒不可寫的輸出區 `<Hands>/output/<grant>/<job>/`（stdout.log、stderr.log、
//   meta.json；每個串流上限 8 MiB）。job_output 只能用 job id 翻頁讀、一律遮蔽；別的 grant 的 job 一律當作找不到（V9）。
// - W183 R1b：輸出在寫進磁碟之前就遮好（HandsStreamRedactor：跨 chunk 帶狀態），磁碟上沒有秘密原文；輸出區每個 grant、全部都有總量上限，
//   超過 7 天的清掉（保留政策）；啟動前最後一次授權檢查（撤銷、交件中、鎖住都不啟動）；跑的時候每 2 秒看磁碟、每 10 秒量工作區，
//   磁碟快滿或超過上限就收掉並鎖住（不只在結束後量）。
// - V12 request_id：以（grant、工具名、request_id）為鍵原子占位（O_EXCL 建檔）；進行中重試回「還在跑」＋ job id；
//   同鍵不同參數拒絕；保留 24 小時，存在 app/requests/（跨 App 重開；上次沒做完的回「被中斷」）。

final class HandsJobs: @unchecked Sendable {
    static let perGrant = 2
    static let global = 3
    static let outputCap = 8 * 1024 * 1024
    static let syncLimit: TimeInterval = 45
    static let defaultJobTimeout: TimeInterval = 300

    struct Job {
        let id: String
        let grantID: String
        let workspaceID: UUID
        let command: String
        let timeout: TimeInterval
        var state: String   // running｜exited｜failed｜timed_out｜cancelled｜interrupted
        let startedAt: Date
        var endedAt: Date?
        var exitCode: Int32?
        var signal: Int32?
        var stdoutBytes = 0
        var stderrBytes = 0
        var stdoutDropped = 0
        var stderrDropped = 0
        var swept = 0
        var diskLocked = false
        /// W183 R1b：啟動前被擋下的原因（撤銷、交件中、鎖住…）。
        var refusal: String?
        /// 頭尾各 32 KiB（run_command 同步回的那份）。
        var stdoutCapture = HandsSandbox.Captured()
        var stderrCapture = HandsSandbox.Captured()

        var finished: Bool { state != "running" }

        var meta: [String: Any] {
            var result: [String: Any] = ["job_id": id, "grant_id": grantID, "workspace_id": workspaceID.uuidString, "state": state,
                                         "started_at": ISO8601DateFormatter().string(from: startedAt), "timeout_s": Int(timeout),
                                         "stdout_bytes": stdoutBytes, "stderr_bytes": stderrBytes,
                                         "stdout_truncated": stdoutDropped > 0, "stderr_truncated": stderrDropped > 0]
            if let endedAt { result["ended_at"] = ISO8601DateFormatter().string(from: endedAt)
                result["seconds"] = (endedAt.timeIntervalSince(startedAt) * 10).rounded() / 10 }
            if let exitCode { result["exit_code"] = Int(exitCode) }
            if let signal { result["signal"] = Int(signal) }
            if swept > 0 { result["stopped_detached_processes"] = swept }
            if diskLocked { result["workspace_locked"] = "disk quota exceeded or the Mac is low on disk space" }
            if let refusal { result["not_started"] = refusal }
            return result
        }
    }

    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var done: [String: DispatchSemaphore] = [:]
    /// 每個 job 的兩個串流遮蔽器（只在收輸出的那條執行緒、與結束時用；一律在 lock 裡碰）。
    private var redactors: [String: (stdout: HandsStreamRedactor, stderr: HandsStreamRedactor)] = [:]
    /// W183 R1b：輸出區上限（每個 grant、全部）與保留天數；每個 grant 最多留幾個 job 的輸出。
    static let outputPerGrant: Int64 = 256 * 1024 * 1024
    static let outputTotal: Int64 = 1024 * 1024 * 1024
    static let outputRetention: TimeInterval = 7 * 86_400
    static let maxJobsKeptPerGrant = 200
    private let queue = DispatchQueue(label: "ai.tatwo.tatwo2.hands.jobs", qos: .userInitiated, attributes: .concurrent)
    let paths: HandsPaths

    init(paths: HandsPaths) { self.paths = paths }

    func outputDirectory(grant: String, job: String) -> URL { paths.output(grant: grant, job: job) }

    /// 開一個 job（在背景跑）。回 job 與「做完」的號誌。
    func start(command: String, workspace: HandsWorkspace, timeout: TimeInterval, service: HandsService,
               onStarted: ((String) -> Void)? = nil) throws -> (Job, DispatchSemaphore) {
        let grant = workspace.record.grantID
        try service.requireNoOutsideLinks(workspace)          // W183 R6c 審查：工作區裡有連到外面的硬連結就不跑（HandsHardLinks.swift）
        try service.requireDiskRoom()                        // W183 R1b：磁碟快滿就不跑
        guard pruneOutputs(keepingRoomFor: grant) else {      // 輸出區滿了（清過還是滿）＝不跑
            throw HandsToolError.invalid("output_area_full: too much command output is kept for this connection; try later")
        }
        lock.lock()
        let running = jobs.values.filter { !$0.finished }
        guard running.count < Self.global else { lock.unlock(); throw HandsToolError.invalid("busy: 3 commands are already running (all connections)") }
        guard running.filter({ $0.grantID == grant }).count < Self.perGrant else {
            lock.unlock(); throw HandsToolError.invalid("busy: 2 commands are already running for this connection; wait or job_cancel")
        }
        let id = "job_" + HandsAuth.hex(bytes: 8)
        let context = service.redactionContext(workspace: workspace)
        let summary = HandsRedactor.clip(HandsRedactor.redact(command, context: context), limit: 400)
        let job = Job(id: id, grantID: grant, workspaceID: workspace.id, command: summary, timeout: timeout, state: "running", startedAt: Date())
        forgetOldJobsLocked()
        jobs[id] = job
        redactors[id] = (HandsStreamRedactor(context: context), HandsStreamRedactor(context: context))
        let finished = DispatchSemaphore(value: 0)
        done[id] = finished
        lock.unlock()
        let directory = outputDirectory(grant: grant, job: id)
        do {
            try HandsFiles.ensureDirectory(paths.outputDir)
            try HandsFiles.ensureDirectory(directory)
        } catch {
            finish(id, state: "failed", result: nil)
            throw HandsToolError.invalid("output_area_unavailable")
        }
        writeMeta(id)
        onStarted?(id)
        let (sandbox, developer) = service.sandboxPaths(mode: .worker, workspace: workspace, scratch: workspace.scratch, forHelper: false)
        let env = service.sandboxEnvironment(scratch: workspace.scratch, developer: developer)
        let outFD = Self.openOutput(directory.appendingPathComponent("stdout.log"))
        let errFD = Self.openOutput(directory.appendingPathComponent("stderr.log"))
        let admit = service.admission(grantID: grant, level: 2, projectID: workspace.record.projectID, workspaceID: workspace.id, forWrite: true)
        let alive = HandsJobs.Flag()
        queue.async { [weak self, weak service] in
            guard let self else { return }
            // 跑的時候看磁碟（W183 R1b）：每 2 秒看可用空間、每 10 秒量工作區；快滿或超過上限就收掉並鎖住。
            DispatchQueue.global(qos: .utility).async { [weak self, weak service] in
                var ticks = 0
                while alive.isSet {
                    Thread.sleep(forTimeInterval: 2)
                    ticks += 1
                    guard alive.isSet, let self, let service else { return }
                    // W183 R8c 審查（GPT-6 高）：跑的時候也看啟用許可（信封過期、不再勾這台＝安全暫停）：收掉這一個工作（grant 留著、工作區不鎖）。
                    if service.permitCheck?() == false {
                        HandsSandbox.terminate(where: { $0.workspace == workspace.id.uuidString }, workspaces: [workspace.id.uuidString],
                                               marksDirectory: HandsPath.realpath(service.paths.marksDir.path))
                        return
                    }
                    // W183 R8 整合審查（GPT-6 高）：跑的時候也看中央上限（等級、專案）：中央收窄、這台的設定沒存成＝一樣收掉這一個工作。
                    // W183 R10 第二輪（GPT-6 7）：每一輪先重讀專案清單（改名、新增指向同一個資料夾的交易類專案＝分類換版本、受影響的工作當下取消），
                    // 不靠別人剛好叫過列表。
                    service.refreshTradingClassification()
                    if service.capProblem(level: 2, projectID: workspace.record.projectID) != nil {
                        HandsSandbox.terminate(where: { $0.workspace == workspace.id.uuidString }, workspaces: [workspace.id.uuidString],
                                               marksDirectory: HandsPath.realpath(service.paths.marksDir.path))
                        return
                    }
                    var reason: String?
                    if service.freeDiskBytes() < service.diskLowWaterBytes / 2 { reason = "disk_low" }
                    else if ticks % 5 == 0, let current = try? service.workspaceSnapshot(workspace.id), service.enforceDiskQuota(current) {
                        reason = "disk_quota_exceeded"
                    }
                    guard let reason else { continue }
                    self.markDiskLocked(id)
                    service.workspaceStore.lock(where: { $0.id == workspace.id }, reason: reason)   // 先鎖（新的寫入者進不來）再收
                    HandsSandbox.terminate(where: { $0.workspace == workspace.id.uuidString }, workspaces: [workspace.id.uuidString],
                                           marksDirectory: HandsPath.realpath(service.paths.marksDir.path))
                    return
                }
            }
            let result = HandsSandbox.run(profile: HandsSandbox.profile(sandbox), command: ["/bin/zsh", "-f", "+o", "bgnice", "-c", command],
                                          environment: env, cwd: workspace.repo, timeout: timeout, cpuSeconds: Int(timeout) + 30,
                                          tag: .init(workspace: workspace.id.uuidString, job: id, grant: grant), admit: admit,
                                          onChunk: { isStdout, data in self.capture(id, isStdout: isStdout, data: data, fd: isStdout ? outFD : errFD) })
            alive.clear()
            self.flush(id, outFD: outFD, errFD: errFD)
            if outFD >= 0 { close(outFD) }
            if errFD >= 0 { close(errFD) }
            let state: String
            if result.cancelled { state = "cancelled" }
            else if result.spawnError?.hasPrefix("refused:") == true { state = "cancelled" }   // 啟動前就被撤銷、交件中、鎖住
            else if result.timedOut { state = "timed_out" }
            else if result.spawnError != nil { state = "failed" }
            else { state = "exited" }
            var locked = false
            if result.spawnError == nil, let service, let current = try? service.workspaceSnapshot(workspace.id) {
                locked = service.enforceDiskQuota(current)
                // V7：指令跑完，保護項目跟開的時候不一樣（例如整個上層資料夾搬走再搬回來）＝鎖住。
                if let drift = service.protectedDrift(current) {
                    service.workspaceStore.lock(where: { $0.id == workspace.id }, reason: "protected_tree_changed:" + drift)
                }
            }
            self.finish(id, state: state, result: result, diskLocked: locked, refusal: result.spawnError)
        }
        return (job, finished)
    }

    /// 跨執行緒的旗標（監看磁碟的迴圈什麼時候停）。
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func clear() { lock.lock(); value = false; lock.unlock() }
    }

    private func markDiskLocked(_ id: String) {
        lock.lock(); jobs[id]?.diskLocked = true; lock.unlock()
    }

    /// 記憶體裡只留最近的：做完超過一小時、而且總數超過 500 的舊 job 從記憶體拿掉（輸出區的 meta.json 還在，照樣查得到）。呼叫時已拿著 lock。
    private func forgetOldJobsLocked() {
        guard jobs.count > 500 else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for (id, job) in jobs where job.finished && (job.endedAt ?? .distantFuture) < cutoff {
            jobs[id] = nil; done[id] = nil; redactors[id] = nil
        }
    }

    /// W183 R1b：輸出區的保留政策與上限。超過 7 天的清掉；每個 grant 超過總量或 job 數、全部超過總量，就從最舊的（做完的）清。
    /// 回 false＝清完這個 grant 還是沒有空間（都在跑）。
    @discardableResult
    func pruneOutputs(keepingRoomFor grant: String? = nil) -> Bool {
        lock.lock(); let running = Set(jobs.values.filter { !$0.finished }.map(\.id)); lock.unlock()
        let fm = FileManager.default
        let now = Date()
        var entries: [(grant: String, job: String, url: URL, modified: Date, bytes: Int64)] = []
        let grants = (try? fm.contentsOfDirectory(at: paths.outputDir, includingPropertiesForKeys: nil)) ?? []
        for grantURL in grants {
            let jobURLs = (try? fm.contentsOfDirectory(at: grantURL, includingPropertiesForKeys: nil)) ?? []
            for jobURL in jobURLs where Self.validID(jobURL.lastPathComponent) {
                var bytes: Int64 = 0
                var modified = Date.distantPast
                for name in ["stdout.log", "stderr.log", "meta.json"] {
                    var info = stat()
                    guard lstat(jobURL.appendingPathComponent(name).path, &info) == 0 else { continue }
                    bytes += Int64(info.st_size)
                    modified = max(modified, Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)))
                }
                entries.append((grantURL.lastPathComponent, jobURL.lastPathComponent, jobURL, modified, bytes))
            }
        }
        var removed = Set<String>()
        func remove(_ entry: (grant: String, job: String, url: URL, modified: Date, bytes: Int64)) {
            guard !running.contains(entry.job), !removed.contains(entry.job) else { return }
            if (try? fm.removeItem(at: entry.url)) != nil { removed.insert(entry.job) }
        }
        for entry in entries where now.timeIntervalSince(entry.modified) > Self.outputRetention { remove(entry) }
        var kept = entries.filter { !removed.contains($0.job) }.sorted { $0.modified < $1.modified }
        for grantID in Set(kept.map(\.grant)) {
            var mine = kept.filter { $0.grant == grantID }
            var total = mine.reduce(Int64(0)) { $0 + $1.bytes }
            while (total > Self.outputPerGrant || mine.count > Self.maxJobsKeptPerGrant), let oldest = mine.first(where: { !running.contains($0.job) }) {
                remove(oldest)
                total -= oldest.bytes
                mine.removeAll { $0.job == oldest.job }
            }
        }
        kept = kept.filter { !removed.contains($0.job) }
        var total = kept.reduce(Int64(0)) { $0 + $1.bytes }
        for entry in kept where total > Self.outputTotal && !running.contains(entry.job) {
            remove(entry)
            total -= entry.bytes
        }
        guard let grant else { return true }
        let remaining = entries.filter { !removed.contains($0.job) }
        let mine = remaining.filter { $0.grant == grant }
        // 新的 job 最多再寫 2 × 8 MiB：留得下才准。
        let room = Int64(2 * Self.outputCap)
        return mine.reduce(Int64(0)) { $0 + $1.bytes } + room <= Self.outputPerGrant
            && remaining.reduce(Int64(0)) { $0 + $1.bytes } + room <= Self.outputTotal
            && mine.count < Self.maxJobsKeptPerGrant
    }

    private static func openOutput(_ url: URL) -> Int32 {
        Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_APPEND, mode_t(0o600))
    }

    /// 輸出一邊收一邊遮蔽、再寫進輸出區（W183 R1b：磁碟上不留秘密原文；上限 8 MiB，超過只記數）。
    private func capture(_ id: String, isStdout: Bool, data raw: Data, fd: Int32) {
        lock.lock()
        guard let streams = redactors[id] else { lock.unlock(); return }
        let data = (isStdout ? streams.stdout : streams.stderr).feed(raw)
        lock.unlock()
        append(id, isStdout: isStdout, data: data, fd: fd)
    }

    /// 結束：兩個串流剩下沒換行的最後一段也遮好寫出去。
    private func flush(_ id: String, outFD: Int32, errFD: Int32) {
        lock.lock()
        let streams = redactors[id]
        redactors[id] = nil
        let tails = (streams?.stdout.finish() ?? Data(), streams?.stderr.finish() ?? Data())
        lock.unlock()
        append(id, isStdout: true, data: tails.0, fd: outFD)
        append(id, isStdout: false, data: tails.1, fd: errFD)
    }

    private func append(_ id: String, isStdout: Bool, data: Data, fd: Int32) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard var job = jobs[id] else { lock.unlock(); return }
        let written = isStdout ? job.stdoutBytes : job.stderrBytes
        let room = max(0, Self.outputCap - written)
        let keep = data.prefix(room)
        if isStdout {
            job.stdoutBytes += keep.count; job.stdoutDropped += data.count - keep.count
            job.stdoutCapture.append(data, keep: HandsSandbox.streamKeep)
        } else {
            job.stderrBytes += keep.count; job.stderrDropped += data.count - keep.count
            job.stderrCapture.append(data, keep: HandsSandbox.streamKeep)
        }
        jobs[id] = job
        lock.unlock()
        if fd >= 0, !keep.isEmpty { _ = HandsFiles.writeAll(fd, Data(keep)) }
    }

    private func finish(_ id: String, state: String, result: HandsSandbox.RunResult?, diskLocked: Bool = false, refusal: String? = nil) {
        lock.lock()
        redactors[id] = nil
        if var job = jobs[id] {
            job.state = state
            job.endedAt = Date()
            job.exitCode = result?.exitCode
            job.signal = result?.signal
            job.swept = result?.sweptProcesses ?? 0
            job.diskLocked = job.diskLocked || diskLocked
            job.refusal = refusal.map { String($0.dropFirst($0.hasPrefix("refused:") ? 8 : 0)) }
            jobs[id] = job
        }
        let semaphore = done[id]
        lock.unlock()
        writeMeta(id)
        semaphore?.signal()
    }

    private func writeMeta(_ id: String) {
        lock.lock(); let job = jobs[id]; lock.unlock()
        guard let job, let data = try? JSONSerialization.data(withJSONObject: job.meta, options: [.sortedKeys]) else { return }
        try? HandsFiles.writeAtomically(data, to: outputDirectory(grant: job.grantID, job: id).appendingPathComponent("meta.json"))
    }

    func job(_ id: String, grant: String) -> Job? {
        lock.lock(); defer { lock.unlock() }
        guard let job = jobs[id], job.grantID == grant else { return nil }
        return job
    }

    /// V9：只看自己 grant 的；App 重開前的 job 從輸出區的 meta.json 讀（當時在跑的＝被中斷）。
    func meta(_ id: String, grant: String) throws -> [String: Any] {
        guard Self.validID(id) else { throw HandsToolError.invalid("job_not_found") }
        if let job = job(id, grant: grant) { return job.meta }
        let url = outputDirectory(grant: grant, job: id).appendingPathComponent("meta.json")
        guard let data = HandsFiles.readSecure(url, limit: 64 * 1024),
              var meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any], meta["grant_id"] as? String == grant else {
            throw HandsToolError.invalid("job_not_found")
        }
        if meta["state"] as? String == "running" { meta["state"] = "interrupted" }
        return meta
    }

    static func validID(_ id: String) -> Bool {
        id.hasPrefix("job_") && id.count == 20 && id.dropFirst(4).allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    /// 等 job 做完（最多 seconds 秒）。做完回 true。
    func wait(_ id: String, seconds: TimeInterval) -> Bool {
        lock.lock(); let semaphore = done[id]; let finished = jobs[id]?.finished ?? true; lock.unlock()
        if finished { return true }
        guard let semaphore else { return true }
        if semaphore.wait(timeout: .now() + seconds) == .success { semaphore.signal(); return true }
        return false
    }

    /// job_output：原始位元組從輸出區讀；起點往前、終點往後對齊到空白（最多 4 KiB；找不到空白＝那段沒切完的字不給），再遮蔽。
    /// 秘密不會被切成遮不到的半截；起點落在私鑰中間時，開頭那段到 END 為止整段遮掉。
    func output(_ id: String, grant: String, stream: String, offset: Int, limit: Int, context: HandsRedactor.Context) throws -> [String: Any] {
        let meta = try self.meta(id, grant: grant)
        guard stream == "stdout" || stream == "stderr" else { throw HandsToolError.invalid("stream must be stdout or stderr") }
        let url = outputDirectory(grant: grant, job: id).appendingPathComponent(stream + ".log")
        let finished = meta["state"] as? String != "running"
        guard let probe = HandsFiles.readRange(url, offset: 0, count: 0) else { throw HandsToolError.invalid("output_missing") }
        let total = probe.total
        let pageSize = min(max(limit, 1), 256 * 1024)
        let requested = min(max(offset, 0), total)
        let lead = min(4096, requested)
        let wantEnd = min(total, requested + pageSize)
        let trail = min(4096, total - wantEnd)
        guard let chunk = HandsFiles.readRange(url, offset: requested - lead, count: lead + (wantEnd - requested) + trail) else {
            throw HandsToolError.invalid("output_unreadable")
        }
        let bytes = [UInt8](chunk.data)
        let base = requested - lead
        let isSpace = HandsSandbox.Captured.isSpace
        var start = lead
        if requested > 0, start <= bytes.count, start > 0, !isSpace(bytes[start - 1]) {
            var back = start
            while back > 0 && !isSpace(bytes[back - 1]) { back -= 1 }
            if back > 0 || base == 0 {
                start = back
            } else {
                var forward = start
                while forward < bytes.count && !isSpace(bytes[forward]) { forward += 1 }
                start = forward
            }
        }
        var end = min(bytes.count, lead + (wantEnd - requested))
        var textEnd = end
        let atEnd = base + end >= total
        if !(atEnd && finished) {
            var cut = end
            while cut > start && !isSpace(bytes[cut - 1]) { cut -= 1 }
            if cut > start { end = cut; textEnd = cut } else { textEnd = start }   // 整頁是一個沒切完的字：這頁不給文字，下一頁會對齊
        }
        start = min(start, textEnd)
        var text = String(decoding: bytes[start..<textEnd], as: UTF8.self)
        if base + start > 0 { text = HandsRedactor.redactKeyTail(text) }
        text = HandsRedactor.redact(text, context: context)
        return ["job_id": id, "stream": stream, "offset": base + start, "next_offset": base + end, "total_bytes": total,
                "complete": finished && base + end >= total, "state": meta["state"] ?? "unknown", "text": text,
                "capture_truncated": meta[stream + "_truncated"] as? Bool ?? false]
    }

    func cancel(_ id: String, grant: String, marksDirectory: String?) throws -> [String: Any] {
        guard let job = job(id, grant: grant) else {
            _ = try meta(id, grant: grant)   // 別的 grant 的或不存在：找不到
            return ["job_id": id, "state": "already finished"]
        }
        guard !job.finished else { return ["job_id": id, "state": job.state] }
        HandsSandbox.terminate(where: { $0.job == id }, workspaces: [], marksDirectory: marksDirectory)
        _ = wait(id, seconds: 10)
        return (try? meta(id, grant: grant)) ?? ["job_id": id, "state": "cancelled"]
    }

    /// 撤銷、降級、移除專案：收掉符合的 job（群組＋工作區標記）。
    func cancel(where matches: (Job) -> Bool, marksDirectory: String?) {
        lock.lock()
        let targets = jobs.values.filter { !$0.finished && matches($0) }
        lock.unlock()
        let ids = Set(targets.map(\.id))
        let workspaces = Array(Set(targets.map { $0.workspaceID.uuidString }))
        HandsSandbox.terminate(where: { $0.job.map(ids.contains) ?? false }, workspaces: workspaces, marksDirectory: marksDirectory)
    }

    func runningCount(grant: String? = nil) -> Int {
        lock.lock(); defer { lock.unlock() }
        return jobs.values.filter { !$0.finished && (grant == nil || $0.grantID == grant) }.count
    }
}

/// V12：request_id 的原子占位與結果（app/requests/<sha256(grant、工具、request_id)>.json，0600）。
final class HandsRequestLedger: @unchecked Sendable {
    enum Reservation {
        case fresh(String)
        case done(text: String, isError: Bool)
        case running(jobID: String?)
        case interrupted
        case conflict
    }

    struct Entry: Codable {
        var fingerprint: String
        var state: String
        var jobID: String?
        var text: String?
        var isError: Bool?
        var createdAt: Date
        var instance: String
    }

    static let retention: TimeInterval = 24 * 3600
    /// W183 R1b：每筆存的結果、整個帳本的總量與筆數都有上限（重試太長的結果只回前段；滿了從最舊、已完成的清）。
    static let maxStoredText = 128 * 1024
    static let maxLedgerBytes = 256 * 1024 * 1024
    static let maxEntries = 20_000
    static let pruneAfterBytes = 32 * 1024 * 1024
    let directory: URL
    /// 這次 App 的執行代號（上次 App 的「進行中」＝被中斷）。
    let instance = UUID().uuidString
    private let lock = NSRecursiveLock()
    private var lastPrune = Date.distantPast
    private var bytesSincePrune = 0

    init(directory: URL) { self.directory = directory }

    static func validID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "._~-".unicodeScalars.contains($0)
        }
    }

    static func fingerprint(tool: String, arguments: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
        return HandsAuth.sha256Hex(Data((tool + "\n").utf8) + data)
    }

    func key(grant: String, tool: String, requestID: String) -> String {
        HandsAuth.hash(grant + "\n" + tool + "\n" + requestID)
    }

    private func url(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }

    private func encode(_ entry: Entry) -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(entry)) ?? Data()
    }

    private func read(_ key: String) -> Entry? {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return HandsFiles.readSecure(url(key), limit: 4 * 1024 * 1024).flatMap { try? decoder.decode(Entry.self, from: $0) }
    }

    /// V12：原子占位。W183 R1b：讀、判過期、刪、重建整段都在同一把鎖裡（清理也用同一把），刪之前再核對一次是不是同一筆（世代）。
    func reserve(grant: String, tool: String, requestID: String, arguments: [String: Any]) throws -> Reservation {
        pruneIfDue()
        let key = key(grant: grant, tool: tool, requestID: requestID)
        let print = Self.fingerprint(tool: tool, arguments: arguments)
        lock.lock(); defer { lock.unlock() }
        let fresh = Entry(fingerprint: print, state: "running", jobID: nil, text: nil, isError: nil, createdAt: Date(), instance: instance)
        if try HandsFiles.createExclusive(encode(fresh), at: url(key)) { noteWritten(fresh); return .fresh(key) }
        guard let existing = read(key) else { throw HandsToolError.invalid("request_ledger_unreadable") }
        if Date().timeIntervalSince(existing.createdAt) > Self.retention {
            // 過期的鍵：當作新的。鎖還在手上，別的請求插不進來；覆寫而不是刪了再建（不會刪到別人剛建的）。
            try HandsFiles.writeAtomically(encode(fresh), to: url(key))
            noteWritten(fresh)
            return .fresh(key)
        }
        guard HandsAuth.constantTimeEqual(existing.fingerprint, print) else { return .conflict }
        if existing.state == "done" { return .done(text: existing.text ?? "", isError: existing.isError ?? true) }
        return existing.instance == instance ? .running(jobID: existing.jobID) : .interrupted
    }

    func attachJob(_ key: String, jobID: String) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = read(key) else { return }
        entry.jobID = jobID
        try? HandsFiles.writeAtomically(encode(entry), to: url(key))
    }

    func complete(_ key: String, text: String, isError: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = read(key) else { return }
        entry.state = "done"
        entry.text = text.utf8.count > Self.maxStoredText ? String(text.prefix(Self.maxStoredText / 4)) + "\n…（原結果太長，重試只回前段）" : text
        entry.isError = isError
        try? HandsFiles.writeAtomically(encode(entry), to: url(key))
        noteWritten(entry)
    }

    /// 呼叫失敗在寫結果之前（例如 App 內部錯誤）：放掉占位，之後同一個 request_id 可以重試。
    func release(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        _ = unlink(url(key).path)
    }

    /// 寫了多少（W183 R1b：磁碟上限；超過就提早清）。呼叫時已拿著鎖。
    private func noteWritten(_ entry: Entry) {
        bytesSincePrune += (entry.text?.utf8.count ?? 0) + 256
    }

    /// 清掉過期的（24 小時）；總量超過上限就從最舊的清（還在跑的不清）。跟占位用同一把鎖；刪之前重讀、確認還是過期的那一筆。
    private func pruneIfDue() {
        lock.lock(); defer { lock.unlock() }
        guard Date().timeIntervalSince(lastPrune) > 600 || bytesSincePrune > Self.pruneAfterBytes else { return }
        lastPrune = Date()
        bytesSincePrune = 0
        let cutoff = Date().addingTimeInterval(-Self.retention)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let items = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? [])
            .filter { $0.pathExtension == "json" }
        var kept: [(URL, Date, Int)] = []
        for item in items {
            let values = try? item.resourceValues(forKeys: Set(keys))
            let modified = values?.contentModificationDate ?? .distantPast
            let key = item.deletingPathExtension().lastPathComponent
            if modified < cutoff, let entry = read(key), Date().timeIntervalSince(entry.createdAt) > Self.retention {
                _ = unlink(item.path)
            } else {
                kept.append((item, modified, values?.fileSize ?? 0))
            }
        }
        var total = kept.reduce(0) { $0 + $1.2 }
        var count = kept.count
        guard total > Self.maxLedgerBytes || count > Self.maxEntries else { return }
        for (item, _, size) in kept.sorted(by: { $0.1 < $1.1 }) where total > Self.maxLedgerBytes / 2 || count > Self.maxEntries / 2 {
            let key = item.deletingPathExtension().lastPathComponent
            guard let entry = read(key), entry.state == "done" else { continue }
            _ = unlink(item.path)
            total -= size
            count -= 1
        }
    }
}
