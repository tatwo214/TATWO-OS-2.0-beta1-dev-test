#if DEBUG
import Foundation

@MainActor enum W351Acceptance {
    private final class RetryPod: FakeTapPod {
        var reads = 0, failures = 1
        override func respond(_ command: [String: Any], id: String, cmd: String) {
            guard cmd == "models" else { return }
            reads += 1
            emit(reads <= failures
                ? ["type": "result", "id": id, "ok": false, "message": "讀不到目前模型送出代號"]
                : ["type": "result", "id": id, "ok": true, "data": ["models": [["slug": "six", "title": "GPT-6"]]]])
        }
    }
    static func models(check: (Bool, String) -> Void) async throws {
        let env = ProcessInfo.processInfo.environment
        let store = ChatLiveStore(root: URL(fileURLWithPath: env["TATWO2_LIVE_ROOT"]!).appendingPathComponent("w351-coder"))
        let engine = ChatLiveEngine(store: store, environment: env, tap: W185FakeConversationTap()); defer { engine.shutdownAll() }
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: store.url.deletingLastPathComponent().appendingPathComponent("bots"))))
        for failures in [1, 9, -1] {
            ChatGPTTapModelCatalog.replace([])
            let pod = RetryPod(running: true); pod.failures = failures == -1 ? 1 : failures
            let tap = ChatGPTTap(transport: pod, connection: .ready)
            var words: [String] = []
            let start = Date()
            let observation = ChatGPTTapModelObservation(tap: tap) {
                words.append(ChatGPTTapModelCatalog.unavailabilityReason(connection: tap.connection) ?? "ready")
            }
            while pod.reads == 0 { try await Task.sleep(for: .milliseconds(10)) }
            model.chatGPTTapConnectionTestDouble = { tap.connection }
            let row = ChatPage(model: model).coderComposerMode().models.first?.options.first { $0.id == "chatgpt-tap:unavailable" }
            let loading = row?.title.contains("讀取中") == true && row?.title.contains("讀不到") == false
            if failures == -1 { tap.sleep() }
            try await Task.sleep(for: .milliseconds(1400))
            if failures == 1 {
                check(loading && pod.reads == 2 && ChatGPTTapModelCatalog.snapshot.first?.id == "six"
                    && Date().timeIntervalSince(start) < 5 && !words.contains(where: { $0.contains("讀不到") }), "W351 retry stays loading then succeeds within five seconds")
            } else if failures == 9 {
                check(loading && pod.reads == 2 && ChatGPTTapModelCatalog.failureReason == "讀不到目前模型送出代號", "W351 retry stops after two failures")
            } else { check(pod.reads == 1, "W351 sleep cancels retry") }
            withExtendedLifetime(observation) { tap.sleep() }
        }
    }
    static func rules(defaults: UserDefaults, check: (Bool, String) -> Void) async throws {
        let rule = "## 4. 角色\n| 審查 | 另一家引擎（GPT 系優先） |\n"
        check(EngineAIUpdate.table(rule, section: "4", role: "審查", model: "gpt-6") == rule, "W351 rule cell stays unchanged")
        let root = TatwoEntry().root, old = "gpt-6.1-sol", new = "gpt-6.2-sol"
        let os = try Data(contentsOf: TatwoEntry().constitution), device = try Data(contentsOf: TatwoEntry().deviceJSON)
        let prior = UltraworkRoleConfigurationStore(defaults: defaults).load(), writer = OSDocuments.secondaryWriter
        defer {
            try? os.write(to: TatwoEntry().constitution); try? device.write(to: TatwoEntry().deviceJSON)
            OSDocuments.secondaryWriter = writer; UltraworkRoleConfigurationStore(defaults: defaults).save(prior)
        }
        func git(_ args: [String]) throws -> String {
            let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", root.path, "-c", "user.name=W351", "-c", "user.email=fixture@localhost"] + args
            p.environment = ProcessInfo.processInfo.environment; p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init"]); _ = try git(["add", "os.md"]); _ = try git(["commit", "-m", "fixture base"])
        try Data("unrelated".utf8).write(to: root.appendingPathComponent("unrelated.txt")); _ = try git(["add", "unrelated.txt"])
        let update = EngineAIUpdate(defaults: defaults), proposal = EngineAIUpdate.Proposal(id: 0, old: old, suggested: new)
        UltraworkRoleConfigurationStore(defaults: defaults).save(.init(primaryModelID: old, auxiliaryModelIDs: []))
        try await update.decide(proposal, accept: true)
        check(try git(["show", "--format=", "--name-only", "HEAD"]) == "os.md" && git(["diff", "--cached", "--name-only"]) == "unrelated.txt", "W351 document writer commits only os")
        try os.write(to: TatwoEntry().constitution)
        try Data("{\"role\":\"secondary\"}".utf8).write(to: TatwoEntry().deviceJSON)
        UltraworkRoleConfigurationStore(defaults: defaults).save(.init(primaryModelID: old, auxiliaryModelIDs: []))
        var queued = false
        OSDocuments.secondaryWriter = { id, text, base in queued = id == "os" && text.contains(new) && !base.contains(new); return .secondary }
        try await update.decide(proposal, accept: true)
        check(queued && UltraworkRoleConfigurationStore(defaults: defaults).load().primaryModelID == old
            && update.message == "已交主設備核准角色", "W351 secondary queues approval without changing local roles")
    }
}
#endif
