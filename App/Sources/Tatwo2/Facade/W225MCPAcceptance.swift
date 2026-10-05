#if DEBUG
import Foundation

enum W225MCPAcceptance {
    @MainActor static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let staging = env["TATWO_STAGING_ROOT"] else { throw HandsToolError.invalid("w225mcp requires isolated staging") }
        let base = URL(fileURLWithPath: staging).appendingPathComponent("w225mcp")
        let fm = FileManager.default
        func dir(_ name: String) throws -> URL {
            let url = base.appendingPathComponent(name)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let entry = try dir("entry"), home = try dir("home"), support = try dir("support")
        let store = ChatLiveStore(root: try dir("live"))
        var seed = store.load()
        let legacy = LiveThreadRecord(title: "Legacy standalone")
        seed.threads.append(legacy); store.save(seed)
        let live = ChatLiveEngine(store: store, environment: env)
        defer { live.shutdownAll() }
        let bots = BotLibrary(root: base, skillsRoot: try dir("skills"))
        await bots.ready()
        let model = ChatPageModel(environment: env, botCoreFixture: (live, BotStore(library: bots)))
        let alpha = live.newProject(name: "Fixture Alpha", workdir: try dir("work/alpha").path)
        let beta = live.newProject(name: "Fixture Beta", workdir: try dir("work/beta").path)
        let trading = live.newProject(name: "BTC 實盤", workdir: try dir("work/trading").path)
        let thread = live.newThread(in: alpha, title: "Collaboration")
        let deniedThread = live.newThread(in: beta, title: "Private")
        let tradingThread = live.newThread(in: trading, title: "Trading")
        let standalone = live.newThread(in: nil, title: "Standalone")
        let canary = "sk" + "-test_" + String(repeating: "Ab12", count: 14)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var rows: [ChatMessage] = []
        for i in (0..<85).reversed() {
            let modelID = i % 4 == 0 ? "claude-opus-4" : i % 4 == 1 ? "grok-4" : "gpt-6.1-sol"
            let body = i == 1 ? "api_key=\(canary)\nvisible" : "row \(i)"
            rows.append(ChatMessage(id: "fixture-\(i)", role: i == 0 ? .user : .assistant,
                        text: body, modelID: modelID, runtimeAdapterID: i % 4 == 2 ? "chatgpt-tap" : nil,
                        createdAt: now.addingTimeInterval(Double(i))))
        }
        _ = live.appendOfflineRows(threadID: thread, rows: rows)
        let bigThread = live.newThread(in: alpha, title: "Bounded")
        _ = live.appendOfflineRows(threadID: bigThread, rows: (0..<8).map { i in
            ChatMessage(id: "big-\(i)", role: .assistant,
                        text: String(repeating: "x", count: 1490) + " " + canary + "\n" + String(repeating: "\"\\\n測", count: 10_000),
                        createdAt: now.addingTimeInterval(Double(i)))
        })
        let toolThread = live.newThread(in: alpha, title: "Tools")
        _ = live.appendOfflineRows(threadID: toolThread, rows: [
            ChatMessage(id: "edit", role: .assistant, text: "Edit：src/main.swift", status: "done|Edit", eventKind: .toolUse, turnID: "artifact-turn"),
            ChatMessage(id: "answer", role: .assistant, text: "Done", modelID: "gpt-6.1-sol", turnID: "artifact-turn")
        ])
        // The persisted artifact index is an observation, not proof of which tool changed a file.
        let artifacts = live.turnArtifacts
        _ = try await Task.detached {
            try await artifacts.collect(threadID: toolThread, turnID: "artifact-turn", messageID: "answer", endedAt: now,
                                        cwd: base.path, claimed: ["src/main.swift", "\(canary).txt"], gitFiles: [], truncated: true)
        }.value
        let paths = HandsPaths(root: try dir("hands"))
        var runtime = HandsRuntime.current(paths: paths, environment: env)
        runtime.home = home.path; runtime.entryRoot = entry.path; runtime.appSupport = support.path
        let service = HandsService(paths: paths, runtime: runtime)
        service.deviceIDOverride = HandsConnectAcceptance.hostID
        service.callsPerMinute = 100_000
        service.noticeSink = { _, _ in }
        service.attach(model: model)
        _ = try service.updateSettings {
            $0.enabled = true; $0.level = 2; $0.allProjects = true
            $0.hostDeviceID = HandsConnectAcceptance.hostID; $0.publicHost = HandsConnectAcceptance.publicHost
        }
        let client = HandsConnectAcceptance.FakeChatGPT(service: service)
        try client.register(); try service.startPairing(); _ = client.begin()
        let access = try client.token(try client.submit(service.auth.pendingCard?.pairingCode ?? ""))
        guard let grant = service.auth.grant(forAccess: access) else { throw HandsToolError.invalid("fixture_pairing") }
        var passed = 0, failed = 0
        func check(_ value: Bool, _ label: String) {
            if value { passed += 1 } else { failed += 1 }
            print("W225MCP \(value ? "PASS" : "FAIL") \(label)")
        }
        func call(_ name: String, _ args: [String: Any], requestID: String? = nil) async -> (Bool, String, [String: Any]) {
            let encoded = await Task.detached {
                var params: [String: Any] = ["access_token": access, "name": name, "arguments": args]
                if let requestID { params["request_id"] = requestID }
                let wire = OSAgentBridge.handsResponse(method: "hands_call", params: params, service: service)
                return (try? JSONSerialization.data(withJSONObject: wire)) ?? Data()
            }.value
            let wire = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] ?? [:]
            let result = wire["result"] as? [String: Any] ?? [:]
            let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
            let body = text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
            return (wire["error"] != nil || result["isError"] as? Bool == true, text, body)
        }
        for name in ["read_session", "create_project"] {
            if name == "create_project" && env["TATWO2_SELFTEST"] == "w225read" { continue }
            let spec = HandsTools.tool(named: name)
            check(spec != nil && spec?.required == [name == "read_session" ? "thread_id" : "name"], "catalog \(name) required input")
        }
        let first = await call("read_session", ["thread_id": thread.uuidString])
        let firstRows = first.2["rows"] as? [[String: Any]] ?? []
        check(!first.0 && firstRows.count == 40 && first.2["project_name"] as? String == "Fixture Alpha" && first.2["title"] as? String == "Collaboration", "read first page metadata and 40 rows")
        check(firstRows.first?["text"] as? String == "row 0" && !first.1.contains(canary) && first.1.contains("已遮蔽"), "chronological rows and fake key masked")
        let speakers = Set(firstRows.compactMap { $0["speaker"] as? String })
        check(speakers.isSuperset(of: ["使用者", "Codex", "Claude", "Grok", "ChatGPT"]), "message speaker identity")
        var combined = firstRows, cursor = first.2["next_cursor"] as? String, pages = 1
        while let next = cursor, pages < 5 {
            let page = await call("read_session", ["thread_id": thread.uuidString, "cursor": next])
            check(!page.0 && page.1.utf8.count <= 24 * 1024, "next page bounded")
            combined += page.2["rows"] as? [[String: Any]] ?? []
            cursor = page.2["next_cursor"] as? String; pages += 1
        }
        check(combined.count == 85 && Set(combined.compactMap { $0["text"] as? String }).count == 85 && cursor == nil, "pagination complete without duplicate rows")
        let big = await call("read_session", ["thread_id": bigThread.uuidString])
        check(!big.0 && big.1.utf8.count <= 24 * 1024 && big.1.contains("truncated") && !big.1.contains(String(canary.prefix(12))) && big.2["next_cursor"] is String, "escaped Unicode text bounded and masked before truncation")
        var bigCount = (big.2["rows"] as? [Any])?.count ?? 0, bigCursor = big.2["next_cursor"] as? String
        for _ in 0..<8 {
            guard let next = bigCursor else { break }
            let page = await call("read_session", ["thread_id": bigThread.uuidString, "cursor": next])
            check(!page.0 && page.1.utf8.count <= 24 * 1024, "byte-limited next page bounded")
            bigCount += (page.2["rows"] as? [Any])?.count ?? 0; bigCursor = page.2["next_cursor"] as? String
        }
        check(bigCount == 8 && bigCursor == nil, "byte-limited pages make progress and finish")
        let tool = await call("read_session", ["thread_id": toolThread.uuidString])
        let toolRows = tool.2["rows"] as? [[String: Any]] ?? []
        let filenames = toolRows.flatMap { $0["files"] as? [String] ?? [] }
        let steps = toolRows.flatMap { $0["steps"] as? [[String: String]] ?? [] }
        check(!tool.0 && steps.contains { $0["tool"] == "Edit" && $0["result"]?.contains("done") == true } && filenames.contains("src/main.swift") && !tool.1.contains(canary), "tool summary and masked artifact filenames")
        check(!toolRows.isEmpty && toolRows.allSatisfy { $0["truncated"] as? Bool == true }, "upstream artifact truncation preserved")
        let independent = await call("read_session", ["thread_id": standalone.uuidString])
        let tradingRead = await call("read_session", ["thread_id": tradingThread.uuidString])
        check(!independent.0 && !tradingRead.0, "standalone and read-only trading sessions readable")
        check(!(await call("read_session", ["thread_id": legacy.id.uuidString])).0, "legacy nil-project session readable with all-project grant")
        live.rename(thread, "Metadata " + canary)
        let metadata = await call("read_session", ["thread_id": thread.uuidString])
        check(!metadata.0 && !metadata.1.contains(canary), "title masked")
        live.rename(thread, "Collaboration")
        live.rename(toolThread, String(repeating: "超長標題", count: 200))
        let longTitle = await call("read_session", ["thread_id": toolThread.uuidString])
        check(!longTitle.0 && longTitle.2["metadata_truncated"] as? Bool == true && (longTitle.2["title"] as? String)?.count == 256, "metadata bounded and truncation marked")
        let pemHeader = ["-----BEGIN", "PRIVATE KEY-----"].joined(separator: " ")
        let splitSecret = live.newThread(in: alpha, title: "Split secret")
        _ = live.appendOfflineRows(threadID: splitSecret, rows: (0..<42).map { i in
            let body = i == 39 ? pemHeader : i == 40 ? "private-fixture-line" : i == 41 ? "-----END PRIVATE KEY-----" : "row \(i)"
            return ChatMessage(id: "split-\(i)", role: .assistant, text: body, createdAt: now.addingTimeInterval(Double(i)))
        })
        let splitFirst = await call("read_session", ["thread_id": splitSecret.uuidString])
        let splitNext = await call("read_session", ["thread_id": splitSecret.uuidString, "cursor": splitFirst.2["next_cursor"] as? String ?? "invalid"])
        check(!splitFirst.0 && !splitNext.0 && !splitNext.1.contains("private-fixture-line") && splitNext.1.contains("已遮蔽"), "private key state carries across rows and pages")
        for (kind, header, tail) in [("bearer", "Authorization: Bearer", "opaque_token_123"),
                                      ("base64", String(repeating: "Ab12", count: 16), "Ab12=="),
                                      ("pem", pemHeader, "private-fixture-line")] {
            for boundary in [0, 39] {
                let secretThread = live.newThread(in: alpha, title: "Trailing newline \(kind) \(boundary)")
                _ = live.appendOfflineRows(threadID: secretThread, rows: (0..<(boundary + 3)).map { i in
                    let body = i == boundary ? header + "\n" : i == boundary + 1 ? tail + "\n" : "visible row \(i)"
                    return ChatMessage(id: "newline-\(i)", role: .assistant, text: body, createdAt: now.addingTimeInterval(Double(i)))
                })
                let start = await call("read_session", ["thread_id": secretThread.uuidString])
                let page = boundary == 39 ? await call("read_session", ["thread_id": secretThread.uuidString, "cursor": start.2["next_cursor"] as? String ?? "invalid"]) : start
                let texts = (page.2["rows"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                check(!start.0 && !page.0 && !texts.isEmpty && !texts.contains { $0.contains(tail) } && texts.contains { $0.contains("已遮蔽") && $0.hasSuffix("\n") }, "\(kind) trailing newline state across \(boundary == 39 ? "pages" : "rows")")
            }
        }
        for header in ["Authorization: Bearer", String(repeating: "Ab12", count: 16)] {
            let tail = header.hasPrefix("Authorization") ? "opaque_token_123" : "Ab12=="
            let blankThread = live.newThread(in: alpha, title: "Actual blank line")
            _ = live.appendOfflineRows(threadID: blankThread, rows: [
                ChatMessage(id: "blank-header", role: .assistant, text: header + "\n\n", createdAt: now),
                ChatMessage(id: "blank-tail", role: .assistant, text: tail, createdAt: now.addingTimeInterval(1))
            ])
            let blank = await call("read_session", ["thread_id": blankThread.uuidString])
            check(!blank.0 && blank.1.contains(tail), "real blank line clears secret continuation")
        }
        let memoryThread = live.newThread(in: alpha, title: "Memory boundary")
        let memoryID = "private-memory-fixture-id", memoryTitle = "Private memory fixture title"
        let memoryNote = TatwoMemoryUsageNote(items: [.init(id: memoryID, title: memoryTitle)], query: "fixture").encoded()
        var memoryRows: [ChatMessage] = []
        for i in 0..<43 {
            if [0, 39, 40, 42].contains(i) {
                for status in [TatwoMemoryUsageNote.status, TatwoMemoryUsageNote.status + "|legacy", CoderImport.summaryStatus, "info|支線摘要"] {
                    memoryRows.append(ChatMessage(id: "memory-\(i)-\(status)", role: .system, text: memoryNote,
                                                  status: status, createdAt: now.addingTimeInterval(Double(memoryRows.count))))
                }
            }
            memoryRows.append(ChatMessage(id: "visible-\(i)", role: i == 42 ? .system : .assistant,
                                          text: "visible \(i)", status: i == 42 ? "info|監工" : nil,
                                          createdAt: now.addingTimeInterval(Double(memoryRows.count))))
        }
        memoryRows.append(ChatMessage(id: "last-memory", role: .system, text: memoryNote,
                                      status: TatwoMemoryUsageNote.status, createdAt: now.addingTimeInterval(Double(memoryRows.count))))
        _ = live.appendOfflineRows(threadID: memoryThread, rows: memoryRows)
        var memoryCursor: String?, memoryTexts: [String] = [], memoryPages = 0, memorySafe = true
        repeat {
            var args: [String: Any] = ["thread_id": memoryThread.uuidString]
            if let memoryCursor { args["cursor"] = memoryCursor }
            let page = await call("read_session", args)
            memorySafe = memorySafe && !page.0 && !page.1.contains(memoryID) && !page.1.contains(memoryTitle)
            memoryTexts += (page.2["rows"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            memoryCursor = page.2["next_cursor"] as? String; memoryPages += 1
        } while memoryCursor != nil && memoryPages < 5
        check(memorySafe, "W225a3 memory usage and derived system summaries withheld")
        check(memoryTexts == (0..<43).map { "visible \($0)" } && memoryPages == 2 && memoryCursor == nil,
              "W225a3 filtered pagination complete and ordinary system row retained")
        let unknown = await call("read_session", ["thread_id": UUID().uuidString])
        check(unknown.0 && unknown.1.contains("session_not_found_or_not_allowed"), "unknown thread clear error")
        if let spec = HandsTools.tool(named: "read_session") {
            let restricted = HandsGrantAccess(grantID: grant.grantID, clientID: grant.clientID, grantLevel: 2, projectIDs: [alpha.uuidString])
            let settings = service.effectiveSettings()
            let context = HandsService.CallContext(grant: restricted, settings: settings, level: 2, landing: .init(projectID: nil, workspaceID: nil, reminder: nil))
            let denied = try await Task.detached { try HandsTools.run(tool: spec, arguments: ["thread_id": deniedThread.uuidString], service: service, context: context).text }.value
            check(denied == unknown.1 && !denied.contains("Private"), "denied and unknown thread indistinguishable")
            let noProject = try await Task.detached { try HandsTools.run(tool: spec, arguments: ["thread_id": standalone.uuidString], service: service, context: context).isError }.value
            check(noProject, "restricted grant cannot read standalone sessions")
            let noLegacy = try await Task.detached { try HandsTools.run(tool: spec, arguments: ["thread_id": legacy.id.uuidString], service: service, context: context).isError }.value
            check(noLegacy, "restricted grant cannot read legacy nil-project sessions")
        } else { check(false, "denied project tested") }
        for args: [String: Any] in [[:], ["thread_id": "invalid"], ["thread_id": thread.uuidString, "cursor": "-1"], ["thread_id": thread.uuidString, "cursor": "bad"]] {
            check(await call("read_session", args).0, "invalid read input rejected")
        }
        if let cursor = first.2["next_cursor"] as? String {
            check(await call("read_session", ["thread_id": bigThread.uuidString, "cursor": cursor]).0, "cursor bound to thread")
        }
        if env["TATWO2_SELFTEST"] == "w225read" {
            print("W225MCP SUMMARY passed=\(passed) failures=\(failed)")
            return failed == 0
        }
        let projectClock = W225ProjectClock()
        service.projectCreationNow = { projectClock.now() }
        let quotaError = "建立太多專案，請稍後再試或在 TATWO 裡手動建立"
        let initialProjectCount = live.doc.projects.count
        var quotaIDs = Set<String>(), quotaCreatesOK = true
        _ = await call("create_project", ["name": "Invalid quota fixture", "folder": "../invalid"])
        for batch in 0..<3 {
            projectClock.set(Double(batch) * 3600)
            for i in 0..<10 {
                let made = await call("create_project", ["name": "Quota \(batch)-\(i)"], requestID: "quota-\(batch)-\(i)")
                quotaCreatesOK = quotaCreatesOK && !made.0
                if let id = made.2["project_id"] as? String { quotaIDs.insert(id) }
            }
            let beforeBlocked = live.doc.projects.count
            let blockedFolder = "quota-blocked-\(batch)"
            let blocked = await call("create_project", ["name": "Blocked project", "folder": blockedFolder])
            check(blocked.0 && blocked.1 == quotaError && live.doc.projects.count == beforeBlocked
                  && !fm.fileExists(atPath: entry.appendingPathComponent("projects/" + blockedFolder).path),
                  "W225a3 hour quota blocks eleventh without record or folder batch \(batch)")
            let retry = await call("create_project", ["name": "Quota \(batch)-0"], requestID: "quota-\(batch)-0")
            check(!retry.0 && quotaIDs.contains(retry.2["project_id"] as? String ?? "") && live.doc.projects.count == beforeBlocked,
                  "W225a3 idempotent retry uses no additional quota batch \(batch)")
        }
        check(quotaCreatesOK && quotaIDs.count == 30 && live.doc.projects.count == initialProjectCount + 30,
              "W225a3 hourly quota recovers at one hour and failures use no quota")
        projectClock.set(3 * 3600)
        let beforeDay = live.doc.projects.count
        let daily = await call("create_project", ["name": "Daily blocked", "folder": "daily-blocked"])
        check(daily.0 && daily.1 == quotaError && live.doc.projects.count == beforeDay
              && !fm.fileExists(atPath: entry.appendingPathComponent("projects/daily-blocked").path),
              "W225a3 day quota blocks thirty-first after hour recovery")
        let otherClient = HandsConnectAcceptance.FakeChatGPT(service: service)
        try otherClient.register(); try service.startPairing(); _ = otherClient.begin()
        let otherAccess = try otherClient.token(try otherClient.submit(service.auth.pendingCard?.pairingCode ?? ""))
        let createProjectTool = "create_project"
        let otherResult = await Task.detached {
            OSAgentBridge.handsResponse(method: "hands_call", params: ["access_token": otherAccess, "name": createProjectTool,
                "arguments": ["name": "Other grant quota fixture"]], service: service)
        }.value
        check((otherResult["result"] as? [String: Any])?["isError"] as? Bool == false && live.doc.projects.count == beforeDay + 1,
              "W225a3 project quotas isolated between grants")
        projectClock.set(24 * 3600)
        let dayRecovered = await call("create_project", ["name": "Day recovered"])
        check(!dayRecovered.0 && live.doc.projects.count == beforeDay + 2, "W225a3 day quota recovers at twenty-four hours")
        projectClock.set(48 * 3600)
        let created = await call("create_project", ["name": "New Project"], requestID: "create-once")
        let createdID = (created.2["project_id"] as? String).flatMap(UUID.init(uuidString:))
        let folder = created.2["folder"] as? String ?? ""
        check(!created.0 && createdID != nil && fm.fileExists(atPath: entry.appendingPathComponent("projects/New Project").path), "create folder under OS project root")
        check(createdID.flatMap { live.projectRecord($0) }?.name == "New Project" && store.load().projects.contains { $0.id == createdID }, "project published to sidebar document and persisted")
        let replay = await call("create_project", ["name": "New Project"], requestID: "create-once")
        check(!replay.0 && replay.2["project_id"] as? String == created.2["project_id"] as? String, "request retry creates only once")
        let duplicate = await call("create_project", ["name": "New Project"])
        check(!duplicate.0 && duplicate.2["name"] as? String == "New Project 2" && duplicate.2["project_id"] as? String != created.2["project_id"] as? String, "duplicate project name numbered")
        let collision = await call("create_project", ["name": "new project"])
        let collisionID = (collision.2["project_id"] as? String).flatMap(UUID.init(uuidString:))
        let collisionName = collision.2["name"] as? String
        check(!collision.0 && collisionName == "new project 3" && ((collision.2["folder"] as? String ?? "") as NSString).lastPathComponent == collisionName && collisionID.flatMap { live.projectRecord($0) }?.name == collisionName, "case-insensitive suffix uses same published name and default folder")
        let shared = try dir("entry/projects/existing")
        let sentinel = shared.appendingPathComponent("keep.txt")
        try Data("unchanged".utf8).write(to: sentinel)
        let reused = await call("create_project", ["name": "Reuse project", "folder": "existing"])
        check(!reused.0 && (try? Data(contentsOf: sentinel)) == Data("unchanged".utf8), "existing folder reused without overwriting files")
        let nested = await call("create_project", ["name": "Nested project", "folder": "one/two"])
        check(!nested.0 && fm.fileExists(atPath: entry.appendingPathComponent("projects/one/two").path), "relative nested folder accepted")
        let outside = try dir("outside")
        try fm.createSymbolicLink(at: entry.appendingPathComponent("projects/escape"), withDestinationURL: outside)
        for mode in ["existing", "empty", "populated", "replacement"] {
            let ancestor = entry.appendingPathComponent("projects/race-\(mode)")
            let moved = outside.appendingPathComponent("race-\(mode)")
            let keep = Data("keep fixture content".utf8)
            if mode == "existing" {
                try fm.createDirectory(at: ancestor, withIntermediateDirectories: true)
                try keep.write(to: ancestor.appendingPathComponent("keep.txt"))
            }
            var gateSucceeded = false
            service.projectDirectoryGate = { depth in
                guard depth == 2 else { return }
                do {
                    if mode == "populated" { try keep.write(to: ancestor.appendingPathComponent("second/keep.txt")) }
                    try fm.moveItem(at: ancestor, to: moved)
                    if mode == "replacement" {
                        try fm.createDirectory(at: ancestor, withIntermediateDirectories: true)
                        try keep.write(to: ancestor.appendingPathComponent("keep.txt"))
                    }
                    gateSucceeded = true
                } catch { }
            }
            let beforeRace = live.doc.projects.count
            let race = await call("create_project", ["name": "Race \(mode)", "folder": "race-\(mode)/second/third"])
            service.projectDirectoryGate = nil
            check(gateSucceeded && race.0 && race.1.contains("project_folder_denied") && live.doc.projects.count == beforeRace, "\(mode) moved ancestor rejected with same error and no project")
            let clean: Bool
            switch mode {
            case "existing": clean = (try? Data(contentsOf: moved.appendingPathComponent("keep.txt"))) == keep && !fm.fileExists(atPath: moved.appendingPathComponent("second").path)
            case "populated": clean = (try? Data(contentsOf: moved.appendingPathComponent("second/keep.txt"))) == keep && !fm.fileExists(atPath: moved.appendingPathComponent("second/third").path)
            case "replacement": clean = !fm.fileExists(atPath: moved.path) && (try? Data(contentsOf: ancestor.appendingPathComponent("keep.txt"))) == keep
            default: clean = !fm.fileExists(atPath: moved.path)
            }
            check(clean, "\(mode) cleanup removes only own empty directories and leaves no escaped child")
        }
        projectClock.set(72 * 3600)
        let beforeControls = live.doc.projects.count
        for (index, value) in ["bad\nname", "bad\rname", "bad\tname", "bad\u{001B}name", "bad\u{007F}name",
                               "bad\u{0085}name", "bad\u{2028}name", "bad\u{2029}name", "\nleading", "trailing\n"].enumerated() {
            let badName = await call("create_project", ["name": value])
            let badFolder = await call("create_project", ["name": "Control fixture \(index)", "folder": value])
            check(badName.0 && badName.1 == "invalid_project_name", "W225a3 raw name controls rejected \(index)")
            check(badFolder.0 && badFolder.1.hasPrefix("invalid_project_folder:"), "W225a3 folder controls rejected \(index)")
            check(!fm.fileExists(atPath: entry.appendingPathComponent("projects/" + value).path),
                  "W225a3 controls create no folder \(index)")
        }
        check(live.doc.projects.count == beforeControls, "W225a3 controls create no project record")
        let beforeInvalid = live.doc.projects.count
        for value in ["..", "../outside", "one/../bad", outside.path, "/tmp/escape", "escape/new", "existing/keep.txt", "", ".", "bad\0name"] {
            check(await call("create_project", ["name": "Invalid project", "folder": value]).0, "unsafe or invalid folder rejected")
        }
        for value in ["", " ", "../bad", "/bad", "bad\0name"] {
            check(await call("create_project", ["name": value]).0, "invalid default folder name rejected")
        }
        check(live.doc.projects.count == beforeInvalid && !fm.fileExists(atPath: outside.appendingPathComponent("new").path), "rejections create no record or escaped directory")
        check(!folder.isEmpty, "create returns folder")
        let journal = await Task.detached { service.roomJournal.rows(projectID: nil) }.value
        check(journal.contains { $0.tool == "read_session" } && journal.contains { $0.tool == "create_project" }, "both tools use existing durable journal")
        let audit = live.transcript(for: service.rootThread(projectID: nil))
        check(audit.contains { $0.text.contains("read_session") && $0.text.contains("thread_id=") } && audit.contains { $0.text.contains("create_project") && $0.text.contains("name=") } && !audit.contains { $0.text.contains(canary) }, "new tool audit parameters retained without dialogue or keys")
        print("W225MCP SUMMARY passed=\(passed) failures=\(failed)")
        return failed == 0
    }
}
private final class W225ProjectClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ time: TimeInterval) { lock.lock(); defer { lock.unlock() }; value = time }
}
#endif
