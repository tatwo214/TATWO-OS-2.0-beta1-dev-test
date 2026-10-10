import test from 'node:test';
import assert from 'node:assert/strict';
import { expiredCard, expiredPage, userTurn, listMatches } from './fixtures/w331-expiredcard.mjs';
import { fixture } from './w185-pod-fixture.mjs';
import { rendererPage, CID, serverFull, terminal, settle } from './fixtures/w318-newrenderer.mjs';

const snapshot = p => p.nodes.map(n => n.clicks);
const errorText = name => `ChatGPT 裡的「${name}」連線已過期：到 OS 的${name.startsWith('TATWO') ? '本機 ' : ' '}ChatGPT 連線卡按［連線］接回後再送一次`;
async function turnDiagnostic(p, id = 'D') {
  p.command({ cmd: 'diagnostics', id }); await p.advance(100);
  return p.reports.find(r => r.id === id).data.turn;
}

for (const userRole of ['section', 'bubble']) for (const wrapped of [false, true]) test(`turn/${userRole}/wrapped=${wrapped}: real user turn without an assistant fails in five seconds`, async () => {
  const rig = expiredPage({ layout: 'turn', userRole, wrapped }), { p } = rig;
  p.send({ conversationID: CID }); await p.advance(15000);
  assert.deepEqual(terminal(p), []);
  rig.showCard();
  assert.equal(rig.heading.textContent, '', 'no ChatGPT answer node in this turn');
  const before = snapshot(p), appeared = p.sandbox.Date.now(), routes = [...p.navigations];
  await p.advance(1200);
  assert.equal(terminal(p).length, 1);
  assert.equal(terminal(p)[0].kind, 'failed');
  assert.equal(terminal(p)[0].reason, 'connector_expired');
  assert.equal(terminal(p)[0].message, errorText('TATWO（Mac mini）4'));
  assert.ok(p.sandbox.Date.now() - appeared < 5000);
  assert.ok(rig.stop.isConnected);
  assert.deepEqual(snapshot(p), before);
  assert.deepEqual(p.navigations, routes);
  assert.equal(await turnDiagnostic(p), 'connector_expired name_len=' + Array.from('TATWO（Mac mini）4').length);
  assert.ok(!JSON.stringify(p.reports).includes('Fixture Account'));
});

for (const layout of ['renderer', 'legacy']) for (const placement of ['answer', 'dialog', 'card']) for (const language of ['en', 'zh', 'zh-CN']) {
  test(`${layout}/${placement}/${language}: expires within five seconds with stop still visible and zero additional clicks`, async () => {
    const rig = expiredPage({ layout, placement, language }), { p } = rig;
    p.send({ conversationID: layout === 'renderer' ? CID : undefined });
    await p.advance(15000);
    assert.deepEqual(terminal(p), []);
    rig.showCard();
    const before = snapshot(p), navigations = [...p.navigations], appeared = p.sandbox.Date.now();
    await p.advance(1200);
    assert.equal(terminal(p).length, 1);
    assert.equal(terminal(p)[0].kind, 'failed');
    assert.equal(terminal(p)[0].reason, 'connector_expired');
    assert.equal(terminal(p)[0].message, errorText('TATWO（Mac mini）4'));
    assert.ok(p.sandbox.Date.now() - appeared < 5000);
    assert.equal(rig.stop.isConnected, true);
    assert.deepEqual(snapshot(p), before);
    assert.equal(p.button.clicks, 1, 'only the requested prompt submission');
    assert.deepEqual(p.navigations, navigations);
    assert.ok(!JSON.stringify(terminal(p)).includes('Fixture Account'));
    p.command({ cmd: 'diagnostics', id: 'D' }); await p.advance(100);
    const diag = p.reports.find(r => r.id === 'D').data;
    assert.equal(diag.turn, 'connector_expired name_len=' + Array.from('TATWO（Mac mini）4').length);
    assert.ok(!JSON.stringify(diag).includes('TATWO（Mac mini）4'));
    await p.advance(180000);
    assert.equal(terminal(p).length, 1);
    assert.deepEqual(snapshot(p), before);
  });
}

for (const name of ['Google Drive', 'TATWO', 'TATWO（Studio）']) test(`${name}: preserves connector name and selects the correct connection card`, async () => {
  const rig = expiredPage({ name }), { p } = rig;
  p.send({ conversationID: CID }); await settle(p); rig.showCard(); await p.advance(1200);
  assert.equal(terminal(p)[0]?.message, errorText(name));
});

