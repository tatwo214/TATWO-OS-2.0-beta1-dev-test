import Foundation

#if DEBUG
enum RestartFlowAcceptance {
    final class Caller: RemoteLiveCalling, @unchecked Sendable {
        let lock = NSLock()
        private var reply: [String: Any]
        init(_ reply: [String: Any]) { self.reply = reply }
        func replace(_ reply: [String: Any]) { lock.lock(); self.reply = reply; lock.unlock() }
        func call(method: String, params: [String: Any]) throws -> [String: Any] {
            lock.lock(); defer { lock.unlock() }; return reply
        }
    }
    @MainActor static func run(root: URL, env: [String: String], check: (String, Bool) -> Void) async throws {
        let store = ChatLiveStore(root: root)
        var document = LiveDocumentRecord()
        let turn = "fixture-turn"
        var thread = LiveThreadRecord(title: "fixture")
        thread.subStatus = "running"
        thread.messages = [
            LiveMessageRecord(ChatMessage(role: .assistant, text: "sample", status: "writing|回覆中", turnID: turn)),
            LiveMessageRecord(ChatMessage(role: .assistant, text: "fixture_tool", status: "running-command|fixture_tool", eventKind: .toolUse, turnID: turn)),
        ]
        document.threads = [thread]; document.selectedThreadID = thread.id
        store.save(document)
        let reopened = ChatLiveEngine(store: store, environment: env)
        check("send-05 restart cancels stale writing and tool rows", !reopened.transcript(for: thread.id).contains {
            $0.status?.hasPrefix("writing") == true || $0.status?.hasPrefix("running-command") == true
        })
        check("send-05 restart ends stale room status", reopened.threadRecord(thread.id)?.subStatus == "done")
        check("send-05 restart leaves interruption explanation", reopened.transcript(for: thread.id).contains {
            $0.role == .system && $0.text.contains("App 重開")
        })
        _ = reopened.appendOfflineRows(threadID: thread.id, rows: [ChatMessage(role: .assistant,
            text: "fixture stale tool", status: "running-command|fixture_tool", eventKind: .toolUse)])
        reopened.stop(threadID: thread.id)
        check("send-05 stop without a runner settles stale tool rows", !reopened.transcript(for: thread.id).contains {
            $0.status?.hasPrefix("running-command") == true
        })
        check("send-05 stop without a runner explains that the turn no longer exists", reopened.transcript(for: thread.id).contains {
            $0.role == .system && $0.text.contains("引擎已不存在")
        })
        reopened.shutdownAll()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let raw = try JSONSerialization.jsonObject(with: encoder.encode(document))
        let modern: [String: Any] = ["document": raw, "revision": 1, "runningThreadIDs": [] as [String]]
        let remote = try RemoteLiveEngine(link: RemoteHostLink(environment: env), callingThrough: Caller(modern),
            store: ChatLiveStore(root: root.appendingPathComponent("remote-fixture")), initial: modern)
        check("send-05 authoritative empty running list overrides stale transcript", !remote.isRunning(thread.id))
        remote.shutdownAll()
        let legacy: [String: Any] = ["document": raw, "revision": 1]
        let old = try RemoteLiveEngine(link: RemoteHostLink(environment: env), callingThrough: Caller(legacy),
            store: ChatLiveStore(root: root.appendingPathComponent("legacy-fixture")), initial: legacy)
        check("send-05 older host keeps transcript fallback", old.isRunning(thread.id))
        old.shutdownAll()
        var busy = modern; busy["runningThreadIDs"] = [thread.id.uuidString]
        let caller = Caller(busy)
        let polled = try RemoteLiveEngine(link: RemoteHostLink(environment: env), callingThrough: caller,
            store: ChatLiveStore(root: root.appendingPathComponent("poll-fixture")), initial: busy)
        check("send-05 host-owned running turn stays busy", polled.isRunning(thread.id))
        var changed = false
        polled.onChange = { changed = true }
        caller.replace(modern)
        for _ in 0..<350 {
            if !polled.isRunning(thread.id) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        check("send-05 unchanged revision still updates running state and toolbar", !polled.isRunning(thread.id) && changed)
        polled.shutdownAll()
    }
}
#endif
