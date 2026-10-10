import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture, source } from './w185-pod-fixture.mjs';
import { expiredCard, userTurn, listMatches } from './fixtures/w331-expiredcard.mjs';
import { terminal } from './fixtures/w318-newrenderer.mjs';

const name = 'TATWO（Mac mini）4';
const message = `ChatGPT 裡的「${name}」連線已過期：到 OS 的本機 ChatGPT 連線卡按［連線］接回後再送一次`;
const clicks = p => p.nodes.map(n => n.clicks);
const forbidText = node => {
  for (const key of ['innerText', 'textContent']) Object.defineProperty(node, key, {
    configurable: true, get() { assert.fail(`readBlocked must not read ${node.tagName} ${key}`); },
  });
};

// Empty root, explicit native personalization consent, accepted original SSE with no ID.
// All fetches are synthetic; the hanging stream keeps personalizedReadBlocked true.
async function firstRound(layout = 'renderer') {
  const p = fixture({ allowNetwork: true, respond(_url, init) {
    assert.equal(init?.method, 'POST', 'a blocked first turn cannot poll the conversation');
    return { ok: true, status: 200, headers: new Headers({ 'content-type': 'text/event-stream' }), body: {},
      clone: () => ({ body: { getReader: () => ({ read: () => new Promise(() => {}) }) } }) };
  } });
  listMatches(p);
  new p.Element('button', { 'aria-label': 'Turn off temporary chat' });
  new p.Element('button', { 'aria-label': 'Personalized' });
  let body, stop, container, bubble;
  p.button.onClick = () => {
    const main = new p.Element('main');
    stop = new p.Element('button', { 'data-testid': 'stop-button' }, p.form);
    if (layout === 'turn') {
      ({ container, bubble } = userTurn(p, main));
      forbidText(bubble);
      body = new p.Element('div', { 'data-message-author-role': 'assistant' }, main);
    } else if (layout === 'renderer') {
      const region = new p.Element('section', { role: 'region', 'aria-label': 'Conversation' }, main);
      const container = new p.Element('div', {}, region);
      new p.Element('h4', { class: 'sr-only' }, container).textContent = 'ChatGPT said:';
      body = new p.Element('div', { class: 'Renderer-fixture' }, container);
    } else body = new p.Element('div', { 'data-message-author-role': 'assistant' }, main);
    // A completed-looking answer and generic error must remain unread during this first turn.
    body.textContent = 'PRIVATE ANSWER MUST NEVER BE READ';
    const answer = new p.Element('p', {}, body); forbidText(answer);
    const alert = new p.Element('div', { role: 'alert' }, main); forbidText(alert);
    forbidText(body);
    p.sandbox.fetch('https://chatgpt.com/backend-api/f/conversation', { method: 'POST',
      body: JSON.stringify({ model: 'auto', history_and_training_disabled: true, is_do_not_remember: false,
        messages: [{ content: { parts: [p.box.value] } }] }) }).catch(() => {});
  };
  p.send({ temporary: true, temporaryPersonalized: true });
  await p.advance(1000);
  assert.equal(p.button.clicks, 1);
  assert.equal(p.requests.length, 1);
  assert.deepEqual(terminal(p), []);
  assert.ok(p.reports.some(r => r.kind === 'accepted'));
  return { p, body, stop, container, bubble };
}

test('blocked first round real user turn reads only a wrapped approval card', async () => {
  const { p, body, stop, container } = await firstRound('turn');
  forbidText(container);
  await p.advance(15000);
  const card = expiredCard(p, container, { turn: true, wrapped: true });
  forbidText(card.account);
  forbidText(card.card);
  const before = clicks(p), routes = [...p.navigations], appeared = p.sandbox.Date.now();
  await p.advance(1200);
  assert.equal(terminal(p).length, 1);
  assert.equal(terminal(p)[0].kind, 'failed');
  assert.equal(terminal(p)[0].reason, 'connector_expired');
  assert.equal(terminal(p)[0].message, message);
  assert.ok(p.sandbox.Date.now() - appeared < 5000);
  assert.ok(stop.isConnected && body.isConnected);
  assert.deepEqual(clicks(p), before);
  assert.deepEqual(p.navigations, routes);
  assert.equal(p.requests.length, 1);
  assert.ok(!p.reports.some(r => r.kind === 'text' || r.kind === 'conversation'));
  p.command({ cmd: 'diagnostics', id: 'D' }); await p.advance(100);
  assert.equal(p.reports.find(r => r.id === 'D').data.turn, `connector_expired name_len=${Array.from(name).length}`);
  assert.ok(!JSON.stringify(p.reports).includes('Fixture Account'));
});

