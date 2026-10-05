// Real embedded Pod script, synthetic response streams/DOM and virtual time. No ChatGPT connection.
import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture } from './w185-pod-fixture.mjs';
const CID = '11111111-1111-4111-8111-111111111111';
const encoder = new TextEncoder();
const frame = (obj, event = '') => (event ? 'event: ' + event + '\n' : '') + 'data: ' + (typeof obj === 'string' ? obj : JSON.stringify(obj)) + '\n\n';
function openStream() {
  let controller;
  const body = new ReadableStream({ start(c) { controller = c; } });
  // This synthetic clone leaves the original for the native page, just like Response.clone.
  const response = { ok: true, status: 200, body, headers: new Headers({ 'content-type': 'text/event-stream' }), clone: () => ({ body }) };
  return { response, raw: (v) => controller.enqueue(encoder.encode(v)), push: (v, name = '') => controller.enqueue(encoder.encode(frame(v, name))), end: () => controller.close() };
}
async function setup({ http, beforeSend, conversation = { current_node: 'old', mapping: {} } } = {}) {
  const stream = openStream();
  const p = fixture({ allowNetwork: true, respond(url, init) {
    if (init?.method === 'POST') return http || stream.response;
    return Response.json(typeof conversation === 'function' ? conversation() : conversation);
  } });
  const main = new p.Element('main');
  new p.Element('div', { 'data-message-author-role': 'user' }, main).innerText = 'synthetic previous question';
  p.sandbox.location.pathname = '/c/' + CID;
  p.button.onClick = () => p.sandbox.fetch('/backend-api/f/conversation', {
    method: 'POST', headers: { authorization: 'Bearer synthetic-only' },
    body: JSON.stringify({ conversation_id: CID, parent_message_id: 'old', messages: [{ content: { parts: ['synthetic question'] } }] }),
  });
  await p.sandbox.fetch('/backend-api/models', { headers: { authorization: 'Bearer synthetic-only' } });
  beforeSend?.(p, main);
  p.send({ conversationID: CID });
  await settle(p);
  assert.equal(p.button.clicks, 1, JSON.stringify(p.reports));
  p.beforeConversationReads = p.requests.filter(r => /\/conversation\//.test(r.url)).length;
  return { p, main, stream };
}
async function settle(p) { for (let n = 0; n < 8; n++) { await new Promise(setImmediate); await p.advance(100); } }
function failedOnce(p, text) {
  const terminal = p.reports.filter(r => r.id === 'S' && ['failed', 'finished'].includes(r.kind));
  assert.equal(terminal.length, 1, JSON.stringify(terminal));
  assert.equal(terminal[0].kind, 'failed');
  if (text) assert.match(terminal[0].message, text);
  return terminal[0];
}
const errorFormats = [
  ['event error, plain string', '對話太長，無法繼續', 'error'],
  ['event error, message/code', { message: 'The conversation is too long', code: 'conversation_too_long' }, 'error'],
  ['error string', { error: 'synthetic provider error' }],
  ['error object', { error: { message: 'synthetic provider error', code: 'server_error' } }],
  ['type error', { type: 'conversation_error', message: 'synthetic provider error' }],
  ['detail string', { detail: 'synthetic provider error' }],
  ['detail object', { detail: { message: 'synthetic provider error', code: 'server_error' } }],
  ['message metadata', { message: { metadata: { error: { message: 'synthetic provider error' } }, content: { content_type: 'text', parts: [] } } }],
  ['error content type', { message: { content: { content_type: 'error', parts: ['synthetic provider error'] } } }],
  ['metadata error_code + content', { message: { metadata: { error_code: 'context_length_exceeded' }, content: { parts: ['對話太長，無法繼續'] } } }],
  ['delta error', { p: '/message/metadata/error', o: 'replace', v: { message: 'synthetic provider error' } }],
];
for (const [name, obj, event] of errorFormats) test('W200 stream: ' + name + ' fails in under 5 seconds', async () => {
  const { p, stream } = await setup();
  stream.push(obj, event);
  await p.advance(400);
  const failure = failedOnce(p, /ChatGPT：/);
  if (name.includes('plain string') || name.includes('message/code') || name.includes('error_code')) assert.equal(failure.reason, 'conversation_too_long');
  else assert.equal(failure.reason, 'provider_failed', 'only parsed provider errors confirm terminal failure');
  if (name.includes('error_code')) assert.match(failure.message, /對話太長，無法繼續/);
  stream.push({ message: { id: 'late', author: { role: 'assistant' }, content: { content_type: 'text', parts: ['late'] } } });
  await p.advance(400);
  failedOnce(p);
  assert.equal(p.reports.some(r => r.full === 'late'), false);
});
for (const phrase of ['對話太長', '对话过长', 'too long', 'conversation_too_long', 'context_length_exceeded', 'max length', 'maximum length']) {
  test('W200 reason: ' + phrase, async () => {
    const { p, stream } = await setup(); stream.push({ error: { message: 'synthetic failure', code: phrase } });
    await p.advance(200); assert.equal(failedOnce(p).reason, 'conversation_too_long');
  });
}
for (const body of [{ detail: { message: 'synthetic provider error' } }, { detail: 'synthetic provider error' }, { error: { message: 'synthetic provider error' } }, { code: 'context_length_exceeded' }]) {
  test('W200 non-2xx body: ' + Object.keys(body), async () => {
    const { p } = await setup({ http: Response.json(body, { status: 400 }) }); await settle(p);
    failedOnce(p, /ChatGPT：/);
  });
}
test('W200 non-2xx caps body reads at 2KB and falls back to HTTP code', async () => {
  let reads = 0, cancelled = false;
  const http = { ok: false, status: 413, body: {}, clone() { return { body: { getReader() { return {
    async read() { reads++; return { value: encoder.encode('x'.repeat(8192)), done: false }; },
    async cancel() { cancelled = true; },
  }; } } }; } };
  const { p } = await setup({ http }); await p.advance(200);
  failedOnce(p, /HTTP 413/); assert.equal(reads, 1); assert.ok(cancelled);
});
test('W200 errors are bounded, sanitized and never enter diagnostics', async () => {
  const { p, stream } = await setup();
  const secret = 'sk-' + 'a'.repeat(48);
  stream.push({ error: { message: 'synthetic ' + secret + ' https://synthetic.invalid/?token=private ' + '錯'.repeat(250) } });
  await p.advance(250); const failure = failedOnce(p);
  assert.ok(Array.from(failure.message).length <= 160);
  assert.doesNotMatch(failure.message, /sk-|token=|synthetic\.invalid/);
  p.command({ cmd: 'diagnostics', id: 'D' }); await p.advance(1);
  assert.doesNotMatch(JSON.stringify(p.reports.filter(r => r.id === 'D')), /synthetic provider|sk-|錯錯|private/);
});
for (const kind of ['root-error', 'root-detail', 'fresh-node']) test('W200 poll error: ' + kind, async () => {
  const conversation = kind === 'fresh-node' ? { current_node: 'new', mapping: { new: { message: {
    id: 'new', author: { role: 'assistant' }, create_time: 1, metadata: { error: { message: 'synthetic provider error' } },
  } } } } : { [kind === 'root-error' ? 'error' : 'detail']: 'synthetic provider error' };
  const { p, stream } = await setup({ conversation });
  stream.push({ conversation_id: CID, type: 'stream_handoff' }); stream.end(); await p.advance(2500);
  failedOnce(p, /synthetic provider error/);
});
test('W200 poll ignores an error node from the previous turn', async () => {
  const { p, stream } = await setup({ conversation: { current_node: 'old', mapping: { old: { message: {
    id: 'old', create_time: -30, author: { role: 'assistant' }, metadata: { error: 'old synthetic failure' },
  } } }, async_status: 'in_progress' } });
  stream.push({ conversation_id: CID, type: 'stream_handoff' }); stream.end(); await p.advance(200000);
  assert.equal(p.failure(), undefined);
});
for (const attrs of [{ role: 'alert' }, { class: 'text-error' }, { class: 'text-red-500' }, { 'data-testid': 'conversation-error' }]) {
  test('W200 page error: ' + JSON.stringify(attrs), async () => {
    const { p, main } = await setup();
    const alert = new p.Element('div', attrs, main); alert.innerText = '對話太長，無法繼續。Retry';
    await p.advance(300); assert.equal(failedOnce(p).reason, 'conversation_too_long');
  });
}
test('W200 page: normal reply, quoted error, alert outside conversation and Pro placeholder do not fail', async () => {
  const { p, main } = await setup();
  const answer = new p.Element('div', { 'data-message-author-role': 'assistant' }, main);
  answer.innerText = 'An ordinary explanation of too long and context_length errors.';
  const outside = new p.Element('div', { role: 'alert' }); outside.innerText = 'unrelated error';
  await p.advance(500); assert.equal(p.failure(), undefined);
  answer.innerText = 'Pro thinking'; await p.advance(200000);
  assert.equal(p.failure(), undefined);
  assert.equal(p.reports.some(r => r.full === 'Pro thinking'), false);
});
test('W200 old page alert and a hidden new alert do not fail the current turn', async () => {
  const { p, main } = await setup({ beforeSend(p, main) {
    new p.Element('div', { role: 'alert' }, main).innerText = 'old synthetic error';
  } });
  const hidden = new p.Element('div', { role: 'alert' }, main); hidden.innerText = 'synthetic error'; hidden.hidden = true;
  await p.advance(300); assert.equal(p.failure(), undefined);
});
for (const event of [
  { type: 'thoughts', thoughts: [{ title: '核對資料', content: 'PRIVATE_REASONING_BODY' }] },
  { type: 'reasoning_recap', content: { title: '核對資料', text: 'PRIVATE_REASONING_BODY' } },
  { message: { content: { content_type: 'thoughts', thoughts: [{ summary_title: '核對資料', body: 'PRIVATE_REASONING_BODY' }] } } },
  { p: '/message/content/thoughts/0/title', o: 'replace', v: '核對資料' },
]) test('W200 progress headings only: ' + (event.type || event.p || 'message'), async () => {
  const { p, stream } = await setup(); stream.push(event); await p.advance(300);
  assert.equal(p.reports.find(r => r.kind === 'progress')?.title, '核對資料');
  assert.doesNotMatch(JSON.stringify(p.reports), /PRIVATE_REASONING_BODY/);
});
test('W200 progress title is at most 80 characters; body-only thoughts disclose no text', async () => {
  const { p, stream } = await setup();
  stream.push({ type: 'thoughts', title: '題'.repeat(100), content: 'PRIVATE_REASONING_BODY' });
  stream.push({ type: 'reasoning_recap', text: 'PRIVATE_REASONING_BODY' }); await p.advance(300);
  assert.equal(p.reports.find(r => r.kind === 'progress')?.title.length, 80);
  assert.doesNotMatch(JSON.stringify(p.reports), /PRIVATE_REASONING_BODY/);
});
test('W200 three minutes accepted without evidence confirms conversation once then fails', async () => {
  const { p } = await setup(); await p.advance(179000); assert.equal(p.failure(), undefined);
  await p.advance(5000); failedOnce(p, /3 分鐘沒有任何進度/);
  assert.equal(p.requests.filter(r => /\/conversation\//.test(r.url)).length - p.beforeConversationReads, 1, 'one authoritative confirmation of absent progress');
});
for (const evidence of ['bytes', 'progress', 'async', 'stop', 'placeholder']) test('W200 thinking evidence: ' + evidence + ' survives 3 minutes', async () => {
  const { p, main, stream } = await setup({ conversation: { mapping: {}, async_status: 'in_progress' } });
  if (evidence === 'async') { stream.push({ conversation_id: CID, type: 'stream_handoff' }); stream.end(); }
  if (evidence === 'stop') new p.Element('button', { 'data-testid': 'stop-button' }, main);
  if (evidence === 'placeholder') { const node = new p.Element('div', { 'data-message-author-role': 'assistant' }, main); node.innerText = 'Pro thinking'; }
  if (evidence === 'bytes' || evidence === 'progress') {
    for (let n = 0; n < 4; n++) { await p.advance(60000); stream.push(evidence === 'bytes' ? { type: 'synthetic-heartbeat' } : { type: 'thoughts', title: '核對資料' }); }
  } else await p.advance(240000);
  assert.equal(p.failure(), undefined);
  assert.equal(p.reports.some(r => r.kind === 'finished'), false);
});

test('W200 Retry box without alert/color has positive error evidence', async () => {
  const { p, main } = await setup();
  const box = new p.Element('div', {}, main);
  new p.Element('span', {}, box).textContent = 'There was a problem generating a response.';
  new p.Element('button', {}, box).textContent = 'Retry';
  await p.advance(300); failedOnce(p, /problem generating/);
});
test('W200 Markdown explaining an error with an ordinary Try again action is not a failure', async () => {
  const { p, main } = await setup();
  const box = new p.Element('div', { 'data-message-author-role': 'assistant' }, main);
  new p.Element('div', { class: 'markdown' }, box).textContent = 'An ordinary answer explains a synthetic error.';
  new p.Element('button', {}, box).textContent = 'Try again';
  const red = new p.Element('span', { class: 'text-red-500' }, box.childNodes[0]); red.innerText = 'synthetic error example';
  await p.advance(300); assert.equal(p.failure(), undefined);
});
test('W200 poll checks new provider errors within five seconds even after backoff reaches its maximum', async () => {
  let error = false;
  const { p, stream } = await setup({ conversation: () => error ? { detail: 'synthetic polling error' } : { mapping: {}, async_status: 'in_progress' } });
  stream.push({ conversation_id: CID, type: 'stream_handoff' }); stream.end();
  await p.advance(30000); error = true; await p.advance(4000);
  failedOnce(p, /synthetic polling error/);
});
test('W200 full reasoning content in an analysis channel is never answer text', async () => {
  const { p, stream } = await setup();
  stream.push({ message: { id: 'thought', channel: 'analysis', author: { role: 'assistant' },
    content: { content_type: 'text', parts: ['PRIVATE_REASONING_BODY'] } } });
  await p.advance(400); assert.doesNotMatch(JSON.stringify(p.reports), /PRIVATE_REASONING_BODY/);
});
test('W200 HTTP body that never arrives is still a terminal failure within five seconds', async () => {
  const http = { ok: false, status: 500, body: {}, clone() { return { body: { getReader() { return {
    read: () => new Promise(() => {}), cancel: async () => {},
  }; } } }; } };
  const { p } = await setup({ http }); await p.advance(3500); failedOnce(p, /HTTP 500/);
});
test('W200 persistent thinking evidence still respects the 35 minute hard deadline', async () => {
  const { p, main } = await setup();
  const node = new p.Element('div', { 'data-message-author-role': 'assistant' }, main); node.innerText = 'Pro thinking';
  await p.advance(35 * 60 * 1000 + 500);
  assert.equal(failedOnce(p).reason, 'timeout');
});

test('W200 a single reasoning heading remains positive thinking evidence without repeated bytes', async () => {
  const { p, stream } = await setup();
  stream.push({ type: 'thoughts', title: '伺服器仍在思考' });
  await p.advance(240000);
  assert.equal(p.failure(), undefined);
  assert.equal(p.reports.some(r => r.kind === 'finished'), false);
});

test('W200 typed context length error without a message still classifies its code', async () => {
  const { p, stream } = await setup(); stream.push({ type: 'context_length_error' });
  await p.advance(200); assert.equal(failedOnce(p).reason, 'conversation_too_long');
});
test('W200 polling never attributes the original parent error with no timestamp to this round', async () => {
  const { p, stream } = await setup({ conversation: { current_node: 'old', mapping: {
    old: { message: { id: 'original-parent', metadata: { error: 'old synthetic error' } } },
  } } });
  stream.push({ type: 'stream_handoff', conversation_id: CID }); stream.end();
  await p.advance(5000); assert.equal(p.failure(), undefined);
});

test('W200 SSE event name alone identifies a reasoning recap heading and omits its body', async () => {
  const { p, stream } = await setup();
  stream.push({ title: '事件摘要標題', text: 'PRIVATE_REASONING_BODY' }, 'reasoning_recap');
  await p.advance(200);
  assert.equal(p.reports.find(r => r.kind === 'progress')?.title, '事件摘要標題');
  assert.doesNotMatch(JSON.stringify(p.reports), /PRIVATE_REASONING_BODY/);
});
test('W200 a cumulative thoughts event selects its newest heading', async () => {
  const { p, stream } = await setup();
  stream.push({ type: 'thoughts', thoughts: [{ title: '舊標題' }, { title: '最新標題', body: 'PRIVATE_REASONING_BODY' }] });
  await p.advance(200); assert.equal(p.reports.find(r => r.kind === 'progress')?.title, '最新標題');
  assert.doesNotMatch(JSON.stringify(p.reports), /PRIVATE_REASONING_BODY/);
});
for (const phrase of ['You have reached the maximum length for this conversation.', '這則對話長度已達上限，請開啟新對話。']) {
  test('W200 maximum-length page alert: ' + phrase, async () => {
    const { p, main } = await setup();
    new p.Element('div', { role: 'alert' }, main).innerText = phrase;
    await p.advance(200); assert.equal(failedOnce(p).reason, 'conversation_too_long');
  });
}

test('W200 a final error SSE frame without a trailing blank line is still terminal', async () => {
  const { p, stream } = await setup();
  stream.raw('event: error\ndata: {"message":"synthetic EOF error"}'); stream.end();
  await p.advance(200); failedOnce(p, /synthetic EOF error/);
});

test('W200 polling an analysis node neither leaks its body nor replays the previous answer', async () => {
  const { p, stream } = await setup({ conversation: { current_node: 'thought', mapping: {
    old: { parent: null, message: { id: 'old', author: { role: 'assistant' }, content: { content_type: 'text', parts: ['OLD_ANSWER'] } } },
    thought: { parent: 'old', message: { id: 'thought', channel: 'analysis', author: { role: 'assistant' },
      status: 'finished_successfully', end_turn: false, content: { content_type: 'text', parts: ['PRIVATE_REASONING_BODY'] } } },
  } } });
  stream.push({ type: 'stream_handoff', conversation_id: CID }); stream.end();
  await p.advance(5000);
  assert.doesNotMatch(JSON.stringify(p.reports), /PRIVATE_REASONING_BODY|OLD_ANSWER/);
  assert.equal(p.reports.some(r => r.kind === 'finished'), false);
  assert.equal(p.reports.some(r => r.kind === 'progress'), true);
});

for (const field of ['error', 'detail']) test('W200 explicitly marked empty ' + field + ' object still terminates with a generic provider error', async () => {
  const { p, stream } = await setup(); stream.push({ [field]: {} });
  await p.advance(200); failedOnce(p, /ChatGPT 回報錯誤/);
});

test('W200 quoted credentials, authorization schemes and relative URL parameters are redacted locally', async () => {
  const { p, stream } = await setup();
  stream.push({ error: 'synthetic error "token":"QUOTED_SECRET_FIXTURE" authorization=Bearer SHORT_SECRET /path?q=QUERY_SECRET&x=SECOND_SECRET' });
  await p.advance(200); const failure = failedOnce(p);
  assert.doesNotMatch(failure.message, /QUOTED_SECRET_FIXTURE|SHORT_SECRET|QUERY_SECRET|SECOND_SECRET/);
  assert.ok(failure.message.length <= 160);
});

test('W200 known reasoning never forwards a thinking bubble recap body through DOM fallback', async () => {
  const { p, stream, main } = await setup();
  stream.push({ type: 'thoughts', title: '核對資料' }); await p.advance(200);
  new p.Element('div', { 'data-message-author-role': 'assistant' }, main).innerText = 'Thinking\n核對資料\nPRIVATE_REASONING_BODY';
  await p.advance(200);
  assert.doesNotMatch(JSON.stringify(p.reports), /PRIVATE_REASONING_BODY/);
  assert.equal(p.reports.some(r => r.kind === 'text'), false);
  stream.push({ message: { id: 'answer', author: { role: 'assistant' }, content: { content_type: 'text', parts: ['synthetic answer'] } } });
  await p.advance(200); assert.equal(p.reports.some(r => r.full === 'synthetic answer'), true);
});
test('W200 polling a finished thoughts content node never publishes its body or marks the answer finished', async () => {
  const { p, stream } = await setup({ conversation: { current_node: 'thought', mapping: {
    thought: { parent: null, message: { id: 'thought', author: { role: 'assistant' }, status: 'finished_successfully',
      end_turn: true, content: { content_type: 'thoughts', title: '核對資料', parts: ['PRIVATE_REASONING_BODY'] } } },
  } } });
  stream.push({ type: 'stream_handoff', conversation_id: CID }); stream.end();
  await p.advance(5000);
  assert.doesNotMatch(JSON.stringify(p.reports), /PRIVATE_REASONING_BODY/);
  assert.equal(p.reports.some(r => r.kind === 'finished'), false);
  assert.equal(p.reports.some(r => r.title === '核對資料'), true);
});

test('W200 a normal envelope type does not hide a failed message status', async () => {
  const { p, stream } = await setup(); stream.push({ type: 'message', status: 'failed', message: 'synthetic provider error' });
  await p.advance(200); failedOnce(p, /synthetic provider error/);
});
test('W200 the error type code classifies length even when the error text is generic', async () => {
  const { p, stream } = await setup(); stream.push({ type: 'conversation_too_long_error', error: 'synthetic provider error' });
  await p.advance(200); assert.equal(failedOnce(p).reason, 'conversation_too_long');
});

test('W207 repeated thinking headings keep activity but publish only changed progress', async () => {
  const { p, stream } = await setup();
  for (let n = 0; n < 3; n++) {
    stream.push({ type: 'thoughts', title: '合成進度' });
    await p.advance(300);
  }
  assert.equal(p.reports.filter(r => r.kind === 'progress' && r.title === '合成進度').length, 1);
  stream.push({ type: 'thoughts', title: '更新進度' });
  await p.advance(300);
  assert.equal(p.reports.filter(r => r.kind === 'progress' && r.title === '更新進度').length, 1);
});
