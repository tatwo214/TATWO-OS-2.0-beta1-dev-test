#if DEBUG
import AppKit
import ApplicationServices
import Darwin

/// Fully isolated fixtures. Native GUI/TCC and real ChatGPT remain the lead's separate real-machine gate.
enum HandsW185Acceptance {
    @MainActor final class ComputerFixture: HandsComputerBackend {
        let session = ComputerUseSession()
        let prompt = IslandNotice(fallback: { _, _, _ in nil }, holdOpen: { _ in }, log: { _ in })
        var requestID: UUID?
        var duration: TimeInterval = 60
        var sensitive = false
        var dispatched = 0
        init() { prompt.hostAvailable = true }
        func application(_ id: String) throws -> ComputerUseExternalPolicy.Application {
            .init(name: "Example", category: "public.app-category.productivity")
        }
        func start(owner: UUID, scope: String, app: String, consent: ComputerUseController.ExternalConsent,
                   valid: @escaping @MainActor () -> Bool) async throws -> ComputerUseSession.Grant {
            requestID = consent.requestID
            let epoch = session.currentEpoch
            let decision = await prompt.ask(title: "ChatGPT 想操作 App", detail: consent.reason,
                                           allowLabel: "允許", timeout: 2, requestID: consent.requestID)
            guard decision != .timeout else { throw ComputerUseFailure("computer_external_expired") }
            guard decision == .allow else { throw ComputerUseFailure("computer_external_denied") }
            guard valid() else { throw ComputerUseFailure("expired") }
            return try session.authorize(owner: owner, scope: scope, pid: 12345, expectedEpoch: epoch,
                                         expiresAt: ProcessInfo.processInfo.systemUptime + duration)
        }
        func perform(_ method: String, params: [String: Any], grant: ComputerUseSession.Grant,
                     valid: @escaping @MainActor () -> Bool) async throws -> [String: Any] {
            guard valid(), !sensitive else { throw ComputerUseFailure("computer_external_sensitive_page_open") }
            try session.validate(grant)
            if method == "computer_action" {
                let observed = try session.beginAction(observationID: params["observationID"] as? String ?? "", fingerprint: "", for: grant)
                if let index = params["element"] as? Int { _ = try observed.element(at: index) }
                try session.dispatch(observationID: observed.id, for: grant) { dispatched += 1 }
                session.endAction(observationID: observed.id, for: grant)
                return ["dispatched": true]
            }
            let observed = try session.publish(fingerprint: "", for: grant, elements: [AXUIElementCreateApplication(12345)])
            return ["observationID": observed.id.uuidString, "text": "fixture clickable element",
                    "imageBase64": "Zml4dHVyZV9pbWFnZQ==", "mimeType": "image/jpeg"]
        }
        func stop(owner: UUID) {
            if let requestID { prompt.resolve(.cancel, id: requestID) }
            session.stop(owner: owner)
        }
    }

