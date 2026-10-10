#if DEBUG
import Foundation
import SwiftUI
import AppKit
import Darwin

/// `w185tap`：假的 ConversationTap，沒有 Pod、網路或引擎程序。
@MainActor
enum ChatGPTTapAcceptance {
    /// 真正走 ChatGPTTap 的排隊、完成與停止回執，不啟動 CEF 或連外。
    private static func visibilityChecks(_ check: (Bool, String) -> Void) {
        let webFlag = UserDefaults.standard.object(forKey: ChatGPTWebSpace.enabledKey)
        UserDefaults.standard.set(false, forKey: ChatGPTWebSpace.enabledKey)
        defer { UserDefaults.standard.set(webFlag, forKey: ChatGPTWebSpace.enabledKey) }
        let pod = VisibilityPod(running: true)
        for visible in [false, true] {
            for active in [false, true] {
                for presented in [false, true] {
                    check(TapWebPod.shouldHide(spaceVisible: visible, workActive: active, pagePresented: presented) == !(visible || active || presented),
                          "A1 native visibility matrix Space=\(visible) turn=\(active) page=\(presented)")
                }
            }
        }
        let tap = ChatGPTTap(transport: pod)
        tap.setSpaceVisible(false)
        let lease = tap.acquireLease()
        check(pod.hidden, "A1 invisible idle DM lease must not keep the renderer visible")
        let first = tap.send(requestID: "visible-first", text: "fixture", conversationID: nil)
        check(!pod.hidden && pod.visibleAtDispatch.last == true, "A1 background turn wakes before send dispatch")
        tap.setSpaceVisible(true)
        tap.setSpaceVisible(false)
        check(!pod.hidden, "A1 hiding Space during a turn keeps renderer visible")
        let second = tap.send(requestID: "visible-second", text: "fixture", conversationID: nil)
        pod.emit(["type": "stream", "id": "visible-first", "kind": "finished"])
        check(!pod.hidden && pod.visibleAtDispatch.last == true, "A1 first turn finishing keeps queued turn awake")
        tap.stop(requestID: "visible-second")
        check(!pod.hidden, "A1 stopping keeps renderer awake until acknowledgement")
        if let stopID = pod.stopID { pod.emit(["type": "result", "id": stopID, "ok": true]) }
        check(pod.hidden, "A1 stop acknowledgement hides idle renderer even with DM lease")
        tap.setSpaceVisible(true)
        let third = tap.send(requestID: "visible-third", text: "fixture", conversationID: nil)
        pod.emit(["type": "stream", "id": "visible-third", "kind": "finished"])
        check(!pod.hidden, "A1 turn finishing while Space visible keeps renderer visible")
        tap.setSpaceVisible(false)
        check(pod.hidden, "A1 hiding idle Space immediately hides renderer")
        let fourth = tap.send(requestID: "visible-failed", text: "fixture", conversationID: nil)
        pod.emit(["type": "stream", "id": "visible-failed", "kind": "failed", "submitted": false, "message": "fixture"])
        check(pod.hidden, "A1 failed send returns invisible renderer to hidden")
        if let voice = tap.claimVoice(owner: UUID()) {
            check(!pod.hidden, "A1 voice wakes renderer before its first command")
            tap.releaseVoice(voice)
            check(pod.hidden, "A1 confirmed voice end hides invisible idle renderer")
        } else { check(false, "A1 voice fixture can claim idle Pod") }
        tap.releaseLease(lease)
        tap.sleep()
        withExtendedLifetime([first, second, third, fourth]) {}
    }

    private static func w318CoderChecks(_ check: (Bool, String) -> Void, root: URL, environment: [String: String]) async throws {
        let tap = W185FakeConversationTap()
        let previous = ChatGPTTapModelCatalog.snapshot
        ChatGPTTapModelCatalog.replace(try await tap.models().items)
        defer { ChatGPTTapModelCatalog.replace(previous) }
        let folder = root.appendingPathComponent("w318-live")
        let engine = ChatLiveEngine(store: ChatLiveStore(root: folder), environment: environment, tap: tap)
        defer { engine.shutdownAll() }
        let id = engine.newThread(in: nil)
        let route = ChatGPTTapModelCatalog.routeID("fixture-model")
        check(engine.send(threadID: id, text: "W318 first", model: route, engine: .codex), "W318 Coder starts renderer turn")
        try await wait { tap.sent.count == 1 }
        tap.emit(.conversation(id: "w318-conversation"))
        tap.emit(.text(messageID: "page", full: "page snapshot"))
        let full = "第一節\n第二節\n第三節\n第四節\n第五節\n伺服器完整結尾\nEND-W318-SERVER"
        tap.emit(.text(messageID: "server-answer", full: full))
        tap.finish()
        try await wait { !engine.isRunning(id) }
        let saved = ChatLiveStore(root: folder).load().threads.first { $0.id == id }?.messages.last
        check(saved?.text == full && saved?.status == "done", "W318 server full text survives Coder store reopen")
        check(engine.send(threadID: id, text: "W318 stop", model: route, engine: .codex), "W318 second turn starts")
        try await wait { tap.sent.count == 2 }
        engine.stop(threadID: id)
        try await wait { !engine.isRunning(id) }
        check(!engine.tapSelfTestHasRunner(id) && engine.transcript(for: id).last?.status == "cancelled|已停止", "W318 stop clears Coder runner and running state")
        check(engine.send(threadID: id, text: "END-W318-S2", model: route, engine: .codex), "W318 same thread accepts sentence after stop")
        try await wait { tap.sent.count == 3 }
        check(tap.sent[2].conversationID == "w318-conversation" && tap.sent[2].text.hasSuffix("END-W318-S2"), "W318 next sentence reaches same server conversation")
        tap.emit(.notSubmitted("W318 送出鍵不可用，沒有送出"))
        try await wait { !engine.isRunning(id) }
        check(engine.tapTurn[id]?.failure?.message == "W318 送出鍵不可用，沒有送出"
              && engine.transcript(for: id).last?.status == "error|沒有送出", "W318 failed follow-up displays Coder error")
    }

    private final class VisibilityPod: FakeTapPod {
        var visibleAtDispatch: [Bool] = []
        var stopID: String?
        override func respond(_ command: [String: Any], id: String, cmd: String) {
            visibleAtDispatch.append(!hidden)
            if cmd == "stop" { stopID = id }
        }
    }

    static func run() async throws -> Bool {
        var passed = 0
        var failed = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("W185TAP \(condition ? "PASS" : "FAIL") \(label)")
        }
        defer { print("W185TAP SUMMARY failures=\(failed) passed=\(passed)") }
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let live = env["TATWO2_LIVE_ROOT"] else {
            check(false, "requires fully isolated staging")
            return false
        }
        let root = URL(fileURLWithPath: live).appendingPathComponent("w185-\(UUID().uuidString)")
        try await W222Acceptance.archiveChecks(root: root.appendingPathComponent("w222-archive"), environment: env, check: check)
        try await W222Acceptance.restoreChecks(root: root.appendingPathComponent("w222-restore"), environment: env, check: check)
        try await W222Acceptance.sharedFolderChecks(root: root.appendingPathComponent("w222-shared"), environment: env, check: check)
        try await W222Acceptance.lifecycleChecks(root: root.appendingPathComponent("w222-lifecycle"), environment: env, check: check)
        visibilityChecks(check)
        try await W196MappingAcceptance.run(check)
        try await W194FixAcceptance.run(check)
        try await W195WakeAcceptance.run(check)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await w203CoderChecks(check, root: root, environment: env)
        try await w318CoderChecks(check, root: root, environment: env)
        let tap = W185FakeConversationTap()
        let catalog = try await tap.models()
        let previousCatalog = ChatGPTTapModelCatalog.snapshot
        ChatGPTTapModelCatalog.replace(catalog.items)
        defer { ChatGPTTapModelCatalog.replace(previousCatalog) }
        let route = ChatGPTTapModelCatalog.routeID("fixture-model")
        let choice = ChatRouteChoice.resolve(route)
        let sections = ChatRouteChoice.brandSections(selectedID: route)
        let order = sections.map(\.brand)
        check(order.firstIndex(of: .chatgptTap) == order.firstIndex(of: .openAI).map { $0 + 1 },
              "ChatGPT（TAP） group immediately after OpenAI")
        check(choice.commandLabel == "ChatGPT / Fixture" && choice.tapEfforts == catalog.items[0].efforts
              && choice.allowedEfforts.isEmpty && choice.allowedSpeedTiers.isEmpty, "TAP model/effort identity; no Codex controls")
        ChatGPTTapModelCatalog.replace([])
        check(ChatGPTTapModelCatalog.choices.count == 1 && !ChatGPTTapModelCatalog.choices[0].isAvailable
              && ChatGPTTapModelCatalog.choices[0].title == "打開後選擇模型", "unavailable placeholder data")
        check(ChatRouteChoice.resolve(route).runtimeAdapter == .chatgptTap, "sleeping TAP never resolves to Codex")
        ChatGPTTapModelCatalog.replace(catalog.items)

