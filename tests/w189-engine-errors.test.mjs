import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
const read = p => readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const source = read('Engines/codex-sidecar/sidecar.mjs');
function notificationFixture() {
  const code = source.slice(source.indexOf('function handleNotification('), source.indexOf('function handleMessage('));
  const events = [], results = [];
  const context = { threadID: 'fixture-thread', currentTurn: { id: 'fixture-turn', uuid: 'fixture' },
    lastCompletedTurnID: null, activeTurnAgentText: '', activeTurnText: '',
    emit: e => events.push(e), finishTurn: (turn, result) => results.push(result),
    sdk: msg => events.push({ ev: 'sdk', msg }), errorText: e => String(e) };
  vm.createContext(context);
  vm.runInContext(code + '\nthis.handle = handleNotification;', context);
  return Object.assign(context, {events, results});
}
test('M5 retry errors expose nested reason without fatal red JSON', () => {
  const fixture = notificationFixture();
  fixture.handle({ method: 'error', params: { threadId: 'fixture-thread', turnId: 'fixture-turn',
    error: { message: 'unsupported model fixture', codexErrorInfo: 'sample' }, willRetry: true } });
  assert.equal(fixture.events[0].message, 'unsupported model fixture');
  assert.equal(fixture.events[0].terminal, false);
  assert.match(fixture.events[0].details, /codexErrorInfo/);
});
test('M5 failed completion retains the error reason when no text streamed', () => {
  const fixture = notificationFixture();
  fixture.handle({ method: 'turn/completed', params: { threadId: 'fixture-thread',
    turn: { id: 'fixture-turn', status: 'failed', error: { message: 'model requires newer version' } } } });
  assert.equal(fixture.results[0].result, 'model requires newer version');
  assert.match(fixture.results[0].error_details, /newer version/);
});
test('M5 raw error details are persisted and expandable, blank failure rows are suppressed', () => {
  assert.match(read('App/Sources/Tatwo2/Chat/ChatPageLeafViews.swift'), /engineErrorDetails[\s\S]*DisclosureGroup/);
  assert.match(read('App/Sources/Tatwo2/Facade/ChatLiveStore.swift'), /engineErrorDetails/);
  const engine = read('App/Sources/Tatwo2/Facade/ChatLiveEngine.swift');
  assert.match(engine, /failed, let r = m\["result"\] as\? String, !r\.[^\n]*isEmpty/);
});
test('M5 failed completion prefers error reason over partial streamed text', () => {
  const fixture = notificationFixture();
  fixture.activeTurnAgentText = 'partial fixture response';
  vm.runInContext('activeTurnAgentText = "partial fixture response";', fixture);
  fixture.handle({method:'turn/completed',params:{turn:{id:'fixture-turn',status:'failed',error:{message:'unsupported model fixture'}}}});
  assert.equal(fixture.results[0].result, 'unsupported model fixture');
});
