import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
const read = p => process.env.W226A_BASELINE
  ? execFileSync('git', ['show', process.env.W226A_BASELINE + ':App/Sources/Tatwo2/' + p], {encoding: 'utf8'})
  : readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');
test('6: event storage never reads the conversation document', () => {
  assert.doesNotMatch(read('Events/OSEventLog.swift'), /document\.json|LiveDocumentRecord|resolvingThread/);
});
test('7: hot hooks use engine messages without transcript copies', () => {
  assert.doesNotMatch(read('Events/OSEventSources.swift'), /transcript\(for:/);
});
test('8: events reuse local device identity', () => {
  assert.match(read('Events/OSEventLog.swift'), /DeviceIdentityStore.readLocal/);
});
test('9: bounded shutdown flush is attached to termination', () => {
  assert.match(read('Tatwo2App.swift'), /OSEventLog.flushAll/);
  assert.match(read('Events/OSEventLog.swift'), /\.now\(\) \+ 1/);
});
test('11: recovery writes to damaged month and write failures cannot abort query', () => {
  const log = read('Events/OSEventLog.swift');
  assert.match(log, /try\? write\(row, to: url\)/);
  assert.doesNotMatch(log, /try write\(row, to: current\)/);
});
test('1: programmatic sends default to system, composer and dispatch are explicitly scoped', () => {
  const sources = read('Events/OSEventSources.swift');
  assert.match(sources, /origin: "system"/);
  assert.match(read('Facade/ChatPageModel.swift'), /"composer"/);
  assert.match(read('DM/GlobalDMStore.swift'), /origin: "composer"/);
  assert.equal((read('Facade/DispatchEngine.swift').match(/origin: "dispatch"/g) ?? []).length, 3);
});
test('2: foreground routing checks page, mode, key window and DM target', () => {
  const p = read('Events/OSPresence.swift');
  for (const s of ['.isKeyWindow', 'TatwoWorkOSWindow', 'tatwoWorkOSPageDidChange', 'mode == .chat', 'surface:', 'store.target']) assert.ok(p.includes(s), s);
});
test('3: both journal phases share the callID and event append deduplicates IDs', () => {
  assert.match(read('Facade/HandsChatGPTRoom.swift'), /eventsHands\(id: id/);
  assert.equal((read('Facade/HandsService.swift').match(/id: callID, at: calledAt/g) ?? []).length, 2);
  assert.match(read('Events/OSEventLog.swift'), /recordedIDs.contains\(id\)/);
});
test('5: workspace resolves its project; thread and workspace remain separate', () => {
  assert.match(read('Facade/HandsChatGPTRoom.swift'), /projectID: workspace\.record\.projectID/);
  assert.doesNotMatch(read('Events/OSEventSources.swift'), /thread: workspace/);
  assert.match(read('Events/OSEventSources.swift'), /eventsHandsThread/);
});
test('4: turn terminal takes actual turnID and tracks active turns', () => {
  assert.match(read('Facade/ChatLiveEngine.swift'), /eventsFinished\(threadID, succeeded: succeeded, turn: turnID\[threadID\]\)/);
  assert.match(read('Events/OSEventSources.swift'), /activeTurns.removeValue/);
});
test('10: timed and condition callbacks execute after unlock', () => {
  const clock = read('Events/OSClock.swift');
  assert.match(clock, /rearm\(\); lock.unlock\(\)[\s\S]*job.action\(\)/);
  assert.match(clock, /lock.unlock\(\); runDue\(\)/);
});
