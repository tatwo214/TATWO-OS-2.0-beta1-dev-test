// Synthetic regressions for the .057 reacceptance. Native checks run in w185tap/w198dispatch/w199quiet.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
const app = p => fs.readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');
const source = app('TAP/ChatGPTTurnPresentation.swift');
const rules = JSON.parse(source.split('static let privacyRulesJSON = #"""')[1].split('"""#')[0]);
const clean = text => rules.reduce((s, r) => s.replace(new RegExp(r.pattern, 'gi'), r.replacement), text).trim();

test('W205-2 local missing record is quiet and same reason can be dismissed', () => {
  const entry = app('New/HandsConnectEntry.swift');
  assert.doesNotMatch(entry, /case \.open: return !hasAccountRecord/);
  assert.match(entry, /mutating func dismiss/);
  assert.match(entry, /先不用/);
  assert.match(entry, /的連線被撤銷了：按一下重新連線/);
});
test('W205-3 reply protection is established through the pinned directory before output', () => {
  const dispatch = app('Facade/ChatGPTDispatch.swift');
  assert.match(dispatch, /openat\(fd, "\.gitignore"/);
  assert.match(dispatch, /Data\("\*\\n".utf8\)/);
  assert.ok(dispatch.includes('git_ignore_unsafe'));
});
test('W205-4 only unconfirmed results are locked; bounded receipts support explicit release', () => {
  const dispatch = app('Facade/ChatGPTDispatch.swift');
  assert.match(dispatch, /resultUnconfirmed/);
  assert.match(dispatch, /uncertainCapacity/);
  assert.match(dispatch, /releaseUncertain/);
});
test('W205-5 live dispatcher deadline protects caller and caller stop cancels dispatch', () => {
  assert.match(app('Facade/DispatchWatchdog.swift'), /chatGPTDispatcher.*isActive/);
  assert.match(app('Facade/ChatLiveEngine.swift'), /chatGPTDispatcher\?\.stop\(caller: threadID\)/);
  assert.match(app('Facade/OSAgentBridge.swift'), /live.chatGPTDispatcher = chatGPTDispatcher/);
});
test('W205-6 relative/API paths and bare timestamps survive; real local paths and phones are masked', () => {
  for (const safe of ['src/home/index.tsx', '/api/users/1', 'src/Users/fixture/index.tsx', '1700000000', '2025550143']) assert.equal(clean(safe), safe, safe);
  for (const secret of ['12025550143', '120255501430000', 'file:///Users/fixture/private.txt', 'file:///Volumes/fixture/private.txt', '/Users/fixture/private.txt', '/Volumes/fixture/private.txt', '/home/fixture/private.txt', '+886 912 345 678', '0912-345-678', '(202) 555-0143', 'phone=2025550143', 'phone 2025550143', '電話：0912345678', 'password=abc']) assert.notEqual(clean(secret), secret, secret);
});
test('W205 optional recovery appends to the existing draft', () => {
  assert.match(app('Facade/ChatPageModel.swift'), /ChatGPTDraftRecovery/);
  assert.match(app('TAP/ChatGPTSpace.swift'), /ChatGPTDraftRecovery/);
});

test('W205-5 caller sidecar closure also cancels in-flight dispatch without erasing uncertain results', () => {
  const engine = app('Facade/ChatLiveEngine.swift');
  const handle = engine.slice(engine.indexOf('    private func handle('), engine.indexOf('    func handleSDK('));
  const closed = handle.slice(handle.lastIndexOf('case .closed:'));
  assert.match(closed, /chatGPTDispatcher\?\.stop\(caller: threadID\)/);
});

test('W205-4 watchdog cancellation preserves unknown receipts until explicit owner release', () => {
  // Sol .058 S-A：停止一律只取消；已送出的結果仍未確認，只有 chatgpt_dispatch_stop 會解除「之前的」收據。
  const dispatch = app('Facade/ChatGPTDispatch.swift');
  const stop = dispatch.slice(dispatch.indexOf('    func stop(caller:'), dispatch.indexOf('    private func record('));
  assert.doesNotMatch(stop, /resultUnconfirmed = false/);
  assert.match(app('Facade/DispatchWatchdog.swift'), /engine\.stop\(threadID: t\.id\)/);
  assert.match(app('Facade/OSAgentBridge.swift'), /stop\(caller: caller, releasingEarlier: true\)/);
});





test('W205-4 generic failed events do not claim a confirmed provider failure', () => {
  const tap = app('TAP/ChatGPTTap.swift');
  assert.doesNotMatch(tap, /object\["reason"\] as\? String \?\? "provider_failed"/);
  assert.match(tap, /tooLong\(error.code \+ ' ' \+ error.message\) \? 'conversation_too_long' : 'provider_failed'/);
});



test('W205-6 shared redactor preserves file URL privacy while allowing relative paths', () => {
  const redactor = app('Facade/HandsSandbox.swift').split('enum HandsRedactor')[1];
  assert.match(redactor, /\(file:\/\/\)\?\/Users\//);
});

test('W207 phone labels preserve product/resolution text and mask Taiwan contacts', () => {
  for (const safe of ['iPhone 14 (2022)', 'mobile 1080 1920', 'smartphone 12345678', 'xA123456789', 'A123456789x']) {
    assert.equal(clean(safe), safe);
  }
  for (const secret of ['A123456789', 'b223456789', '(02)2345-6789', '(049)234-5678', 'phone=12345678', 'phone 2025550143']) {
    assert.equal(clean(secret), '[聯絡資料]', secret);
  }
});
