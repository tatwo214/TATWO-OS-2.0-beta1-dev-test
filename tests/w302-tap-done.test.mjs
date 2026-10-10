// Production Pod script, synthetic DOM and virtual time. No browser/account/network.
import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture } from './w185-pod-fixture.mjs';

const terminal = p => p.reports.filter(r => r.id === 'S' && ['finished', 'failed'].includes(r.kind));
const answerText = '有必修\n\n必修 1｜Claude 更新無誤\n必修 2｜等待全文\n必修 3｜完成訊號\n必修 4｜隔離測試\n必修 5｜完整保存\n建議 1｜穩定等待\n建議 2｜重讀正文\n建議 3｜舊版面\n結論：回答已完整。';

function page() {
  const p = fixture();
  // An older completed turn and unchanged live region must never complete this turn.
  const old = new p.Element('article');
  new p.Element('div', {}, old).textContent = 'old answer';
  new p.Element('button', { 'aria-label': 'Copy response' }, old);
  const live = new p.Element('div', { 'aria-live': 'polite', role: 'status' });
  live.textContent = 'Response complete';
  let stop, body, article;
  p.button.onClick = () => {
    stop = new p.Element('button', { 'data-testid': 'stop-button' });
    article = new p.Element('article', { 'data-testid': 'conversation-turn-2' });
    const message = new p.Element('div', { 'data-message-author-role': 'assistant' }, article);
    new p.Element('div', {}, message).textContent = '已思考 5 秒';
    body = new p.Element('div', { class: 'markdown' }, message);
    body.textContent = 'Thinking';
    live.textContent = 'Thinking';
  };
  p.send();
  return { p, live, get stop() { return stop; }, get body() { return body; }, get article() { return article; } };
}

for (const layout of ['live', 'legacy']) test(`5s thinking → 3s gap → 20s stream → ${layout} completion saves full page`, async () => {
  const rig = page(), { p, live } = rig;
  await p.advance(5000);
  assert.deepEqual(terminal(p), []);
  rig.stop.isConnected = false;
  rig.body.textContent = '';
  await p.advance(3000);
  assert.deepEqual(terminal(p), [], 'thinking-to-answer gap cannot complete');
  // A code block Copy action is not a response action bar.
  const pre = new p.Element('pre', {}, rig.body);
  new p.Element('button', { 'aria-label': 'Copy' }, pre);
  for (let i = 1; i <= 20; i++) {
    rig.body.textContent = answerText.slice(0, Math.max(22, Math.floor(answerText.length * i / 20)));
    await p.advance(1000);
    assert.deepEqual(terminal(p), [], `still generating after ${i} body seconds`);
  }
  if (layout === 'live') live.textContent = 'Response complete';
  else { live.isConnected = false; new p.Element('button', { 'aria-label': '複製' }, rig.article); }
  await p.advance(1800);
  assert.deepEqual(terminal(p), [], 'completion must stay stable for two seconds');
  // A late page update resets the stability window and becomes the saved answer.
  const full = answerText + '\n最後補充：全文以網頁為準。';
  rig.body.textContent = full;
  await p.advance(1800);
  assert.deepEqual(terminal(p), []);
  await p.advance(500);
  assert.equal(terminal(p).length, 1);
  assert.equal(terminal(p)[0].kind, 'finished');
  const texts = p.reports.filter(r => r.id === 'S' && r.kind === 'text');
  assert.equal(texts.at(-1).full, full);
  assert.equal(p.reports.indexOf(texts.at(-1)) + 1, p.reports.indexOf(terminal(p)[0]), 'final reread immediately precedes completion');
});

test('completed live region and stable text still wait for the stop button', async () => {
  const rig = page(), { p } = rig;
  await p.advance(1000);
  rig.body.textContent = answerText;
  rig.live.textContent = 'Response complete';
  await p.advance(5000);
  assert.deepEqual(terminal(p), []);
  rig.stop.isConnected = false;
  await p.advance(2300);
  assert.equal(terminal(p)[0]?.kind, 'finished');
});

test('35 minute deadline reports unfinished even with stable partial text', async () => {
  const rig = page(), { p } = rig;
  await p.advance(5000);
  rig.stop.isConnected = false;
  rig.body.textContent = answerText.slice(0, 22);
  await p.advance(35 * 60 * 1000);
  assert.equal(terminal(p).length, 1);
  assert.equal(terminal(p)[0].kind, 'failed');
  assert.equal(terminal(p)[0].reason, 'timeout');
  assert.match(terminal(p)[0].message, /未完成/);
});

test('short SSE snapshot cannot complete and final page text replaces it', async () => {
  let p, article, body;
  p = fixture({ allowNetwork: true, respond(url, init) {
    if (init?.method !== 'POST') return Response.json({ mapping: {} });
    const frame = { message: { id: 'partial', author: { role: 'assistant' },
      content: { content_type: 'text', parts: [answerText.slice(0, 22)] } } };
    return new Response('data: ' + JSON.stringify(frame) + '\n\ndata: [DONE]\n\n',
      { headers: { 'content-type': 'text/event-stream' } });
  } });
  p.button.onClick = () => {
    article = new p.Element('article');
    const message = new p.Element('div', { 'data-message-author-role': 'assistant' }, article);
    body = new p.Element('div', { class: 'markdown' }, message);
    body.textContent = answerText.slice(0, 22);
    p.sandbox.fetch('https://chatgpt.com/backend-api/f/conversation', { method: 'POST',
      body: JSON.stringify({ model: 'auto', messages: [{ content: { parts: [p.box.value] } }] }) }).catch(() => {});
  };
  p.send();
  await p.advance(1000);
  for (let i = 0; i < 8; i++) { await new Promise(setImmediate); await p.advance(200); }
  assert.ok(p.reports.some(r => r.kind === 'text' && r.full === answerText.slice(0, 22)));
  await p.advance(10000);
  assert.deepEqual(terminal(p), [], 'EOF with partial text is not webpage completion');
  body.textContent = answerText;
  new p.Element('button', { 'aria-label': 'Copy response' }, article);
  await p.advance(2300);
  assert.equal(terminal(p)[0]?.kind, 'finished');
  assert.equal(p.reports.filter(r => r.kind === 'text').at(-1).full, answerText);
});