for (const layout of ['renderer', 'turn']) for (const missing of ['heading', 'expired', 'reconnect', 'dismiss']) test(`${layout}: incomplete card without ${missing} cannot fail a normal turn`, async () => {
  const rig = expiredPage({ layout, [missing]: false }), { p } = rig;
  p.send({ conversationID: CID }); await settle(p); rig.showCard(); await p.advance(5000);
  assert.deepEqual(terminal(p), []);
  assert.equal(p.nodes.filter(n => n.tagName === 'BUTTON').reduce((s, n) => s + n.clicks, 0), 1);
  const diag = await turnDiagnostic(p);
  if (missing === 'dismiss') assert.ok(!diag?.startsWith('connector_card_unmatched:'));
  else assert.equal(diag, 'connector_card_unmatched:' + { heading: 'no_title', expired: 'no_text', reconnect: 'no_reconnect' }[missing]);
});

for (const language of ['en', 'zh']) test(`${language}: pre-submit cards in an old answer and user turn never fail a normal answer`, async () => {
  const rig = rendererPage(), { p } = rig;
  rig.old.body.textContent = '';
  const old = expiredCard(p, rig.old.body, { language });
  const user = userTurn(p, rig.region);
  const quote = expiredCard(p, user.container, { language, turn: true });
  p.send({ conversationID: CID }); await settle(p); await p.advance(5000);
  assert.deepEqual(terminal(p), []);
  assert.ok(!(await turnDiagnostic(p))?.startsWith('connector_card_unmatched:'));
  rig.complete(); await settle(p);
  assert.equal(terminal(p)[0]?.kind, 'finished');
  assert.equal(p.reports.filter(r => r.kind === 'text').at(-1).full, serverFull);
  for (const card of [old, quote]) assert.equal(card.notNow.clicks + card.connect.clicks, 0);
});

for (const layout of ['renderer', 'turn']) test(`${layout}: hidden reconnect button cannot supply the second required action`, async () => {
  const rig = expiredPage({ layout }), { p } = rig;
  p.send({ conversationID: CID }); await settle(p);
  const card = rig.showCard(); card.connect.hidden = true; await p.advance(5000);
  assert.deepEqual(terminal(p), []);
  assert.equal(await turnDiagnostic(p), 'connector_card_unmatched:reconnect_hidden');
});

test('new connector card inserted in an old reply records old_reply without failing', async () => {
  const rig = rendererPage({ api: 'hanging', thinking: true }), { p } = rig;
  p.send({ conversationID: CID }); await settle(p);
  rig.old.body.textContent = '';
  const card = expiredCard(p, rig.old.body), before = snapshot(p);
  await p.advance(5000);
  assert.deepEqual(terminal(p), []);
  assert.equal(await turnDiagnostic(p), 'connector_card_unmatched:old_reply');
  assert.deepEqual(snapshot(p), before);
  assert.equal(card.notNow.clicks + card.connect.clicks, 0);
});

test('a pre-existing Reconnect action cannot pair with a new Not now', async () => {
  const rig = expiredPage({ layout: 'turn' }), { p } = rig;
  const user = userTurn(p, new p.Element('main'));
  const card = expiredCard(p, user.container, { turn: true, dismiss: false });
  p.send({ conversationID: CID }); await settle(p);
  const button = new p.Element('button', {}, card.connect.parentElement); button.textContent = 'Not now';
  await p.advance(5000);
  assert.deepEqual(terminal(p), []);
  assert.equal(await turnDiagnostic(p), 'connector_card_unmatched:old_reconnect');
});

for (const boundary of ['main', 'region', 'assistant', 'renderer', 'body']) test(`scan boundary ${boundary} records a fixed stop reason`, async () => {
  const rig = expiredPage({ layout: 'turn' }), { p } = rig;
  p.send({ conversationID: CID }); await settle(p);
  const host = new p.Element(boundary === 'main' || boundary === 'body' ? boundary : 'div',
    boundary === 'region' ? { role: 'region' } : boundary === 'assistant' ? { 'data-message-author-role': 'assistant' } : boundary === 'renderer' ? { class: 'Renderer-fixture' } : {});
  const card = expiredCard(p, host, { reconnect: false });
  card.notNow.parentElement.parentElement = host;
  await p.advance(5000);
  assert.deepEqual(terminal(p), []);
  assert.equal(await turnDiagnostic(p), 'connector_card_unmatched:stopped_at:' + boundary);
});