for (const layout of ['renderer', 'legacy']) for (const placement of ['answer', 'dialog', 'card']) for (const language of ['en', 'zh', 'zh-CN']) {
  test(`blocked first round ${layout}/${placement}/${language}: expired card fails in seconds without reading answers or clicking`, async () => {
    const { p, body, stop } = await firstRound(layout);
    await p.advance(15000);
    const card = expiredCard(p, placement === 'answer' ? body : null,
      { language, role: placement === 'dialog' ? 'dialog' : 'group' });
    const account = p.nodes.find(n => n.parentElement === card.card && n.textContent === 'Fixture Account');
    forbidText(account);
    const before = clicks(p), routes = [...p.navigations], appeared = p.sandbox.Date.now();
    await p.advance(1200);
    assert.equal(terminal(p).length, 1);
    assert.equal(terminal(p)[0].kind, 'failed');
    assert.equal(terminal(p)[0].reason, 'connector_expired');
    assert.equal(terminal(p)[0].message, message);
    assert.ok(p.sandbox.Date.now() - appeared < 5000);
    assert.ok(stop.isConnected);
    assert.deepEqual(clicks(p), before);
    assert.deepEqual(p.navigations, routes);
    assert.equal(p.requests.length, 1);
    assert.ok(!p.reports.some(r => r.kind === 'text' || r.kind === 'conversation'));
    p.command({ cmd: 'diagnostics', id: 'D' }); await p.advance(100);
    const diag = p.reports.find(r => r.id === 'D').data;
    assert.equal(diag.turn, `connector_expired name_len=${Array.from(name).length}`);
    assert.ok(!JSON.stringify(diag).includes(name));
    await p.advance(180000);
    assert.equal(terminal(p).length, 1);
    assert.deepEqual(clicks(p), before);
  });
}

for (const layout of ['renderer', 'legacy']) test(`${layout}: normal blocked first round keeps waiting with zero answer reads`, async () => {
  const { p } = await firstRound(layout), before = clicks(p);
  await p.advance(15000);
  assert.deepEqual(terminal(p), []);
  assert.equal(p.requests.length, 1);
  assert.deepEqual(clicks(p), before);
  assert.ok(!p.reports.some(r => r.kind === 'text' || r.kind === 'conversation'));
});

test('blocked first round scans incomplete connector cards at most once per second', async () => {
  const { p, body } = await firstRound();
  const card = expiredCard(p, body, { expired: false });
  const heading = p.nodes.find(n => n.parentElement === card.card && n.textContent === `Reconnect ${name}`);
  let reads = 0;
  Object.defineProperty(heading, 'textContent', { get() { reads++; return `Reconnect ${name}`; } });
  const before = clicks(p);
  for (let i = 0; i < 50; i++) { p.mutate(); await p.advance(100); }
  // Two heading reads per scan (normalized heading match and connector name).
  assert.equal(reads, 10);
  assert.deepEqual(terminal(p), []);
  assert.deepEqual(clicks(p), before);
});

test('expired scan precedes the privacy return while generic page errors retain their position', () => {
  const tick = source.slice(source.indexOf('function tick(turn)'), source.indexOf('// 專案裡送出後網頁'));
  assert.ok(tick.indexOf('expiredConnector(turn)') < tick.indexOf('if (readBlocked)'));
  assert.ok(tick.indexOf('expiredConnector(turn)') < tick.indexOf('if (turn.personalizedProof)'));
  assert.ok(tick.indexOf('expiredConnector(turn)') < tick.indexOf('35 * 60 * 1000'));
  assert.ok(tick.indexOf('expiredConnector(turn)') < tick.indexOf('turn.serverAnswer'));
  assert.ok(tick.indexOf('pageError(turn)') > tick.indexOf('if (readBlocked)'));
  assert.ok(!source.slice(source.indexOf('const pageError ='), source.indexOf('const thinkingPlaceholder')).includes('connector_expired'));
});
