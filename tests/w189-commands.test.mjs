import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read = file => readFileSync(new URL(`../App/Sources/Tatwo2/${file}`, import.meta.url), 'utf8');
test('F1 canvas and composer always expose mode exit', () => {
  assert.match(read('Chat/ChatPage+Plan.swift'), /Button\("離開模式", action: onExitMode\)/);
  assert.match(read('Chat/ChatPage.swift'), /onExitMode: model.exitActiveCanvasMode/);
  assert.match(read('Chat/ChatPage+Composer.swift'), /model\.exitActiveCanvasMode/);
});

test('F3/send-03 completed canvases do not block running local commands or hide Stop', () => {
  const model = read('Facade/ChatPageModel.swift');
  assert.doesNotMatch(model, /if activePlanArtifact != nil, let id = selectedThreadID, localLive\?\.isRunning\(id\) == true/);
  assert.match(model, /if isActivePlanTurnWriting/);
  assert.match(read('Chat/ChatPage+Composer.swift'), /if model\.isRunning \{[\s\S]*composerStopButton/);
  assert.match(read('Chat/ChatPage+Plan.swift'), /if isExecuting[\s\S]*Button\("實作中…"\)[\s\S]*Text\("實作已結束"\)/);
});

test('F9 PR scope is explicit and another project cannot trigger a contribution checkout', () => {
  assert.match(read('Facade/ChatPageModel.swift'), /\/pr — 貢獻到 TATWO OS 公開倉/);
  const start = read('Facade/ChatPageModel.swift').split('private func startPRContribution')[1].split('private func resetPRPlan')[0];
  const guardAt = start.indexOf('isContributionCheckout');
  const checkoutAt = start.indexOf('contributionCheckout(');
  assert.ok(guardAt >= 0 && checkoutAt > guardAt, 'verify current project before checkout or thread switch');
  assert.match(read('Facade/PullRequestCoordinator.swift'), /目前專案不是 git 工作目錄/);
});

test('DM-09 assistant slash commands are rejected before invoking the engine', () => {
  const assistant = read('DM/GlobalDMStore.swift').split('func send() -> Bool {')[1].split('switch target {\n        case .assistant:')[1].split('case .thread')[0];
  assert.ok(assistant.indexOf('dmCoderOnlyCommand') >= 0 && assistant.indexOf('dmCoderOnlyCommand') < assistant.indexOf('sendToAssistant'));
  const direct = read('Facade/ChatPageModel.swift').split('func sendToAssistant(text:')[1].split('switch assistantPlacement')[0];
  assert.match(direct, /dmCoderOnlyCommand/);
});

test('S4 production goal branch captures native intent before clearing the composer', async () => {
  const { spawnSync } = await import('node:child_process');
  const { writeFileSync } = await import('node:fs');
  const { join } = await import('node:path');
  const { testScratch } = await import('./helpers/test-scratch.mjs');
  const source = read('Facade/ChatPageModel.swift').split('    func send() {')[1];
  const branch = source.slice(source.indexOf('        if prompt.split(maxSplits: 1'), source.indexOf('        let wasGroupBusy = canQueueCurrentGroup'));
  assert.ok(branch.includes('setNativeGoal'));
  const goalListUI = read('Facade/ChatPageModel.swift').match(/    private func openGoalList\(\) \{[\s\S]*?\n    \}/)[0];
  const scratch = testScratch('w189-goal-');
  const fixture = join(scratch, 'main.swift');
  writeFileSync(fixture, String.raw`import Foundation
struct Goal { let id = 1; var status = Status.active; let parent: String? = nil }
enum Status { case active }
enum Actor { case user }
struct GoalList { var goals: [Goal] = [] }
final class ThreadGoalStore {
 static let shared = ThreadGoalStore(); var goals = GoalList()
 func list(_ id: UUID) -> GoalList { goals }
 func update<T>(_ id: UUID, _ body: (inout GoalList) throws -> T) rethrows -> T { try body(&goals) }
}
enum ThreadGoalRules {
 static func add(_ list: inout GoalList, title: String, userWords: String, proposed: Bool) throws -> Goal { let g = Goal(); list.goals.append(g); return g }
 static func setStatus(_ list: inout GoalList, id: Int, to: Status, evidence: String?, actor: Actor) throws {}
}
enum Kind { case codex }
struct Login { var isLoggedIn = true }
struct EngineLogin { func status(for kind: Kind) -> Login { Login() } }
struct Route { let modelArgument: String? = "fixture" }
final class LocalLive {
 var calls = 0; var objective: String?
 func refreshNativeGoal(_ id: UUID) {}
 func setNativeGoal(threadID: UUID, status: String, objective: String, model: String?, completion: (Bool, String?) -> Void) -> Bool { calls += 1; self.objective = objective; return true }
}
final class Model {
 var prompt = "/goal fixture"; var native = true; var goalCardExpanded = false; var selectedThreadID: UUID?
 let engineLogin = EngineLogin(), routeChoice = Route(); var localLive: LocalLive? = LocalLive()
 var isLocalNativeGoalCommand: Bool { native && prompt.split(whereSeparator: \.isWhitespace).first == "/goal" }
 func rejectRemoteWrite(_ text: String) -> Bool { false }
 func flashComposerHint(_ text: String) {}
 ` + goalListUI + String.raw`
 func send() {
 let id = UUID(), trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
 ` + branch + String.raw`
 }
}
let native = Model(); native.send()
precondition(native.prompt.isEmpty && native.localLive!.calls == 1 && native.localLive!.objective == "fixture", "native goal was never dispatched after composer cleared")
let other = Model(); other.native = false; other.send()
precondition(other.prompt.isEmpty && other.localLive!.calls == 0, "other engine must only add local goal")
print("S4 SUMMARY checks=2 failures=0")
`);
  const build = spawnSync('swiftc', [fixture, '-o', join(scratch, 'probe')], { encoding: 'utf8' });
  assert.equal(build.status, 0, build.stderr);
  const run = spawnSync(join(scratch, 'probe'), [], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  console.log(run.stdout.trim());
  assert.match(run.stdout, /S4 SUMMARY checks=2 failures=0/);
});

test('F12 uncertain PR offers GitHub inspection and human-confirmed retry', () => {
  const actions = read('Chat/PRPlanActions.swift');
  assert.match(actions, /Link\("到 GitHub 查/);
  assert.match(actions, /Button\("確認未送出，允許重試"/);
  assert.match(actions, /\.alert\(/);
  assert.match(read('Chat/ChatPage.swift'), /onPRRetry: model.retryActivePRSubmission/);
});
