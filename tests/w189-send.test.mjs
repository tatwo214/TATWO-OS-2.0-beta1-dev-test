import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const source = file => readFileSync(`App/Sources/Tatwo2/${file}`, 'utf8');
function body(text, signature) {
  const start = text.indexOf(signature);
  assert.notEqual(start, -1, signature);
  let parens = (signature.match(/\(/g) ?? []).length - (signature.match(/\)/g) ?? []).length;
  let open = -1;
  for (let i = start + signature.length; i < text.length; i++) {
    if (text[i] === '(') parens++;
    if (text[i] === ')') parens--;
    if (text[i] === '{' && parens === 0) { open = i; break; }
  }
  assert.notEqual(open, -1, signature);
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    if (text[i] === '{') depth++;
    if (text[i] === '}' && --depth === 0) return text.slice(open, i + 1);
  }
  assert.fail(`missing body: ${signature}`);
}

test('F2 recovery identity includes device and thread; delivery snapshot is bound to request token', () => {
  const model = source('Facade/ChatPageModel.swift');
  assert.match(model, /coderUndeliveredByContext: \[CoderDraftIdentity: CoderUndelivered\]/);
  assert.match(body(model, 'private var currentCoderDraftIdentity:'), /selectedRemote\?\.threadID \?\? selectedThreadID/);
  assert.match(body(model, 'private func finishCoderDelivery('), /coderDeliverySnapshots\.removeValue\(forKey: token\)/);
  assert.match(body(model, 'private func putBackUndelivered('), /deviceID: sent\.deviceID, threadID: id/);
});

test('send-12/F4 mention selection preserves text and requires explicit keyboard selection', () => {
  const model = source('Facade/ChatPageModel.swift');
  assert.match(body(model, 'func pickIssueMention('), /prompt\.removeSubrange\(token\.startIndex\.\.<token\.endIndex\)/);
  assert.doesNotMatch(body(model, 'func pickIssueMention('), /joined\(|trimmingCharacters/);
  assert.match(body(model, 'func handleIssueMentionKey('), /guard let index = issueMentionSelectedIndex/);
});

test('send-04 strict failure preserves original before record recovery', () => {
  const load = body(source('Facade/ChatLiveStore.swift'), 'func load()');
  assert.ok(load.indexOf('preserveUnreadable(data') < load.indexOf('ChatDocumentRecovery.decode(data)'));
  assert.match(source('Facade/ChatDocumentRecovery.swift'), /TatwoPermissionPreset\.askFirst\.rawValue/);
});

test('send-09/F1 forced stop settles delivery before disconnecting sidecar events', () => {
  const force = body(source('Facade/ChatLiveEngine.swift'), 'private func forceStop(');
  assert.ok(force.indexOf('settleUnconfirmedDelivery(') >= 0);
  assert.ok(force.indexOf('settleUnconfirmedDelivery(') < force.indexOf('sidecar.onEvent = nil'));
  assert.match(force, /cancelUnfinishedRows/);
  assert.match(force, /appendSystem\(threadID, "已強制停止"/);
});

test('send-05 running lists own current work; same-revision polls still notify toolbar', () => {
  const remote = source('Facade/RemoteLiveEngine.swift');
  assert.match(body(remote, 'func isRunning('), /if hasAuthoritativeRunningList \{ return runningThreadIDs\.contains/);
  assert.match(body(remote, 'private func applyFetched('), /if runningChanged \{ onChange\?\(\) \}/);
  assert.match(source('Facade/ChatLiveEngine.swift'), /recoverInterruptedWork\(reason: "App 重開/);
});

test('send-11 host refusal codes and remote refresh keep diagnostics visible', () => {
  const bridge = source('Facade/OSAgentBridge.swift');
  assert.match(bridge, /sendTurnRejected\("thread_busy"\)/);
  assert.match(bridge, /sendTurnRejected\("thread_missing"\)/);
  assert.match(bridge, /RemoteSendRejection\.code\(for: refusal\?\.status\)/);
  const remote = source('Facade/RemoteLiveEngine.swift');
  const send = body(remote.slice(remote.indexOf('static func delivery(for error:')), '@discardableResult func send(');
  const failed = send.slice(send.indexOf('case .failure(let error)'));
  assert.match(failed, /if case RemoteHostLinkError\.remoteError = error/);
  assert.match(failed, /transcriptCache\[threadID\] = nil/);
  assert.match(failed, /refreshDocument\(notify: true\)/);
});

test('send-08 real queued stop emits notSubmitted before finishing its stream', () => {
  const stop = body(source('TAP/ChatGPTTap.swift'), 'func stop(requestID: String)');
  const queued = stop.slice(stop.indexOf('if activeRequestID != requestID'), stop.indexOf('streamWatchdog?.cancel()'));
  assert.match(queued, /\.yield\(\.notSubmitted\(/);
  assert.ok(queued.indexOf('.notSubmitted(') < queued.indexOf('finishStream(requestID)'));
});

for (const signature of ['private func sendLoginStatus(', 'private func sendToLocalAssistant(',
  'private func startPRContribution(', 'func sendFromDM(', 'func send()', 'init(environment: [String: String]']) {
  test(`send-01 ${signature} does not launch synchronous login processes`, () => {
    // Explicit Codex status only reads its auth file; the separate /goal branch
    // is outside this send preflight. Dynamic/Claude checks can launch processes.
    assert.doesNotMatch(body(source('Facade/ChatPageModel.swift'), signature), /engineLogin\.status\(for:(?!\s*\.codex\b)|engineLogin\.statuses\(/);
  });
}