        // W221b: reject managed TAP before constructing a runner or calling any ChatGPT method.
        for mode in ["explicit", "stored", "direct"] {
            let managedTap = W185FakeConversationTap()
            let managed = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("managed-" + mode)), environment: env, tap: managedTap)
            let id = managed.newThread(in: nil)
            managed.markControllerThread(id, fingerprint: "synthetic-controller")
            managed.setRequestedModel(route, threadID: id)
            let accepted = mode == "direct" ? managed.tapSelfTestSendDirect(id, route: route)
                : managed.send(threadID: id, text: "synthetic", model: mode == "stored" ? nil : route, engine: .codex)
            check(!accepted, "W221b managed-\(mode)-rejected")
            check(!managed.tapSelfTestHasRunner(id) && !managed.isRunning(id) && managed.tapTurn[id] == nil,
                  "W221b managed-\(mode)-no-runner-or-turn")
            try await Task.sleep(for: .milliseconds(30))
            check(managedTap.requestCalls == 0 && managedTap.sent.isEmpty && managedTap.createdNames.isEmpty && managedTap.modelCalls == 0 && managedTap.folders.isEmpty,
                  "W221b managed-\(mode)-zero-ChatGPT-requests")
            check(managed.transcript(for: id).count == 1 && managed.transcript(for: id).first?.role == .system
                  && managed.transcript(for: id).first?.text == "受管對話不能使用 ChatGPT TAP，因為它會使用這台的私人 ChatGPT 帳號與記憶。",
                  "W221b managed-\(mode)-one-inline-reason")
            managed.shutdownAll()
        }

        let store = ChatLiveStore(root: root.appendingPathComponent("live"))
        let engine = ChatLiveEngine(store: store, environment: env, tap: tap)
        defer { engine.shutdownAll() }
        let projectFolder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        let project = engine.newProject(name: "Fixture", workdir: projectFolder.path)
        let thread = engine.newThread(in: project)
        var delivery: LiveSendDelivery?
        check(engine.send(threadID: thread, text: "first message", model: route, engine: .codex,
                          systemPrompt: nil, attachments: [], reasoningEffort: "tap-heavy", serviceTier: nil,
                          ultrawork: nil, delivery: { delivery = $0 }), "send accepted into TAP runner")
        try await wait { tap.sent.count == 1 }
        check(engine.isRunning(thread) && engine.sidecarProcessID(threadID: thread) == nil
              && engine.sidecarProcessOwners().isEmpty, "running/Island source without a sidecar")
        let first = tap.sent[0]
        check(first.gizmoID == tap.folders.first?.id && first.conversationID == nil
              && first.model == "fixture-model" && first.effort == "tap-heavy", "first round has project and TAP effort")
        check(first.text.hasPrefix("你在 TATWO OS 的 Coder 裡被當作模型使用")
              && first.text.contains("project_id=\(project.uuidString)") && first.text.hasSuffix("first message"),
              "hidden first preamble uses stable OS project ID")
        check(engine.transcript(for: thread).first?.text == "first message", "Coder user bubble excludes hidden preamble")
        tap.emit(.conversation(id: "conversation-1"))
        tap.emit(.text(messageID: "answer-1", full: "one"))
        try await wait { engine.transcript(for: thread).last?.text == "one" }
        let replyID = engine.transcript(for: thread).last?.id
        tap.emit(.text(messageID: "answer-1", full: "one two"))
        try await wait { engine.transcript(for: thread).last?.text == "one two" }
        check(engine.transcript(for: thread).last?.id == replyID && engine.transcript(for: thread).count == 2,
              "full text replaces the same assistant row")
        let pageFull = "有必修\n\n" + (1...5).map { "必修 \($0)｜完整正文" }.joined(separator: "\n")
            + "\n建議 1\n建議 2\n建議 3\n結論：全文保存"
        tap.emit(.text(messageID: "page", full: pageFull))
        tap.finish()
        try await wait { !engine.isRunning(thread) }
        check(delivery == .delivered && engine.transcript(for: thread).last?.status == "done", "finished releases running state")
        let savedReply = ChatLiveStore(root: root.appendingPathComponent("live")).load().threads.first(where: { $0.id == thread })?.messages.last
        check(savedReply?.text == pageFull && savedReply?.status == "done" && engine.transcript(for: thread).last?.id == replyID,
              "W302 final page text replaces partial stream and survives document reopen")
        let unfinished = ChatGPTTurnFailure(message: "ChatGPT 回答逾時，這句未完成", reason: "timeout", draft: "fixture")
        check(unfinished.storedStatus == "error|未完成" && ChatGPTTurnFailure.restored(status: unfinished.storedStatus, draft: "fixture")?.category == "未完成",
              "W302 timeout persists and reopens as unfinished")
        let file = TapProjectMapStore.mapFile(at: projectFolder)
        let map = try JSONDecoder().decode(TapProjectMap.self, from: Data(contentsOf: file))
        let fileMode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        let directoryMode = (try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue
        let data = try Data(contentsOf: file)
        check(map.threads[thread.uuidString] == "conversation-1" && fileMode == 0o600 && directoryMode == 0o700
              && !String(decoding: data, as: UTF8.self).contains("first message"), "ID-only map atomically saved 0600 / folder 0700")
        let keys = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        check(Set(keys?.keys.map { $0 } ?? []) == Set(["chatgpt_project_id", "name", "threads", "updated_at"]), "metadata only schema")
        let created = tap.createdNames.count

        let codex = ChatMessage(role: .assistant, text: "updated the files", status: "done",
                                modelID: "gpt-6.1-sol", runtimeAdapterID: "codex-exec")
        let claude = ChatMessage(role: .assistant, text: "reviewed the diff", status: "done",
                                 modelID: "fable-5.1", runtimeAdapterID: "claude-cli-native")
        _ = engine.appendOfflineRows(threadID: thread, rows: [codex, claude])
        check(engine.send(threadID: thread, text: "second message", model: route, engine: .codex), "second send accepted")
        try await wait { tap.sent.count == 2 }
        check(tap.createdNames.count == created && tap.sent[1].conversationID == "conversation-1"
              && tap.sent[1].gizmoID == map.chatgpt_project_id, "second round reuses project and conversation ID")
        check(!tap.sent[1].text.contains("你在 TATWO OS 的 Coder") &&
              tap.sent[1].text.hasPrefix("〔TATWO：這中間 Codex 說：updated the files；Claude 說：reviewed the diff〕"),
              "only intervening engine turns summarized; preamble once")
        engine.stop(threadID: thread)
        try await wait { !engine.isRunning(thread) }
        check(tap.stopped == [tap.sent[1].requestID] && engine.transcript(for: thread).last(where: { $0.role == .assistant })?.status == "cancelled|已停止",
              "stop targets this request ID; no other send stopped")
        let many = (0..<12).map { _ in
            ChatMessage(role: .assistant, text: String(repeating: "中", count: 2_000), modelID: "gpt-6.1-sol")
        }
        let summary = ChatGPTTapTurnRunner.collaborationSummary(many)
        check(summary != nil && summary!.count <= 1_500 && summary!.contains("已截斷"), "summary bounded to 1500 characters")
        let onlyTap = [ChatMessage(role: .user, text: "prior", runtimeAdapterID: "chatgpt-tap"),
                       ChatMessage(role: .assistant, text: "prior reply", runtimeAdapterID: "chatgpt-tap")]
        check(ChatGPTTapTurnRunner.collaborationSummary(onlyTap) == nil, "ChatGPT-only rounds add no collaboration summary")
        let sourceRoot = root.appendingPathComponent("source-fixture")
        let sourceStore = ChatLiveStore(root: sourceRoot)
        let sourceThread = LiveThreadRecord(title: "fixture", messages: onlyTap.map(LiveMessageRecord.init))
        sourceStore.save(LiveDocumentRecord(threads: [sourceThread]))
        let sourceRows = ChatLiveStore(root: sourceRoot).load().threads.first?.messages.map(\.chatMessage) ?? []
        check(sourceRows.map(\.runtimeAdapterID) == onlyTap.map(\.runtimeAdapterID), "M6 TAP source survives save and reopen")
        check(ChatGPTTapTurnRunner.collaborationSummary(sourceRows) == nil, "M6 reopened TAP replies never become another model's summary")
        let recordEncoder = JSONEncoder(); recordEncoder.dateEncodingStrategy = .iso8601
        let recordDecoder = JSONDecoder(); recordDecoder.dateDecodingStrategy = .iso8601
        let native = ChatMessage(role: .assistant, text: "sample", modelID: "gpt-6.1-sol", runtimeAdapterID: "codex-exec")
        var legacyObject = try JSONSerialization.jsonObject(with: recordEncoder.encode(LiveMessageRecord(native))) as! [String: Any]
        legacyObject.removeValue(forKey: "runtimeAdapterID")
        let legacyRecord = try recordDecoder.decode(LiveMessageRecord.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        check(legacyRecord.chatMessage.runtimeAdapterID == nil && legacyRecord.chatMessage.text == "sample", "M6 old files without source remain readable without guessing native adapters")
        legacyObject["modelID"] = route
        let legacyTap = try recordDecoder.decode(LiveMessageRecord.self, from: JSONSerialization.data(withJSONObject: legacyObject)).chatMessage
        check(legacyTap.runtimeAdapterID == TatwoChatRuntimeAdapter.chatgptTap.rawValue
              && ChatGPTTapTurnRunner.collaborationSummary([legacyTap]) == nil, "M6 explicit legacy TAP model prefix remains a TAP reply")


        let independent = engine.newThread(in: nil)
        check(engine.send(threadID: independent, text: "inbox", model: route, engine: .codex), "independent thread send accepted")
        try await wait { tap.sent.count == 3 }
        check(tap.folders.contains { $0.id == tap.sent[2].gizmoID && $0.title == "TATWO · 收件匣" }, "general/unbound OS thread goes to inbox project")
        tap.emit(.conversation(id: "inbox-1"))
        tap.finish()
        try await wait { !engine.isRunning(independent) }

        let failedFolder = root.appendingPathComponent("failed-project")
        try FileManager.default.createDirectory(at: failedFolder, withIntermediateDirectories: true)
        let failedProject = engine.newProject(name: "test", workdir: failedFolder.path)
        tap.failNames.insert("TATWO · test")
        let failedThread = engine.newThread(in: failedProject)
        check(engine.send(threadID: failedThread, text: "fallback", model: route, engine: .codex), "failed project preparation handled asynchronously")
        try await wait { !engine.isRunning(failedThread) }
        check(tap.sent.count == 3 && engine.tapTurn[failedThread]?.failure?.message.contains("quota fixture") == true
              && engine.transcript(for: failedThread).last?.status == "error|沒有送出"
              && !engine.transcript(for: failedThread).contains { $0.text.contains("quota fixture") },
              "W203 project preparation failure stays transient; storage has unsent category without inbox reroute")
        check(tap.sent.allSatisfy { $0.gizmoID?.hasPrefix("g-p-") == true }, "never sends to general ChatGPT chat")

        // 兩種終態嚴格分開：notSubmitted 可以回草稿，failed 絕不能回草稿。
        delivery = nil
        check(engine.send(threadID: thread, text: "not sent", model: route, engine: .codex, systemPrompt: nil,
                          attachments: [], reasoningEffort: nil, serviceTier: nil, ultrawork: nil, delivery: { delivery = $0 }), "notSubmitted fixture starts")
        try await wait { tap.sent.count == 4 }
        tap.emit(.notSubmitted("not submitted fixture"))
        try await wait { !engine.isRunning(thread) }
        check(delivery == .notDelivered("not submitted fixture"), "notSubmitted returns draft")
        delivery = nil
        check(engine.send(threadID: thread, text: "unknown result", model: route, engine: .codex, systemPrompt: nil,
                          attachments: [], reasoningEffort: nil, serviceTier: nil, ultrawork: nil, delivery: { delivery = $0 }), "failed fixture starts")
        try await wait { tap.sent.count == 5 }
        tap.emit(.progress(title: "合成進度標題", server: false))
        try await wait { engine.tapTurn[thread]?.thinking?.title == "合成進度標題" }
        check(engine.tapTurn[thread]?.thinking != nil, "W200 Coder displays transient progress heading")
        tap.emit(.text(messageID: "fixture", full: "合成回答"))
        try await wait { engine.tapTurn[thread]?.thoughtSeconds != nil }
        tap.emit(.progress(title: "late heading", server: false))
        try await Task.sleep(for: .milliseconds(20))
        check(engine.tapTurn[thread]?.thinking == nil, "W200 Coder answer collapses thought duration; late heading cannot restart thinking")
        let partialDuration = engine.tapTurn[thread]?.thoughtSeconds
        tap.emit(.failed("network fixture", reason: "fixture_error"))
        try await wait { !engine.isRunning(thread) }
        check(delivery == .delivered && engine.tapTurn[thread]?.failure?.message == "network fixture"
              && engine.tapTurn[thread]?.failure?.draft == "unknown result" && engine.tapTurn[thread]?.thinking == nil,
              "failed displays local error without draft return")
        check(engine.tapTurn[thread]?.thoughtSeconds == partialDuration && partialDuration != nil,
              "W207 partial-answer failure retains thought duration alongside recovery")
        let failureDocument = String(decoding: try recordEncoder.encode(engine.doc), as: UTF8.self)
        check(!failureDocument.contains("network fixture") && !engine.transcript(for: thread).contains { $0.text == "network fixture" },
              "W200 provider error never enters persisted transcript or memory")

        // 對應的專案消失／換帳號，不能把舊 conversationID 帶去新帳號或收件匣。
        tap.folders.removeAll { $0.id == map.chatgpt_project_id }
        check(engine.send(threadID: thread, text: "missing project", model: route, engine: .codex), "missing mapped project fixture starts")
        try await wait { tap.sent.count == 6 }
        check(tap.sent[5].gizmoID == tap.sent[2].gizmoID && tap.sent[5].conversationID == nil &&
              tap.sent[5].text.contains("你在 TATWO OS 的 Coder"), "missing project uses a new inbox conversation, never old project conversation")
        tap.emit(.conversation(id: "fallback-main"))
        tap.finish()
        try await wait { !engine.isRunning(thread) }
        tap.folders.removeAll { $0.title == "TATWO · 收件匣" }
        let before = tap.sent.count
        delivery = nil
        check(engine.send(threadID: independent, text: "no inbox", model: route, engine: .codex, systemPrompt: nil,
                          attachments: [], reasoningEffort: nil, serviceTier: nil, ultrawork: nil, delivery: { delivery = $0 }),
              "missing inbox fixture starts")
        try await wait { !engine.isRunning(independent) }
        if case .notDelivered = delivery { check(true, "inbox failure returns draft without sending") }
        else { check(false, "inbox failure returns draft without sending") }
        check(tap.sent.count == before, "inbox failure has no general-chat fallback")

        let redirected = try await TapProjectMapStore.shared.load(at: projectFolder)!
        let reopenedTap = W185FakeConversationTap()
        reopenedTap.folders = [TapFolder(id: redirected.chatgpt_project_id, title: redirected.name, kind: .project,
                                        description: "fixture 00000000")]
        reopenedTap.seedConversation("fallback-main", in: redirected.chatgpt_project_id)
        let restoredStore = ChatLiveStore(root: root.appendingPathComponent("restored-live"))
        restoredStore.save(engine.doc)
        let restored = ChatLiveEngine(store: restoredStore, environment: env, tap: reopenedTap)
        defer { restored.shutdownAll() }
        check(restored.send(threadID: thread, text: "after restart", model: route, engine: .codex), "restored thread accepts TAP send")
        try await wait { reopenedTap.sent.count == 1 }
        check(reopenedTap.sent[0].conversationID == "fallback-main"
              && !reopenedTap.sent[0].text.contains("你在 TATWO OS 的 Coder"), "conversation map and first-preamble marker survive engine restart")
        reopenedTap.finish()
        try await wait { !restored.isRunning(thread) }
        check(restored.send(threadID: thread, text: "sample archive", model: route, engine: .codex), "M19 TAP archive fixture accepts a turn")
        try await wait { reopenedTap.sent.count == 2 }
        _ = restored.archive(thread)
        check(restored.threadRecord(thread)?.isArchived == false, "M19 TAP awaiting stop confirmation stays visible")
        try await wait { !restored.isRunning(thread) }
        check(restored.threadRecord(thread)?.isArchived == true, "M19 TAP stop confirmation completes pending archive automatically")

        let mapStore = TapProjectMapStore()
        let otherThread = UUID()
        async let saveOne: Void = mapStore.save(map, at: projectFolder, threadID: thread, conversationID: "conversation-1")
        async let saveTwo: Void = mapStore.save(map, at: projectFolder, threadID: otherThread, conversationID: "conversation-2")
        _ = try await (saveOne, saveTwo)
        let merged = try await mapStore.load(at: projectFolder)
        check(merged?.threads[thread.uuidString] == "conversation-1" && merged?.threads[otherThread.uuidString] == "conversation-2",
              "concurrent metadata updates keep both thread mappings")
        try await runGateChecks(root: root.appendingPathComponent("gates"), check: check)
        try await runUIChecks(root: root.appendingPathComponent("ui"), environment: env, check: check)
        return failed == 0
    }

    private static func runGateChecks(root: URL, check: (Bool, String) -> Void) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tap = W185FakeConversationTap()
        let catalog = try await tap.models()
        ChatGPTTapModelCatalog.replace(catalog.items)
        let mapper = TapProjectMapper(tap: tap, inboxFolder: root.appendingPathComponent("inbox"))
        let runner = ChatGPTTapTurnRunner(tap: tap, mapper: mapper)
        var completed = false, failed = false
        runner.start(threadID: UUID(), project: nil, title: "fixture", text: "fixture stop", routeID: ChatGPTTapModelCatalog.routeID("fixture-model"),
                     effort: nil, attachmentPaths: [], history: [], notice: { _ in }, event: {
            if case .finished = $0 { completed = true }
            if case .failed = $0 { failed = true }
        })
        try await wait { tap.sent.count == 1 }
        runner.stop() // 真 TAP 在 stop 只 finish 串流，沒有 .finished 事件。
        try await wait { completed || failed }
        check(completed && !failed, "F2-7 stream closes without terminal event on stop: cancelled, never failed")

        let file = root.appendingPathComponent("fixture.txt")
        try Data("fixture".utf8).write(to: file)
        let admitted = try await ChatGPTTapTurnRunner.loadAttachments([file.path])
        check(admitted.first?.data == Data("fixture".utf8), "F2-8 regular bounded attachment admitted")
        let link = root.appendingPathComponent("link.txt"), fifo = root.appendingPathComponent("fifo.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        guard mkfifo(fifo.path, 0o600) == 0 else { throw TapError.remote("fixture FIFO creation failed") }
        let big = root.appendingPathComponent("large.txt")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(ChatGPTSpaceModel.attachmentLimit + 1)); try handle.close()
        for url in [link, fifo, root, big] {
            do {
                _ = try await ChatGPTTapTurnRunner.loadAttachments([url.path])
                check(false, "F2-8 refuses symlink/FIFO/directory/oversize: \(url.lastPathComponent)")
            } catch {
                check(error.localizedDescription.contains("20 MB"), "F2-8 refuses symlink/FIFO/directory/oversize: \(url.lastPathComponent)")
            }
        }
        let part = root.appendingPathComponent("part.txt")
        FileManager.default.createFile(atPath: part.path, contents: nil)
        let partHandle = try FileHandle(forWritingTo: part)
        try partHandle.truncate(atOffset: 11 * 1024 * 1024); try partHandle.close()
        do {
            _ = try await ChatGPTTapTurnRunner.loadAttachments([part.path, part.path])
            check(false, "F2-8 aggregate attachment limit rejects two individually valid files")
        } catch { check(error.localizedDescription.contains("附件合計超過 20 MB"), "F2-8 aggregate attachment limit rejects two individually valid files") }
        do {
            _ = try await ChatGPTTapTurnRunner.loadAttachments([file.path], timeout: 0.01, reader: { _, _ in
                Thread.sleep(forTimeInterval: 0.1); return Data()
            })
            check(false, "F2-8 stalled reader times out before send")
        } catch { check(error.localizedDescription.contains("逾時"), "F2-8 stalled reader times out before send") }

        let secret = "sk" + "-" + String(repeating: "A", count: 24)
        let history = [ChatMessage(role: .assistant, text: String(repeating: "x", count: 390) + " " + secret,
                                   modelID: "gpt-6.1-sol", runtimeAdapterID: "codex-exec")]
        let summary = ChatGPTTapTurnRunner.collaborationSummary(history) ?? ""
        check(!summary.contains(secret) && !summary.contains(String(secret.prefix(9)))
              && ChatGPTTapTurnRunner.collaborationNotice(history) == "已附上前面 1 則其他模型的摘要（已遮敏）",
              "F2-9 summary redacts complete secrets before truncation and reports count")
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")), tap: tap)
        defer { engine.shutdownAll() }
        let thread = engine.newThread(in: nil)
        _ = engine.appendOfflineRows(threadID: thread, rows: history)
        check(engine.send(threadID: thread, text: "fixture notice", model: ChatGPTTapModelCatalog.routeID("fixture-model"), engine: .codex), "F2-9 notice send accepted")
        try await wait { tap.sent.count == 2 }
        check(engine.transcript(for: thread).contains { $0.role == .system && $0.text == "已附上前面 1 則其他模型的摘要（已遮敏）" },
              "F2-9 user-visible system notice in actual transcript")
        tap.finish(); try await wait { !engine.isRunning(thread) }

        let project = TapProjectContext(id: UUID(), name: "fixture", folder: root)
        let id = UUID()
        let initial = try await mapper.destination(project: project, threadID: id)
        try await mapper.record("fixture-conversation", threadID: id, destination: initial)
        tap.seedConversation("fixture-conversation", in: initial.map.chatgpt_project_id)
        let saved = try await mapper.storage.load(at: root)
        for projectError in [true, false] {
            tap.projectFailure = projectError; tap.conversationFailure = !projectError
            do { _ = try await mapper.destination(project: project, threadID: id); check(false, "F2-10 transient lookup propagates") }
            catch { check(true, "F2-10 transient lookup propagates") }
            let after = try await mapper.storage.load(at: root)
            check(saved == after && tap.createdNames.count == 2, "F2-10 transient lookup does not change map or create inbox")
        }
        tap.projectFailure = false; tap.conversationFailure = false
        // 確定對話不存在，只修該串的 ID，仍在原 ChatGPT 專案。
        let missingID = UUID()
        try await mapper.record("missing-conversation", threadID: missingID, destination: initial)
        let missing = try await mapper.destination(project: project, threadID: missingID)
        let repaired = try await mapper.storage.load(at: root)
        check(missing.conversationID == nil && missing.map.chatgpt_project_id == initial.map.chatgpt_project_id
              && repaired?.threads[id.uuidString] == "fixture-conversation" && repaired?.threads[missingID.uuidString] == nil,
              "F2-10 missing conversation repairs only that thread in original project")
        tap.folders.removeAll { $0.id == initial.map.chatgpt_project_id }
        let fallback = try await mapper.destination(project: project, threadID: id)
        try await mapper.record("fixture-inbox-conversation", threadID: id, destination: fallback)
        tap.seedConversation("fixture-inbox-conversation", in: fallback.map.chatgpt_project_id)
        let next = try await mapper.destination(project: project, threadID: id)
        check(next.map.chatgpt_project_id == fallback.map.chatgpt_project_id && next.conversationID == "fixture-inbox-conversation",
              "F2-10 missing project persists inbox remap and reuses next conversation")

        let namedFolder = root.appendingPathComponent("named-inbox-project")
        try FileManager.default.createDirectory(at: namedFolder, withIntermediateDirectories: true)
        let namedProject = TapProjectContext(id: UUID(), name: "收件匣", folder: namedFolder)
        let namedThread = UUID()
        let named = try await mapper.destination(project: namedProject, threadID: namedThread)
        let reusedNamed = try await mapper.destination(project: namedProject, threadID: namedThread)
        check(named.map.chatgpt_project_id == reusedNamed.map.chatgpt_project_id,
              "F2-10 ordinary project named inbox still validates its own project identity")

        let calls = tap.modelCalls
        ChatGPTTapModelCatalog.replace(catalog.items, fetchedAt: Date().addingTimeInterval(-301))
        try await ChatGPTTapModelCatalog.refreshForSend(tap: tap)
        try await ChatGPTTapModelCatalog.refreshForSend(tap: tap)
        check(ChatGPTTapModelCatalog.isFresh && tap.modelCalls == calls + 1, "F2-11 stale catalog refreshes once; fresh send needs no extra lookup")
        tap.modelFailure = true
        ChatGPTTapModelCatalog.replace(catalog.items, fetchedAt: Date().addingTimeInterval(-301))
        do { try await ChatGPTTapModelCatalog.refreshForSend(tap: tap); check(false, "F2-11 refresh failure explains not sent") }
        catch { check(error.localizedDescription.contains("重新整理失敗") && error.localizedDescription.contains("503"), "F2-11 refresh failure explains not sent") }
        ChatGPTTapModelCatalog.replace(catalog.items)

        let index = "## Private skills\n- user: hidden fixture\n## test — 私人段落\n- demo: hidden fixture\n## public index\n- fixture: public fixture\n"
        check(HandsSkillet.parse(index).map(\.name) == ["fixture"], "F2-12 private headings suppress index-shaped body entries")
        let skilletFile = root.appendingPathComponent("skillet.md")
        try index.write(to: skilletFile, atomically: true, encoding: .utf8)
        let paths = HandsPaths(root: root.appendingPathComponent("hands"))
        var runtime = HandsRuntime.current(paths: paths)
        runtime.environment["TATWO2_SKILLET_PATH"] = skilletFile.path
        let service = HandsService(paths: paths, runtime: runtime)
        for name in ["user", "demo", "test"] {
            do { _ = try HandsSkillet.read(name: name, service: service); check(false, "F2-12 private section skill cannot be read") }
            catch { check(String(describing: error) == "skillet_not_listed", "F2-12 private section skill cannot be read") }
        }
        let legacyFolder = root.appendingPathComponent("legacy-project")
        let legacyDirectory = legacyFolder.appendingPathComponent(".tatwo")
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacyFile = legacyDirectory.appendingPathComponent("tap-map.json")
        let legacyID = UUID()
        let legacyMap = TapProjectMap(chatgpt_project_id: "g-p-legacy-fixture", name: "TATWO · fixture",
                                      threads: [legacyID.uuidString: "legacy-conversation"])
        try JSONEncoder().encode(legacyMap).write(to: legacyFile)
        let migrated = try await mapper.storage.load(at: legacyFolder)
        let migratedAgain = try await mapper.storage.load(at: legacyFolder)
        check(migrated?.threads[legacyID.uuidString] == "legacy-conversation"
              && migratedAgain?.threads == legacyMap.threads
              && !FileManager.default.fileExists(atPath: legacyFile.path),
              "F2-13 legacy map migrates out of project git without losing conversation IDs")
        let unreadableFolder = root.appendingPathComponent("unreadable-legacy-project")
        let unreadableDirectory = unreadableFolder.appendingPathComponent(".tatwo")
        try FileManager.default.createDirectory(at: unreadableDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(legacyMap).write(to: unreadableDirectory.appendingPathComponent("tap-map.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableDirectory.path)
        do {
            _ = try await mapper.storage.load(at: unreadableFolder)
            check(false, "F2-13 unreadable legacy metadata is an error, never an absent mapping")
        } catch {
            check(!FileManager.default.fileExists(atPath: TapProjectMapStore.mapFile(at: unreadableFolder).path),
                  "F2-13 unreadable legacy metadata is an error, never an absent mapping")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadableDirectory.path)
        let mapFile = TapProjectMapStore.mapFile(at: root)
        check(!mapFile.path.hasPrefix(root.path + "/") && FileManager.default.fileExists(atPath: mapFile.path)
              && !FileManager.default.fileExists(atPath: root.appendingPathComponent(".tatwo/tap-map.json").path),
              "F2-13 mapping stored only in TATWO data directory outside project git")
    }

    private static func runUIChecks(root: URL, environment: [String: String], check: (Bool, String) -> Void) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("sidecar-fixture.mjs")
        let log = root.appendingPathComponent("sidecar.jsonl")
        try #"""
        import fs from 'node:fs';
        import readline from 'node:readline';
        const args = process.argv.slice(2);
        const write = o => fs.appendFileSync(process.env.TATWO2_W185_UI_LOG, JSON.stringify(o) + '\n');
        const sdk = msg => console.log(JSON.stringify({ev: 'sdk', msg}));
        write({op: 'start', args});
        sdk({type: 'system', subtype: 'init', session_id: 'fixture-session', model: 'gpt-6.1-sol'});
        let turn = null;
        readline.createInterface({input: process.stdin}).on('line', line => {
          const c = JSON.parse(line);
          write(c);
          if (c.op === 'send') {
            turn = c.uuid;
            sdk({type: 'system', subtype: 'turn_accepted', session_id: 'fixture-session', client_turn_id: turn});
          } else if (c.op === 'interrupt') {
            sdk({type: 'result', subtype: 'cancelled', client_turn_id: turn, is_error: false, result: ''});
          } else if (c.op === 'close') process.exit(0);
        }).on('close', () => process.exit(0));
        """#.write(to: script, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = previous
        overrides["tatwo2.disabledEngines"] = [String]()
        for kind in ClaudeSidecar.Kind.allCases { overrides["tatwo2.sidecarPath.\(kind.rawValue)"] = script.path }
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        // 既有 sidecar 從 ProcessInfo 取環境，不從 ChatLiveEngine 的參數取自測旗標。
        let logKey = "TATWO2_W185_UI_LOG"
        let previousLog = ProcessInfo.processInfo.environment[logKey]
        setenv(logKey, log.path, 1)
        defer {
            if let previousLog { setenv(logKey, previousLog, 1) }
            else { unsetenv(logKey) }
        }
        var env = environment
        env["TATWO2_W185_UI_LOG"] = log.path
        let tap = W185FakeConversationTap()
        let catalog = try await tap.models()
        ChatGPTTapModelCatalog.replace(catalog.items, currentEffortID: catalog.currentEffortID)
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")), environment: env, tap: tap)
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "Fixture UI", workdir: root.path)
        let thread = engine.newThread(in: project)
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root.appendingPathComponent("bots"))))
        model.selectedThreadID = thread
        model.engineLoginTestDouble = [] // CLI 沒登入；TAP 送出不應查它。
        model.chatGPTTapConnectionTestDouble = { tap.connection }
        engine.onChange = {
            model.document = engine.document
            model.isRunning = engine.isRunning(model.selectedThreadID)
        }
        func mode() -> TatwoComposerMode { ChatPage(model: model).coderComposerMode() }
        func tapOptions(_ mode: TatwoComposerMode) -> [TatwoComposerMode.ModelOption] {
            mode.models.first { $0.id == "single" }?.options.filter { $0.brand == .chatgptTap } ?? []
        }
        func sidecarCommands() -> [[String: Any]] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }
        let route = ChatGPTTapModelCatalog.routeID("fixture-model")
        let plain = ChatGPTTapModelCatalog.routeID("fixture-plain")
        model.setSingleModel(route)
        model.prompt = "UI fixture message"
        let ready = mode()
        let options = tapOptions(ready)
        let brands = ready.models[0].options.map(\.brand)
        check(options.count == 2 && options.allSatisfy { !$0.isDisabled }
              && brands.firstIndex(of: .chatgptTap) == brands.lastIndex(of: .openAI).map { $0 + 1 },
              "UI actual Coder mode lists every TAP model immediately after OpenAI")
        check(ready.segments.first?.text == "ChatGPT / Fixture"
              && ready.segments.first?.short == "ChatGPT / Fixture"
              && model.modelPickerRouteLabel == "ChatGPT / Fixture",
              "UI selected TAP chip retains full brand/model in both wide and compact layouts")
        check(ready.speed == nil && ready.collaboration == nil && ready.badge == nil && ready.footnote == nil && ready.models.count == 1
              && ready.effort?.options.map(\.id) == catalog.items[0].efforts.map { "tap-effort:" + $0.id }
              && ready.effort?.selectedID == "tap-effort:tap-heavy"
              && ready.effort?.hasUltra == false
              && ready.effort?.sliderOptions.count == catalog.items[0].efforts.count,
              "UI only TAP efforts; no speed or CLI collaboration controls")
        ready.effort?.choose("tap-effort:tap-light")
        model.selectTapEffort("xhigh")
        check(model.selectedTapEffortID == "tap-light", "UI rejects Codex effort IDs not provided by TAP")
        let checksBefore = model.sendLoginChecks.count
        check(model.canSend, "UI ready TAP can send without CLI login")
        model.send()
        try await wait { tap.sent.count == 1 }
        check(tap.sent[0].model == "fixture-model" && tap.sent[0].effort == "tap-light"
              && tap.sent[0].text.hasSuffix("UI fixture message"),
              "UI ChatPageModel.send reaches fake TAP with selected native model/effort")
        check(model.sendLoginChecks.count == checksBefore && engine.sidecarProcessOwners().isEmpty
              && !FileManager.default.fileExists(atPath: log.path),
              "UI TAP send checks no CLI login and starts no sidecar of any kind")
        check(model.prompt.isEmpty && model.isRunning
              && engine.transcript(for: thread).first?.text == "UI fixture message",
              "UI TAP accepted send clears composer and preserves ordinary user bubble")
        tap.emit(.conversation(id: "ui-conversation"))
        tap.emit(.text(messageID: "ui-reply", full: "fixture answer"))
        try await wait { engine.transcript(for: thread).last?.text == "fixture answer" }
        tap.finish()
        try await wait { !model.isRunning }
        model.restoreModelPreferences()
        check(model.selectedModel == route && model.tapEffortIDForSend == "tap-light"
              && engine.threadRecord(thread)?.requestedEffort == "tap-light",
              "UI existing TAP thread restores its TAP route and native effort without Codex normalization")

        model.prompt = "UI stop fixture"
        model.send()
        try await wait { tap.sent.count == 2 }
        // W199：排隊保持可停止的 writing 狀態，不再報備連線／啟動；下面的 stop 與零 sidecar 保證照舊。
        try await wait { engine.transcript(for: thread).last?.status == "writing|ChatGPT 準備中" }
        let request = tap.sent[1].requestID
        model.stop()
        try await wait { !model.isRunning }
        check(tap.stopped == [request] && engine.sidecarProcessOwners().isEmpty,
              "UI ChatPageModel.stop targets the TAP request, never CLI stop")
        ChatGPTTapModelCatalog.replace([])
        model.restoreModelPreferences()
        check(model.selectedModel == route && model.selectedTapEffortID == "tap-light",
              "UI cold TAP thread keeps stored native effort while catalog is absent")
        ChatGPTTapModelCatalog.replace(catalog.items, currentEffortID: catalog.currentEffortID)
        model.setSingleModel(route)
        check(model.tapEffortIDForSend == "tap-light", "UI later catalog refresh and same-model selection preserve stored TAP effort")

        for (connection, reason) in [(TapConnection.needsLogin, "請打開 ChatGPT 登入"),
                                     (.sleeping, "休眠"), (.off, "已停用"),
                                     (.starting, "啟動中"), (.failed("fixture"), "連線失敗")] {
            tap.connection = connection
            model.prompt = "keep unavailable draft"
            let blocked = mode()
            let sentBefore = tap.sent.count
            let rowsBefore = engine.transcript(for: thread).count
            check(tapOptions(blocked).count == 2 && tapOptions(blocked).allSatisfy { connection == .sleeping || connection == .starting ? !$0.isDisabled : $0.isDisabled }
                  && blocked.modelNote?.contains(reason) == true,
                  "UI TAP selection availability with reason: \(reason)")
            if connection == .sleeping || connection == .starting {
                check(model.canSend && model.prompt == "keep unavailable draft", "W194-2 dormant selected model allows queued send")
                continue
            }
            model.send()
            check(!model.canSend && model.prompt == "keep unavailable draft" && tap.sent.count == sentBefore
                  && model.sendLoginChecks.count == checksBefore && engine.transcript(for: thread).count == rowsBefore
                  && model.sendAvailabilityDiagnostic.contains(reason),
                  "UI unavailable TAP blocks direct send and retains draft: \(reason)")
        }
        var wakes = 0
        model.chatGPTTapWakeTestDouble = { wakes += 1; tap.connection = .starting }
        tap.connection = .sleeping
        let sleepingDraft = model.prompt
        model.setSingleModel(plain)
        check(wakes == 1 && model.selectedModel == plain && tap.connection == .starting
              && model.canSend && model.prompt == sleepingDraft && tap.sent.count == 2,
              "M15 selecting a sleeping model wakes ChatGPT once without sending or changing the draft")
        for connection in [TapConnection.off, .needsLogin] {
            tap.connection = connection
            model.setSingleModel(route)
            check(wakes == 1 && model.selectedModel == plain && !model.canSend,
                  "M15 disabled or logged-out ChatGPT cannot be woken by model selection")
        }
        // .052 實機：模式卡（selectRouteChoice）先喚醒、下一輪才 applyCoderRoute，那時已是 starting，以前會被「啟動中」擋回。
        tap.connection = .sleeping
        let cardChoice = ChatRouteChoice.resolve(route)
        if model.prepareTapSelection(cardChoice) { TatwoComposerMode.applyCoderRoute(cardChoice, to: model) }
        check(wakes == 2 && model.selectedModel == route && tap.connection == .starting && model.canSend,
              "M15 model card path: choosing while ChatGPT is still starting keeps the choice; sending waits for ready")
        model.chatGPTTapWakeTestDouble = nil
        tap.connection = .ready
        model.setSingleModel(route)
        ChatGPTTapModelCatalog.replace(catalog.items, fetchedAt: Date().addingTimeInterval(-ChatGPTTapModelCatalog.maxAge - 1))
        let expired = mode()
        check(model.canSend, "UI stale cached selection can send and refresh before dispatch")
        model.send()
        try await wait { tap.sent.count == 3 }
        check(tapOptions(expired).allSatisfy(\.isDisabled) && expired.modelNote?.contains("過期") == true
              && ChatGPTTapModelCatalog.isFresh && model.prompt.isEmpty,
              "UI expired catalog automatically refreshes once and sends without reopening menu")
        tap.finish()
        try await wait { !model.isRunning }
        ChatGPTTapModelCatalog.replace([])
        let missing = mode()
        model.send()
        check(tapOptions(missing).count == 1 && tapOptions(missing).allSatisfy(\.isDisabled)
              && !model.canSend && model.routeChoice.runtimeAdapter == .chatgptTap && tap.sent.count == 3,
              "UI empty catalog shows disabled placeholder; stored TAP never falls back to CLI")
        model.setSingleModel("gpt-6.1-sol")
        let priorModel = model.selectedModel
        model.setSingleModel(route)
        check(model.selectedModel == priorModel, "UI unavailable TAP cannot be selected programmatically")
        ChatGPTTapModelCatalog.replace(catalog.items, currentEffortID: catalog.currentEffortID)
        model.setSingleModel(plain)
        check(mode().effort == nil && mode().speed == nil && model.tapEffortIDForSend == nil,
              "UI TAP model with no native efforts exposes no effort controls")
        model.setSingleModel(route)
        model.selectedRemote = ("fixture-device", thread)
        model.prompt = "remote fixture"
        check(tapOptions(mode()).allSatisfy(\.isDisabled) && !model.canSend
              && model.sendAvailabilityDiagnostic.contains("本機"),
              "UI remote Coder cannot dispatch local TAP as Codex")
        model.selectedRemote = nil
        model.prompt = "UI not submitted"
        model.send()
        try await wait { tap.sent.count == 4 }
        tap.emit(.notSubmitted("fixture not submitted"))
        try await wait { !model.isRunning }
        check(model.prompt == "UI not submitted", "UI TAP notSubmitted uses ordinary draft restoration")

        if let path = environment["TATWO2_SELFTEST_ARTIFACTS"] {
            let artifacts = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
            try renderMode(mode(), model: model, to: artifacts.appendingPathComponent("tap-ready.png"))
            tap.connection = .needsLogin
            try renderMode(mode(), model: model, to: artifacts.appendingPathComponent("tap-needs-login.png"))
            tap.connection = .ready
            check(true, "UI native mode card/chip screenshots exported (ready and needsLogin)")
        }
        model.setSingleModel("gpt-6.1-sol")
        model.engineLoginTestDouble = [.codex]
        model.prompt = "UI Codex fixture"
        model.send()
        try await wait { sidecarCommands().contains { $0["op"] as? String == "send" } }
        let commands = sidecarCommands()
        let sent = commands.first { $0["op"] as? String == "send" }
        check(sent?["model"] as? String == "gpt-6.1-sol" && sent?["effort"] as? String == model.selectedEffort.codexRawValue
              && sent?["serviceTier"] as? String == model.selectedSpeedTier.appServerValue
              && tap.sent.count == 4 && model.sendLoginChecks.last == .codex
              && commands.filter { $0["op"] as? String == "start" }.count == 1,
              "UI switch back to Codex sends to Codex sidecar with CLI login, effort and speed as before")
        model.stop()
        try await wait { sidecarCommands().contains { $0["op"] as? String == "interrupt" } && !model.isRunning }
        check(tap.stopped == [request], "UI Codex stop stays on CLI and does not stop TAP again")
        let codexMode = mode()
        check(codexMode.speed != nil && codexMode.effort != nil && codexMode.collaboration != nil
              && !codexMode.segments[0].text.contains("ChatGPT TAP"),
              "UI switch back restores Codex controls and chip")
        if let path = environment["TATWO2_SELFTEST_ARTIFACTS"] {
            try Data(contentsOf: log).write(to: URL(fileURLWithPath: path).appendingPathComponent("codex-fixture.jsonl"))
        }
    }

    private static func renderMode(_ mode: TatwoComposerMode, model: ChatPageModel, to url: URL) throws {
        let page = ChatPage(model: model)
        let view = HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 12) {
                ChatComposerModeChip(segments: mode.segments, selected: true, help: mode.help) {}
                TatwoComposerModeCard(mode: mode, metrics: .main)
            }.frame(width: 420)
            VStack(alignment: .leading, spacing: 6) {
                page.modelPickerBrandHeader(.chatgptTap)
                if let reason = model.chatGPTTapUnavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(ChatGPTTapModelCatalog.choices) { page.modelPickerInlineRouteRow($0) }
            }.padding(12).frame(width: 360).liquidGlassPanelSurface(cornerRadius: LiquidGlassTokens.radiusCard)
        }.padding(20).frame(width: 860, height: 760).background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 860, height: 760)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw TapError.remote("W185 UI bitmap unavailable")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw TapError.remote("W185 UI PNG unavailable")
        }
        try png.write(to: url)
    }

    private final class W203RemoteCaller: RemoteLiveCalling, @unchecked Sendable {
        let initial: [String: Any]
        let messages: Any
        init(initial: [String: Any], messages: Any) { self.initial = initial; self.messages = messages }
        func call(method: String, params: [String: Any]) throws -> [String: Any] {
            switch method {
            case "get_document": return initial
            case "transcript": return ["messages": messages]
            default: throw RemoteHostLinkError.invalidResponse
            }
        }
    }

    /// Actual Coder ChatPage → runner → native TAP → fake Pod, including restart/storage.
    private static func w203CoderChecks(_ check: (Bool, String) -> Void, root: URL, environment: [String: String]) async throws {
        let syntheticMailbox = ["fixture", "example.invalid"].joined(separator: "@")
        let pod = DispatchTapPod()
        pod.isRunning = true
        let tap = ChatGPTTap(transport: pod)
        let previous = ChatGPTTapModelCatalog.snapshot
        ChatGPTTapModelCatalog.replace([TapModel(id: "fixture-model", title: "合成模型", detail: "")])
        defer { tap.sleep(); ChatGPTTapModelCatalog.replace(previous) }
        let folder = root.appendingPathComponent("w203-coder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let attachment = folder.appendingPathComponent("draft-fixture.txt")
        try Data("synthetic attachment".utf8).write(to: attachment)
        let store = ChatLiveStore(root: folder.appendingPathComponent("live"))
        let engine = ChatLiveEngine(store: store, environment: environment, tap: tap)
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "合成驗收", workdir: folder.path)
        let id = engine.newThread(in: project)
        let model = ChatPageModel(environment: environment, botCoreFixture: (engine, BotStore(root: folder.appendingPathComponent("bots"))))
        model.selectLocalThread(id)
        engine.onChange = {
            model.document = engine.document
            model.isRunning = engine.isRunning(model.selectedThreadID)
            model.objectWillChange.send()
        }
        model.chatGPTTapConnectionTestDouble = { tap.connection }
        model.setSingleModel(ChatGPTTapModelCatalog.routeID("fixture-model"))
        let palette = TatwoActivePalette.current, appearance = NSApp.appearance
        _ = TatwoThemeStore.shared
        TatwoActivePalette.current = TatwoTheme.aurora.palette
        defer { TatwoActivePalette.current = palette; NSApp.appearance = appearance }
        try W205Acceptance.contrast(check, coder: model)
        // Render the actual chip on a dark backdrop and measure text/background contrast.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        for theme in [TatwoTheme.aurora, .fable5] {
            TatwoActivePalette.current = theme.palette
            for selected in [false, true] {
                if let chip = GlobalDMChatAcceptance.renderSync(
                    Button("放回輸入框") {}.buttonStyle(.plain).font(.system(size: 13))
                        .frame(width: 180, height: 40).chatGlassChip(isSelected: selected, readable: true)
                        .frame(width: 340, height: 100).background(Color.black),
                    size: CGSize(width: 340, height: 100), scheme: .dark) {
                    defer { chip.close() }
                    let bitmap = chip.bitmap
                    var darkest = 1.0, lightest = 0.0, inkPixels = 0
                    for x in Int(Double(bitmap.pixelsWide) * 0.32)..<Int(Double(bitmap.pixelsWide) * 0.68) {
                        for y in Int(Double(bitmap.pixelsHigh) * 0.40)..<Int(Double(bitmap.pixelsHigh) * 0.60) {
                            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                            func linear(_ value: CGFloat) -> Double {
                                let v = Double(value); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
                            }
                            let luminance = 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
                            darkest = min(darkest, luminance); lightest = max(lightest, luminance)
                            if luminance < 0.2 { inkPixels += 1 }
                        }
                    }
                    check(inkPixels > 5 && (lightest + 0.05) / (darkest + 0.05) >= 4.5,
                          "W203-6 actual dark chip text contrast is at least 4.5:1 selected=\(selected)")
                    if let path = environment["TATWO2_SELFTEST_ARTIFACTS"] {
                        GlobalDMChatAcceptance.save(chip, "w203-chip-" + (theme.palette.usesGlass ? "glass" : "matte") + (selected ? "-selected-dark.png" : "-dark.png"), to: URL(fileURLWithPath: path))
                    }
                } else { check(false, "W203-6 actual dark chip render") }
            }
        }
        TatwoActivePalette.current = TatwoTheme.aurora.palette
        func shot(_ name: String, _ scheme: ColorScheme, _ pageModel: ChatPageModel, has identifier: String) throws {
            NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            // Use the app's retained container lifecycle: closing a screenshot host is not stopping the conversation.
            let lifecycle = TatwoRetainedChatLifecycle(initiallySelectedChat: true)
            guard let rendered = GlobalDMChatAcceptance.renderSync(ChatPage(model: pageModel, retainedLifecycle: lifecycle), size: CGSize(width: 1120, height: 820), scheme: scheme) else {
                check(false, "W203 Coder screenshot " + name); return
            }
            defer { rendered.close() }
            check(GlobalDMChatAcceptance.identifiers(in: rendered).contains(identifier), "W203-7 actual Coder transcript AX " + identifier)
            if let path = environment["TATWO2_SELFTEST_ARTIFACTS"] {
                GlobalDMChatAcceptance.save(rendered, name + ".png", to: URL(fileURLWithPath: path))
            }
        }
        func remoteCheck(_ name: String, has identifier: String) async throws {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let initial: [String: Any] = ["document": try JSONSerialization.jsonObject(with: encoder.encode(engine.doc)),
                "revision": 1, "runningThreadIDs": engine.isRunning(id) ? [id.uuidString] : [String]()]
            // The live transcript is fresher than the throttled document snapshot.
            let records = engine.transcript(for: id).map(LiveMessageRecord.init)
            let caller = W203RemoteCaller(initial: initial, messages: try JSONSerialization.jsonObject(with: encoder.encode(records)))
            let remote = try RemoteLiveEngine(link: RemoteHostLink(environment: environment), callingThrough: caller,
                store: ChatLiveStore(root: folder.appendingPathComponent(name)), initial: initial)
            defer { remote.shutdownAll() }
            // A second page must not overwrite the original engine's onChange observer.
            let unusedLocal = ChatLiveEngine(store: ChatLiveStore(root: folder.appendingPathComponent(name + "-local")), environment: environment, tap: tap)
            defer { unusedLocal.shutdownAll() }
            let remoteModel = ChatPageModel(environment: environment, botCoreFixture: (unusedLocal, BotStore(root: folder.appendingPathComponent(name + "-bots"))))
            remoteModel.coderRemoteEngineTestDouble = ("synthetic-peer", remote)
            remoteModel.selectedRemote = ("synthetic-peer", id)
            remoteModel.selectedThreadID = id
            remoteModel.isRunning = remote.isRunning(id)
            try await wait { !remoteModel.transcriptMessages.isEmpty }
            if identifier == "chatgpt.thinkingProgress" {
                check(remoteModel.chatGPTTurnState?.thinking != nil, "W203-7 remote Coder uses the remote transcript thinking status")
            } else if identifier == "chatgpt.thoughtDuration" {
                check((remoteModel.chatGPTTurnState?.thoughtSeconds ?? 0) > 0, "W203-7 remote Coder restores completed thinking seconds")
            } else {
                check(remoteModel.chatGPTTurnState?.failure?.isTooLong == true && remoteModel.chatGPTTurnState?.failure?.actionTitle == "開新對話接著聊",
                      "W203-4 remote Coder restores fixed too-long classification and action")
            }
            try shot(name, .dark, remoteModel, has: identifier)
        }
        model.prompt = "合成 Coder 問題"
        model.send()
        try await wait { pod.sends.count == 1 && model.chatGPTTurnState?.thinking != nil }
        let request = pod.sends.last!["id"] as! String
        let started = model.chatGPTTurnState!.thinking!.started
        check(engine.tapTurn[id]?.thinking != nil && model.chatGPTTurnState?.thinking != nil,
              "W203-7 accepted native TAP triggers Coder thinking without a progress event")
        pod.emit(["type": "stream", "id": request, "kind": "accepted"])
        pod.emit(["type": "stream", "id": request, "kind": "progress", "title": "核對合成資料"])
        try await wait { model.chatGPTTurnState?.thinking?.title == "核對合成資料" }
        check(model.chatGPTTurnState?.thinking?.started == started, "W203-7 duplicate accepted does not restart the thinking clock")
        try await Task.sleep(for: .milliseconds(1100))
        try shot("w203-coder-thinking-light", .light, model, has: "chatgpt.thinkingProgress")
        try shot("w203-coder-thinking-dark", .dark, model, has: "chatgpt.thinkingProgress")
        try await remoteCheck("w203-coder-remote-thinking-dark", has: "chatgpt.thinkingProgress")
        pod.emit(["type": "stream", "id": request, "kind": "conversation", "conversationID": "w203-coder-conversation"])
        pod.emit(["type": "stream", "id": request, "kind": "text", "messageID": "reply", "full": "合成回答"])
        pod.emit(["type": "stream", "id": request, "kind": "finished"])
        try await wait { !model.isRunning }
        check(model.chatGPTTurnState?.thinking == nil && (model.chatGPTTurnState?.thoughtSeconds ?? 0) > 0,
              "W203-7 actual Coder answer has completed thinking seconds")
        try shot("w203-coder-completed-dark", .dark, model, has: "chatgpt.thoughtDuration")
        try await remoteCheck("w203-coder-remote-completed-dark", has: "chatgpt.thoughtDuration")
        model.prompt = "合成失敗問題"
        model.droppedPaths = [attachment.path]
        model.droppedPathDisplayNames = [attachment.path: "合成附件.txt"]
        model.send()
        try await wait { pod.sends.count == 2 }
        let failedID = pod.sends.last!["id"] as! String
        pod.emit(["type": "stream", "id": failedID, "kind": "failed", "message": "password=abc \(syntheticMailbox) /Users/fixture/private.txt", "reason": "conversation_too_long"])
        try await wait { !model.isRunning }
        check(model.chatGPTTurnState?.failure?.isTooLong == true, "W203-4 Coder too-long failure has recovery action")
        let encoded = String(decoding: try JSONEncoder().encode(engine.doc), as: UTF8.self)
        check(!encoded.contains("password=abc") && !encoded.contains(syntheticMailbox) && !encoded.contains("/Users/fixture/private.txt")
              && encoded.contains("error|對話太長"), "W203-4 Coder persists only fixed failure category")
        try shot("w203-coder-error-dark", .dark, model, has: "chatgpt.turnFailure")
        try await remoteCheck("w203-coder-remote-error-dark", has: "chatgpt.turnFailure")
        let reopened = ChatLiveEngine(store: ChatLiveStore(root: folder.appendingPathComponent("live")), environment: environment, tap: tap)
        defer { reopened.shutdownAll() }
        let reopenedModel = ChatPageModel(environment: environment, botCoreFixture: (reopened, BotStore(root: folder.appendingPathComponent("reopened-bots"))))
        reopenedModel.selectLocalThread(id)
        check(reopenedModel.chatGPTTurnState?.failure?.isTooLong == true && reopenedModel.chatGPTTurnState?.failure?.actionTitle == "開新對話接著聊",
              "W203-4 reopened Coder restores too-long category and action without raw provider text")
        try shot("w203-coder-reopened-dark", .dark, reopenedModel, has: "chatgpt.turnFailure")
        if let failure = model.chatGPTTurnState?.failure { model.restoreChatGPTInput(failure, in: id) }
        check(model.prompt == "合成失敗問題" && model.droppedPaths == [attachment.path]
              && model.droppedPathDisplayNames[attachment.path] == "合成附件.txt",
              "W207 Coder manual failed-turn recovery restores attachment and its original display name")
        model.droppedPaths = []; model.droppedPathDisplayNames = [:]
        // Website explicitly proves no send; even this exit must never persist provider text.
        model.prompt = "合成未送出問題"
        model.droppedPaths = [attachment.path]
        model.droppedPathDisplayNames = [attachment.path: "合成附件.txt"]
        model.send()
        try await wait { pod.sends.count == 3 }
        pod.emit(["type": "stream", "id": pod.sends.last!["id"] as! String, "kind": "failed", "submitted": false,
                  "message": "short password=xyz /Volumes/fixture/private.txt \(syntheticMailbox)"])
        try await wait { !model.isRunning }
        let unsent = String(decoding: try JSONEncoder().encode(engine.doc), as: UTF8.self)
        check(unsent.contains("error|沒有送出") && !unsent.contains("password=xyz") && !unsent.contains("/Volumes/fixture/private.txt")
              && !unsent.contains(syntheticMailbox), "W203-4 notSubmitted exit persists category only")
        check(model.prompt == "合成未送出問題" && model.droppedPaths == [attachment.path]
              && model.droppedPathDisplayNames[attachment.path] == "合成附件.txt",
              "W207 actual TAP website rejection restores draft, attachment and display name")
        model.prompt = ""; model.droppedPaths = []; model.droppedPathDisplayNames = [:]
        for delay in [0, 50, 500, 1000, 4500] {
            let before = pod.sends.count
            model.prompt = "時序合成問題 \(delay)"
            model.send()
            try await wait { pod.sends.count == before + 1 }
            pod.stream("text", ["messageID": "timing-reply", "full": "時序合成回覆"])
            pod.stream("finished")
            try await wait { !model.isRunning && model.transcriptMessages.last?.text == "時序合成回覆" }
            let appeared = Date()
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            model.prompt = "回覆後再送 \(delay)"
            let elapsed = Date().timeIntervalSince(appeared)   // measured at the press: the case must fall inside the 5 s window
            model.send()
            check(model.prompt.isEmpty && elapsed <= 5,
                  "W207 Coder ChatGPT model reply followed by send at \(delay)ms clears composer (elapsed=\(elapsed))")
            try await wait { pod.sends.count == before + 2 }
            check(pod.sends.count == before + 2 && (pod.sends.last?["text"] as? String)?.hasSuffix("回覆後再送 \(delay)") == true,
                  "W207 Coder next prompt reaches website exactly once at \(delay)ms")
            pod.stream("finished")
            try await wait { !model.isRunning }
        }

    }

    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TapError.remote("W185 fixture timed out")
    }
}

@MainActor
final class W185FakeConversationTap: ConversationTap {
    struct Send {
        let requestID: String
        let text: String
        let conversationID: String?
        let model: String?
        let effort: String?
        let gizmoID: String?
    }
    let tapID = "fixture"
    let displayName = "Fixture"
    var connection: TapConnection = .ready
    var folders: [TapFolder] = []
    var createdNames: [String] = []
    var failNames: Set<String> = []
    var sent: [Send] = []
    var stopped: [String] = []
    var projectFailure = false
    var conversationFailure = false
    var modelFailure = false
    var modelCalls = 0
    var modelFixture: (items: [TapModel], defaultID: String?, currentEffortID: String?)?
    var modelGate: (() async -> Void)?
    var projectGate: (() async -> Void)?
    var requestCalls = 0
    private var continuation: AsyncStream<TapStreamEvent>.Continuation?
    private var conversationsByProject: [String: [TapConversation]] = [:]
    func seedConversation(_ id: String, in project: String) {
        conversationsByProject[project, default: []].append(TapConversation(id: id, title: "fixture", updatedAt: Date()))
    }
    func removeConversation(_ id: String) {
        for project in conversationsByProject.keys { conversationsByProject[project]?.removeAll { $0.id == id } }
    }
    func emit(_ event: TapStreamEvent) {
        if case .conversation(let id) = event, let project = sent.last?.gizmoID {
            conversationsByProject[project, default: []].append(TapConversation(id: id, title: "fixture", updatedAt: Date()))
        }
        continuation?.yield(event)
        switch event {
        case .failed, .notSubmitted: continuation?.finish()
        default: break
        }
    }
    func finish() { continuation?.yield(.finished); continuation?.finish() }
    func createProject(name: String, description: String) async throws -> TapFolder {
        await projectGate?()
        requestCalls += 1
        createdNames.append(name)
        if failNames.contains(name) { throw TapError.remote("quota fixture") }
        let folder = TapFolder(id: "g-p-fixture-\(createdNames.count)", title: name, kind: .project, description: description)
        folders.append(folder)
        return folder
    }
    func projects() async throws -> [TapFolder] {
        requestCalls += 1
        if projectFailure { throw TapError.remote("HTTP 503 fixture") }
        return folders
    }
    func conversations(inProject projectID: String) async throws -> [TapConversation] {
        requestCalls += 1
        if conversationFailure { throw TapError.remote("HTTP 503 fixture") }
        return conversationsByProject[projectID] ?? []
    }
    func models() async throws -> (items: [TapModel], defaultID: String?, currentEffortID: String?) {
        requestCalls += 1
        modelCalls += 1
        await modelGate?()
        if modelFailure { throw TapError.remote("HTTP 503 fixture") }
        if let modelFixture { return modelFixture }
        return ([TapModel(id: "fixture-model", title: "Fixture", detail: "",
                   efforts: [TapEffort(id: "tap-heavy", title: "Heavy"), TapEffort(id: "tap-light", title: "Light"),
                             TapEffort(id: "ultra", title: "Native Extra")]),
          TapModel(id: "fixture-plain", title: "Fixture Plain", detail: "")], "fixture-model", "tap-heavy")
    }
    func send(text: String, conversationID: String?, model: String?, effort: String?, attachments: [TapAttachment],
              tool: String?, gizmoID: String?, temporary: Bool, parentID: String?) -> AsyncStream<TapStreamEvent> {
        requestCalls += 1
        let requestID = "fixture-request-\(sent.count)"
        sent.append(Send(requestID: requestID, text: text, conversationID: conversationID, model: model, effort: effort, gizmoID: gizmoID))
        let pair = AsyncStream.makeStream(of: TapStreamEvent.self)
        continuation = pair.continuation
        continuation?.yield(.request(id: requestID))
        continuation?.yield(.queued)
        return pair.stream
    }
    func stop(requestID: String) { stopped.append(requestID); continuation?.finish() }
    func stop() { preconditionFailure("global stop must not be called") }
    func conversations(offset: Int, limit: Int) async throws -> (items: [TapConversation], total: Int) { ([], 0) }
    func messages(conversationID: String) async throws -> [TapMessage] { [] }
    func thread(conversationID: String, branch: String?) async throws -> TapThread { TapThread(messages: [], leaf: nil, isCurrent: true) }
    func pinned() async throws -> [TapFolder] { [] }
    func tools() async throws -> [TapTool] { [] }
    func home() async throws -> (greeting: String?, suggestions: [TapSuggestion]) { (nil, []) }
    func gpts() async throws -> [TapFolder] { [] }
    func regenerate(conversationID: String, model: String?, effort: String?, temporary: Bool) -> AsyncStream<TapStreamEvent> { AsyncStream { $0.finish() } }
    func rename(conversationID: String, title: String) async throws {}
    func feedback(conversationID: String, messageID: String, good: Bool) async throws {}
    func setPinned(conversationID: String, pinned: Bool) async throws {}
    func branch(conversationID: String) async throws -> String? { nil }
    func archive(conversationID: String) async throws {}
    func delete(conversationID: String) async throws {}
    func search(query: String) async throws -> [TapConversation] { [] }
    func imageData(pointer: String, conversationID: String?) async throws -> Data { Data() }
    func library(tab: TapLibraryTab, query: String, cursor: String?) async throws -> (items: [TapLibraryItem], cursor: String?) { ([], nil) }
    func libraryData(itemID: String, full: Bool) async throws -> Data { Data() }
}
#endif
