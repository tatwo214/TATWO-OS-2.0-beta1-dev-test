import Foundation
@main struct GroupTests {
    @MainActor static func main() async {
        var failed = 0
        func check(_ ok: Bool, _ name: String) {
            print("W225CORE \(ok ? "PASS" : "FAIL") \(name)"); if !ok { failed += 1 }
        }
        func settle(_ engine: GroupTurnEngine) async {
            for _ in 0..<300 where engine.busy { try? await Task.sleep(for: .milliseconds(5)) }
        }
        var sent: [String: [String]] = [:]
        var held: [String: (Result<String, Error>) -> Void] = [:]
        var stops: [String] = []
        func member(_ id: String, hold: Bool = false, reply: String = "fixed reply") -> GroupParticipant {
            GroupParticipant(id: id, join: id == "ChatGPT", invoke: { payload, done in
                sent[id, default: []].append(payload)
                if hold { held[id] = done } else { done(.success(reply)) }
            }, stop: { stops.append(id) })
        }
        let solitary = GroupTurnEngine(threadID: UUID(), primary: "Codex", participants: [member("Codex"), member("ChatGPT"), member("Other")])
        check(solitary.human("alone"), "human accepted")
        await settle(solitary)
        check(sent["Codex"]?.count == 1 && sent["ChatGPT"] == nil && sent["Other"] == nil, "uncalled AI zero calls")
        let engine = GroupTurnEngine(threadID: UUID(), primary: "Codex", participants: [member("Codex"), member("ChatGPT"), member("Other")])
        check(engine.human("@@ChatGPT join"), "join accepted")
        await settle(engine)
        check(sent["ChatGPT"]?.filter { $0.contains("read_session") && $0.contains("加入") }.count == 1, "join once with read_session")
        check(engine.collaborating.contains("ChatGPT") && engine.events.contains { $0.kind == "summary" }, "summary event and collaboration")
        let eventNumbers = try! NSRegularExpression(pattern: "#([0-9]+) ")
        func sequences(_ payload: String) -> [Int] {
            eventNumbers.matches(in: payload, range: NSRange(payload.startIndex..., in: payload)).compactMap { match in
                Range(match.range(at: 1), in: payload).flatMap { Int(payload[$0]) }
            }
        }
        var seen = Dictionary(uniqueKeysWithValues: ["Codex", "ChatGPT"].map { ($0, Set(sent[$0, default: []].suffix(2).flatMap(sequences))) })
        let initialJoins = sent["ChatGPT"]?.filter { $0.contains("加入") }.count
        for round in 2...30 {
            let marker = String(format: "human-%02d", round)
            check(engine.human(marker), "round \(round) accepted")
            await settle(engine)
            check(engine.autoExchanges == 1 && !engine.exchange(), "one exchange phase, second blocked")
            if [2,10,30].contains(round) { print("W225CORE ACCOUNT round=\(round) participant=使用者 sent=\(engine.accounting[engine.turn]?["使用者"]?.sent ?? -1) received=\(engine.accounting[engine.turn]?["使用者"]?.received ?? -1)") }
            for id in ["Codex", "ChatGPT"] {
                let payloads = Array(sent[id, default: []].suffix(2))
                let ids = payloads.flatMap(sequences)
                check(ids.allSatisfy { seen[id, default: []].insert($0).inserted }, "\(id) every delivered event cursor is new")
                check(payloads.filter { $0.contains(marker) }.count == 1, "\(id) new human delivered once")
                check(payloads.allSatisfy { !$0.contains("alone") && !$0.contains("@@ChatGPT join") }, "\(id) no history replay")
                if [2,10,30].contains(round) {
                    let count = engine.accounting[engine.turn]?[id]?.sent ?? -1
                    print("W225CORE ACCOUNT round=\(round) participant=\(id) sent=\(count) received=\(engine.accounting[engine.turn]?[id]?.received ?? -1)")
                }
            }
        }
        check(initialJoins == sent["ChatGPT"]?.filter { $0.contains("加入") }.count, "no repeated join")
        for id in ["Codex", "ChatGPT"] {
            let second = engine.accounting[2]?[id]?.sent ?? 0
            let last = engine.accounting[30]?[id]?.sent ?? 1
            check(Double(last) <= Double(second) * 1.5, "\(id) bounded round 30/2")
        }
        check(sent["Other"] == nil && engine.accounting.values.allSatisfy { ($0["Other"]?.sent ?? 0) == 0 }, "uncalled participant stays at zero calls and zero characters for all 30 turns")
        check(engine.events.map(\.sequence) == Array(1...engine.events.count), "stable unique event sequence")
        check(engine.events.filter { $0.kind == "pending" }.isEmpty, "no dropped replies")
        let stalled = GroupTurnEngine(threadID: UUID(), primary: "Codex", participants: [member("Codex"), member("ChatGPT", hold: true)], timeout: 0.05)
        _ = stalled.human("@@ChatGPT timeout")
        check(stalled.events.contains { $0.speaker == "Codex" && $0.text == "fixed reply" }, "Coder completes before slow TAP")
        await settle(stalled)
        check(stalled.events.contains { $0.speaker == "ChatGPT" && $0.kind == "failure" && !$0.text.contains("\n") }, "timeout in place")
        let before = stalled.events
        held["ChatGPT"]?(.success("late reply"))
        check(stalled.events == before, "late reply ignored")
        let stop = GroupTurnEngine(threadID: UUID(), primary: "Codex", participants: [member("Codex", hold: true), member("ChatGPT", hold: true)])
        _ = stop.human("@@ChatGPT stop")
        let start = Date(); stop.stop()
        check(!stop.busy && stops.contains("Codex") && stops.contains("ChatGPT") && Date().timeIntervalSince(start) < 3, "both stop within 3 seconds")
        for direction in ["Codex", "ChatGPT"] {
            var calls: [String: Int] = [:]
            let peers = ["Codex", "ChatGPT"].map { id in
                GroupParticipant(id: id, join: false, invoke: { _, done in
                    calls[id, default: 0] += 1
                    done(.success(id == direction ? (id == "Codex" ? "@@ChatGPT ask" : "@Codex ask") : "plain"))
                }, stop: {})
            }
            let explicit = GroupTurnEngine(threadID: UUID(), primary: direction, participants: peers)
            _ = explicit.human("named turn"); await settle(explicit)
            check(calls[direction] == 1 && calls[direction == "Codex" ? "ChatGPT" : "Codex"] == nil, "\(direction) reply mention cannot join an unjoined participant")
        }
        let plain = GroupTurnEngine(threadID: UUID(), primary: "Codex", participants: [member("Codex", reply: "@ChatGPTish ignored"), member("ChatGPT")])
        let beforeCalls = sent["ChatGPT", default: []].count
        _ = plain.human("plain"); await settle(plain)
        check(sent["ChatGPT", default: []].count == beforeCalls, "partial name does not route")
        let archived = try! engine.snapshot()
        let restored = GroupTurnEngine(threadID: engine.threadID, primary: "Codex", participants: [member("Codex"), member("ChatGPT")])
        try! restored.restore(archived, content: { engine.events[$0.sequence - 1].text })
        check(restored.events == engine.events && restored.cursors == engine.cursors && restored.collaborating == engine.collaborating, "ledger restores events, cursors and collaboration")
        let joinsBefore = sent["ChatGPT", default: []].filter { $0.contains("加入") }.count
        _ = restored.human("restored human"); await settle(restored)
        check(sent["ChatGPT", default: []].filter { $0.contains("加入") }.count == joinsBefore, "restored member is not rejoined")
        var delayedSends: [String: [String]] = [:]
        var delayedDone: [String: (Result<String, Error>) -> Void] = [:]
        var delayedTime: TimeInterval = 0
        let delayed = GroupTurnEngine(threadID: UUID(), primary: "Codex", participants: ["Codex", "ChatGPT"].map { id in
            GroupParticipant(id: id, invoke: { text, done in delayedSends[id, default: []].append(text); delayedDone[id] = done }, stop: {})
        }, clock: { delayedTime += 1; return Date(timeIntervalSince1970: delayedTime) })
        _ = delayed.human("@@ChatGPT same-human")
        let firstCodex = delayedDone["Codex"]!, firstTap = delayedDone["ChatGPT"]!
        check(delayedSends.values.allSatisfy { $0.count == 1 && $0[0].contains("same-human") }, "both dispatched before any reply")
        firstTap(.success("@Codex ask"))
        check(delayedSends["Codex"]?.count == 1 && delayed.busy, "exchange waits for both without dropping fast reply")
        firstCodex(.success("@@ChatGPT ask"))
        firstTap(.success("duplicate")); firstCodex(.success("duplicate"))
        delayedDone["ChatGPT"]?(.success("plain")); delayedDone["Codex"]?(.success("plain"))
        check(delayed.events.map(\.speaker) == ["使用者", "Codex", "ChatGPT", "Codex", "ChatGPT"] && !delayed.events.contains { $0.text == "duplicate" } && !delayed.busy, "reverse arrival still stable, duplicate completions ignored")
        let long = GroupTurnEngine(threadID: UUID(), primary: "Codex", participants: [member("Codex")])
        _ = long.human(String(repeating: "long content ", count: 500))
        check(sent["Codex"]?.last?.contains("read_session(thread_id=") == true && (sent["Codex"]?.last?.count ?? 9999) <= 1200, "long content uses summary and pointer within 1200 characters")
        let lagging = GroupTurnEngine(threadID: UUID(), primary: "Codex", participants: [member("Codex"), member("Other")])
        lagging.lagLimit = 2
        lagging.seed((0..<20).map { ("使用者", "seed-\($0) " + String(repeating: "full detail ", count: 60)) })
        _ = lagging.human("@@Other catchup"); await settle(lagging)
        let progress = sent["Other"]!.last!
        let lines = progress.components(separatedBy: "進度：\n").last!.components(separatedBy: "\n\n").first!.split(separator: "\n")
        check(lines.count <= 12 && progress.contains("read_session(thread_id=") && progress.count <= 1200, "lagging member receives at most 12 progress lines and detail pointer")
        let priorManual = sent["Codex", default: []].count
        check(restored.continueRound(), "explicit continue entry opens one more exchange")
        await settle(restored)
        check(sent["Codex", default: []].count == priorManual + 1 && !restored.exchange(), "manual continuation is bounded again")
        var configurableCalls: [String: Int] = [:]
        let configurable = GroupTurnEngine(threadID: UUID(), primary: "Codex", participants: ["Codex", "ChatGPT"].map { id in
            GroupParticipant(id: id, join: id == "ChatGPT", invoke: { _, done in configurableCalls[id, default: 0] += 1; done(.success("fixed")) }, stop: {})
        }, exchangeLimit: 2)
        _ = configurable.human("@@ChatGPT configurable"); await settle(configurable)
        check(configurable.autoExchanges == 2 && configurableCalls.values.allSatisfy { $0 == 3 }, "exchange budget is configurable")
        print("W225CORE SUMMARY failures=\(failed)"); exit(failed == 0 ? 0 : 1)
    }
}
