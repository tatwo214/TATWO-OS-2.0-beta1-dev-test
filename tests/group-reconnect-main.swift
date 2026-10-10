import Foundation

@MainActor final class Fixture {
    var now = Date(timeIntervalSince1970: 1_791_187_200)
    var sent: [String: [String]] = [:]
    var held: [String: [(Result<String, Error>) -> Void]] = [:]
    var stops: [String] = []
    var unavailable: String?
    var missingConversation = false
    var hold: Set<String> = []
    var engine: GroupTurnEngine!
    init(tap: String = "Fixture", exchange: Int = 0, thread: UUID = UUID()) {
        engine = GroupTurnEngine(threadID: thread, primary: "Coder", participants: ["Coder", tap].map { id in
            GroupParticipant(id: id, join: id != "Coder", timeout: 0, unavailable: { [unowned self] in id == "Coder" ? nil : self.unavailable }, invoke: { [unowned self] text, done in
                self.sent[id, default: []].append(id != "Coder" && self.missingConversation ? self.engine.restartConversation(id, replacing: text) ?? text : text)
                if self.hold.contains(id) { self.held[id, default: []].append(done) }
                else { done(.success("\(id) reply")) }
            }, stop: { [unowned self] in self.stops.append(id) })
        }, exchangeLimit: exchange, clock: { [unowned self] in self.now })
    }
    func finish(_ id: String = "Fixture", _ result: Result<String, Error> = .success("finished reply")) {
        guard !held[id, default: []].isEmpty else { return }
        held[id]!.removeFirst()(result)
    }
    var calls: Int { sent.values.reduce(0) { $0 + $1.count } }
}

