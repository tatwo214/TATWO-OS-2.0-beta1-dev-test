#if DEBUG
import Foundation
import SwiftUI
import AppKit

/// 只用隔離 root 與假 Pod；hello 必須在網頁未隱藏時才會出現。
@MainActor
enum W195WakeAcceptance {
    static func run(_ check: (Bool, String) -> Void) async throws {
        let env = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(env), NativeStagingIsolation.validationError(env) == nil,
              let live = env["TATWO2_LIVE_ROOT"] else { throw TapError.notReady }
        let root = URL(fileURLWithPath: live).appendingPathComponent("w195-wake")
        let previous = ChatGPTTapModelCatalog.snapshot
        defer { ChatGPTTapModelCatalog.replace(previous) }
        let route = ChatGPTTapModelCatalog.routeID("fixture-stop-model")
        ChatGPTTapModelCatalog.replace([TapModel(id: "fixture-stop-model", title: "Fixture Stop Model", detail: "")])
        do {
            let store = ChatLiveStore(root: root.appendingPathComponent("legacy-fixture"))
            var document = LiveDocumentRecord()
            var thread = LiveThreadRecord(projectID: document.ensureGeneralProject(), title: "Fixture")
            let text = "ChatGPT 啟動中，這句已排隊"
            thread.messages = [
                LiveMessageRecord(ChatMessage(role: .system, text: text, status: "info|ChatGPT")),
                LiveMessageRecord(ChatMessage(role: .user, text: text)),
                LiveMessageRecord(ChatMessage(role: .system, text: text, status: "info|fixture"))
            ]
            document.threads = [thread]
            store.save(document)
            let pod = Pod(), tap = ChatGPTTap(transport: pod, connection: .sleeping)
            let engine = ChatLiveEngine(store: store, environment: env, tap: tap)
            let visible = engine.transcript(for: thread.id)
            check(visible.count == 2 && visible.contains { $0.role == .user && $0.text == text }
                  && visible.contains { $0.status == "info|fixture" },
                  "W195-D persisted .054 startup notice is hidden while user quotations and other notes remain")
            engine.shutdownAll(); tap.sleep()
            check(store.load().threads.first?.messages.count == 3, "W195-D legacy startup filtering preserves every stored record")
        }

        for surface in ["Coder", "DM", "Space"] {
            let pod = Pod()
            pod.helloDelay = .seconds(5)
            let tap = ChatGPTTap(transport: pod, connection: .sleeping)
            let (engine, coder, thread) = makeCoder(tap, root: root, env: env, route: route)
            let dm = ChatGPTConversationSession(tap: tap), space = ChatGPTSpaceModel(testTap: tap)
            defer { engine.shutdownAll(); tap.sleep() }
            switch surface {
            case "Coder": coder.prompt = "wake fixture"; coder.send()
            case "DM": dm.send("wake fixture")
            default: space.draft = "wake fixture"; space.send()
            }
            _ = try await until(seconds: 1) { pod.starts == 1 }
            check(!pod.hidden && tap.hasActiveUsers, "W195-A \(surface) wake keeps the background renderer awake before hello")
            if surface == "Coder" {
                check(coder.isRunning && !coder.canSend && engine.isRunning(thread), "W195-E Coder waiting is running and selects the stop button")
                // W203 explicitly separates preparation from accepted thinking.
                check(engine.transcript(for: thread).contains { $0.status == "writing|ChatGPT 準備中" }
                      && !engine.transcript(for: thread).contains { $0.role == .system && $0.text.contains("啟動中") },
                      "W195-D queued reply remains running without reporting startup or appending a system row")
                try await composerEvidence(coder, artifact: "w195-waking")
                coder.prompt = "/issue 等待時的新草稿"
                check(coder.isRunning && coder.canSend, "W195-E waiting permits a local command without ending the TAP turn")
                try await composerEvidence(coder, artifact: "w195-waking-with-command")
                coder.prompt = ""
            }
            let sent = try await until(seconds: 6) { !pod.sentIDs.isEmpty }
            check(sent, "W195-A \(surface) hidden-sensitive hello dispatches within five seconds of wake")
            if let id = pod.sentIDs.first {
                check(pod.hiddenDispatches.isEmpty, "W195-A \(surface) preparation and metadata requests stay awake until stream dispatch")
                pod.emit(["type":"stream", "id":id, "kind":"text", "full":"wake fixture reply"])
                pod.emit(["type":"stream", "id":id, "kind":"finished"])
                _ = try await until(seconds: 1) { !engine.isRunning(thread) && !dm.isSending && !space.isSending }
            } else {
                switch surface { case "Coder": coder.stop(); case "DM": dm.stop(); default: space.stop() }
                _ = try await until(seconds: 1) { !engine.isRunning(thread) && !dm.isSending && !space.isSending }
            }
            switch surface {
            case "Coder":
                check(engine.transcript(for: thread).contains { $0.text == "wake fixture reply" && ($0.status == "done" || $0.status?.hasPrefix("done|已思考 ") == true) }
                      && !hasStartup(engine, thread), "W195-D successful Coder reply removes every startup hint")
            case "DM": check(dm.messages.last?.text == "wake fixture reply" && !dm.isSending, "W195-A DM dormant send completes through the shared TAP")
            default: check(space.messages.last?.text == "wake fixture reply" && !space.isSending, "W195-A Space dormant send completes through the shared TAP")
            }
            check(pod.hidden && !tap.hasActiveUsers, "W195-A \(surface) completion releases all background work and hides the idle renderer")
        }

        // 正式期限，不縮短：永遠沒有 hello 時必須約 60 秒收尾並可直接重試。
        do {
            let pod = Pod(); pod.helloDelay = nil
            let tap = ChatGPTTap(transport: pod, connection: .sleeping)
            let (engine, coder, thread) = makeCoder(tap, root: root, env: env, route: route)
            defer { engine.shutdownAll(); tap.sleep() }
            coder.prompt = "timeout fixture"; coder.send()
            let clock = ContinuousClock(), start = clock.now
            let settled = try await until(seconds: 70) { !engine.isRunning(thread) }
            let elapsed = start.duration(to: clock.now)
            check(settled && elapsed >= .seconds(55) && elapsed < .seconds(66), "W195-B absent hello settles near 60 seconds elapsed=\(elapsed)")
            check(coder.prompt == "timeout fixture" && coder.coderDeliveries[thread] == nil && pod.sentIDs.isEmpty,
                  "W195-B startup timeout restores the actual Coder draft without submitting")
            // W203 keeps only a fixed unsent category; provider text never becomes a system row.
            check(engine.transcript(for: thread).contains { $0.status == "error|沒有送出" }
                  && coder.chatGPTTurnState?.failure?.category == "沒有送出"
                  && !hasStartup(engine, thread) && !coder.isRunning && coder.canSend,
                  "W195-B timeout explains failure, clears startup and enables retry")
            pod.helloDelay = .milliseconds(100)
            coder.send()
            let retried = try await until(seconds: 2) { !pod.sentIDs.isEmpty }
            if let id = pod.sentIDs.first {
                pod.emit(["type":"stream", "id":id, "kind":"text", "full":"retry fixture reply"])
                pod.emit(["type":"stream", "id":id, "kind":"finished"])
            }
            _ = try await until(seconds: 1) { !engine.isRunning(thread) }
            check(retried && coder.prompt.isEmpty && !hasStartup(engine, thread)
                  && engine.transcript(for: thread).contains { $0.text == "retry fixture reply" && ($0.status == "done" || $0.status?.hasPrefix("done|已思考 ") == true) },
                  "W195-B timeout retry wakes again and delivers without selecting the model again")
        }
        for scenario in ["cancel", "immediate-cancel", "late-closed", "shutdown"] {
            let pod = Pod(); pod.helloDelay = nil
            let tap = ChatGPTTap(transport: pod, connection: .sleeping)
            let (engine, coder, thread) = makeCoder(tap, root: root, env: env, route: route)
            defer { engine.shutdownAll(); tap.sleep() }
            coder.prompt = "cancel fixture"; coder.send()
            if scenario != "immediate-cancel" { _ = try await until(seconds: 1) { pod.starts == 1 } }
            if scenario == "late-closed" {
                engine.tapSelfTestSidecarClosed(thread)
                check(engine.isRunning(thread) && coder.isRunning, "W195-F late CLI closed cannot clear a waking TAP turn")
                coder.prompt = "new fixture draft"; coder.send()
                check(engine.transcript(for: thread).filter { $0.role == .user }.count == 1,
                      "W195-F late CLI closed cannot admit a replacement turn and lose the original receipt")
                tap.sleep()
            } else if scenario == "shutdown" {
                engine.shutdownAll()
            } else { coder.stop() }
            let settled = try await until(seconds: 2) { coder.coderDeliveries[thread] == nil }
            check(settled && pod.sentIDs.isEmpty && !hasStartup(engine, thread), "W195-C \(scenario) terminal receipt always clears startup and settles delivery")
            if scenario == "late-closed" {
                check(coder.prompt == "new fixture draft" && coder.coderUndelivered?.text == "cancel fixture",
                      "W195-F old receipt preserves the newer typed draft and retains the unsent original")
            } else {
                check(coder.prompt == "cancel fixture" && !coder.isRunning,
                      "W195-C \(scenario) restores the draft before website submission")
                check(engine.transcript(for: thread).contains { $0.status == "cancelled|已停止" },
                      "W195-C \(scenario) retains the W194 neutral stopped explanation")
            }
            // 晚到 hello 不得把已停止的文字重新送出。
            pod.emit(["type":"hello", "loggedIn":true])
            try await Task.sleep(for: .milliseconds(100))
            check(pod.sentIDs.isEmpty, "W195-C \(scenario) late hello never submits the cancelled turn")
        }
        // 關閉後立即續送：上一輪回執能回稿，但不能清掉新 runner 或通知新回合已結束。
        do {
            let pod = Pod(); pod.helloDelay = nil
            let tap = ChatGPTTap(transport: pod, connection: .sleeping)
            let (engine, coder, thread) = makeCoder(tap, root: root, env: env, route: route)
            defer { engine.shutdownAll(); tap.sleep() }
            coder.prompt = "old fixture"; coder.send()
            _ = try await until(seconds: 1) { pod.starts == 1 }
            let originalTurn = engine.transcript(for: thread).first?.turnID
            engine.shutdownAll()
            var newerCompletions = 0
            engine.onTurnComplete[thread] = { _, _ in newerCompletions += 1 }
            coder.prompt = "replacement fixture"; coder.send()
            coder.prompt = "keep this newly typed fixture"
            let returned = try await until(seconds: 2) { coder.coderUndelivered?.text == "old fixture" }
            check(returned && engine.isRunning(thread) && coder.coderDeliveries[thread]?.text == "replacement fixture"
                  && newerCompletions == 0 && coder.prompt == "keep this newly typed fixture",
                  "W195-F old shutdown receipt settles its draft without ending a replacement TAP turn")
            check(engine.transcript(for: thread).contains { $0.role == .assistant && $0.status == "cancelled|已停止" && $0.turnID == originalTurn },
                  "W195-F late terminal explanation remains attached to the original turn")
            coder.stop()
            _ = try await until(seconds: 2) { coder.coderDeliveries[thread] == nil }
            check(!engine.isRunning(thread) && newerCompletions == 1, "W195-F replacement turn receives exactly its own terminal notification")
        }
    }

