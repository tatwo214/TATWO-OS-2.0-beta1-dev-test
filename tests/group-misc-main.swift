import Foundation

@main struct GroupMiscTests {
    @MainActor static func main() async throws {
        var failures = 0
        func check(_ ok: Bool, _ name: String) { print("W225B4MISC \(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }
        var plainSends: [String] = []
        let plain = GroupTurnEngine(threadID: UUID(), primary: "Coder", participants: [GroupParticipant(id: "Coder", timeout: 0, invoke: { text, done in plainSends.append(text); done(.success("reply")) }, stop: {})])
        let original = "paste @@ROWCOUNT @@ROWCOUNT and @@Outside original"
        _ = plain.human(original)
        check(plainSends.count == 1 && plain.events.last { $0.speaker == "使用者" }?.text == original && plainSends.last!.contains("@@ROWCOUNT"), "4.1 unknown names preserve every character of human text")
        check(plain.events.filter { $0.kind == "failure" }.count == 1 && plain.events.filter { $0.kind == "failure" }.first?.speaker == "系統", "4.1 unknown names make only one host notice")
        var now = Date(timeIntervalSince1970: 1_791_187_200), tapCalls = 0
        var pending: ((Result<String, Error>) -> Void)?
        let peers = [GroupParticipant(id: "Coder", timeout: 0, invoke: { _, done in done(.success("reply")) }, stop: {}), GroupParticipant(id: "ChatGPT", join: true, timeout: 0, invoke: { _, done in tapCalls += 1; pending = done }, stop: {})]
        let cool = GroupTurnEngine(threadID: UUID(), primary: "Coder", participants: peers, exchangeLimit: 0, clock: { now })
        let error = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture timeout"])
        _ = cool.human("@@ChatGPT join"); pending?(.success("joined"))
        _ = cool.human("one"); pending?(.failure(error))
        _ = cool.human("two"); pending?(.failure(error))
        let before = tapCalls
        _ = cool.human("next human")
        check(cool.state("ChatGPT") == .away && tapCalls == before, "4.4 timeout-away never auto-retries on next human")
        pending?(.failure(error))
        let saved = try cool.snapshot()
        let restored = GroupTurnEngine(threadID: cool.threadID, primary: "Coder", participants: peers, exchangeLimit: 0, clock: { now })
        try restored.restore(saved)
        now += 599
        _ = restored.human("before ten minutes")
        check(tapCalls == before, "4.4 cooldown persists through restore and includes 599 seconds")
        pending?(.failure(error))
        now += 1
        _ = restored.human("after ten minutes")
        check(tapCalls == before + 1, "4.4 ten-minute expiry retries on a human turn")
        pending?(.success("returned"))
        now -= 600
        let explicit = GroupTurnEngine(threadID: cool.threadID, primary: "Coder", participants: peers, exchangeLimit: 0, clock: { now })
        try explicit.restore(saved)
        let beforeExplicit = tapCalls
        _ = explicit.human("@@ChatGPT return now")
        check(tapCalls == beforeExplicit + 1, "4.4 explicit human mention bypasses cooldown")
        pending?(.success("returned"))
        var held: [String: (Result<String, Error>) -> Void] = [:]
        let missing = GroupTurnEngine(threadID: UUID(), primary: "Coder", participants: ["Coder", "ChatGPT"].map { id in GroupParticipant(id: id, join: id == "ChatGPT", timeout: 0, invoke: { _, done in held[id] = done }, stop: {}) }, exchangeLimit: 0)
        _ = missing.human("@@ChatGPT join"); held["Coder"]?(.success("reply")); held["ChatGPT"]?(.success("summary"))
        _ = missing.human("the current human after deletion")
        let opening = missing.restartConversation("ChatGPT", replacing: "previous") ?? ""
        check(opening.contains("請先用") && opening.contains("the current human after deletion"), "4.5 missing conversation opening carries current human despite pending reply slots")
        missing.stop()
        print("W225B4MISC SUMMARY failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
