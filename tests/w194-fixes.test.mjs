import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, mkdtempSync, writeFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import vm from 'node:vm';
import {spawnSync} from 'node:child_process';
const read = p => {
  const rev = process.env.TATWO_W194_SOURCE_REV;
  if (!rev) return readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');
  const result = spawnSync('git', ['show', rev + ':App/Sources/Tatwo2/' + p], {encoding:'utf8'});
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
};

test('W194-1 stop preparation is bounded and never releases an unknown send', async () => {
  const source = read('TAP/ChatGPTTap.swift');
  const start = source.indexOf('stop: async (command) => {');
  const end = source.indexOf('\n        },', start);
  let timer;
  const work = {command: {}, promise: new Promise(() => {})};
  const context = vm.createContext({preparing: new Map([['fixture', work]]), turns: {}, pendingSend: null,
    personalizedProof: {}, revokePersonalizedProof() {}, document: {querySelector() {return null;}},
    waitFor: async () => null, Date, Promise, setTimeout: fn => {timer = fn; return 1;}, clearTimeout() {}});
  const stop = vm.runInContext('(' + source.slice(start + 'stop: '.length, end) + '})', context);
  const result = stop({requestID:'fixture'});
  await Promise.resolve();
  assert.equal(typeof timer, 'function', 'preparation must schedule a bounded wait');
  timer();
  const reply = await result;
  assert.equal(work.command.cancelled, true);
  assert.equal(reply.preparationPending, true, 'Swift must close the old Pod before releasing the slot');
  assert.notEqual(reply.submitted, false, 'unknown preparation is never a returned draft');
});
test('W194-2 Coder allows dormant sends and runner waits for wake', () => {
  assert.match(read('Facade/ChatPageModel.swift'), /private func tapSendUnavailableReason[\s\S]*?\.sleeping[\s\S]*?return nil/);
  assert.match(read('Facade/ChatGPTTapTurnRunner.swift'), /await chatGPT\.readyForSend\(/);
});
test('W194-3 DM stop keeps consuming the receipt and uses a neutral stopped note', () => {
  const session = read('TAP/ChatGPTConversationSession.swift');
  const stop = session.slice(session.indexOf('    func stop()'), session.indexOf('    /// W184 G3b：私訊框換'));
  assert.doesNotMatch(stop, /consumer\?\.cancel\(\)/);
  assert.match(session, /stopNotice/);
  assert.match(read('New/ChatErrorCard.swift'), /isStopped/);
});
test('W194-4 offscreen parking window always blocks capture', () => {
  const pod = read('TAP/TapWebPod.swift');
  assert.match(pod.slice(pod.indexOf('private func parkingView()')), /window\.sharingType = \.none/);
});
test('W194-5 shared four-form message viewport reserves the floating header', () => {
  assert.match(read('DM/GlobalDMView.swift'), /headerAvoidanceInset/);
});
test('W194-6 plan controls use Chinese and shared glass chips', () => {
  const plan = read('Chat/ChatPage+Plan.swift');
  assert.doesNotMatch(plan, /Button\("(?:Close|Expand plan)"\)/);
  assert.match(plan, /Button\("展開計畫"\)[\s\S]*?chatGlassChip/);
});
test('W194-7 connection copy uses the current Plugin path and build name', () => {
  assert.doesNotMatch(read('New/HandsConnectEntry.swift'), /設定 › TAP › ChatGPT/);
  assert.match(read('New/HandsConnectEntry.swift'), /設定 › Plugin › TAP/);
  assert.doesNotMatch(read('Resources/tatwo-assistant.md'), /對話 [時的做]/);
  assert.doesNotMatch(read('TAP/ChatGPTSpace.swift'), /"[^"\n]*ChatGPT 手腳[^"\n]*"/);
});
test('W194-8 login details follow the provider row and align to its leading edge', () => {
  const card = read('New/EngineLoginCard.swift');
  const rowStart = card.indexOf('private func engineRow');
  const source = rowStart < 0 ? card : card.slice(rowStart);
  assert.ok(source.indexOf('Text(Self.title(kind))') < source.indexOf('DisclosureGroup("詳細"'));
  assert.match(source, /DisclosureGroup\("詳細"[\s\S]*?VStack\(alignment: \.leading/);
});
test('W194-9 read-only message states that sending is blocked', () => {
  const model = read('Facade/ChatPageModel.swift');
  assert.match(model, /唯讀中，不能送出/);
  assert.doesNotMatch(model, /這次的新對話不會存/);
});
test('W194-10 login failure has a settings action; restore failures are plain language', () => {
  assert.match(read('New/ChatErrorCard.swift'), /Button\("登入"\)/);
  assert.match(read('Chat/ChatPageLeafViews.swift'), /Button\("登入"\)/);
  assert.doesNotMatch(read('Facade/ChatLiveEngine.swift'), /尚未還原：\\\(error\)/);
});
test('W194-11 model labels survive persisted replies and catalog loss; login refreshes models', () => {
  assert.match(read('Facade/ChatLiveStore.swift'), /var modelDisplayName: String\?/);
  assert.match(read('Chat/ChatPageLeafViews.swift'), /message\.modelDisplayName/);
  assert.match(read('Chat/ChatGPTTapModelCatalog.swift'), /rememberedTitles/);
  assert.match(read('Facade/ChatPageModel.swift').slice(read('Facade/ChatPageModel.swift').indexOf('func loginEngine(')), /status\.isLoggedIn[\s\S]*?refreshEngineModelCatalog/);
});

// Exercise the real classifier twice, as ChatLiveEngine normalizes the provider
// error before the rendered card decides whether to offer Model Login.
test('W194-10 normalized login failure retains the settings exit and non-login errors do not gain it', {timeout:180000}, t => {
  const home = mkdtempSync(join(tmpdir(), 'w194-error-card-'));
  t.after(() => rmSync(home, {recursive:true, force:true}));
  writeFileSync(join(home, 'presentation.swift'), read('Chat/EngineFailurePresentation.swift'));
  writeFileSync(join(home, 'stubs.swift'), `import Foundation
enum TatwoSettingsPage {enum Section: String {case modelAccess}}
extension Notification.Name {static let tatwoOpenSettingsSection = Notification.Name("fixture-settings")}
enum HandsRedactor {static func redact(_ value:String)->String {value}}
enum HandsSecretLines {static func maskText(_ value:String)->String {value}}
`);
  writeFileSync(join(home, 'main.swift'), `import Foundation
let first = EngineFailurePresentation.make("token expired", alternative:"fixture")
let normalized = EngineFailurePresentation.make(first.summary, details:first.details, alternative:"fixture")
let quota = EngineFailurePresentation.make("rate limit", alternative:"fixture")
var opened = false
let observer = NotificationCenter.default.addObserver(forName:.tatwoOpenSettingsSection, object:nil, queue:nil) { note in
 opened = note.object as? String == TatwoSettingsPage.Section.modelAccess.rawValue
}
EngineFailurePresentation.openModelLogin()
NotificationCenter.default.removeObserver(observer)
print("W194-10 normalized-login=\\(normalized.category == .login) settings=\\(opened)")
exit(first.category == .login && normalized.category == .login && quota.category == .quota && opened ? 0 : 1)
`);
  const binary = join(home, 'probe');
  const build = spawnSync('swiftc', ['-num-threads','2',join(home,'stubs.swift'),join(home,'presentation.swift'),join(home,'main.swift'),'-o',binary], {encoding:'utf8',timeout:150000});
  assert.equal(build.status, 0, build.stderr);
  const result = spawnSync(binary, [], {encoding:'utf8',timeout:15000});
  assert.equal(result.status, 0, result.stdout + result.stderr);
});