const flushNetwork = async p => {
  for (let i = 0; i < 10; i++) { await new Promise(setImmediate); await p.advance(100); }
};
const frame = message => 'data: ' + JSON.stringify({ message }) + '\n\n';
const reply = (text, status = 'finished_successfully', channel = 'final') => ({
  id: 'server-answer', author: { role: 'assistant' }, channel, status, end_turn: true,
  content: { content_type: 'text', parts: [text] },
});
const sendFetch = p => p.sandbox.fetch('https://chatgpt.com/backend-api/f/conversation', {
  method: 'POST', headers: { authorization: 'Bearer synthetic-fixture' },
  body: JSON.stringify({ model: 'auto', messages: [{ content: { parts: [p.box.value] } }] }),
}).catch(() => {});

for (const encoding of ['legacy', 'v1']) test(`${encoding} finished message uses server full text despite stale page and stop button`, async () => {
  const full = answerText + '\n\nserver tail';
  const message = reply(answerText, encoding === 'v1' ? 'in_progress' : 'finished_successfully');
  message.content.parts.push('server tail');
  const sse = encoding === 'legacy' ? frame(message)
    : 'data: ' + JSON.stringify({ p: '', o: 'add', c: 1, v: { message } }) + '\n\n'
      + 'data: ' + JSON.stringify({ p: '/message/status', o: 'replace', v: 'finished_successfully' }) + '\n\n';
  const p = fixture({ allowNetwork: true, respond: () => new Response(sse + 'data: [DONE]\n\n', { headers: { 'content-type': 'text/event-stream' } }) });
  p.button.onClick = () => {
    new p.Element('button', { 'data-testid': 'stop-button' });
    const node = new p.Element('div', { 'data-message-author-role': 'assistant' });
    new p.Element('div', { class: 'markdown' }, node).textContent = 'stale page snapshot';
    sendFetch(p);
  };
  p.send(); await flushNetwork(p);
  assert.equal(terminal(p).length, 1);
  assert.equal(terminal(p)[0].kind, 'finished');
  assert.equal(p.reports.filter(r => r.kind === 'text').at(-1).full, full);
});

test('finished reasoning and thinking placeholders never complete a turn', async () => {
  const sse = frame(reply('private reasoning', 'finished_successfully', 'analysis'))
    + frame(reply('Pro thinking')) + frame(reply('已思考 5 秒')) + 'data: [DONE]\n\n';
  const p = fixture({ allowNetwork: true, respond: () => new Response(sse, { headers: { 'content-type': 'text/event-stream' } }) });
  p.button.onClick = () => sendFetch(p);
  p.send(); await flushNetwork(p); await p.advance(10000);
  assert.deepEqual(terminal(p), []);
  assert.ok(!p.reports.some(r => r.kind === 'text'));
});

test('completed thinking label with a copy action still waits for body text', async () => {
  const rig = page(), { p } = rig;
  await p.advance(1000);
  rig.body.isConnected = false;
  rig.body.parentElement.textContent = '已思考 5 秒';
  rig.stop.isConnected = false;
  new p.Element('button', { 'aria-label': 'Copy response' }, rig.article);
  await p.advance(10000);
  assert.deepEqual(terminal(p), []);
});

test('handoff discards pre-handoff finished text and polling saves the fresh server full answer', async () => {
  const cid = '11111111-2222-4333-8444-555555555555';
  let polls = 0;
  const p = fixture({ allowNetwork: true, respond(_url, init) {
    if (init?.method === 'POST') return new Response(frame(reply('pre-handoff text'))
      + 'data: ' + JSON.stringify({ type: 'stream_handoff', conversation_id: cid }) + '\n\ndata: [DONE]\n\n',
      { headers: { 'content-type': 'text/event-stream' } });
    const m = ++polls === 1 ? { ...reply('OLD'), create_time: -3600 }
      : polls === 2 ? reply('reasoning body', 'finished_successfully', 'analysis')
        : polls === 3 ? reply('Pro thinking') : reply(answerText);
    return Response.json({ current_node: m.id, mapping: { [m.id]: { message: m } } });
  } });
  p.button.onClick = () => {
    const node = new p.Element('div', { 'data-message-author-role': 'assistant' });
    new p.Element('div', { class: 'markdown' }, node).textContent = 'stale DOM body';
    sendFetch(p);
  };
  p.send(); await flushNetwork(p);
  for (let i = 0; i < 15 && !terminal(p).length; i++) { await p.advance(1000); await flushNetwork(p); }
  assert.ok(polls >= 4);
  assert.equal(terminal(p).length, 1);
  assert.equal(terminal(p)[0].kind, 'finished');
  assert.equal(p.reports.filter(r => r.kind === 'text').at(-1).full, answerText);
  assert.ok(!p.reports.some(r => r.kind === 'text' && ['OLD', 'reasoning body', 'Pro thinking'].includes(r.full)));
});