test('unmatched diagnostics are assigned only once per reason and change when evidence changes', async () => {
  const rig = expiredPage({ layout: 'turn', heading: false }), { p } = rig;
  p.send({ conversationID: CID }); await settle(p);
  const card = rig.showCard(), before = snapshot(p);
  await p.advance(1200);
  assert.equal(await turnDiagnostic(p), 'connector_card_unmatched:no_title');
  p.command({ cmd: 'listModels', id: 'M' }); await p.advance(100);
  const afterOtherDiagnostic = await turnDiagnostic(p, 'D2');
  await p.advance(3000);
  assert.equal(await turnDiagnostic(p, 'D3'), afterOtherDiagnostic);
  card.connect.hidden = true;
  await p.advance(1200);
  assert.equal(await turnDiagnostic(p, 'D4'), 'connector_card_unmatched:reconnect_hidden');
  assert.deepEqual(terminal(p), []);
  assert.deepEqual(snapshot(p), before);
});

test('Chinese heading without a separator and aria-only buttons still identify the connector', async () => {
  const rig = expiredPage({ language: 'zh' }), { p } = rig;
  p.send({ conversationID: CID }); await settle(p);
  const card = rig.showCard();
  p.nodes.find(n => n.parentElement === card.card && n.textContent === '重新連線 TATWO（Mac mini）4').textContent = '重新連線TATWO（Mac mini）4';
  for (const b of [card.notNow, card.connect]) { b.attrs['aria-label'] = b.textContent; b.textContent = ''; }
  const before = snapshot(p); await p.advance(1200);
  assert.equal(terminal(p)[0]?.message, errorText('TATWO（Mac mini）4'));
  assert.deepEqual(snapshot(p), before);
});

test('normal renderer response without expired card still saves the complete answer', async () => {
  const rig = rendererPage(), { p } = rig;
  p.send({ conversationID: CID }); await settle(p); rig.complete(); await settle(p);
  assert.equal(terminal(p)[0]?.kind, 'finished');
  assert.equal(p.reports.filter(r => r.kind === 'text').at(-1).full, serverFull);
});

async function cardDiagnostic(p, id = 'CARD') {
  p.command({ cmd: 'diagnostics', id }); await p.advance(100);
  return p.reports.find(r => r.id === id).data.turn_card;
}

for (const space of ['\u00a0', '\u3000', '   ']) for (const labelSource of ['textContent', 'aria-label']) for (const language of ['en', 'zh', 'zh-CN']) {
  test(`normalized ${JSON.stringify(space)}/${labelSource}/${language}: both labels and heading match within five seconds`, async () => {
    const rig = expiredPage({ layout: 'turn', language }), { p } = rig;
    p.send({ conversationID: CID }); await settle(p);
    const card = rig.showCard(), title = p.nodes.find(n => /^(?:Reconnect |重新[連连][線线] )/.test(n.textOverride || ''));
    for (const n of [card.notNow, card.connect, title]) {
      const value = ' ' + n.textContent.replace(/^(?:Not now|Reconnect)/, s => s.toUpperCase()).replace(/ /g, space) + ' ';
      n.textContent = labelSource === 'textContent' ? value : 'Opaque fixture label';
      n.attrs['aria-label'] = labelSource === 'aria-label' ? value : 'Opaque fixture label';
    }
    const before = snapshot(p), appeared = p.sandbox.Date.now();
    await p.advance(1200);
    assert.equal(terminal(p)[0]?.kind, 'failed');
    assert.equal(terminal(p)[0]?.reason, 'connector_expired');
    assert.equal(terminal(p)[0]?.message, errorText('TATWO（Mac mini）4'));
    assert.ok(p.sandbox.Date.now() - appeared < 5000);
    assert.deepEqual(snapshot(p), before);
  });
}

test('unaccepted round checks expired cards before any send response or answer arrives', async () => {
  const p = listMatches(fixture());
  p.button.onClick = () => { p.box.value = ''; };
  p.send(); await p.advance(500);
  assert.equal(p.button.clicks, 1);
  assert.ok(!p.reports.some(r => r.kind === 'accepted'));
  const card = expiredCard(p, new p.Element('main'), { turn: true }), before = snapshot(p), appeared = p.sandbox.Date.now();
  await p.advance(1200);
  assert.equal(terminal(p)[0]?.reason, 'connector_expired');
  assert.equal(terminal(p)[0]?.message, errorText('TATWO（Mac mini）4'));
  assert.ok(p.sandbox.Date.now() - appeared < 5000);
  assert.equal(card.notNow.clicks + card.connect.clicks, 0);
  assert.deepEqual(snapshot(p), before);
});