@main struct GroupReconnectTests {
    @MainActor static func main() async throws {
        var failed = 0
        func check(_ ok: Bool, _ name: String) {
            print("W225B2CORE \(ok ? "PASS" : "FAIL") \(name)"); if !ok { failed += 1 }
        }
        let generic = Fixture(tap: "OtherTap")
        check(generic.engine.state("OtherTap") == .unjoined && generic.engine.cursors["OtherTap"] == nil, "four states: initially unjoined, no cursor")
        _ = generic.engine.human("@@OtherTap join")
        check(generic.engine.state("OtherTap") == .collaborating && generic.sent["OtherTap"]?.count == 1, "new TAP code joins and speaks without changing engine")
        let beforeLeave = generic.calls, beforeCursor = generic.engine.cursors["OtherTap"]!
        let proposal = generic.engine.record(speaker: "OtherTap", text: "proposed change", kind: "proposal")
        _ = generic.engine.human("@@OtherTap 離開")
        check(generic.calls == beforeLeave && generic.engine.state("OtherTap") == .left, "leave command makes zero AI calls")
        let handoff = generic.engine.membership["OtherTap"]!.handoff
        check(handoff.contains("第 \(beforeCursor) 筆") && handoff.contains("OtherTap reply") && handoff.contains("#\(proposal)") && handoff.split(separator: "\n").count <= 3, "handoff comes from read cursor, last reply and pending proposal")
        _ = generic.engine.human("plain human")
        check(generic.sent["OtherTap"]?.count == 1 && generic.engine.cursors["OtherTap"] == beforeCursor, "left member remains left until human names it")
        let unknownCalls = generic.calls
        _ = generic.engine.human("@@Missing")
        check(generic.calls == unknownCalls + 1 && generic.engine.events.contains { $0.text == "這台沒有連這個 TAP" } && generic.engine.events.last { $0.speaker == "使用者" }?.text == "@@Missing", "unknown name replies in place and preserves original human for primary")
        let unknownAI = Fixture(); unknownAI.hold = ["Coder"]
        _ = unknownAI.engine.human("plain"); unknownAI.finish("Coder", .success("@@Missing"))
        check(unknownAI.engine.events.last?.text == "這台沒有連這個 TAP" && unknownAI.calls == 1, "AI names unknown TAP: reason without extra calls")
        let prefixAI = Fixture(tap: "OtherTap", exchange: 1); prefixAI.hold = ["Coder"]
        _ = prefixAI.engine.human("plain"); prefixAI.finish("Coder", .success("@@OtherTap-not-connected"))
        check(prefixAI.sent["OtherTap"] == nil, "unknown hyphenated TAP code never routes to a prefix member")
        let simultaneous = Fixture(tap: "Alpha"); _ = simultaneous.engine.human("@@Alpha join")
        check(simultaneous.engine.events[1].speaker == "Alpha" && simultaneous.engine.events[2].speaker == "Coder", "same clock time resolves participant order by code")
        generic.engine.resolveProposal(proposal, applied: true)
        _ = generic.engine.human("@@OtherTap return")
        check(generic.engine.state("OtherTap") == .collaborating && generic.sent["OtherTap"]!.last!.contains("已套用") && !generic.sent["OtherTap"]!.last!.contains("請先用"), "human reconnect sends proposal result without join summary")

        let leaving = Fixture(); leaving.hold = ["Fixture"]
        _ = leaving.engine.human("@@Fixture first")
        let active = leaving.held["Fixture"]!.first!
        let leavingCalls = leaving.calls
        _ = leaving.engine.human("@@Fixture 離開")
        check(leaving.engine.busy && leaving.stops.isEmpty && leaving.calls == leavingCalls && leaving.engine.state("Fixture") == .unjoined, "leave waits for running first step without interrupt or calls")
        active(.success("last line\nsecond line"))
        check(leaving.engine.state("Fixture") == .left && leaving.engine.events.contains { $0.text == "last line\nsecond line" }, "running reply completes normally before state changes")
        check(leaving.engine.membership["Fixture"]!.handoff.contains("last line second line") && leaving.engine.membership["Fixture"]!.handoff.split(separator: "\n").count == 3, "multiline last reply still yields three handoff lines")
        let apiLeave = Fixture(); _ = apiLeave.engine.human("@@Fixture join"); let apiCalls = apiLeave.calls
        apiLeave.engine.leave("Fixture")
        check(apiLeave.calls == apiCalls && apiLeave.engine.state("Fixture") == .left, "participant label engine entry leaves without AI")

        let away = Fixture(); _ = away.engine.human("@@Fixture join"); away.hold = ["Fixture"]
        let error = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture timeout"])
        _ = away.engine.human("one"); away.finish("Fixture", .failure(error))
        check(away.engine.state("Fixture") == .collaborating, "first timeout leaves participant collaborating")
        let read = away.engine.cursors["Fixture"]!
        _ = away.engine.human("two"); away.finish("Fixture", .failure(error))
        check(away.engine.state("Fixture") == .away && away.engine.events.last?.text.contains("fixture timeout") == true && away.engine.cursors["Fixture"] == read, "second consecutive error moves away with reason and frozen cursor")
        check(away.sent["Coder"]?.count == 3 && !away.engine.busy, "primary completes during both TAP errors")
        away.unavailable = "offline"
        let idleCalls = away.calls; away.now += 600
        check(away.calls == idleCalls, "ten idle minutes on fake clock make zero calls")
        _ = away.engine.human("still offline")
        check(away.sent["Coder"]?.count == 4 && away.sent["Fixture"]?.count == 3 && away.engine.state("Fixture") == .away, "offline TAP never blocks primary")
        away.unavailable = nil
        check(away.calls == idleCalls + 1, "restored connection while idle makes zero calls")
        _ = away.engine.human("recovered human")
        check(away.sent["Fixture"]?.count == 4 && away.sent["Fixture"]!.last!.contains("交接：") && !away.sent["Fixture"]!.last!.contains("請先用"), "away participant reconnects on next human turn")
        away.finish()
        let unavailable = Fixture(); _ = unavailable.engine.human("@@Fixture join"); unavailable.unavailable = "login expired"
        _ = unavailable.engine.human("next")
        check(unavailable.engine.state("Fixture") == .away && unavailable.sent["Fixture"]?.count == 1 && unavailable.engine.events.contains { $0.kind == "away" && $0.text.contains("login expired") }, "adapter unavailability moves away immediately")
        let resetErrors = Fixture(); _ = resetErrors.engine.human("@@Fixture join"); resetErrors.hold = ["Fixture"]
        _ = resetErrors.engine.human("err1"); resetErrors.finish("Fixture", .failure(error))
        _ = resetErrors.engine.human("ok"); resetErrors.finish()
        _ = resetErrors.engine.human("err2"); resetErrors.finish("Fixture", .failure(error))
        check(resetErrors.engine.state("Fixture") == .collaborating, "success resets consecutive error count")

        for lag in [5, 20, 200] {
            let reconnect = Fixture(thread: UUID(uuidString: "00000000-0000-4000-8000-000000000225")!); _ = reconnect.engine.human("@@Fixture join")
            reconnect.engine.leave("Fixture")
            let cursor = reconnect.engine.cursors["Fixture"]!
            while reconnect.engine.events.count - cursor < lag - 1 {
                reconnect.engine.record(speaker: "Coder", text: "progress-\(reconnect.engine.events.count) " + String(repeating: "long ", count: 100))
            }
            reconnect.now += 67 * 60
            reconnect.hold = ["Fixture"]
            _ = reconnect.engine.human("@@Fixture reconnect")
            let text = reconnect.sent["Fixture"]!.last!
            check(text.count <= 2400 && text.hasPrefix("現在第") && text.contains("交接：") && !text.contains("cursor=0)") && text.contains("cursor=\(reconnect.engine.threadID):0)") && !text.contains("請先用"), "lag \(lag) opening <=2400, time and own handoff, no rejoin history")
            check(reconnect.engine.cursors["Fixture"] == reconnect.engine.events.count - 2, "lag \(lag) cursor advances to latest delivery snapshot")
            if lag <= 20 {
                check(!text.contains("進度："), "lag \(lag) uses short delta")
            } else {
                let progress = text.components(separatedBy: "進度：\n").last!.components(separatedBy: "\n\n").first!
                check(progress.split(separator: "\n").count <= 12 && text.contains("read_session(thread_id=") && text.contains("cursor=\(reconnect.engine.threadID):0)"), "lag 200 uses <=12 progress lines and cursor pointer")
            }
            print("W225B2CORE OPENING lag=\(lag) characters=\(text.count)")
            reconnect.finish()
            _ = reconnect.engine.human("after opening")
            check(!reconnect.sent["Fixture"]!.last!.contains("交接："), "lag \(lag) reconnect opening only once")
        }

        let timed = Fixture(); _ = timed.engine.human("@@Fixture join")
        let lastRead = timed.engine.cursors["Fixture"]!
        timed.now += 120
        _ = timed.engine.human("two minutes")
        let timeText = timed.sent["Fixture"]!.last!
        check(timeText.contains("上次讀到第 \(lastRead) 筆") && timeText.contains("中間 3 筆、2 分鐘") && timed.engine.events.allSatisfy { $0.time != nil }, "time line reports accurate event count and minutes with injected clock")
        let archived = try timed.engine.snapshot()
        let reopened = Fixture(); try reopened.engine.restore(archived, content: { timed.engine.events[$0.sequence - 1].text })
        check(reopened.engine.events == timed.engine.events && reopened.engine.cursors == timed.engine.cursors && reopened.engine.state("Fixture") == .collaborating, "Ledger restores time, cursor and active state")
        timed.engine.leave("Fixture"); try reopened.engine.restore(timed.engine.snapshot(), content: { timed.engine.events[$0.sequence - 1].text })
        check(reopened.engine.state("Fixture") == .left && reopened.engine.membership["Fixture"]?.handoff == timed.engine.membership["Fixture"]?.handoff, "Ledger restores left state and handoff")
        try reopened.engine.restore(unavailable.engine.snapshot())
        check(reopened.engine.state("Fixture") == .away, "Ledger restores away state")
        var old = try JSONSerialization.jsonObject(with: archived) as! [String: Any]
        old.removeValue(forKey: "membership"); old.removeValue(forKey: "leaving")
        old["events"] = (old["events"] as! [[String: Any]]).map { event in var copy = event; copy.removeValue(forKey: "time"); return copy }
        let legacy = Fixture(); try legacy.engine.restore(JSONSerialization.data(withJSONObject: old))
        _ = legacy.engine.human("old ledger")
        check(legacy.engine.state("Fixture") == .collaborating && legacy.sent["Fixture"]!.last!.contains("時間不明"), "old Ledger without time or states remains readable")
        let lost = Fixture(); _ = lost.engine.human("@@Fixture join"); lost.engine.leave("Fixture"); lost.missingConversation = true
        _ = lost.engine.human("@@Fixture after deletion")
        check(lost.sent["Fixture"]!.last!.contains("請先用") && lost.engine.events.last?.kind == "summary", "only confirmed missing TAP conversation restarts first join")

        let queue = Fixture(exchange: 1); queue.hold = ["Coder", "Fixture"]
        _ = queue.engine.human("@@Fixture current")
        let firstReply = queue.held["Fixture"]!.first!, firstCalls = queue.calls
        check(queue.engine.human("queued-one") && queue.engine.human("queued-two"), "busy accepts two queued humans")
        check(queue.calls == firstCalls && queue.stops.isEmpty && queue.engine.turn == 1, "queue never interrupts or starts a parallel turn")
        queue.finish("Coder"); queue.finish()
        check(queue.engine.turn == 1 && queue.calls == 4, "current automatic exchange finishes before queued turn")
        queue.finish("Coder"); queue.finish()
        check(queue.engine.turn == 2 && queue.calls == 6 && queue.engine.events.filter { $0.speaker == "使用者" }.last?.text == "queued-one\nqueued-two", "two queued messages become one next human turn")
        check(queue.sent["Coder"]!.last!.contains("queued-one") && queue.sent["Coder"]!.last!.contains("queued-two") && queue.sent["Fixture"]!.last!.contains("queued-two"), "both participants receive merged next human")
        firstReply(.success("late duplicate"))
        check(!queue.engine.events.contains { $0.text == "late duplicate" }, "old callback cannot complete next round")
        let stopState = queue.engine.state("Fixture"), stoppedAt = Date()
        _ = queue.engine.human("discard on stop"); queue.engine.stop()
        check(Date().timeIntervalSince(stoppedAt) < 3 && !queue.engine.busy && queue.engine.state("Fixture") == stopState && queue.stops.contains("Coder") && queue.stops.contains("Fixture"), "stop is immediate for both and preserves collaboration state")
        let stoppedCalls = queue.calls, stoppedEvents = queue.engine.events
        queue.finish("Coder"); queue.finish()
        check(queue.calls == stoppedCalls && queue.engine.queuedHumanCount == 0 && queue.engine.events.contains { $0.kind == "queue-cancelled" && $0.text == "discard on stop" } && queue.engine.events == stoppedEvents && !queue.engine.events.contains { $0.kind == "queued" }, "stop preserves the unsent original, discards dispatch and ignores late replies")
        print("W225B2CORE SUMMARY failures=\(failed)")
        exit(failed == 0 ? 0 : 1)
    }
}
