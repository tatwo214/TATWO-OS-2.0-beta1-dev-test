import { fixture } from '../w185-pod-fixture.mjs';

export const CID = '11111111-2222-4333-8444-555555555555';
export const pageFull = '第一節｜完整頁面\n\n第二節｜段落與清單\n第三節｜結尾\nEND-W318-PAGE';
export const serverFull = pageFull + '\n伺服器仍有最後一段\nEND-W318-SERVER';
export function rendererPage({ api = 'finished', asyncStatus, language = 'en', stopLabel = 'Stop streaming', thinking = false, form = true } = {}) {
  let rig, round = 0;
  const p = fixture({ allowNetwork: true, respond(url, init) {
    if (init?.method === 'POST') {
      const frames = thinking ? [{ message: { id: 'reasoning', author: { role: 'assistant' }, channel: 'analysis',
        content: { content_type: 'thoughts', thoughts: [{ title: '已思考 5 秒' }] } } }] : [];
      const data = new TextEncoder().encode(frames.map(x => 'data: ' + JSON.stringify(x) + '\n\n').join(''));
      return { ok: true, status: 200, headers: new Headers({ 'content-type': 'text/event-stream' }), body: {},
        clone: () => ({ body: { getReader() { let first = true; return { read() {
          if (first && data.length) { first = false; return Promise.resolve({ done: false, value: data }); }
          return new Promise(() => {});
        } }; } } }) };
    }
    if (!url.includes('/conversation/') || round === 0) return Response.json({});
    if (api === 'failed') return new Response('{}', { status: 503 });
    if (api === 'hanging') return new Promise(() => {});
    const message = { id: 'answer-' + round, author: { role: 'assistant' }, channel: 'final',
      status: api === 'finished' ? 'finished_successfully' : api, end_turn: api === 'finished',
      content: { content_type: 'text', parts: [serverFull] } };
    return Response.json({ async_status: asyncStatus, current_node: message.id, mapping: { [message.id]: { parent: null, message } } });
  } });
  if (!form) p.form.tagName = 'DIV';
  p.sandbox.history.pushState({}, '', '/c/' + CID);
  const main = new p.Element('main');
  const region = new p.Element('section', { role: 'region', 'aria-label': language === 'en' ? 'Conversation' : '對話', class: 'thread-scroll-container' }, main);
  const transcript = new p.Element('div', { class: 'transcriptContent-fixture' }, region);
  const live = new p.Element('div', { role: 'status', 'aria-live': 'polite' }, main);
  live.textContent = 'Response complete'; // Already present before the new turn.
  const addTurn = text => {
    const container = new p.Element('div', { class: 'relative shrink-0' }, transcript);
    const user = new p.Element('h4', { class: 'sr-only' }, container); user.textContent = 'You said:';
    const bubble = new p.Element('div', { class: 'bg-user-message' }, container);
    new p.Element('div', { class: 'whitespace-pre-wrap' }, bubble).textContent = text;
    for (const label of ['Copy message', 'Share prompt', 'Edit message']) new p.Element('button', { 'aria-label': label }, container);
    const heading = new p.Element('h4', { class: 'sr-only' }, container); heading.textContent = language === 'en' ? 'ChatGPT said:' : 'ChatGPT 說：';
    const body = new p.Element('div', { class: 'relative PortalBoundary-fixture Renderer-fixture' }, container);
    new p.Element('h2', { class: 'TextBase-fixture Title-fixture' }, body);
    new p.Element('p', { class: 'TextBase-fixture Text-fixture' }, body);
    return { container, heading, body };
  };
  const actions = container => {
    for (const label of ['Copy', 'Share', 'Add to project sources', 'Read aloud', 'Regenerate response', 'More actions']) new p.Element('button', { 'aria-label': label }, container);
    new p.Element('div', {}, container).textContent = 'ChatGPT can make mistakes…';
  };
  const old = addTurn('old question'); old.body.textContent = 'old answer'; actions(old.container);
  p.button.onClick = () => {
    round++;
    const text = p.box.value;
    Object.assign(rig, addTurn(text));
    rig.stop = new p.Element('button', { 'aria-label': stopLabel }, p.form);
    rig.stop.onClick = () => { rig.stop.isConnected = false; p.button.disabled = false; };
    p.button.disabled = true;
    rig.body.textContent = '已思考 5 秒'; live.textContent = 'Thinking'; p.box.value = '';
    p.sandbox.fetch('https://chatgpt.com/backend-api/f/conversation', { method: 'POST',
      headers: { authorization: 'Bearer synthetic-w318' }, body: JSON.stringify({ model: 'auto', conversation_id: CID,
        messages: [{ content: { parts: [text] } }] }) }).catch(() => {});
  };
  p.sandbox.fetch('https://chatgpt.com/backend-api/me', { headers: { authorization: 'Bearer synthetic-w318' } });
  rig = { p, live, region, transcript, old, complete({ signal = 'both', text = pageFull } = {}) {
    rig.body.textContent = text;
    rig.stop.isConnected = false; p.button.disabled = false;
    if (signal !== 'actions') live.textContent = 'Response complete';
    if (signal !== 'live') actions(rig.container);
  } };
  return rig;
}
export const terminal = (p, id = 'S') => p.reports.filter(r => r.id === id && ['finished', 'failed'].includes(r.kind));
export async function settle(p, ms = 150) {
  for (let i = 0; i < 8; i++) { await new Promise(setImmediate); await p.advance(ms); }
}
