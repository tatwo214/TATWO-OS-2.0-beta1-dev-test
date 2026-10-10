import Foundation

@main struct GroupFixTests {
    @MainActor static func main() async throws {
        var failures = 0
        func check(_ ok: Bool, _ name: String) { print("W225B4CORE \(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }
        var sent: [String: [String]] = [:]
        let peers = ["Codex", "Other"].map { id in
            GroupParticipant(id: id, timeout: 0, invoke: { text, done in
                sent[id, default: []].append(text); done(.success("plain reply"))
            }, stop: {})
        }
        let lag = GroupTurnEngine(threadID: UUID(), primary: "Codex", participants: peers)
        lag.lagLimit = 2
        lag.seed((0..<20).map { ("使用者", "seed-\($0) " + String(repeating: "full detail ", count: 60)) })
        _ = lag.human("@@Other catchup")
        check(sent["Other"]?.count == 1 && sent["Other"]!.last!.contains("進度：") && sent["Other"]!.last!.contains("詳情"), "1 lagging one-shot member receives exactly one progress delivery")
        let pointers = sent["Other"]!.first!.components(separatedBy: "cursor=").dropFirst().map { String($0.prefix { $0 != ")" }) }
        check(!pointers.isEmpty && pointers.allSatisfy { $0.hasPrefix(lag.threadID.uuidString + ":") }, "2 every detail cursor uses thread-bound row format")
        var queuedSends: [String] = [], completions: [(Result<String, Error>) -> Void] = []
        let queue = GroupTurnEngine(threadID: UUID(), primary: "Coder", participants: [GroupParticipant(id: "Coder", timeout: 0, invoke: { text, done in queuedSends.append(text); completions.append(done) }, stop: {})], exchangeLimit: 0)
        _ = queue.human("current")
        check(queue.human("queued-one") && queue.human("queued-two") && queue.queuedHumanCount == 2 && queue.events.filter { $0.kind == "queued" }.map(\.text) == ["queued-one", "queued-two"], "3 both busy messages enter queue and ledger")
        completions.removeFirst()(.success("finished"))
        check(queuedSends.count == 2 && queuedSends.last!.components(separatedBy: "queued-one").count == 2 && queuedSends.last!.components(separatedBy: "queued-two").count == 2 && queue.events.last { $0.speaker == "使用者" && $0.kind == "message" }?.text == "queued-one\nqueued-two", "3 next turn delivers both messages once as merged human")
        queue.stop()
        print("W225B4CORE SUMMARY failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