    @MainActor static func run() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment), NativeStagingIsolation.validationError(environment) == nil,
              let staging = environment["TATWO_STAGING_ROOT"], let livePath = environment["TATWO2_LIVE_ROOT"] else {
            throw HandsToolError.invalid("w185tools requires fully isolated staging")
        }
        let base = URL(fileURLWithPath: HandsPath.realpath(staging) ?? staging).appendingPathComponent("w185tools-" + UUID().uuidString)
        func dir(_ path: String) throws -> URL {
            let url = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let entry = try dir("entry"), home = try dir("home"), support = try dir("support")
        let slowRuntime = try dir("slow-runtime/bin")
        let slowCLI = slowRuntime.appendingPathComponent("codex")
        try "#!/bin/sh\nsleep 1\nprintf 'codex 0.99.0\\n'\n".write(to: slowCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: slowCLI.path)
        var slowEnvironment = environment
        slowEnvironment["TATWO2_RUNTIME_BIN"] = slowRuntime.path
        let slowPaths = EnginePaths(environment: slowEnvironment)
        let probeStarted = Date()
        let pendingSelection = slowPaths.selection(for: .codex)
        let mainProbeElapsed = Date().timeIntervalSince(probeStarted)
        let alphaDir = try dir("work/alpha"), betaDir = try dir("work/beta"), tradingDir = try dir("work/live")
        let live = ChatLiveEngine(store: ChatLiveStore(root: URL(fileURLWithPath: livePath).appendingPathComponent("w185tools")), environment: environment)
        defer { live.shutdownAll() }
        let bots = BotLibrary(root: base, skillsRoot: try dir("bot-skills"))
        await bots.ready()
        let model = ChatPageModel(environment: environment, botCoreFixture: (live, BotStore(library: bots)))
        let alpha = live.newProject(name: "fixture", workdir: alphaDir.path)
        let beta = live.newProject(name: "sample", workdir: betaDir.path)
        let trading = live.newProject(name: "BTC 實盤", workdir: tradingDir.path)
        let paths = HandsPaths(root: try dir("hands"))
        var runtime = HandsRuntime.current(paths: paths, environment: environment)
        let nodeFixture = URL(fileURLWithPath: "/private/tmp/w185-node-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: nodeFixture) }
        if let node = HandsUIAcceptance.findNode(fixtureDirectory: nodeFixture) {
            // 自測的沙盒小幫手用明確 Node 副本；仍走正式 profile、spawn 與授權檢查。
            runtime.nodePath = node.path
            runtime.nodeBundled = true
        }
        runtime.home = home.path; runtime.entryRoot = entry.path; runtime.appSupport = support.path
        runtime.workspaceEntry = nil
        runtime.environment["TATWO2_SKILLET_PATH"] = entry.appendingPathComponent("skillet.md").path
        let service = HandsService(paths: paths, runtime: runtime)
        service.deviceIDOverride = HandsConnectAcceptance.hostID
        service.callsPerMinute = 100_000
        service.noticeSink = { _, _ in }
        service.attach(model: model)
        _ = try dir("entry/memory")
        let memory = TatwoMemoryStore()
        memory.pathsOverride = EngineMemoryPaths(home: home.path, entryRoot: entry)
        service.memoryStore = memory
        _ = try service.updateSettings {
            $0.enabled = true; $0.level = 2; $0.allProjects = true
            $0.hostDeviceID = HandsConnectAcceptance.hostID; $0.publicHost = HandsConnectAcceptance.publicHost
        }
        let client = HandsConnectAcceptance.FakeChatGPT(service: service)
        try client.register(); try service.startPairing(); _ = client.begin()
        let access = try client.token(try client.submit(service.auth.pendingCard?.pairingCode ?? ""))
        guard let grant = service.auth.grant(forAccess: access) else { throw HandsToolError.invalid("fixture_pairing") }
        let selected = live.doc.selectedThreadID
        var passed = 0, failed = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("W185TOOLS \(condition ? "PASS" : "FAIL") \(label)")
        }
        func refuses(_ work: () throws -> Void) -> Bool { do { try work(); return false } catch { return true } }
        func tool(_ name: String, _ args: [String: Any] = [:]) async -> [String: Any] {
            let data = await Task.detached { () -> Data in
                let response = OSAgentBridge.handsResponse(method: "hands_call",
                    params: ["access_token": access, "name": name, "arguments": args], service: service)
                return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
            }.value
            return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["result"] as? [String: Any] ?? [:]
        }
        func text(_ result: [String: Any]) -> String { (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "" }

        // The index itself is a fixture, not executable instructions.
        let skillDir = try dir("entry/skills/test")
        let canary = "sk" + "-" + "test_" + String(repeating: "A1b2", count: 14)
        try "# Verify\nCheck results.\napi_key=\(canary)\n".write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        check(mainProbeElapsed < 0.15 && pendingSelection.version == nil,
              "A2 slow candidate main-thread call returns without subprocess wait elapsed=\(mainProbeElapsed)")
        var heartbeat = false
        let pulse = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            heartbeat = true
        }
        let refreshedSelection = try await slowPaths.selectionAsync(for: .codex, forceVerification: true)
        await pulse.value
        check(heartbeat && refreshedSelection.version == "0.99.0" && slowPaths.cachedSelection(for: .codex) == refreshedSelection,
              "A2 background slow probe lets main actor advance and publishes completed cache")
        let cancelledProbe = Task { try await slowPaths.selectionAsync(for: .codex, forceVerification: true) }
        try await Task.sleep(for: .milliseconds(100))
        cancelledProbe.cancel()
        var cancelled = false
        do { _ = try await cancelledProbe.value } catch is CancellationError { cancelled = true }
        check(cancelled && slowPaths.cachedSelection(for: .codex) == refreshedSelection,
              "A2 cancelled probe cannot replace the completed choice")

        let startupCapture = base.appendingPathComponent("startup-writes")
        let startupMarker = base.appendingPathComponent("startup-marker")
        let fixtureNode = slowRuntime.appendingPathComponent("node")
        try "#!/bin/sh\nprintf started > '\(startupMarker.path)'\nprintf '%s\\n' \"$TATWO2_ENGINE_IDENTITY\" >> '\(startupCapture.path)'\nwhile IFS= read -r line; do printf '%s\\n' \"$line\" >> '\(startupCapture.path)'; done\n"
            .write(to: fixtureNode, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixtureNode.path)
        let priorRuntime = ProcessInfo.processInfo.environment["TATWO2_RUNTIME_BIN"]
        func restoreRuntime() {
            if let priorRuntime { setenv("TATWO2_RUNTIME_BIN", priorRuntime, 1) }
            else { unsetenv("TATWO2_RUNTIME_BIN") }
        }
        setenv("TATWO2_RUNTIME_BIN", slowRuntime.path, 1)
        defer { restoreRuntime() }
        let queuedSidecar = ClaudeSidecar(kind: .codex)
        defer { queuedSidecar.terminate() }
        let startupStarted = Date()
        try queuedSidecar.start(cwd: home.path, resume: nil, model: nil)
        let startupElapsed = Date().timeIntervalSince(startupStarted)
        check(startupElapsed < 0.15 && queuedSidecar.send(text: "queued fixture", uuid: "fixture-turn"),
              "A2 sidecar startup queues the turn without blocking UI elapsed=\(startupElapsed)")
        for _ in 0..<60 {
            if (try? String(contentsOf: startupCapture, encoding: .utf8))?.contains("fixture-turn") == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let queuedOutput = (try? String(contentsOf: startupCapture, encoding: .utf8)) ?? ""
        check(queuedOutput.components(separatedBy: "fixture-turn").count == 2 && queuedOutput.contains("0.99.0"),
              "A2 completed selection delivers the queued turn exactly once")
        queuedSidecar.terminate()
        for interrupt in [false, true] {
            try? FileManager.default.removeItem(at: startupMarker)
            let cancelledSidecar = ClaudeSidecar(kind: .codex)
            try cancelledSidecar.start(cwd: home.path, resume: nil, model: nil)
            _ = cancelledSidecar.send(text: "cancelled fixture", uuid: "cancelled-turn")
            if interrupt { cancelledSidecar.interrupt() } else { cancelledSidecar.close() }
            try await Task.sleep(for: .milliseconds(1200))
            check(!FileManager.default.fileExists(atPath: startupMarker.path) && !cancelledSidecar.isRunning,
                  "A2 \(interrupt ? "stop" : "close") cancels startup and cannot launch a queued turn later")
        }
        restoreRuntime()
        let index = "- [test](skills/test/SKILL.md)：Verify results\n- `$demo`：Inline public skill\n- `$private`：私人不進公開\n"
        try index.write(to: entry.appendingPathComponent("skillet.md"), atomically: true, encoding: .utf8)
        let list = await tool("skillet_list")
        check(text(list).contains("test") && text(list).contains("demo") && !text(list).contains("private"), "skillet_list only public listed entries")
        let read = await tool("skillet_read", ["name": "test"])
        check(text(read).contains("Check results.") && !text(read).contains(canary), "skillet_read full skill redacts secrets before return")
        for name in ["../check", "/etc/passwd", "private", "unlisted", ".ssh/id_rsa"] {
            let result = await tool("skillet_read", ["name": name])
            check(result["isError"] as? Bool == true, "skillet rejects \(name)")
        }
        let big = try dir("entry/skills/big")
        try String(repeating: "x", count: 64 * 1024 + 1).write(to: big.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let outside = try dir("outside")
        try "outside private data".write(to: outside.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: entry.appendingPathComponent("skills/escape"), withDestinationURL: outside)
        try (index + "- [big](skills/big/SKILL.md)：Too large\n- [escape](skills/escape/SKILL.md)：Escape\n- [secret](skills/.ssh/SKILL.md)：Key file\n")
            .write(to: entry.appendingPathComponent("skillet.md"), atomically: true, encoding: .utf8)
        for name in ["big", "escape", "secret"] {
            let result = await tool("skillet_read", ["name": name])
            check(result["isError"] as? Bool == true, "skillet rejects over-limit/symlink/key path \(name)")
        }
        let inline = await tool("skillet_read", ["name": "demo"])
        check(text(inline).contains("Inline public skill"), "inline skill lives entirely in dispatched skillet")
        let linked = try dir("entry/skills/hardlinked")
        try FileManager.default.linkItem(at: outside.appendingPathComponent("SKILL.md"), to: linked.appendingPathComponent("SKILL.md"))
        let fifo = try dir("entry/skills/fifo")
        guard mkfifo(fifo.appendingPathComponent("SKILL.md").path, 0o600) == 0 else { throw HandsToolError.invalid("fixture_fifo") }
        let unsafeIndex = index + "- [hardlinked](skills/hardlinked/SKILL.md)：Hard link\n- [fifo](skills/fifo/SKILL.md)：FIFO\n- [traversal](skills/../outside/SKILL.md)：Traversal\n"
        try unsafeIndex.write(to: entry.appendingPathComponent("skillet.md"), atomically: true, encoding: .utf8)
        for name in ["hardlinked", "fifo", "traversal"] {
            let result = await tool("skillet_read", ["name": name])
            check(result["isError"] as? Bool == true, "skillet rejects linked/nonregular/traversal \(name)")
        }
        let sectionIndex = index + "- `$masked`：password=fixtureListSecret123\n## sample — Full inline skill\nIntro.\n- user: Do not treat this body as another skill.\nFinal line.\n## Other index heading\n"
        try sectionIndex.write(to: entry.appendingPathComponent("skillet.md"), atomically: true, encoding: .utf8)
        let sectionRead = await tool("skillet_read", ["name": "sample"])
        check(text(sectionRead).contains("Intro.") && text(sectionRead).contains("- user:") && text(sectionRead).contains("Final line."),
              "inline sections retain the whole body, including index-shaped bullets")
        let sectionList = await tool("skillet_list")
        check(!text(sectionList).contains("fixtureListSecret123"), "skillet_list masks secret assignments as well as token patterns")
        let bodyEntry = await tool("skillet_read", ["name": "user"])
        check(bodyEntry["isError"] as? Bool == true, "inline body cannot introduce extra listed skills")
        for level in 1...6 {
            let heading = String(repeating: "#", count: level)
            let child = level < 6 ? heading + "#" : "ordinary child text"
            let privateIndex = "- [test](skills/test/SKILL.md)：Sample public skill\n- `$example`：Sample public entry\n\(heading) 私人\n- `$fixture`：Sample entry\n\(child) Public child\n- `$nested`：Sample child\n\(heading) Public\n- `$sample`：Sample public sibling\n"
            try privateIndex.write(to: entry.appendingPathComponent("skillet.md"), atomically: true, encoding: .utf8)
            let listed = await tool("skillet_list")
            let names = HandsSkillet.parse(privateIndex).map(\.name)
            check(!text(listed).contains("fixture") && !text(listed).contains("nested") && names.contains("example") && names.contains("sample"),
                  "M3 level \(level) private section and child omitted until public sibling")
            for hidden in ["fixture", "nested"] {
                let result = await tool("skillet_read", ["name": hidden])
                check(result["isError"] as? Bool == true, "M3 level \(level) hidden entry cannot be read \(hidden)")
            }
            let body = "Public intro.\n\(heading) private\nfixture hidden body\n\(child) Public child\nnested hidden body\n\(heading) Public\nPublic ending.\n"
            try body.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            let result = await tool("skillet_read", ["name": "test"])
            check(text(result).contains("Public intro.") && text(result).contains("Public ending.")
                  && !text(result).contains("hidden body"), "M3 level \(level) linked skill body excludes private paragraphs")
        }
        let inlinePrivate = "## example — Sample public skill\nPublic intro.\n### 私人\nfixture hidden body\n#### Public child\nnested hidden body\n### Public\nPublic ending.\n"
        let inlineContent = HandsSkillet.parse(inlinePrivate).first?.content ?? ""
        check(inlineContent.contains("Public intro.") && inlineContent.contains("Public ending.") && !inlineContent.contains("hidden body"),
              "M3 inline skill retains public text around a private child section")
        for (opening, falseClose, closing) in [("```swift", "~~~", "````"), ("  ~~~~~", "  ~~~", "  ~~~~~~"), ("    ````", "    ```", "    ````")] {
            let fenced = "## 私人\n\(opening)\n## 公開\n- `$exampleHidden`：Sample hidden entry\n\(falseClose)\n## 公開\n\(closing)\n- `$afterFenceHidden`：Sample hidden entry\nPrivate fixture body.\n## 公開\n- `$visibleSibling`：Sample public sibling\n"
            try ("- [test](skills/test/SKILL.md)：Sample public skill\n" + fenced).write(to: entry.appendingPathComponent("skillet.md"), atomically: true, encoding: .utf8)
            let listed = await tool("skillet_list")
            check(!text(listed).contains("exampleHidden") && !text(listed).contains("afterFenceHidden") && text(listed).contains("visibleSibling"),
                  "S4 fenced public headings cannot reopen private index \(opening)")
            for hidden in ["exampleHidden", "afterFenceHidden"] {
                let result = await tool("skillet_read", ["name": hidden])
                check(result["isError"] as? Bool == true, "S4 fenced private entry cannot be read \(hidden) \(opening)")
            }
            try ("Public intro.\n" + fenced).write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            let result = await tool("skillet_read", ["name": "test"])
            check(!text(result).contains("Private fixture body") && !text(result).contains("afterFenceHidden") && text(result).contains("visibleSibling"),
                  "S4 linked skill keeps text private after a fenced heading \(opening)")
        }
        // .053 Claude 驗收：寧可多藏——公開段落的圍欄裡出現私人標題，也從那裡開始藏，直到圍欄外的公開標題。
        let publicFence = "```markdown\n## 私人\nS4c fenced private body\n```\nS4c text after example\n## 公開\nPublic fixture after example."
        let fencedShown = HandsSkillet.publicContent(publicFence)
        check(!fencedShown.contains("S4c fenced private body") && !fencedShown.contains("S4c text after example")
              && fencedShown.contains("Public fixture after example."), "S4c fenced private heading in a public section hides until a real public heading")
        // .053 驗收 S4（Sol）：單行「```範例```」與沒收尾的圍欄開頭都不能把後面的私人段落變成公開。
        for opener in ["```inline example```", "```", "~~~ never closed", "  ```swift"] {
            let leaky = "Public intro.\n\(opener)\n## 私人\nS4b hidden fixture body\n### Private child\nS4b nested hidden\n## 公開\nPublic ending."
            let shown = HandsSkillet.publicContent(leaky)
            check(shown.contains("Public intro.") && shown.contains("Public ending.") && !shown.contains("S4b hidden fixture body")
                  && !shown.contains("S4b nested hidden"), "S4b \(opener) does not reopen a later private section")
        }
        let closedAfterInline = "Public intro.\n```inline```\n```text\n## 公開 example\n```\n## 私人\nS4b closed hidden\n## 公開\nPublic ending."
        let closedShown = HandsSkillet.publicContent(closedAfterInline)
        check(closedShown.contains("## 公開 example") && !closedShown.contains("S4b closed hidden") && closedShown.contains("Public ending."),
              "S4b inline code before a real fence keeps the real fence and the private section")
        check(HandsTools.catalog(level: 0).allSatisfy { !$0.name.hasPrefix("skillet") && !$0.name.hasPrefix("computer") },
              "L0 has neither skillet nor CU")
        check(HandsTools.catalog(level: 1).allSatisfy { !$0.name.hasPrefix("computer") }, "L1 has no CU")

        for (name, arguments) in [
            ("memory_inbox_save", ["title": "fixture note", "content": "fixture memory"] as [String: Any]),
            ("propose_goal", ["title": "Verify Alpha"] as [String: Any]),
            ("write_report", ["text": "Intentional fixture report"] as [String: Any])
        ] {
            var args = arguments; args["project_id"] = alpha.uuidString
            let result = await tool(name, args)
            check(result["isError"] as? Bool == false && service.roomJournal.rows(projectID: alpha).contains { $0.tool == name },
                  "\(name) project_id routes to Alpha ChatGPT room")
            args["project_id"] = UUID().uuidString
            let unknown = await tool(name, args)
            check(unknown["isError"] as? Bool == true && text(unknown).contains("fixture") && text(unknown).contains("sample")
                  && !text(unknown).contains(alphaDir.path), "\(name) unknown project returns names, not paths/no auto-create")
            args["project_id"] = trading.uuidString
            let denied = await tool(name, args)
            check(denied["isError"] as? Bool == true && text(denied).contains("read_only"), "\(name) trading floor cannot be bypassed")
        }
        let unclassified = await tool("memory_inbox_save", ["title": "unclassified", "content": "fixture note"])
        check(unclassified["isError"] as? Bool == false && text(unclassified).contains("未分類")
              && service.roomJournal.rows(projectID: nil).contains { $0.tool == "memory_inbox_save" }, "missing project does work + unclassified + reminder")
        check(HandsTools.all.allSatisfy { $0.properties["project_id"]?["type"] as? String == "string" },
              "W196 C3 every tool accepts project_id in its advertised schema")
        for name in ["tatwo_status", "list_projects", "list_workspaces", "memory_inbox_list"] {
            let classified = await tool(name, ["project_id": alpha.uuidString])
            check(classified["isError"] as? Bool == false && service.roomJournal.rows(projectID: alpha).contains { $0.tool == name },
                  "W196 C3 \(name) explicit project routes through real wire and journal")
            let missing = await tool(name)
            check(missing["isError"] as? Bool == false && service.roomJournal.rows(projectID: nil).contains { $0.tool == name },
                  "W196 C3 \(name) omitted project uses unclassified journal")
            let invalid = await tool(name, ["project_id": beta.uuidString + "invalid"])
            check(invalid["isError"] as? Bool == true, "W196 C3 \(name) invalid project is rejected")
        }
        // 真正開隔離工作區，驗 project_id 僅決定紀錄歸屬、不能擴大工作區權限。
        try await Task.detached {
            _ = try HandsGit.run(["init", "-q", "-b", "main"], cwd: alphaDir.path)
            try Data("mapping fixture\n".utf8).write(to: alphaDir.appendingPathComponent("fixture.txt"))
            _ = try HandsGit.run(["add", "fixture.txt"], cwd: alphaDir.path)
            _ = try HandsGit.run(["-c", "user.name=fixture", "-c", "user.email=fixture@localhost", "commit", "-q", "-m", "fixture"], cwd: alphaDir.path)
        }.value
        let opened = await tool("open_workspace", ["project_id": alpha.uuidString, "title": "PRIVATE_MAPPING_TITLE"])
        let openedObject = (try? JSONSerialization.jsonObject(with: Data(text(opened).utf8))) as? [String: Any]
        if let workspaceID = openedObject?["workspace_id"] as? String ?? openedObject?["id"] as? String {
            let read = await tool("read_file", ["project_id": alpha.uuidString, "workspace_id": workspaceID, "path": "fixture.txt"])
            check(read["isError"] as? Bool == false && text(read).contains("mapping fixture"),
                  "W196 C3 workspace read accepts matching explicit project" + (read["isError"] as? Bool == true ? " result=" + text(read) : ""))
            let wrong = await tool("read_file", ["project_id": beta.uuidString, "workspace_id": workspaceID, "path": "fixture.txt"])
            check(wrong["isError"] as? Bool == true && text(wrong).contains("project_workspace_mismatch"),
                  "W196 C3 mismatched project cannot read another workspace")
            let missing = await tool("read_file", ["workspace_id": workspaceID, "path": "fixture.txt"])
            check(missing["isError"] as? Bool == false && service.roomJournal.rows(projectID: alpha).contains {
                $0.tool == "read_file" && $0.workspaceID?.uuidString == workspaceID
            }, "W226a workspace-only call retains access checks and records in workspace project")
            check(!service.roomJournal.rows(projectID: alpha).contains { $0.summary.contains("PRIVATE_MAPPING_TITLE") }
                  && !live.transcript(for: service.rootThread(projectID: alpha)).contains { $0.text.contains("PRIVATE_MAPPING_TITLE") },
                  "W196 privacy workspace title is absent from tool audit and transcript metadata")
        } else { check(false, "W196 C3 workspace fixture opens through real wire") }
        let inbox = await tool("memory_inbox_list")
        check(text(inbox).contains(alpha.uuidString), "intentional inbox notes retain their resolved project_id for local reviewers")
        let alphaRoot = service.rootThread(projectID: alpha), betaRoot = service.rootThread(projectID: beta)
        check(alphaRoot != betaRoot && live.threadRecord(alphaRoot)?.projectID == alpha
              && live.transcript(for: alphaRoot).contains { $0.text.contains("write_report") }, "project rooms are distinct, recorded, readable by existing transcript tools")
        check(live.doc.selectedThreadID == selected, "tool logging never starts/selects an engine")
        let beforeProjects = live.doc.projects.count
        _ = await tool("write_report", ["project_id": "not-a-project", "text": "must not be stored"])
        check(live.doc.projects.count == beforeProjects, "unknown project never creates a project")

        for id in ComputerUseExternalPolicy.deniedIdentifiers.union(ComputerUseExternalPolicy.deniedBrowserIdentifiers) {
            check(refuses { _ = try ComputerUseExternalPolicy.validateApplication(id, name: "Example", category: "public.app-category.productivity") }, "denied App constant \(id)")
        }
        for id in ["ai.tatwo.tatwo2", "ai.tatwo.tatwo2.staging", "com.example.bank", "com.example.terminal"] {
            check(refuses { _ = try ComputerUseExternalPolicy.validateApplication(id, name: "Example", category: "public.app-category.productivity") }, "self/approval/bank/terminal cannot be a target \(id)")
        }
        check(!refuses { _ = try ComputerUseExternalPolicy.validateApplication("com.example.productivity", name: "Example", category: "public.app-category.productivity") }, "safe category permitted before explicit host consent")
        for phrase in ["配對碼", "OAuth authorization", "sign in", "銀行", "隱私權與安全性", "ChatGPT 核准", "api key"] {
            check(!ComputerUseExternalPolicy.safe(role: "", text: phrase), "sensitive page denied \(phrase)")
        }
        check(!ComputerUseExternalPolicy.safe(role: "AXSecureTextField", text: ""), "secure fields denied, even without titles/values")
        check(!ComputerUseExternalPolicy.safe(role: "AXWebArea", text: ""), "opaque browser/auth pages cannot bypass external page security")
        check(!ComputerUseExternalPolicy.focusOwnerAllowed(owner: getpid(), target: 12345)
              && !ComputerUseExternalPolicy.focusOwnerAllowed(owner: 111, target: 12345)
              && ComputerUseExternalPolicy.focusOwnerAllowed(owner: 12345, target: 12345),
              "TATWO approval and system security dialogue cannot receive external input")
        for file in ["file:///fixture/.ssh/id_rsa", "file:///fixture/wallet.dat", "file:///fixture/%2Eenv",
                     "file:///fixture/credentials%2Ejson", "file:///fixture/private.pem"] {
            check(!ComputerUseExternalPolicy.documentAllowed(file), "CU cannot expose secret-class AXDocument \(file)")
        }
        check(ComputerUseExternalPolicy.documentAllowed("file:///fixture/readme.txt"), "ordinary AXDocument remains permitted")
        check(refuses { try ComputerUseNative.requireNonSecure(role: "AXTextField", subrole: kAXSecureTextFieldSubrole) }, "native secure subrole protection retained")
        check(ComputerUseWindowPick.protection(sharingState: 0) == .protected
              && ComputerUseWindowPick.protection(sharingState: nil) == .unknown, "protected/unknown capture is fail-closed")
        let requestSpec = HandsTools.tool(named: "computer_request")!
        for bad: [String: Any] in [
            ["app": "com.example.productivity", "reason": "test", "minutes": 16],
            ["app": "com.example.productivity", "reason": "test", "minutes": 0],
            ["app": "com.example.productivity", "reason": "test", "minutes": true],
            ["app": "com.example.productivity", "reason": "test", "minutes": 1, "approve": true],
            ["app": "com.example.productivity", "reason": "test", "minutes": 1, "sessionID": "fake"]
        ] { check(refuses { try HandsTools.check(bad, requestSpec) }, "request cannot supply approval/token or invalid duration") }
        let fixture = ComputerFixture(), manager = HandsComputerUse(backend: fixture)
        service.computerUseForTesting = manager
        let landing = HandsProjectLanding(projectID: alpha, workspaceID: nil, reminder: nil)
        func wait(_ predicate: () -> Bool) async -> Bool {
            for _ in 0..<100 { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
            return false
        }
        func start() async throws {
            let response = await tool("computer_request", ["app": "com.example.productivity", "reason": "Verify fixture",
                                                          "minutes": 1, "project_id": alpha.uuidString])
            check(response["isError"] as? Bool == false && text(response).contains("pending"), "computer_request wire returns pending and routes project")
            _ = await wait { fixture.prompt.current != nil }
        }
        try await start()
        check(manager.current?.appDisplayName == "Example" && manager.current?.app == "com.example.productivity",
              "M13 Island uses application name while authorization keeps bundle ID")
        check(manager.status(grant: grant.grantID, service: service)["status"] as? String == "pending", "CU request returns pending before host click")
        do { _ = try await manager.perform("computer_observe", arguments: [:], grant: grant.grantID, service: service); check(false, "pending blocks observe") }
        catch { check(true, "pending blocks observe") }
        fixture.prompt.resolve(.allow, id: fixture.requestID ?? UUID())
        let allowed = await wait { manager.current?.state == .allowed }
        check(allowed && (manager.status(grant: grant.grantID, service: service)["remaining_minutes"] as? Double ?? 0) > 0, "local Island click transitions pending→allowed with remaining time")
        let wireStatus = await tool("computer_status")
        check(text(wireStatus).contains("allowed") && text(wireStatus).contains("remaining_minutes"), "computer_status wire reports lease time")
        check(service.roomJournal.rows(projectID: nil).contains { $0.tool == "computer_status" },
              "W196 C3 omitted CU project is recorded as unclassified")
        let matchingStatus = await tool("computer_status", ["project_id": alpha.uuidString])
        check(matchingStatus["isError"] as? Bool == false && text(matchingStatus).contains("allowed"),
              "W196 C3 matching CU project keeps native lease checks")
        let wrongStatus = await tool("computer_status", ["project_id": beta.uuidString])
        check(wrongStatus["isError"] as? Bool == true && text(wrongStatus).contains("project_lease_mismatch"),
              "W196 C3 wrong CU project cannot relabel the authorized lease")
        let wireObservation = await tool("computer_observe")
        check(wireObservation["isError"] as? Bool == false
              && (wireObservation["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "image" } == true,
              "computer_observe wire returns MCP image without persisting it")
        let wireJSON = (try? JSONSerialization.jsonObject(with: Data(text(wireObservation).utf8))) as? [String: Any] ?? [:]
        let wireAction = await tool("computer_action", ["action": "click", "element": 0,
                                                       "observationID": wireJSON["observationID"] ?? ""])
        check(wireAction["isError"] as? Bool == false && fixture.dispatched == 1, "computer_action wire uses native observation gate")
        let observation = try await manager.perform("computer_observe", arguments: [:], grant: grant.grantID, service: service)
        let action = ["action": "click", "element": 0, "observationID": observation["observationID"] ?? ""] as [String: Any]
        _ = try await manager.perform("computer_action", arguments: action, grant: grant.grantID, service: service)
        check(fixture.dispatched == 2, "allowed observe→action consumes native observation")
        do { _ = try await manager.perform("computer_action", arguments: action, grant: grant.grantID, service: service); check(false, "stale observation denied") }
        catch { check(fixture.dispatched == 2, "stale observation denied") }
        fixture.sensitive = true
        do { _ = try await manager.perform("computer_observe", arguments: [:], grant: grant.grantID, service: service); check(false, "sensitive observe denied") }
        catch { check(true, "sensitive observe denied") }
        do { _ = try await manager.perform("computer_action", arguments: action, grant: grant.grantID, service: service); check(false, "sensitive page action denied") }
        catch { check(fixture.dispatched == 2, "sensitive page action denied") }
        fixture.sensitive = false
        check(manager.status(grant: "another-grant", service: service)["status"] as? String == "expired", "cross-grant status cannot inspect another request")
        let fresh = try await manager.perform("computer_observe", arguments: [:], grant: grant.grantID, service: service)
        let auditFolder = service.roomJournal.url.deletingPathExtension().appendingPathComponent(alpha.uuidString)
        let auditArchive = base.appendingPathComponent("audit-archive")
        try FileManager.default.moveItem(at: auditFolder, to: auditArchive)
        try Data("fixture storage blocker".utf8).write(to: auditFolder)
        let blockedAction = await tool("computer_action", ["action": "click", "element": 0, "observationID": fresh["observationID"] ?? ""])
        check(blockedAction["isError"] as? Bool == true && fixture.dispatched == 2, "unwritable audit storage refuses new input before dispatch")
        manager.tick()
        check(manager.current?.state == .expired && manager.current?.native.map { (try? fixture.session.validate($0)) == nil } == true,
              "unwritable action audit revokes the native lease")
        let wireStop = await tool("computer_stop")
        check(wireStop["isError"] as? Bool == false && text(wireStop).contains("expired"), "computer_stop wire revokes without replaying a stale result")
        try FileManager.default.moveItem(at: auditFolder, to: base.appendingPathComponent("audit-blocker-archived"))
        try FileManager.default.moveItem(at: auditArchive, to: auditFolder)
        check(manager.current?.state == .expired, "tool stop transitions allowed→expired")
        do { _ = try await manager.perform("computer_observe", arguments: [:], grant: grant.grantID, service: service); check(false, "stop fences all later calls") }
        catch { check(String(describing: error) == "expired", "stop fences all later calls") }
        try await start()
        fixture.prompt.resolve(.cancel, id: fixture.requestID ?? UUID())
        check(await wait { manager.current?.state == .denied }, "host denies pending request")
        try await start()
        try FileManager.default.moveItem(at: auditFolder, to: auditArchive)
        try Data("fixture approval storage blocker".utf8).write(to: auditFolder)
        fixture.prompt.resolve(.allow, id: fixture.requestID ?? UUID())
        check(await wait { manager.current?.state == .expired }, "unwritable approval receipt expires lease instead of permitting unlogged operations")
        check(manager.current?.native.map { (try? fixture.session.validate($0)) == nil } == true,
              "approval receipt failure synchronously revokes native input")
        try FileManager.default.moveItem(at: auditFolder, to: base.appendingPathComponent("approval-blocker-archived"))
        try FileManager.default.moveItem(at: auditArchive, to: auditFolder)
        try await start()
        fixture.prompt.resolve(.allow, id: fixture.requestID ?? UUID())
        _ = await wait { manager.current?.state == .allowed }
        manager.stop()
        check(manager.current?.state == .expired, "Island user stop invalidates native epoch immediately")
        fixture.duration = 0.08
        try await start()
        fixture.prompt.resolve(.allow, id: fixture.requestID ?? UUID())
        _ = await wait { manager.current?.state == .allowed }
        try? await Task.sleep(for: .milliseconds(100))
        manager.tick()
        check(manager.current?.state == .expired, "timeout expires without another tool call")
        fixture.duration = 60
        try await start()
        fixture.prompt.resolve(.allow, id: fixture.requestID ?? UUID())
        _ = await wait { manager.current?.state == .allowed }
        if let native = manager.current?.native { fixture.session.stop(ifCurrent: native) }
        manager.tick()
        check(manager.current?.state == .expired, "native App-close/revocation gate expires external request")
        try await start()
        fixture.prompt.resolve(.allow, id: fixture.requestID ?? UUID())
        _ = await wait { manager.current?.state == .allowed }
        let nativeBeforeLowering = manager.current?.native
        _ = try service.updateSettings { $0.level = 1 }
        check(nativeBeforeLowering.map { (try? fixture.session.validate($0)) == nil } == true,
              "settings downgrade invalidates native input synchronously, before actor cleanup")
        manager.tick()
        check(manager.current?.state == .expired, "settings downgrade expires external lease")
        _ = try service.updateSettings { $0.level = 2 }
        try await start()
        fixture.prompt.resolve(.allow, id: fixture.requestID ?? UUID())
        _ = await wait { manager.current?.state == .allowed }
        manager.stop()
        let hardened = try await HandsW185CUAcceptance.run(service: service, grant: grant.grantID, landing: landing, base: base)
        passed += hardened.passed; failed += hardened.failed
        try await start()
        fixture.prompt.resolve(.allow, id: fixture.requestID ?? UUID())
        _ = await wait { manager.current?.state == .allowed }
        service.auth.revokeGrant(grant.grantID)
        manager.tick()
        check(manager.current?.state == .expired, "TATWO grant revocation expires CU and stops native input")
        let rows = service.roomJournal.rows(projectID: alpha)
        let stored = String(decoding: try JSONEncoder().encode(rows), as: UTF8.self)
        check(rows.contains { $0.approval == "allowed" } && rows.contains { $0.approval == "denied" } && rows.contains { $0.approval == "expired" },
              "ChatGPT room has CU decision and stop history")
        check(!stored.contains("imageBase64") && !stored.contains("Intentional fixture report")
              && !stored.contains("fixture memory") && !stored.contains("Zml4dHVyZV9pbWFnZQ=="), "journal never saves dialogue/tool bodies/screenshots")
        let metadata = HandsTools.summarize(arguments: ["text": "DIALOGUE_CANARY"], tool: "computer_action", redact: { $0 })
        check(!metadata.contains("DIALOGUE_CANARY"), "typed text is bytes-only metadata")
        let mapDir = alphaDir.appendingPathComponent(".tatwo")
        try FileManager.default.createDirectory(at: mapDir, withIntermediateDirectories: true)
        try #"{"chatgpt_project_id":"g-p-fixture","name":"TATWO · Alpha","threads":{}}"#
            .write(to: mapDir.appendingPathComponent("tap-map.json"), atomically: true, encoding: .utf8)
        check(HandsTapMap.name(workdir: alphaDir.path) == "TATWO · Alpha" && HandsTapMap.name(workdir: betaDir.path) == nil,
              "project card shows mapping only when tap-map exists")
        print("W185TOOLS SUMMARY passed=\(passed) failures=\(failed)")
        return failed == 0
    }
}
#endif
