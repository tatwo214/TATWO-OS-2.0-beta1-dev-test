import Foundation

#if DEBUG
enum SendFlowAcceptance {
    @MainActor static func run() async throws -> Bool {
        var failures = 0
        func check(_ name: String, _ value: Bool) {
            if !value { failures += 1 }
            print("W189SEND \(value ? "PASS" : "FAIL") \(name)")
        }
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TATWO2_LIVE_ROOT"] else { return false }
        let root = URL(fileURLWithPath: path).appendingPathComponent("send-fixture")
        LoginFlowAcceptance.run(root: root.appendingPathComponent("login-fixture"), env: env, check: check)
        UndeliveredFlowAcceptance.run(root: root.appendingPathComponent("draft-fixture"), env: env, check: check)
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: env)
        defer { engine.shutdownAll() }
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root)))
        let thread = engine.newThread(in: nil)
        model.selectedThreadID = thread
        engine.addIssue(threadID: thread, title: "fixture", body: "sample")
        model.refreshIssueLists()
        let entry = engine.issues(threadID: thread, global: false).first!
        let prefix = "sample  text\n```swift\n    let example = 1\n```\n"
        model.prompt = prefix + "@fixture  \n"
        model.pickIssueMention(entry)
        check("send-12/F4 only trailing token removed, formatting preserved", model.prompt == prefix + "  \n")
        for token in ["@fixture", "@"] {
            model.prompt = prefix + token
            model.issueMentionSelectedIndex = nil
            check("send-12 unselected Enter submits \(token)", !model.handleIssueMentionKey(.commit))
            check("send-12 unselected Enter preserves draft", model.prompt == prefix + token)
        }
        model.issueMentionSelectedIndex = 0
        check("send-12 selected Enter picks issue", model.handleIssueMentionKey(.commit))
        try documentRecovery(root: root.appendingPathComponent("document-fixture"), env: env, check: check)
        try await StopFlowAcceptance.run(root: root.appendingPathComponent("stop-fixture"), env: env, check: check)
        await QueuedStopAcceptance.run(check: check)
        try await RestartFlowAcceptance.run(root: root.appendingPathComponent("restart-fixture"), env: env, check: check)
        try await RemoteRejectionAcceptance.run(root: root.appendingPathComponent("rejection-fixture"), env: env, check: check)
        print("W189SEND SUMMARY failures=\(failures)")
        return failures == 0
    }

    @MainActor private static func documentRecovery(root: URL, env: [String: String],
                                                    check: (String, Bool) -> Void) throws {
        let store = ChatLiveStore(root: root)
        var doc = LiveDocumentRecord()
        let entry = TatwoIssueListEntryV1(id: "fixture", title: "fixture", body: "sample",
                                         sourceReference: "fixture", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        var thread = LiveThreadRecord(title: "fixture")
        thread.issues = [entry]
        thread.cliTabs = [LiveCLITabRecord(id: UUID(), engine: "codex", cwd: root.path, title: "fixture")]
        let permissionThread = LiveThreadRecord(title: "sample")
        let otherThread = LiveThreadRecord(title: "example")
        doc.threads = [thread, permissionThread, otherThread]
        doc.selectedThreadID = thread.id
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var object = try JSONSerialization.jsonObject(with: encoder.encode(doc)) as! [String: Any]
        var threads = object["threads"] as! [[String: Any]]
        var badIssue = (threads[0]["issues"] as! [[String: Any]])[0]
        badIssue["status"] = "future-fixture-value"
        threads[0]["issues"] = [badIssue] + (threads[0]["issues"] as! [[String: Any]])
        threads[0]["cliTabs"] = [["id": "bad-fixture-id"]] + (threads[0]["cliTabs"] as! [[String: Any]])
        threads[1]["botPermissionPreset"] = "future-fixture-value"
        threads.insert(["id": 42], at: 0)
        object["threads"] = threads
        let original = try JSONSerialization.data(withJSONObject: object)
        try original.write(to: store.url)
        let restored = store.load()
        check("send-04 corrupt thread skips only that record", restored.threads.map(\.id) == doc.threads.map(\.id))
        check("send-04 corrupt issue skips only that record", restored.threads.first?.issues == [entry])
        check("send-04 corrupt CLI tab skips only that record", restored.threads.first?.cliTabs == thread.cliTabs)
        check("send-04 unknown permission requires approval", restored.threads.first(where: { $0.id == permissionThread.id })?.botPermissionPreset == .askFirst)
        let backup = ChatLiveStore.lastUnreadableBackup
        check("send-04 original backup remains byte identical", backup.flatMap { try? Data(contentsOf: $0) } == original)
        check("send-04 load never rewrites original", try Data(contentsOf: store.url) == original)
        let reopened = ChatLiveEngine(store: store, environment: env)
        check("send-04 good thread survives startup", reopened.threadRecord(otherThread.id)?.title == "example")
        check("send-04 startup explains saved original", reopened.transcript(for: thread.id).contains { $0.status == "error|對話紀錄" })
        reopened.shutdownAll()
        check("send-04 saved recovery survives reload", store.load().threads.contains { $0.id == otherThread.id })
    }
}
#endif
