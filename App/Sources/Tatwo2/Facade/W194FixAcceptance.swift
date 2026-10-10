#if DEBUG
import Foundation
import AppKit

/// W194：只用假傳輸與隔離 root；走正式停止、恢復與私訊框的事件消費。
@MainActor
enum W194FixAcceptance {
    static func run(_ check: (Bool, String) -> Void) async throws {
        let parked = TapWebPod(podID: "w194-fixture", profileID: UUID(), homeURL: ChatGPTTap.homeURL, script: "fixture")
        check(parked.parkingSharingTypeForSelfTest() == .none, "W194-4 real offscreen NSWindow blocks capture before any background work")
        parked.stop()
        let previous = ChatGPTTapModelCatalog.snapshot
        defer { ChatGPTTapModelCatalog.replace(previous) }
        let model = TapModel(id: "fixture-stop-model", title: "Fixture Stop Model", detail: "")
        ChatGPTTapModelCatalog.replace([model])
        let route = ChatGPTTapModelCatalog.routeID(model.id)
        ChatGPTTapModelCatalog.replace([])
        check(ChatRouteChoice.resolve(route).title == model.title, "W194-11 cached model title survives empty catalog")
        ChatGPTTapModelCatalog.replace([model])
        let encoder = JSONEncoder()
        let saved = try JSONSerialization.jsonObject(with: encoder.encode(LiveMessageRecord(ChatMessage(role: .assistant, text: "fixture", modelID: route)))) as? [String: Any]
        check(saved?["modelDisplayName"] as? String == model.title, "W194-11 reply persists its display name")
        let device = "w194-name-fixture"
        let native = EngineModelCatalog.Model(model: "fixture-native-model", displayName: "Fixture Native Display", efforts: [],
                                              defaultEffort: "low", speeds: [], defaultSpeed: "standard", images: false)
        EngineModelCatalog.replace([.init(engine: "codex", identity: "fixture", source: "fixture", models: [native])], deviceID: device)
        let reply = ChatMessage(role: .assistant, text: "fixture", modelID: native.model, modelDisplayName: native.displayName)
        EngineModelCatalog.replace([], deviceID: device)
        let remembered = ChatRouteChoice.resolve(native.model, deviceID: device)
        check(remembered.title == native.displayName && remembered.runtimeAdapter == .unavailable,
              "W194-11 native empty catalog keeps the display name without stale capabilities")
        let restored = try JSONDecoder().decode(LiveMessageRecord.self, from: encoder.encode(LiveMessageRecord(reply))).chatMessage
        check(restored.modelDisplayName == native.displayName, "W194-11 historical reply name survives serialization and catalog loss")
        let coldModelID = "fixture-cold-name-" + UUID().uuidString
        let coldRoute = ChatGPTTapModelCatalog.routeID(coldModelID)
        var coldSaved = LiveMessageRecord(ChatMessage(role: .assistant, text: "fixture"))
        coldSaved.modelID = coldRoute
        coldSaved.modelDisplayName = "Fixture Cold Display"
        check(ChatGPTTapModelCatalog.rememberedTitle(coldModelID) == nil,
              "W194-11 cold persisted fixture has never populated the name cache")
        let restoredCold = try JSONDecoder().decode(LiveMessageRecord.self, from: encoder.encode(coldSaved)).chatMessage
        check(restoredCold.modelDisplayName == "Fixture Cold Display" && ChatGPTTapModelCatalog.rememberedTitle(coldModelID) == "Fixture Cold Display"
              && ChatRouteChoice.resolve(coldRoute).id == route, "W194-11 restored reply preserves historical name while active selection uses the current catalog")
        let stopped = ChatErrorCardPresentation.resolve(ChatMessage(role: .system, text: "這句尚未送出，已停止", status: "error|沒送到"))
        check(stopped?.isStopped == true && stopped?.headline == "已停止", "W194-3 old stopped errors render neutrally too")
        let login = EngineFailurePresentation.make("token expired", alternative: "fixture")
        let loginCard = ChatErrorCardPresentation.resolve(ChatMessage(role: .system, text: login.summary, status: "error|回合失敗"))
        check(loginCard?.needsModelLogin == true, "W194-10 normalized login error card offers Model Login")
        for streaming in [false, true] {
            for acknowledged in [false, true] {
                let pod = Pod()
                let tap = ChatGPTTap(transport: pod, stopDeadline: .milliseconds(40))
                let id = "fixture-\(streaming)-\(acknowledged)"
                let stream = tap.send(requestID: id, text: "fixture", conversationID: nil)
                if streaming { pod.emit(["type":"stream", "id":id, "kind":"text", "full":"partial fixture"]) }
                tap.stop(requestID: id)
                if acknowledged, let stop = pod.stopID { pod.emit(["type":"result", "id":stop, "ok":true, "data":["submitted":true]]) }
                try await Task.sleep(for: .milliseconds(80))
                var events: [TapStreamEvent] = []
                for await event in stream { events.append(event) }
                check(!events.contains { if case .failed = $0 { return true }; return false }, "W194-1 stopped stream never fails streaming=\(streaming) ack=\(acknowledged)")
                check(tap.connection == (acknowledged ? .ready : .sleeping) && pod.isRunning == acknowledged,
                      "W194-1 deadline closes unknown Pod but leaves automatic recovery streaming=\(streaming) ack=\(acknowledged)")
                let next = tap.send(requestID: "next", text: "next fixture", conversationID: nil)
                if !acknowledged { pod.emit(["type":"hello", "loggedIn":true]) }
                pod.emit(["type":"stream", "id":"next", "kind":"finished"])
                var succeeded = false
                for await event in next { if event == .finished { succeeded = true } }
                check(succeeded && tap.connection == .ready, "W194-1 next send reopens and succeeds streaming=\(streaming) ack=\(acknowledged)")
                tap.sleep()
            }
        }
        // CEF 關閉是非同步的：尚未還回設定檔租約時，下一句先等，不能把 profileInUse 當連線失敗。
        do {
            let pod = Pod(); pod.delaysClose = true; pod.autoHello = true
            let tap = ChatGPTTap(transport: pod, stopDeadline: .milliseconds(20))
            _ = tap.send(requestID: "closing-first", text: "fixture", conversationID: nil)
            tap.stop(requestID: "closing-first")
            try await Task.sleep(for: .milliseconds(40))
            let next = tap.send(requestID: "closing-next", text: "fixture", conversationID: nil)
            check(tap.connection == .starting && pod.starts == 0, "W194-1 delayed CEF close queues restart without reusing the held profile")
            pod.isClosing = false
            try await wait { tap.connection != .starting }
            if tap.connection == .ready { pod.emit(["type":"stream", "id":"closing-next", "kind":"finished"]) }
            var completed = false
            for await item in next { if item == .finished { completed = true } }
            check(completed && tap.connection == .ready && pod.starts == 1, "W194-1 delayed CEF lease release automatically resumes the next send")
            pod.delaysClose = false; tap.sleep()
        }
        // 一定未送出：網站回執證據，保留文字與附件；不能用「尚未出字」猜測。
        let pod = Pod()
        let tap = ChatGPTTap(transport: pod, stopDeadline: .milliseconds(40))
        let session = ChatGPTConversationSession(tap: tap)
        let fileName = "fixture.txt"
        let attachment = TapAttachment(name: fileName, mime: "text/plain", data: Data("fixture".utf8))
        session.send("draft fixture", attachments: [attachment])
        await Task.yield()
        session.stop()
        if let stop = pod.stopID { pod.emit(["type":"result", "id":stop, "ok":true, "data":["submitted":false]]) }
        try await Task.sleep(for: .milliseconds(80))
        check(session.returnedDrafts.first?.text == "draft fixture" && session.returnedDrafts.first?.attachments == [attachment],
              "W194-3 DM pre-submit stop retains draft and attachment")
        tap.sleep()
        try await surfaces(check)
    }

    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TapError.remote("W194 isolated fixture did not converge")
    }

    private static func surfaces(_ check: (Bool, String) -> Void) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let live = env["TATWO2_LIVE_ROOT"] else { throw TapError.notReady }
        let root = URL(fileURLWithPath: live).appendingPathComponent("w194-surfaces")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let route = ChatGPTTapModelCatalog.routeID("fixture-stop-model")
        for surface in ["Coder", "Space", "DM"] {
            for streaming in [false, true] {
                for timely in [false, true] {
                    let tag = "\(surface)-streaming=\(streaming)-receipt=\(timely)"
                    let pod = Pod()
                    pod.autoHello = true
                    let tap = ChatGPTTap(transport: pod, stopDeadline: .milliseconds(40))
                    let folder = root.appendingPathComponent(UUID().uuidString)
                    let engine = ChatLiveEngine(store: ChatLiveStore(root: folder), environment: env, tap: tap)
                    let thread = engine.newThread(in: nil)
                    let coder = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: folder.appendingPathComponent("bots"))))
                    coder.chatGPTTapConnectionTestDouble = { tap.connection }
                    coder.chatGPTTapWakeTestDouble = { tap.start() }
                    coder.engineLoginTestDouble = []
                    coder.selectedThreadID = thread
                    engine.onChange = { coder.document = engine.document; coder.isRunning = engine.isRunning(thread) }
                    coder.setSingleModel(route)
                    let space = ChatGPTSpaceModel(testTap: tap)
                    let dm = ChatGPTConversationSession(tap: tap)
                    func send() {
                        switch surface {
                        case "Coder": coder.prompt = "fixture turn"; coder.send()
                        case "Space": space.draft = "fixture turn"; space.send()
                        default: dm.send("fixture turn")
                        }
                    }
                    func stopped() -> Bool {
                        surface == "Coder" ? !engine.isRunning(thread) : surface == "Space" ? !space.isSending : !dm.isSending
                    }
                    send()
                    try await wait { pod.sentIDs.count == 1 }
                    let id = pod.sentIDs[0]
                    if streaming { pod.emit(["type":"stream", "id":id, "kind":"text", "full":"partial fixture"]) }
                    await Task.yield()
                    switch surface {
                    case "Coder": coder.stop()
                    case "Space": space.stop()
                    default: dm.stop()
                    }
                    try await wait { pod.stopID != nil }
                    if timely { pod.emit(["type":"result", "id":pod.stopID!, "ok":true, "data":["submitted":true]]) }
                    try await wait { stopped() }
                    check(tap.connection == (timely ? .ready : .sleeping), "W194-1 \(tag) connection remains recoverable")
                    switch surface {
                    case "Coder":
                        check(engine.transcript(for: thread).last(where: { $0.role == .assistant })?.status == "cancelled|已停止"
                              && coder.modelPickerRouteLabel == "ChatGPT / Fixture Stop Model", "W194-1 \(tag) cancelled turn retains model label")
                    case "Space":
                        check(space.messages.last?.stopNotice == "已停止" && space.failure == nil, "W194-3 \(tag) neutral per-turn stop")
                    default:
                        check(dm.messages.last?.stopNotice == "已停止" && dm.state == .idle && dm.returnedDrafts.isEmpty,
                              "W194-3 \(tag) neutral per-turn stop; unknown send is never restored")
                    }
                    if !timely { check(tap.recoveryNotice == ChatGPTTap.stopRecoveryNotice, "W194-1 \(tag) recovery explanation") }
                    // 保持已選模型；Coder 與 DM 下一句從睡著的狀態直接送，不再選模。
                    send()
                    try await wait { pod.sentIDs.count == 2 }
                    pod.emit(["type":"stream", "id":pod.sentIDs[1], "kind":"text", "full":"next fixture succeeds"])
                    pod.emit(["type":"stream", "id":pod.sentIDs[1], "kind":"finished"])
                    try await wait { stopped() }
                    check(tap.connection == .ready && (timely || pod.starts == 1), "W194-1 \(tag) next send wakes exactly once and succeeds")
                    engine.shutdownAll()
                    tap.sleep()
                }
            }
        }
        for surface in ["Coder", "Space", "DM"] {
            let pod = Pod()
            // Each surface gets its own transport; no user data or singleton Pod.
            let realTap = ChatGPTTap(transport: pod, stopDeadline: .milliseconds(40))
            let folder = root.appendingPathComponent(UUID().uuidString)
            let engine = ChatLiveEngine(store: ChatLiveStore(root: folder), environment: env, tap: realTap)
            let thread = engine.newThread(in: nil)
            let coder = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: folder.appendingPathComponent("bots"))))
            coder.chatGPTTapConnectionTestDouble = { realTap.connection }
            coder.engineLoginTestDouble = []
            coder.selectedThreadID = thread
            engine.onChange = { coder.document = engine.document; coder.isRunning = engine.isRunning(thread) }
            coder.setSingleModel(route)
            let space = ChatGPTSpaceModel(testTap: realTap), dm = ChatGPTConversationSession(tap: realTap)
            var returned = ""
            dm.returned = { draft in returned = draft.text; return true }
            switch surface {
            case "Coder": coder.prompt = "proven unsent fixture"; coder.send()
            case "Space": space.draft = "proven unsent fixture"; space.send()
            default: dm.send("proven unsent fixture")
            }
            try await wait { pod.sentIDs.count == 1 }
            switch surface { case "Coder": coder.stop(); case "Space": space.stop(); default: dm.stop() }
            try await wait { pod.stopID != nil }
            pod.emit(["type":"result", "id":pod.stopID!, "ok":true, "data":["submitted":false]])
            try await wait { !engine.isRunning(thread) && !space.isSending && !dm.isSending }
            switch surface {
            case "Coder":
                // W203 stores the neutral stop on the reply instead of duplicating the provider reason in a system row.
                check(coder.prompt == "proven unsent fixture" && engine.transcript(for: thread).contains { $0.status == "cancelled|已停止" }
                      && engine.tapTurn[thread]?.failure == nil,
                      "W194-3 Coder proven pre-submit stop restores draft with a neutral note")
            case "Space":
                check(space.draft == "proven unsent fixture" && space.failure == nil && space.messages.isEmpty,
                      "W194-3 Space proven pre-submit stop restores draft without an error")
            default:
                check(returned == "proven unsent fixture" && dm.messages.isEmpty && dm.returnedDrafts.isEmpty && dm.state == .idle,
                      "W194-3 DM proven pre-submit stop restores the actual composer callback and removes unsent bubbles")
            }
            engine.shutdownAll(); realTap.sleep()
        }
        // Coder 已選模型後休眠：按送出立即清稿並排隊，啟動失敗則回稿。
        for fails in [false, true] {
            let pod = Pod(); pod.autoHello = !fails; pod.failStart = fails
            let tap = ChatGPTTap(transport: pod)
            let folder = root.appendingPathComponent(UUID().uuidString)
            let engine = ChatLiveEngine(store: ChatLiveStore(root: folder), environment: env, tap: tap)
            let thread = engine.newThread(in: nil)
            let coder = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: folder.appendingPathComponent("bots"))))
            coder.chatGPTTapConnectionTestDouble = { tap.connection }
            coder.chatGPTTapWakeTestDouble = { tap.start() }
            coder.engineLoginTestDouble = []
            coder.selectedThreadID = thread
            engine.onChange = { coder.document = engine.document; coder.isRunning = engine.isRunning(thread) }
            engine.onHint = { coder.flashComposerHint($0) }
            coder.catalogRefreshTestDouble = {}
            let loginCount = coder.catalogRefreshStartsForSelfTest
            coder.completeEngineLoginForSelfTest(.init(kind: .codex, isLoggedIn: true, account: nil, detail: "fixture"))
            check(coder.catalogRefreshStartsForSelfTest == loginCount + 1, "W194-11 successful login refreshes the model catalog")
            coder.completeEngineLoginForSelfTest(.init(kind: .codex, isLoggedIn: false, account: nil, detail: "fixture"))
            check(coder.catalogRefreshStartsForSelfTest == loginCount + 1, "W194-11 failed login never probes a model catalog")
            coder.setSingleModel(route)
            tap.sleep()
            coder.prompt = "sleeping fixture draft"
            check(coder.canSend, "W194-2 selected dormant model keeps send enabled failure=\(fails)")
            coder.send()
            check(coder.prompt.isEmpty && engine.isRunning(thread), "W194-2 dormant send queues immediately failure=\(fails)")
            if fails {
                try await wait { !engine.isRunning(thread) }
                check(coder.prompt == "sleeping fixture draft" && pod.sentIDs.isEmpty && coder.composerHint?.contains("沒有送出") == true,
                      "W194-2 wake failure restores draft with explanation")
            } else {
                try await wait {
                    // W203 separates preparation from accepted thinking; this fake Pod auto-accepts.
                    pod.sentIDs.count == 1 && engine.transcript(for: thread).last(where: { $0.role == .assistant })?.status == "writing|ChatGPT 思考中"
                }
                check(pod.starts == 1 && !engine.transcript(for: thread).contains { $0.text.contains("ChatGPT 啟動中") }
                      && engine.transcript(for: thread).last(where: { $0.role == .assistant })?.status == "writing|ChatGPT 思考中",
                      "W194-2 automatic dispatch replaces temporary startup without a permanent system row")
                pod.emit(["type":"stream", "id":pod.sentIDs[0], "kind":"finished"])
                try await wait { !engine.isRunning(thread) }
            }
            engine.shutdownAll(); tap.sleep()
        }
    }

    final class Pod: ChatGPTPodTransport {
        var onEvent: ((String) -> Void)?
        var isRunning = true
        var isHosted = false
        var stopID: String?
        var starts = 0
        var autoHello = false
        var failStart = false
        var delaysClose = false
        var isClosing = false
        func waitUntilClosed(timeout: Duration) async throws {
            let deadline = ContinuousClock().now.advanced(by: timeout)
            while isClosing, ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard !isClosing else { throw TapError.remote("fixture close timeout") }
        }
        var sentIDs: [String] = []
        var projectDescription = ""
        var projectName = "Fixture"
        func start() throws {
            starts += 1
            if failStart || isClosing { throw TapError.remote("fixture launch rejected") }
            isRunning = true
            if autoHello { Task { @MainActor in self.emit(["type":"hello", "loggedIn":true]) } }
        }
        func stop() { isRunning = false; if delaysClose { isClosing = true } }
        func run(_ script: String) {
            guard let range = script.range(of: ".command("),
                  let data = String(script[range.upperBound...].dropLast()).data(using: .utf8),
                  let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            guard let id = command["id"] as? String, let cmd = command["cmd"] as? String else { return }
            if cmd == "stop" { stopID = id; return }
            if cmd == "send" { sentIDs.append(id); return }
            let result: [String: Any]
            switch cmd {
            case "models": result = ["models":[["slug":"fixture-stop-model", "title":"Fixture Stop Model"]]]
            case "projects":
                result = ["items":projectDescription.isEmpty ? [] : [["id":"g-p-fixture", "title":projectName, "kind":"project", "description":projectDescription]]]
            case "createProject":
                projectName = command["name"] as? String ?? "Fixture"
                projectDescription = command["description"] as? String ?? ""
                result = ["id":"g-p-fixture", "title":command["name"] ?? "Fixture", "kind":"project", "description":projectDescription]
            case "projectDetails": result = ["id":"g-p-fixture", "title":"Fixture", "kind":"project", "description":projectDescription]
            default: result = ["items":[], "messages":[]]
            }
            emit(["type":"result", "id":id, "ok":true, "data":result])
        }
        func emit(_ event: [String: Any]) {
            if let data = try? JSONSerialization.data(withJSONObject: event), let json = String(data:data, encoding:.utf8) { onEvent?(json) }
        }
    }
}
#endif