test('turn_card describes old, visible, code and hidden candidates without private text', async () => {
  const rig = expiredPage({ layout: 'turn' }), { p } = rig;
  rig.region.parentElement.parentElement = new p.Element('body');
  const old = expiredCard(p, rig.old.body, { reconnect: false });
  old.notNow.textContent = ' NOT\u00a0NOW ';
  Object.assign(old.card.attrs, { role: 'TATWO（Mac mini）4', 'data-message-author-role': 'Fixture Account', 'data-testid': 'PRIVATE TEST ID', 'aria-hidden': 'true' });
  Object.assign(old.card, { hidden: true, inert: true });
  Object.assign(old.card.style, { display: 'none', visibility: 'collapse', opacity: '0' });
  p.send({ conversationID: CID }); await settle(p);
  const visible = expiredCard(p, rig.container, { reconnect: false });
  const code = expiredCard(p, new p.Element('pre', {}, rig.container), { reconnect: false });
  const hidden = expiredCard(p, rig.container, { reconnect: false }); hidden.card.hidden = true;
  await p.advance(5200);
  const diag = await cardDiagnostic(p);
  assert.match(diag, /^buttons=\d+;not_now=4;old=1;visible=2;old_reply=1;code=1;expired=true;iframe=0;shadow=0;/);
  assert.match(diag, /div\/other\/other\/yes\/1,1,1,1,collapse,1,0,0/);
  assert.match(diag, /body\//);
  assert.ok(diag.length <= 600);
  for (const privateText of ['TATWO（Mac mini）4', 'Fixture Account', 'synthetic question', '請用這個 app 的 tatwo_status', 'PRIVATE TEST ID', 'Renderer-fixture']) {
    assert.ok(!diag.includes(privateText), `turn_card leaked ${privateText}`);
  }
  assert.deepEqual(terminal(p), []);
  for (const card of [old, visible, code, hidden]) assert.equal(card.notNow.clicks, 0);
});

test('W350 turn_card skips iframe and shadow scan without Not now candidates', async () => {
  const rig = expiredPage({ layout: 'turn' }), { p } = rig;
  const frame = new p.Element('iframe');
  frame.contentDocument = { privateCard: 'TATWO（Mac mini）4' };
  const host = new p.Element('div'); host.shadowRoot = { privateCard: 'Fixture Account' };
  assert.equal(await cardDiagnostic(p), undefined, 'no diagnostic before a round');
  let allScans = 0;
  const query = p.doc.querySelectorAll.bind(p.doc);
  p.doc.querySelectorAll = selector => { if (selector === '*') allScans++; return query(selector); };
  p.send({ conversationID: CID }); await p.advance(1200);
  const diag = await cardDiagnostic(p, 'ACTIVE');
  assert.equal(diag, undefined);
  assert.equal(allScans, 0, 'no candidate means no whole-page diagnostic scan');
  assert.deepEqual(terminal(p), []);
});

test('turn_card scans at most once per five seconds and stops after completion', async () => {
  const rig = expiredPage({ layout: 'turn', reconnect: false }), { p } = rig;
  const query = p.doc.querySelectorAll.bind(p.doc), scans = [];
  p.doc.querySelectorAll = selector => { if (selector === '*') scans.push(p.sandbox.Date.now()); return query(selector); };
  p.send({ conversationID: CID }); await settle(p);
  const initial = await cardDiagnostic(p);
  rig.showCard();
  await p.advance(1200);
  assert.equal(await cardDiagnostic(p, 'EARLY'), initial);
  await p.advance(4000);
  const changed = await cardDiagnostic(p, 'CHANGED');
  assert.match(changed, /;not_now=1;/);
  await p.advance(5500);
  assert.equal(await cardDiagnostic(p, 'STABLE'), changed);
  for (let i = 1; i < scans.length; i++) assert.ok(scans[i] - scans[i - 1] >= 5000);
  p.command({ cmd: 'stop', id: 'STOP', requestID: 'S' }); await p.advance(100);
  const count = scans.length;
  new p.Element('iframe'); await p.advance(6000);
  assert.equal(scans.length, count);
  assert.equal(await cardDiagnostic(p, 'ENDED'), changed);
});

test('turn_card stays within 600 characters even with a deep ancestor chain', async () => {
  const rig = expiredPage({ layout: 'turn', reconnect: false }), { p } = rig;
  p.send({ conversationID: CID }); await settle(p);
  let parent = rig.container;
  for (let i = 0; i < 40; i++) parent = new p.Element('div', { 'data-testid': 'Fixture Account' }, parent);
  expiredCard(p, parent, { reconnect: false }); await p.advance(5500);
  const diag = await cardDiagnostic(p);
  assert.equal(diag.length, 600);
  assert.match(diag, /div\/-\/-\/yes\//);
  assert.ok(!diag.includes('Fixture Account'));
  assert.deepEqual(terminal(p), []);
});
