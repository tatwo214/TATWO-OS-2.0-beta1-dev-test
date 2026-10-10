import test from 'node:test';
import assert from 'node:assert/strict';
import { rendererPage, CID, pageFull, serverFull, terminal, settle } from './fixtures/w318-newrenderer.mjs';

for (const language of ['en', 'zh']) for (const signal of ['live', 'actions']) test(`${language} ${signal}: complete immediately reads and saves authoritative server full text`, async () => {
  const rig = rendererPage({ language, thinking: true }), { p } = rig;
  p.send({ conversationID: CID }); await settle(p);
  await p.advance(4000);
  assert.deepEqual(terminal(p), [], 'old completed turn and thinking placeholder cannot complete');
  rig.complete({ signal });
  await settle(p, 30);
  assert.equal(terminal(p)[0]?.kind, 'finished', 'finish within 240ms after completion');
  assert.equal(terminal(p).length, 1);
  assert.equal(p.reports.filter(r => r.kind === 'text').at(-1).full, serverFull);
  assert.ok(p.requests.some(r => r.url.includes('/conversation/' + CID)));
});

for (const api of ['failed', 'hanging']) test(`${api} API: saves whole Renderer body within five seconds, excluding labels and user bubble`, async () => {
  const rig = rendererPage({ api, thinking: true }), { p } = rig;
  p.send({ conversationID: CID }); await settle(p);
  rig.complete(); await p.advance(5000); await settle(p, 20);
  assert.equal(terminal(p)[0]?.kind, 'finished');
  assert.equal(p.reports.filter(r => r.kind === 'text').at(-1).full, pageFull);
});

test('stable completion with two unfinished API reads saves page full text after ten seconds', async () => {
  const rig = rendererPage({ api: 'in_progress', asyncStatus: 'in_progress', thinking: true }), { p } = rig;
  p.send({ conversationID: CID }); await settle(p);
  new p.Element('div', { 'data-testid': 'reasoning-status' }).textContent = 'Thinking';
  rig.complete(); await settle(p); await p.advance(8500);
  assert.deepEqual(terminal(p), []);
  await p.advance(1000); await settle(p, 20);
  assert.equal(terminal(p).length, 1); assert.equal(terminal(p)[0].kind, 'finished');
  assert.equal(p.reports.filter(r => r.kind === 'text').at(-1).full, pageFull);
  assert.ok(p.requests.filter(r => r.url.includes('/conversation/' + CID)).length >= 2);
  p.command({ cmd: 'diagnostics', id: 'D' }); await settle(p, 20);
  assert.equal(p.reports.find(r => r.id === 'D').data['收尾來源'], '頁面（伺服器未標完成）');
});

test('static thinking label remains active for 240 seconds', async () => {
  const rig = rendererPage({ thinking: true, api: 'in_progress' }), { p } = rig;
  p.send({ conversationID: CID }); await settle(p);
  rig.stop.isConnected = false;
  await p.advance(240000); await settle(p);
  assert.deepEqual(terminal(p), []);
});

test('visible static Renderer thinking without live status or API remains active for 240 seconds', async () => {
  const rig = rendererPage({ thinking: true, api: 'failed' }), { p } = rig;
  p.send({ conversationID: CID }); await settle(p);
  rig.stop.isConnected = false; rig.live.textContent = '';
  await p.advance(240000); await settle(p);
  assert.deepEqual(terminal(p), []);
});

test('static async_status in progress without stop or thinking indicator remains active for five minutes', async () => {
  const rig = rendererPage({ api: 'queued', asyncStatus: 'in_progress' }), { p } = rig;
  p.send({ conversationID: CID }); await settle(p);
  rig.stop.isConnected = false; rig.live.textContent = ''; rig.body.textContent = '';
  await p.advance(300000); await settle(p);
  assert.deepEqual(terminal(p), []);
  assert.ok(p.reports.filter(r => r.kind === 'activity').length > 100);
});

test('latest server in_progress without page indicators remains active for five minutes', async () => {
  const rig = rendererPage({ api: 'in_progress' }), { p } = rig;
  p.send({ conversationID: CID }); await settle(p);
  rig.stop.isConnected = false; rig.live.textContent = ''; rig.body.textContent = '';
  await p.advance(300000); await settle(p);
  assert.deepEqual(terminal(p), []);
});

test('past reasoning alone expires when no current thinking evidence remains', async () => {
  const rig = rendererPage({ api: 'failed', thinking: true }), { p } = rig;
  p.send({ conversationID: CID }); await settle(p);
  rig.stop.isConnected = false; rig.live.textContent = ''; rig.body.textContent = '';
  await p.advance(240000); await settle(p);
  assert.equal(terminal(p).length, 1); assert.equal(terminal(p)[0].reason, 'no_progress');
});

