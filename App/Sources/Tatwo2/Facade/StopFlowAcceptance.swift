import Foundation

#if DEBUG
enum StopFlowAcceptance {
    @MainActor static func run(root: URL, env: [String: String], check: (String, Bool) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("fixture.mjs")
        try #"""
        import readline from 'node:readline';
        const rl = readline.createInterface({input:process.stdin});
        rl.on('line', line => {
          const c = JSON.parse(line);
          if(c.op === 'send' && c.text === 'login-error') console.log(JSON.stringify({ev:'sdk',msg:{
            type:'result',client_turn_id:c.uuid,is_error:true,result:'fixture login required'}}));
          if(c.op === 'close' || (c.op === 'send' && c.text === 'closed')) process.exit(0);
        });
        rl.on('close',()=>process.exit(0));
        """#.write(to: script, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard
        let prior = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = prior; overrides["tatwo2.sidecarPath.codex"] = script.path
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(prior, forName: UserDefaults.argumentDomain) }
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env)
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "fixture", workdir: root.path)
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root)))
        model.engineLoginTestDouble = [.codex]
        model.selectedModel = "gpt-6.1-sol"
        engine.onChange = { [weak model, weak engine] in
            guard let model, let engine else { return }
            model.document = engine.document
            model.isRunning = engine.isRunning(model.selectedThreadID)
        }
        let attachment = root.appendingPathComponent("sample.txt")
        try Data("sample".utf8).write(to: attachment)
        func send(_ text: String, attachmentPaths: [String] = []) -> UUID {
            let id = engine.newThread(in: project)
            model.selectedThreadID = id
            model.prompt = text; model.droppedPaths = attachmentPaths
            model.droppedPathDisplayNames = [attachment.path: "sample.txt"]
            model.send()
            check("send-09 fixture accepted \(text)", engine.isRunning(id) && model.prompt.isEmpty)
            return id
        }
        func tool(_ id: UUID) {
            let turn = engine.transcript(for: id).last(where: { $0.role == .user })!.turnID!
            engine.handleSDK(id, ["type": "assistant", "client_turn_id": turn,
                "message": ["content": [["type": "tool_use", "id": UUID().uuidString,
                                          "name": "fixture", "input": [:]]]]])
        }
        let unknown = send("unknown", attachmentPaths: [attachment.path])
        engine.stop(threadID: unknown); engine.stop(threadID: unknown)
        check("send-09/F1 forced stop settles unconfirmed delivery", model.coderDeliveries[unknown] == nil)
        check("send-09/F1 forced stop restores text and attachment", model.prompt == "unknown" && model.droppedPaths == [attachment.path])
        check("send-09/F1 unconfirmed user row is not silently delivered", engine.transcript(for: unknown).contains {
            $0.role == .user && ($0.status?.contains("沒送到") == true || $0.status?.contains("待確認") == true)
        })
        check("send-09 forced stop leaves one visible record", engine.transcript(for: unknown).filter { $0.text == "已強制停止" }.count == 1)
        check("send-09 forced stop releases engine", !engine.isRunning(unknown) && engine.sidecarProcessID(threadID: unknown) == nil)
        let activeTool = send("tool")
        tool(activeTool)
        engine.stop(threadID: activeTool); engine.stop(threadID: activeTool)
        check("send-09 forced stop closes running tool", engine.transcript(for: activeTool).filter { $0.eventKind == .toolUse }.allSatisfy { $0.status?.hasPrefix("cancelled|") == true })
        let timeout = send("timeout")
        engine.stop(threadID: timeout)
        for _ in 0..<300 {
            if !engine.isRunning(timeout) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        check("send-09 timeout restores unconfirmed turn", !engine.isRunning(timeout) && model.prompt == "timeout" && model.coderDeliveries[timeout] == nil)
        let closed = send("closed")
        tool(closed)
        for _ in 0..<150 {
            if !engine.isRunning(closed) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        check("send-09 closed sidecar closes running tool", !engine.isRunning(closed) && !engine.transcript(for: closed).contains { $0.status?.hasPrefix("running-command") == true })
        let archive = send("archive"); tool(archive)
        var archiveHint: String?
        engine.onHint = { archiveHint = $0 }
        _ = engine.archive(archive)
        check("send-10 running thread stays visible until stopped", engine.threadRecord(archive)?.isArchived == false)
        check("send-10 archive explains pending stop", archiveHint?.contains("停止") == true)
        // The fixture never acknowledges interrupts; the second stop forces it closed.
        engine.stop(threadID: archive)
        engine.stop(threadID: archive)
        check("M19 forced stop completes pending archive without another archive click", !engine.isRunning(archive) && engine.threadRecord(archive)?.isArchived == true)
        check("M19 archived thread is no longer selected in the visible model", model.selectedThreadID != archive && model.selectedThreadID == engine.doc.selectedThreadID)
        let acknowledged = send("sample archive")
        _ = engine.archive(acknowledged)
        check("M19 awaiting stop acknowledgement stays visible and selected", engine.threadRecord(acknowledged)?.isArchived == false && model.selectedThreadID == acknowledged)
        let acknowledgedTurn = engine.transcript(for: acknowledged).last(where: { $0.role == .user })!.turnID!
        engine.handleSDK(acknowledged, ["type": "result", "client_turn_id": acknowledgedTurn, "is_error": false, "result": "sample"])
        check("M19 native terminal acknowledgement completes pending archive", !engine.isRunning(acknowledged) && engine.threadRecord(acknowledged)?.isArchived == true)
        check("M19 native acknowledged archive selects the remaining visible chat", model.selectedThreadID != acknowledged && model.selectedThreadID == engine.doc.selectedThreadID)
        model.engineLoginTestDouble = nil
        model.seedSendLoginStatusForSelfTest(EngineLoginStatus(kind: .codex, isLoggedIn: true, account: nil, detail: "fixture"), checkedAt: Date())
        let login = send("login-error", attachmentPaths: [attachment.path])
        for _ in 0..<150 {
            if !engine.isRunning(login) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        check("send-01 native login failure remains visible with original details", engine.transcript(for: login).contains {
            $0.status == "error|登入" && $0.text.contains("設定 › 登入")
                && $0.engineErrorDetails?.contains("fixture login required") == true
        })
        check("send-01 native login failure restores original draft and attachment", model.prompt == "login-error" && model.droppedPaths == [attachment.path])
        model.engineLoginTestDouble = [.codex]
        let shutdownTool = send("shutdown-tool"); tool(shutdownTool)
        let shutdownPending = send("shutdown-pending")
        engine.shutdownAll()
        check("send-09 shutdown settles unconfirmed delivery", model.prompt == "shutdown-pending" && model.coderDeliveries[shutdownPending] == nil)
        check("send-09 shutdown closes running tool", !engine.transcript(for: shutdownTool).contains { $0.status?.hasPrefix("running-command") == true })
        let restored = engine.store.load()
        check("send-09 stopped tool remains stopped after reload", restored.threads.first(where: { $0.id == activeTool })?.messages.contains { $0.status?.hasPrefix("running-command") == true } == false)
    }
}
#endif
