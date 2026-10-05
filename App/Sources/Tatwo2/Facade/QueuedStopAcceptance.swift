import Foundation

#if DEBUG
enum QueuedStopAcceptance {
    @MainActor final class Pod: ChatGPTPodTransport {
        var onEvent: ((String) -> Void)?
        var isRunning = true
        var isHosted = false
        var scripts: [String] = []
        func start() throws { isRunning = true }
        func stop() { isRunning = false }
        func run(_ script: String) { scripts.append(script) }
    }
    @MainActor static func run(check: (String, Bool) -> Void) async {
        let pod = Pod()
        let tap = ChatGPTTap(transport: pod, stopDeadline: .milliseconds(20))
        func send(_ text: String) -> AsyncStream<TapStreamEvent> {
            tap.send(text: text, conversationID: nil, model: "fixture", effort: nil,
                     attachments: [], tool: nil, gizmoID: nil, temporary: false, parentID: nil)
        }
        var held = send("fixture-held").makeAsyncIterator()
        guard let first = await held.next(), case .request(let heldID) = first else {
            check("send-08 held request fixture", false); return
        }
        var queued = send("fixture-queued").makeAsyncIterator()
        guard let second = await queued.next(), case .request(let queuedID) = second else {
            check("send-08 queued request fixture", false); return
        }
        let dispatched = pod.scripts.count
        tap.stop(requestID: queuedID)
        var notSubmitted = false, failed = false
        while let event = await queued.next() {
            switch event {
            case .notSubmitted: notSubmitted = true
            case .failed: failed = true
            default: break
            }
        }
        check("send-08 real TAP queued cancellation reports not submitted", notSubmitted && !failed)
        check("send-08 cancelled queued request never reaches Pod", pod.scripts.count == dispatched && dispatched == 1)
        tap.stop(requestID: heldID)
    }
}
#endif