test('page completion stability restarts when answer text changes', async () => {
  const rig = rendererPage({ api: 'in_progress' }), { p } = rig;
  p.send({ conversationID: CID }); await settle(p); rig.complete(); await settle(p);
  await p.advance(7000); rig.body.textContent = pageFull + '\nextra page paragraph'; await p.advance(8000);
  assert.deepEqual(terminal(p), []);
  await p.advance(2200);
  assert.equal(terminal(p).length, 1);
  assert.equal(p.reports.filter(r => r.kind === 'text').at(-1).full, pageFull + '\nextra page paragraph');
});

test('changing page thinking evidence keeps an active turn alive', async () => {
  const rig = rendererPage({ thinking: true, api: 'in_progress' }), { p } = rig;
  p.send({ conversationID: CID }); await settle(p);
  for (let i = 1; i <= 5; i++) { await p.advance(60000); rig.body.textContent = '已思考 ' + i + ' 分鐘'; await p.advance(200); }
  assert.deepEqual(terminal(p), []);
});

for (const form of [true, false]) for (const stopLabel of ['Stop streaming', 'Stop', '停止']) test(`${stopLabel}, form=${form}: stop releases turn and next sentence reaches same conversation`, async () => {
  const rig = rendererPage({ form, stopLabel, api: 'in_progress', thinking: true }), { p } = rig;
  p.send({ conversationID: CID }); await settle(p);
  p.command({ cmd: 'stop', id: 'cancel', requestID: 'S' }); await p.advance(1500);
  assert.ok(p.reports.some(r => r.id === 'cancel' && r.ok));
  assert.equal(rig.stop.clicks, 1);
  p.send({ id: 'NEXT', text: '第二句 END-W318-S2', conversationID: CID }); await settle(p);
  const sent = p.requests.filter(r => r.init?.method === 'POST').map(r => JSON.parse(r.init.body));
  assert.equal(sent.length, 2);
  assert.equal(sent[1].conversation_id, CID);
  assert.equal(sent[1].messages[0].content.parts[0], '第二句 END-W318-S2');
  assert.equal(p.box.value, '');
  assert.equal(p.button.clicks, 2);
});

test('Stop label outside composer never blocks completion or gets clicked', async () => {
  const rig = rendererPage(), { p } = rig;
  const unrelated = new p.Element('button', { 'aria-label': 'Stop' }, rig.region);
  p.send({ conversationID: CID }); await settle(p); rig.complete(); await settle(p);
  assert.equal(terminal(p)[0]?.kind, 'finished'); assert.equal(unrelated.clicks, 0);
});

test('response code-block Copy plus user actions cannot complete an unfinished answer', async () => {
  const rig = rendererPage({ api: 'failed' }), { p } = rig;
  p.send({ conversationID: CID }); await settle(p);
  rig.body.textContent = pageFull;
  const pre = new p.Element('pre', {}, rig.body); new p.Element('button', { 'aria-label': 'Copy' }, pre);
  rig.stop.isConnected = false; await p.advance(10000);
  assert.deepEqual(terminal(p), []);
});

test('completion while composer stop remains does not start final API read', async () => {
  const rig = rendererPage(), { p } = rig;
  p.send({ conversationID: CID }); await settle(p);
  const readsBefore = p.requests.filter(r => r.url.includes('/conversation/')).length;
  rig.body.textContent = pageFull; rig.live.textContent = 'Response complete'; await p.advance(5000);
  assert.deepEqual(terminal(p), []);
  assert.equal(p.requests.filter(r => r.url.includes('/conversation/')).length, readsBefore);
});

test('failed follow-up send emits visible failure instead of silent success', async () => {
  const rig = rendererPage({ api: 'in_progress' }), { p } = rig;
  p.send({ conversationID: CID }); await settle(p);
  p.command({ cmd: 'stop', id: 'cancel', requestID: 'S' }); await p.advance(1500);
  p.button.disabled = true;
  p.send({ id: 'NEXT', text: 'next failure', conversationID: CID }); await p.advance(7000);
  const fail = terminal(p, 'NEXT');
  assert.equal(fail.length, 1); assert.equal(fail[0].kind, 'failed'); assert.equal(fail[0].submitted, false);
  assert.match(fail[0].message, /沒有送出/);
  assert.equal(p.requests.filter(r => r.init?.method === 'POST').length, 1);
});