    private static func makeCoder(_ tap: ChatGPTTap, root: URL, env: [String:String], route: String) -> (ChatLiveEngine, ChatPageModel, UUID) {
        let folder = root.appendingPathComponent(UUID().uuidString)
        let engine = ChatLiveEngine(store: ChatLiveStore(root: folder), environment: env, tap: tap)
        let thread = engine.newThread(in: nil)
        let coder = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: folder.appendingPathComponent("bots"))))
        coder.chatGPTTapConnectionTestDouble = { tap.connection }
        coder.chatGPTTapWakeTestDouble = {} // 已選模型後休眠；選模型不能偷偷替本測試預熱。
        coder.engineLoginTestDouble = []
        coder.selectedThreadID = thread
        engine.onChange = { [weak coder, weak engine] in
            guard let coder, let engine else { return }
            coder.document = engine.document; coder.isRunning = engine.isRunning(thread)
        }
        coder.setSingleModel(route)
        return (engine, coder, thread)
    }

    private static func hasStartup(_ engine: ChatLiveEngine, _ thread: UUID) -> Bool {
        engine.transcript(for: thread).contains { $0.text.contains("啟動中") || $0.status?.contains("啟動中") == true || $0.status?.contains("排隊中") == true }
    }
    private static func composerEvidence(_ coder: ChatPageModel, artifact: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["TATWO2_SELFTEST_ARTIFACTS"] else { throw TapError.notReady }
        let page = ChatPage(model: coder)
        let rig = TatwoComposerModeAcceptance.ClickRig(VStack(spacing: 12) {
            page.composerToolbar(compactToolbar: false)
            page.composerStatusBar
        }.padding(16), size: CGSize(width: 900, height: 120))
        defer { rig.close() }
        // 全透明地放在螢幕內，避免 offscreen hosting 偶爾只擷取到白底。
        _ = rig.moveOnScreen()
        var png: Data?
        for _ in 0..<30 {
            await rig.settle(2)
            if let shot = rig.capture(), let ink = GlobalDMChatAcceptance.ink(shot), ink.width > 30, ink.height > 6 {
                png = shot.bitmap.representation(using: .png, properties: [:])
                break
            }
        }
        guard let png, !png.isEmpty else {
            throw TapError.remote("W195 native composer did not render")
        }
        let url = URL(fileURLWithPath: path).appendingPathComponent(artifact + ".png")
        try png.write(to: url)
        print("W195 PNG \(url.path)")
    }
    private static func until(seconds: Double, _ condition: () -> Bool) async throws -> Bool {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(seconds))
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    final class Pod: ChatGPTPodTransport {
        private let responses = W194FixAcceptance.Pod()
        init() { responses.stop() }
        var onEvent: ((String) -> Void)? {
            get { responses.onEvent }
            set { responses.onEvent = newValue }
        }
        var isRunning: Bool { responses.isRunning }
        let isHosted = false
        var hidden = true
        var starts: Int { responses.starts }
        var sentIDs: [String] { responses.sentIDs }
        private(set) var hiddenDispatches: [String] = []
        var helloDelay: Duration? = .milliseconds(100)
        private var helloTask: Task<Void, Never>?
        func setBackgroundWorkActive(_ active: Bool) { hidden = !active }
        func setSpaceVisible(_ visible: Bool) {}
        func start() throws {
            try responses.start()
            guard let helloDelay else { return }
            helloTask = Task { @MainActor in
                do {
                    while hidden { try await Task.sleep(for: .milliseconds(10)) }
                    try await Task.sleep(for: helloDelay)
                    guard !hidden, isRunning else { return }
                    emit(["type":"hello", "loggedIn":true])
                } catch {}
            }
        }
        func stop() { helloTask?.cancel(); responses.stop() }
        func run(_ script: String) {
            if hidden { hiddenDispatches.append("fixture command") }
            responses.run(script)
        }
        func emit(_ event: [String:Any]) { responses.emit(event) }
    }
}
#endif
