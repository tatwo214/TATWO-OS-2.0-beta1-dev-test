import Foundation
import AppKit

/// W179: real bridge/store reads, no listener, engine, command, SSH or production live root.
enum OSToolsAcceptance {
    @MainActor static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["TATWO2_SELFTEST"] == "w179tools" else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        Task.detached {
            do { try await run(); print("W179TOOLS ALL PASS"); exit(0) }
            catch { print("W179TOOLS FAIL \(error)"); exit(1) }
        }
        RunLoop.main.run()
        exit(1)
    }

    private static func check(_ value: Bool, _ label: String) throws {
        guard value else { throw NSError(domain: label, code: 1) }
        print("W179TOOLS PASS \(label)")
    }

    private static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let path = env["TATWO2_LIVE_ROOT"] else { throw NSError(domain: "isolated live root required", code: 1) }
        let root = URL(fileURLWithPath: path)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.appendingPathComponent("document.json").path),
              !fm.fileExists(atPath: root.appendingPathComponent("goals").path) else {
            throw NSError(domain: "fresh fixture required", code: 1)
        }
        let secret = "W179_PRIVATE_CONTENT_MUST_NOT_LEAK"
        let now = Date()
        let project = LiveProjectRecord(name: "OS tools fixture", workdir: root.path)
        var a = LiveThreadRecord(projectID: project.id, title: "Thread A")
        var b = LiveThreadRecord(projectID: project.id, title: "Thread B", isArchived: true)
        a.messages = [LiveMessageRecord(ChatMessage(role: .user, text: secret))]
        b.parentThreadID = a.id; b.roomBrief = secret; b.subStatus = "running"
        var stalled = LiveThreadRecord(projectID: project.id, title: "Stalled room")
        stalled.parentThreadID = a.id; stalled.subStatus = "stalled"
        var failed = LiveThreadRecord(projectID: project.id, title: "Failed room")
        failed.parentThreadID = a.id; failed.subStatus = "failed"
        var old = LiveThreadRecord(projectID: project.id, title: "No output")
        old.subStatus = "running"; old.lastOutputAt = now.addingTimeInterval(-1000)
        var normalFailure = LiveThreadRecord(projectID: project.id, title: "Failed session")
        normalFailure.messages = [LiveMessageRecord(ChatMessage(role: .system, text: secret, status: "error|failed"))]
        var completed = LiveThreadRecord(projectID: nil, title: "Completed only")
        completed.isArchived = true
        let extra = (0..<24).map { index -> LiveThreadRecord in
            var row = LiveThreadRecord(projectID: project.id, title: "Running \(index)")
            row.subStatus = "running"; return row
        }
        let doc = LiveDocumentRecord(projects: [project],
            threads: [a, b, stalled, failed, old, normalFailure, completed] + extra, selectedThreadID: a.id)
        let store = ChatLiveStore(root: root)
        try store.saveChecked(doc)
        for thread in [a, b, completed] {
            try ThreadGoalStore.shared.update(thread.id) { list in
                let goal = try ThreadGoalRules.add(&list, title: "Goal \(thread.title)", userWords: secret, proposed: false)
                if thread.id != a.id {
                    try ThreadGoalRules.setStatus(&list, id: goal.id, to: .done, evidence: secret, actor: .lead)
                }
                if thread.id == b.id {
                    _ = try ThreadGoalRules.add(&list, title: "Still working", userWords: secret, proposed: false)
                    _ = try ThreadGoalRules.add(&list, title: "Proposal", userWords: secret, proposed: true)
                    _ = try ThreadGoalRules.add(&list, title: "Child goal", userWords: secret, proposed: false, parent: goal.id)
                }
            }
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let job = BackgroundJobManager.Record(jobID: UUID(), pid: 0, title: secret, command: secret,
            cwd: secret, logPath: root.appendingPathComponent("private.log").path, threadID: b.id,
            startedAt: now, state: "exited", exitCode: 1)
        try Data(secret.utf8).write(to: root.appendingPathComponent("private.log"))
        try encoder.encode([job]).write(to: root.appendingPathComponent("bg-jobs.json"))
        let manager = BackgroundJobManager(root: root)
        let model = await MainActor.run { () -> ChatPageModel in
            let live = ChatLiveEngine(store: store, environment: env)
            // Loading closes interrupted persisted turns. Seed this test's current
            // work after that recovery, before taking the read-only snapshots.
            for thread in doc.threads where thread.subStatus == "running" {
                live.markSubStatus(thread.id, "running")
            }
            let model = ChatPageModel(environment: env, botCoreFixture: (live, BotStore(root: root)))
            OSAgentBridge.shared.configureCallerTest(model: model, manager: manager)
            return model
        }
        let bridge = OSAgentBridge.shared
        let before = await MainActor.run { model.localLiveForBridge!.doc }
        let files = [store.url, root.appendingPathComponent("bg-jobs.json")] + [a, b, completed].map {
            root.appendingPathComponent("goals/\($0.id.uuidString.lowercased()).json")
        }
        let contents = try files.map { try Data(contentsOf: $0) }
        func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
            try bridge.callForSelfTest(method: method, params: params)
        }
        let index = try call("goal_index")
        let all = try call("goal_index", ["includeDone": true, "callerThreadID": a.id.uuidString])
        let rows = index["threads"] as? [[String: Any]] ?? []
        let allRows = all["threads"] as? [[String: Any]] ?? []
        let goals = rows.flatMap { $0["goals"] as? [[String: Any]] ?? [] }
        try check(rows.count == 2 && allRows.count == 3 &&
                  goals.allSatisfy { $0["status"] as? String != "done" }, "goal_index default excludes done; true includes archived and done-only threads")
        let bRow = rows.first { $0["threadID"] as? String == b.id.uuidString }
        try check(bRow?["title"] as? String == b.title && bRow?["projectName"] as? String == project.name &&
                  bRow?["progress"] as? [String: Int] == ["done": 1, "total": 2],
                  "goal_index identity and full mainline progress (not filtered/proposed/child count)")
        try check(allRows.flatMap { $0["goals"] as? [[String: Any]] ?? [] }.filter { $0["status"] as? String == "done" }.count == 2,
                  "includeDone returns completed goal metadata")
        for (method, params) in [
            ("goal_index", ["includeDone": "true"]), ("goal_index", ["includeDone": 1]),
            ("goal_index", ["includeDone": NSNull()]), ("goal_index", ["path": "/"]),
            ("os_status", ["includeDone": true]), ("os_status", ["path": "/"]),
        ] as [(String, [String: Any])] {
            var refused = false
            do { _ = try call(method, params) } catch { refused = true }
            try check(refused, "\(method) rejects malformed arguments")
        }
        let status = try call("os_status")
        try check([index, all, status].allSatisfy { $0["device"] as? String == "local" },
                  "both tools identify local device")
        for key in ["running", "awaitingApproval", "stalled", "failed", "rooms", "backgroundJobs",
                    "cliSessions", "devices", "pendingRequestTitles", "pendingMemories"] {
            try check(status[key] is [Any], "os_status array \(key)")
        }
        try check((status["running"] as? [Any])?.count == 25, "global running threads not truncated to Island's 20")
        try check((status["stalled"] as? [Any])?.count == 2 && (status["failed"] as? [Any])?.count == 2,
                  "explicit/aged stalled and room/session failures")
        let room = (status["rooms"] as? [[String: Any]])?.first { $0["threadID"] as? String == b.id.uuidString }
        try check(room?["parentThreadID"] as? String == a.id.uuidString && room?["parentTitle"] as? String == a.title &&
                  room?["projectName"] as? String == project.name && room?["status"] as? String == "running",
                  "room links parent, project and status")
        try check((status["backgroundJobs"] as? [[String: Any]])?.first?["jobID"] as? String == job.jobID.uuidString,
                  "background snapshot through real manager")
        let output = try JSONSerialization.data(withJSONObject: [index, all, status])
        try check(!String(decoding: output, as: UTF8.self).contains(secret), "bridge output excludes message, brief, goal source/evidence and command/log")
        try check(try files.map { try Data(contentsOf: $0) } == contents, "bridge reads leave persisted files byte-identical")
        let after = await MainActor.run { model.localLiveForBridge!.doc }
        try check(before == after, "bridge reads leave document and selection unchanged")

        // Exercise nonempty CLI/device data without opening a terminal or probing a paired device.
        let cli = CLISessionStore.Record(id: UUID(), title: "Terminal", engine: "codex", cwd: secret,
            createdAt: now, lastActiveAt: now, status: .waitingInput, pinned: false, order: 0,
            threadID: a.id, projectID: project.id, tmuxName: secret)
        let device = DeviceRecord(id: "fixture-device", name: "Fixture device", host: secret, user: secret,
            sshPort: 22, publicKeyFingerprint: secret, addedAt: now, lastSeenAt: now, workdirMap: [secret: secret])
        let projected = await MainActor.run {
            IslandWorkProvider.project(threads: doc.threads, pending: [a.id], running: [a.id],
                bots: .init(), jobs: [], now: now, limit: nil)
        }
        let islandRows = projected.exceptions + projected.normal
        try check(!islandRows.contains { $0.threadID == stalled.id || $0.threadID == normalFailure.id } &&
                  islandRows.first { $0.threadID == failed.id }?.hint == "房間失敗",
                  "Island ignores idle stalled/error history and retains room failure wording")
        let enriched = OSAgentBridge.statusMetadata(doc: doc, work: projected, jobs: [], sessions: [cli],
            devices: [device], requestTitles: ["Approval title"], now: now)
        try check((enriched["awaitingApproval"] as? [[String: Any]])?.first?["threadID"] as? String == a.id.uuidString,
                  "approval takes precedence over running")
        let pendingSets: [Set<UUID>] = [[], [stalled.id, normalFailure.id]]
        for pending in pendingSets {
            let work = IslandWorkProvider.project(threads: [stalled, normalFailure], pending: pending,
                running: [stalled.id, normalFailure.id], bots: .init(), jobs: [], now: now, limit: nil)
            let metadata = OSAgentBridge.statusMetadata(doc: doc, work: work, jobs: [], sessions: [],
                devices: [], requestTitles: [], now: now)
            for (thread, expected) in [(stalled, pending.isEmpty ? "stalled" : "awaitingApproval"),
                                        (normalFailure, pending.isEmpty ? "running" : "awaitingApproval")] {
                let rows = metadata[expected] as? [[String: Any]] ?? []
                try check(rows.filter { $0["threadID"] as? String == thread.id.uuidString }.count == 1,
                          "OS-only classification preserves \(expected) precedence for \(thread.title)")
            }
        }
        try check((enriched["cliSessions"] as? [[String: Any]])?.first?["status"] as? String == "waitingInput" &&
                  (enriched["devices"] as? [[String: Any]])?.first?["name"] as? String == device.name,
                  "CLI and device allowlisted projection")
        try check(!String(decoding: try JSONSerialization.data(withJSONObject: enriched), as: UTF8.self).contains(secret),
                  "no CLI cwd/tmux or device host/user/fingerprint leaks")
        try await noticeChecks(bridge: bridge, secret: secret)
        for method in ["os_status", "goal_index"] {
            for staging in [false, true] {
                for caller in [OSSocketCaller.other(pid: nil), .ssh, .externalAI] {   // W183 R1：外部 AI 也拒
                    try check(!OSAgentBridge.allows(caller: caller, method: method, params: [:], staging: staging),
                              "\(method) rejects \(caller.label) staging=\(staging)")
                }
                for caller in [OSSocketCaller.app, .engine(a.id), .job(a.id), .helper] {
                    try check(OSAgentBridge.allows(caller: caller, method: method, params: [:], staging: staging),
                              "\(method) permits \(caller.label) staging=\(staging)")
                }
            }
        }
        // W180 E2：overview_snapshot 給已配對設備（SSH）讀；外部程式不論是不是 staging 都擋。只回白名單欄位。
        for staging in [false, true] {
            try check(OSAgentBridge.allows(caller: .ssh, method: "overview_snapshot", params: [:], staging: staging),
                      "overview_snapshot permits ssh staging=\(staging)")
            try check(!OSAgentBridge.allows(caller: .other(pid: nil), method: "overview_snapshot", params: [:], staging: staging),
                      "overview_snapshot rejects other staging=\(staging)")
        }
        let overview = try call("overview_snapshot")
        try check(AssistantOverviewWire.allKeys(overview).isSubset(of: AssistantOverviewWire.allowedKeys),
                  "overview_snapshot returns only allowlisted keys")
        try check(!String(decoding: try JSONSerialization.data(withJSONObject: overview), as: UTF8.self).contains(secret),
                  "overview_snapshot excludes message, brief, goal source/evidence and command/cwd/log")
        let overviewGoals = (overview["goals"] as? [[String: Any]] ?? []).first { $0["threadID"] as? String == a.id.uuidString }
        try check(overviewGoals?["done"] as? Int == 0 && overviewGoals?["total"] as? Int == 1,
                  "overview_snapshot goal progress matches goal_index")
        var malformedRefused = false
        do { _ = try call("overview_snapshot", ["path": "/"]) } catch { malformedRefused = true }
        try check(malformedRefused, "overview_snapshot rejects unknown arguments")
        _ = model // Keep the bridge's weak owner alive throughout all reads.
    }

    private static func noticeChecks(bridge: OSAgentBridge, secret: String) async throws {
        let firstID = UUID(), secondID = UUID()
        await MainActor.run { IslandNotice.shared.hostAvailable = true }
        let first = Task { @MainActor in
            await IslandNotice.shared.ask(title: "First approval", detail: secret, allowLabel: "Allow",
                timeout: 60, requestID: firstID)
        }
        let second = Task { @MainActor in
            await IslandNotice.shared.ask(title: "Queued approval", detail: secret, allowLabel: "Allow",
                timeout: 60, requestID: secondID)
        }
        for _ in 0..<100 {
            if await MainActor.run(body: { IslandNotice.shared.pendingRequestTitles.count == 2 }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let status = try bridge.callForSelfTest(method: "os_status", params: [:])
        let titles = status["pendingRequestTitles"] as? [String] ?? []
        let unchanged = await MainActor.run { IslandNotice.shared.pendingRequestTitles }
        await MainActor.run {
            IslandNotice.shared.resolve(.cancel, id: firstID)
            IslandNotice.shared.resolve(.cancel, id: secondID)
            IslandNotice.shared.hostAvailable = false
        }
        _ = await first.value; _ = await second.value
        try check(Set(titles) == ["First approval", "Queued approval"] && titles == unchanged,
                  "bridge lists active and queued Island titles without resolving requests")
        try check(!String(decoding: try JSONSerialization.data(withJSONObject: status), as: UTF8.self).contains(secret),
                  "Island request detail excluded")
        let fallback = await MainActor.run { IslandNotice(fallback: { _, _, _ in {} }, holdOpen: { _ in }, log: { _ in }) }
        let pending = Task { await fallback.ask(title: "Fallback approval", detail: secret, allowLabel: "Allow",
            timeout: 60, requestID: firstID) }
        for _ in 0..<100 {
            if await MainActor.run(body: { !fallback.pendingRequestTitles.isEmpty }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let fallbackOK = await MainActor.run { () -> Bool in
            let ok = fallback.current == nil && fallback.pendingRequestTitles == ["Fallback approval"]
            fallback.resolve(.cancel, id: firstID)
            return ok
        }
        _ = await pending.value
        try check(fallbackOK, "fallback-hosted pending request remains visible by title only")
    }
}
