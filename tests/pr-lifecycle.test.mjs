import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { testScratch } from './helpers/test-scratch.mjs';
const root = path.resolve(import.meta.dirname, '..');
const app = path.join(root, 'App/Sources/Tatwo2');

test('production PR lifecycle, persistence, fork discovery and retry boundaries', { timeout: 180_000 }, () => {
  const scratch = testScratch('pr-lifecycle-');
  const fixture = path.join(scratch, 'Checks.swift');
  fs.writeFileSync(fixture, String.raw`
import Foundation
struct FeedbackIdentity { let username: String; let token: String }
enum FeedbackService { static func scanSecrets(_ text: String) throws {} }
struct FeedbackHTTPTransport {
    static let shared = Self()
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { fatalError("real network forbidden") }
}
struct ChatMessage { var id = "fixture"; let text: String }
enum DistillCanvas {
    static func draft(from text: String, legacy: Bool) -> String? { nil }
    static func template(for output: DistillOutputKind) -> String { "" }
    static func output(of plan: TatwoPlanArtifactV1) -> DistillOutputKind { plan.distillOutput ?? .skill }
}
final class ChatLiveEngine {
    struct Store { let url: URL }
    let store: Store
    init(root: URL) { store = Store(url: root.appendingPathComponent("document.json")) }
    var onTurnComplete: [UUID: Bool] = [:]
    var onPlanChange: ((TatwoPlanArtifactV1) -> Void)?
    func isRunning(_ id: UUID) -> Bool { false }
    func appendSystemMessage(threadID: UUID, text: String, status: String) { fatalError(text) }
}
func check(_ value: Bool, _ name: String) {
    precondition(value, name); print("PASS " + name)
}
final class HTTPProbe {
    var calls: [URLRequest] = []
    var responses: [(String, Int, Any)]
    init(_ responses: [(String, Int, Any)]) { self.responses = responses }
    func request(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls.append(request)
        precondition(!responses.isEmpty, "unexpected HTTP call")
        let next = responses.removeFirst()
        check(request.httpMethod! + " " + request.url!.path + (request.url!.query.map { "?" + $0 } ?? "") == next.0, "HTTP route " + next.0)
        return (try JSONSerialization.data(withJSONObject: next.2), HTTPURLResponse(url: request.url!, statusCode: next.1, httpVersion: nil, headerFields: nil)!)
    }
}
@main struct Checks {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let id = UUID(), engine = ChatLiveEngine(root: root)
        var plan = TatwoPlanArtifactV1(threadID: id, objective: "fix", kind: "pr")
        check(engine.planContext(plan, userText: "discuss") != nil, "new PR discusses")
        plan.confirm()
        check(engine.planContext(plan, userText: "start") != nil, "confirmation without dispatch remains guarded")
        plan.prModeExited = true; plan.executionTurnID = "sent-turn"
        try engine.savePlanArtifact(plan)
        let reloaded = try engine.loadPlanArtifact(id)!
        check(reloaded.prModeExited == true && engine.planContext(reloaded, userText: "next") == nil, "exit survives restart")
        plan.recoverInterruptedPR(hasActiveTurn: false)
        check(plan.state == .discussing && engine.planContext(plan, userText: "next") == nil, "interruption does not relock conversation")
        try engine.savePlanArtifact(plan)
        engine.updatePlanFromReply(id, reply: ChatMessage(text: "\u{0060}\u{0060}\u{0060}tatwo-plan\n## 做什麼\nunrelated\n\u{0060}\u{0060}\u{0060}"))
        check(try engine.loadPlanArtifact(id) == plan, "ordinary replies preserve exited plan")
        let snapshot = PullRequestService.Snapshot(head: "abc", status: "M", diff: "text", stat: "1", origin: "fixture/repo")
        var review = PRPlanReview(directory: root, repository: "upstream/repo", account: "me", snapshot: snapshot)
        review.attempted = true
        check(review.recordSubmissionFailure(PullRequestFailure(message: "fork failed", safeToRetry: true)) && !review.attempted, "pre-submission failure unlocks retry")
        review.attempted = true
        check(!review.recordSubmissionFailure(PullRequestFailure(message: "unknown")) && review.attempted, "uncertain submission cannot replay")
        let savedReview = try JSONDecoder().decode(PRPlanReview.self, from: JSONEncoder().encode(review))
        check(savedReview.attempted, "uncertainty survives restart")
        var legacy = TatwoPlanArtifactV1(threadID: id, objective: "old PR", state: .ready, kind: "pr")
        legacy.prReview = review
        check(engine.planContext(legacy, userText: "next") == nil, "legacy ready PR no longer locks chat")
        legacy.state = .confirmed; legacy.prContinuationThreadID = UUID()
        check(engine.planContext(legacy, userText: "next") == nil, "transferred source no longer locks chat")
        let fresh = TatwoPlanArtifactV1(threadID: id, objective: "new PR", kind: "pr")
        check(fresh.isPRModeActive, "new PR explicitly reenters mode")
        for kind in ["plan", "feedback", "distill"] {
            let other = TatwoPlanArtifactV1(threadID: id, objective: "other", kind: kind)
            check(engine.planContext(other, userText: "next") != nil, kind + " behavior preserved")
        }
        let identity = FeedbackIdentity(username: "fixture", token: "fixture")
        func fork(_ name: String, parent: String = "upstream/repo") -> [String: Any] {
            ["full_name": name, "fork": true, "parent": ["full_name": parent]]
        }
        let conventional = HTTPProbe([("GET /repos/fixture/repo", 200, fork("fixture/repo"))])
        check(try await PullRequestService(http: conventional.request).resolveFork(repository: "upstream/repo", identity: identity) == "fixture/repo", "existing conventional fork")
        let renamed = HTTPProbe([
            ("GET /repos/fixture/repo", 200, ["full_name": "fixture/repo", "fork": false]),
            ("GET /repos/upstream/repo/forks?per_page=100&page=1", 200, [fork("someone/repo"), fork("fixture/repo-1")]),
            ("GET /repos/fixture/repo-1", 200, fork("fixture/repo-1"))
        ])
        check(try await PullRequestService(http: renamed.request).resolveFork(repository: "upstream/repo", identity: identity) == "fixture/repo-1", "renamed fork reused despite name collision")
        check(renamed.calls.allSatisfy { $0.httpMethod == "GET" }, "existing fork discovery creates nothing")
        let created = HTTPProbe([
            ("GET /repos/fixture/repo", 200, ["full_name": "fixture/repo", "fork": false]),
            ("GET /repos/upstream/repo/forks?per_page=100&page=1", 200, []),
            ("POST /repos/upstream/repo/forks", 202, fork("fixture/returned-name")),
            ("GET /repos/fixture/returned-name", 200, fork("fixture/returned-name"))
        ])
        check(try await PullRequestService(http: created.request).resolveFork(repository: "upstream/repo", identity: identity) == "fixture/returned-name", "creation uses returned repository name")
        let payload = try JSONSerialization.jsonObject(with: created.calls[2].httpBody!) as! [String: String]
        check(payload["name"]?.hasPrefix("repo-") == true, "creation avoids existing unrelated repository")
        let paged = HTTPProbe([
            ("GET /repos/fixture/repo", 404, [:]),
            ("GET /repos/upstream/repo/forks?per_page=100&page=1", 200, Array(repeating: fork("someone/repo"), count: 100)),
            ("GET /repos/upstream/repo/forks?per_page=100&page=2", 200, [fork("fixture/renamed")]),
            ("GET /repos/fixture/renamed", 200, fork("fixture/renamed"))
        ])
        check(try await PullRequestService(http: paged.request).resolveFork(repository: "upstream/repo", identity: identity) == "fixture/renamed", "fork discovery paginates")
        let wrongParent = HTTPProbe([
            ("GET /repos/fixture/repo", 200, fork("fixture/repo", parent: "other/repo")),
            ("GET /repos/upstream/repo/forks?per_page=100&page=1", 200, []),
            ("POST /repos/upstream/repo/forks", 202, fork("someone/stolen"))
        ])
        do {
            _ = try await PullRequestService(http: wrongParent.request).resolveFork(repository: "upstream/repo", identity: identity)
            fatalError("wrong owner accepted")
        } catch { check(true, "wrong parent and owner cannot become push destination") }
        let unavailable = PullRequestService(http: { _ in throw URLError(.timedOut) })
        do {
            _ = try await unavailable.submit(directory: root, repository: "upstream/repo", identity: identity, snapshot: snapshot, title: "fix", description: "details")
            fatalError("non-repository submitted")
        } catch { check((error as? PullRequestFailure)?.safeToRetry == true, "preflight failure is retryable before git mutations") }
        print("PR_LIFECYCLE_OK")
    }
}
`);
  const binary = path.join(scratch, 'checks');
  const sources = ['Facade/PullRequestService.swift', 'Facade/ChatLiveEngine+Plan.swift', 'Chat/TatwoPlanArtifact.swift', 'Chat/PRPlanReview.swift', 'Chat/DistillSubmission.swift'].map(p => path.join(app, p));
  const build = spawnSync('swiftc', ['-num-threads', '2', ...sources, fixture, '-o', binary], { encoding: 'utf8', timeout: 120_000 });
  fs.writeFileSync(path.join(scratch, 'compile.log'), build.stdout + build.stderr);
  assert.equal(build.status, 0, build.stderr);
  const run = spawnSync(binary, [path.join(scratch, 'data')], { encoding: 'utf8', timeout: 30_000 });
  fs.writeFileSync(path.join(scratch, 'result.log'), run.stdout + run.stderr);
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /PR_LIFECYCLE_OK/);
  console.log(run.stdout, 'Evidence:', scratch);
});

test('successful dispatch persists mode exit before sending, failed acceptance does not exit', () => {
  const engine = fs.readFileSync(path.join(app, 'Facade/ChatLiveEngine.swift'), 'utf8');
  const send = engine.slice(engine.indexOf('@discardableResult func send(threadID: UUID, text: String, model: String?, engine: ClaudeSidecar.Kind ='), engine.indexOf('// MARK:', engine.indexOf('let planBriefing =')));
  assert.match(send, /guard let sidecar = ensureSidecar[\s\S]*confirmed\.prModeExited = true[\s\S]*try savePlanArtifact\(confirmed\)[\s\S]*sidecar\.send/);
  assert.match(send, /confirmed\.kind == "pr" && confirmed\.state == \.confirmed && onTurnComplete\[threadID\] != nil/);
});
