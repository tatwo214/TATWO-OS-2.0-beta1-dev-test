import { podScript } from './w185-pod-fixture.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const read = (name) => readFileSync(new URL('../App/Sources/Tatwo2/' + name, import.meta.url), 'utf8');
const source = read('TAP/ChatGPTTap.swift');
// W183 R9 審查（GPT-6 #3）：App 每次建立 Pod 換一把鑰匙（keyedPodScript 換掉佔位字），每個指令都帶它；測試用一把假的。
const POD_KEY = '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef';
const script = podScript(POD_KEY);
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// No real fetch, cookies, CEF, login or filesystem. Execute the actual embedded Pod script.
// delayFetch: the real page runs its own checks after Send is pressed and only then posts the message
//   (Infinity: the page swallowed the click and never posts). Read at each Send press, so a test can change it.
// holdResponse: the answer keeps streaming (page shows Stop) until Stop is pressed.
// stopOnSubmit: the page shows its Stop as soon as Send is pressed; pressing it before the request only hides it.
// stopAfterPost / respondAfter: the page shows Stop and the response headers arrive this long after the request.
// ignoreStopClicks: the page swallows this many Stop presses.
function fakePod({ delayFetch = 0, holdResponse = false, stopOnSubmit = false, stopAfterPost = 0, respondAfter = 0,
  ignoreStopClicks = 0 } = {}) {
  const reports = [], sent = [], timers = [];
  const state = { path: '/', composer: true, enabled: true, stop: false, stopClicks: 0, draft: '',
    posts: 0, holdResponse, endStream: null, delayFetch, served: [], aborted: 0, ignoreStopClicks };
  // Stable, connected DOM nodes: selection/focus, layout, editability and form ownership
  // are fixture capabilities, not exceptions in the production send checks.
  const element = (tagName, attrs = {}, parentElement = null) => ({
    tagName, parentElement, isConnected: true, hidden: false, inert: false, disabled: false, readOnly: false,
    style: { display: 'block', visibility: 'visible', opacity: '1' },
    getAttribute(name) { return attrs[name] ?? null; },
    getClientRects() { return this.hidden || this.style.display === 'none' ? [] : [{ width: 300, height: 40 }]; },
    matches(selector) { return selector === ':disabled' && this.disabled; },
    closest(selector) {
      for (let node = this; node; node = node.parentElement) {
        if (selector.split(',').some((part) => {
          const sel = part.trim();
          if (sel === 'form') return node.tagName === 'FORM';
          if (sel === '[inert]') return node.inert;
          const attr = sel.match(/^\[([\w-]+)="([^"]*)"\]$/);
          return !!attr && node.getAttribute(attr[1]) === attr[2];
        })) return node;
      }
      return null;
    },
    contains(other) {
      for (let node = other; node; node = node.parentElement) if (node === this) return true;
      return false;
    },
    get form() { return this.closest('form'); },
    querySelectorAll(selector) {
      return sandbox.document.querySelectorAll(selector).filter((node) => node !== this && this.contains(node));
    },
  });
  const form = element('FORM');
  const box = {
    ...element('TEXTAREA', { id: 'prompt-textarea' }, form),
    get isConnected() { return state.composer; },
    get value() { return state.draft; },
    get innerText() { return state.draft; },
    focus() { sandbox.document.activeElement = this; },
    select() { sandbox.document.selected = this; },
  };
  const stopButton = {
    ...element('BUTTON', { 'data-testid': 'stop-button' }, form),
    get isConnected() { return state.stop; },
    click() {
      state.stopClicks++;
      if (state.ignoreStopClicks > 0) { state.ignoreStopClicks--; return; }
      state.stop = false;
      state.endStream?.();
    },
  };
  const sendButton = {
    ...element('BUTTON', { 'data-testid': 'send-button', type: 'submit' }, form),
    get disabled() { return !state.enabled; },
    click() {
      const text = state.draft;
      sent.push({ text, path: state.path });
      if (stopOnSubmit) state.stop = true;
      const post = () => {
        state.posts++;
        sandbox.fetch('https://chatgpt.com/backend-api/f/conversation', {
          method: 'POST', headers: { authorization: 'Bearer fixture-only' },
          body: JSON.stringify({ action: 'next', model: 'auto', messages: [{ content: { parts: [text] } }] }),
        }).then((r) => r.text()).catch((e) => {
          // The page sees the same AbortError as after pressing its own Stop.
          if (e && e.name === 'AbortError') { state.aborted++; state.stop = false; } else throw e;
        });
      };
      const delay = state.delayFetch;
      if (delay === Infinity) return;
      if (delay) sandbox.setTimeout(post, delay);
      else post();
    },
  };
  const sandbox = {
    Headers, Request, Response, ReadableStream, TextEncoder, TextDecoder, URL, URLSearchParams,
    setTimeout(fn, ms) { const timer = setTimeout(fn, ms); timer.unref(); timers.push(timer); return timer; },
    setInterval(fn, ms) { const timer = setInterval(fn, ms); timer.unref(); timers.push(timer); return timer; },
    clearInterval, clearTimeout,
    location: { host: 'chatgpt.com', get pathname() { return state.path; } },
    history: { pushState(_a, _b, path) { state.path = path; } },
    PopStateEvent: class {},
    dispatchEvent() {},
    getComputedStyle: (node) => node.style,
    document: {
      readyState: 'complete',
      activeElement: null, selected: null,
      addEventListener() {},
      execCommand(cmd, _ui, text) {
        assert.equal(sandbox.document.activeElement, box, 'typing only in the focused composer');
        assert.equal(sandbox.document.selected, box, 'selection stays inside the composer');
        if (cmd === 'insertText') state.draft = text;
        if (cmd === 'delete') state.draft = '';
        return true;
      },
      querySelector(selector) {
        if (selector === '#prompt-textarea') return state.composer ? box : null;
        if (selector === '[data-message-author-role]') return {};
        if (selector === '[data-testid="stop-button"]') return state.stop ? stopButton : null;
        if (selector === '[data-testid="send-button"]') return sendButton;
        return null;
      },
      querySelectorAll(selector) {
        if (selector === '#prompt-textarea') return state.composer ? [box] : [];
        if (selector === '[data-testid="send-button"]' || selector === 'button[type="submit"]') return [sendButton];
        if (selector === '[data-testid="stop-button"]') return state.stop ? [stopButton] : [];
        if (selector === 'button') return state.stop ? [sendButton, stopButton] : [sendButton];
        return [];
      },
    },
    async fetch(input, init) {
      const url = typeof input === 'string' ? input : input.url;
      if (url.endsWith('/backend-api/f/conversation')) {
        // The fixture answer names the fixture question, so a stream delivered to the wrong user is visible.
        const asked = JSON.parse(init.body).messages[0]?.content?.parts?.[0] ?? '';
        // What actually reached ChatGPT.
        state.served.push(asked);
        const event = (status) => 'data: ' + JSON.stringify({ message: { id: 'fixture-answer', author: { role: 'assistant' },
          content: { content_type: 'text', parts: ['answer: ' + asked] }, status, end_turn: status === 'finished_successfully' },
        conversation_id: 'fixture-conversation' }) + '\n\n';
        if (state.holdResponse) {
          if (stopAfterPost) sandbox.setTimeout(() => { state.stop = true; }, stopAfterPost);
          else state.stop = true;
          if (respondAfter) await wait(respondAfter);
          return new Response(new ReadableStream({
            start(controller) {
              controller.enqueue(new TextEncoder().encode(event('in_progress')));
              state.endStream = () => { state.endStream = null; try { controller.close(); } catch {} };
            },
          }), { headers: { 'content-type': 'text/event-stream' } });
        }
        state.stop = false; // answered at once: the page's Stop (if it showed one on Send) goes away
        return new Response(event('finished_successfully') + 'data: [DONE]\n\n',
          { headers: { 'content-type': 'text/event-stream' } });
      }
      return new Response('{}', { headers: { 'content-type': 'application/json' } });
    },
  };
  sandbox.window = sandbox;
  vm.runInNewContext(script, sandbox)((json) => reports.push(JSON.parse(json)));
  return {
    reports, sent, state,
    command: (command) => sandbox.__tatwoPod.command({ ...command, key: POD_KEY }),
    async ready() {
      await sandbox.fetch('https://chatgpt.com/backend-api/me', { headers: { authorization: 'Bearer fixture-only' } });
    },
    async until(predicate, timeout = 4000) {
      const deadline = Date.now() + timeout;
      while (Date.now() < deadline) {
        const result = reports.find(predicate);
        if (result) return result;
        await wait(10);
      }
      assert.fail('fake Pod event timeout');
    },
    close() { state.endStream?.(); for (const timer of timers) { clearTimeout(timer); clearInterval(timer); } },
  };
}

test('Swift queue has scoped cancellation, stop acknowledgement gate, and idle usage accounting', () => {
  assert.match(source, /sendQueue\.removeFirst\(\)/);
  assert.match(source, /continuation\.yield\(\.queued\)/);
  assert.match(source, /continuation\.yield\(\.request\(id: id\)\)/);
  assert.match(source, /if activeRequestID != requestID/);
  assert.match(source, /if id == stopAcknowledgementID/);
  // W195（.055）：等網頁就緒的送出也算使用中；Coder 的背景工作租約與等待計數會讓網頁保持醒著（不被隱藏節流）。
  assert.match(source, /usageCount = leases\.count \+ readinessWaiters \+ streams\.count \+ \(stoppingRequestID == nil \? 0 : 1\)/);
  assert.match(source, /transport\.setBackgroundWorkActive\(!backgroundWorkLeases\.isEmpty \|\| readinessWaiters > 0 \|\| !streams\.isEmpty \|\| stoppingRequestID != nil/);
  assert.match(source, /guard !hasActiveUsers, !transport\.isHosted/);
  assert.match(source, /onTermination[\s\S]{0,220}stop\(requestID: id\)/);
  const space = read('TAP/ChatGPTSpace.swift');
  assert.match(space, /tap\.acquireLease\(\)/);
  assert.match(space, /tap\.releaseLease\(visibilityLease\)/);
  assert.match(space, /tap\.scheduleIdleSleep\(after: Self\.idleSleepDelay\)/);
  assert.match(space, /tap\.stop\(requestID: requestID\)/);
  // A send cancelled while still queued never reached ChatGPT: no "no reply" error or "reply ready" notice,
  // but the view the caller already changed (local question, removed answer, truncated history) goes back.
  assert.match(space, /case \.accepted:\s*dispatched = true/);
  assert.match(space, /let before = \(messages: messages, branchLeaf: branchLeaf\)\s*messages\.append\(TapMessage\(id: "local-user-/);
  assert.match(space, /let before = \(messages: messages, branchLeaf: branchLeaf\)\s*if let last = messages\.lastIndex/);
  assert.match(space, /let before = \(messages: messages, branchLeaf: branchLeaf\)\s*messages\.removeSubrange\(index\.\.\.\)/);
  assert.equal((space.match(/restore: before\)/g) || []).length, 3, 'send, regenerate and edit all pass their snapshot');
  const queued = space.split('if stopRequested, !dispatched {')[1]?.split('// 專案裡的新對話')[0] ?? '';
  assert.match(queued, /loadMessages\(conversationID, reuseInFlight: false\)/);
  assert.match(queued, /messages = restore\.messages\s*branchLeaf = restore\.branchLeaf/);
  assert.match(queued, /selectedID == nil, viewEpoch == epoch \{\s*messages = restore\.messages/);
  assert.match(queued, /return\s*\}\s*$/);
  assert.doesNotMatch(queued, /failure =|SpaceNotice|refresh\(\)/);
  assert.doesNotMatch(space, /tap\.stop\(\)|self\.tap\.sleep\(\)/);
});

test('session is memory-only, handles full-text replacement and needsLogin without opening UI', () => {
  const session = read('TAP/ChatGPTConversationSession.swift');
  for (const name of ['idle', 'needsLogin', 'queued', 'answering', 'failed']) assert.match(session, new RegExp('case ' + name));
  assert.match(session, /messages\[index\]\.text = full/);
  assert.match(session, /self\.requestID == id/);
  assert.match(session, /tap\.stop\(requestID: id\)/);
  assert.match(session, /guard tap\.connection != \.needsLogin/);
  assert.doesNotMatch(session, /FileManager|UserDefaults|ChatGPTSpaceModel|NSWorkspace|NSLog|print\(/);
  const checks = read('SelfTest.swift');
  assert.match(checks, /TATWO2_SELFTEST"\] == "w179tap"/);
  assert.match(checks, /W179FakeChatGPTPod: ChatGPTPodTransport/);
});

test('Pod: stopping while opening a conversation cancels preparation before acknowledging', async (t) => {
  const pod = fakePod();
  t.after(() => pod.close());
  await pod.ready();
  pod.command({ cmd: 'send', id: 'A', text: 'cancelled fixture', conversationID: 'first' });
  pod.command({ cmd: 'stop', id: 'STOP', requestID: 'A' });
  await pod.until((r) => r.type === 'result' && r.id === 'STOP');
  assert.equal(pod.sent.length, 0, 'cancelled preparation never presses Send');
  pod.command({ cmd: 'send', id: 'B', text: 'second fixture' });
  await pod.until((r) => r.type === 'stream' && r.id === 'B' && r.kind === 'finished');
  assert.deepEqual(pod.sent.map((s) => s.text), ['second fixture']);
  assert.ok(!pod.reports.some((r) => r.type === 'stream' && r.id === 'A' && r.kind === 'text'));
});

test('Pod: stopping during disabled Send wait cannot send later after a new request starts', async (t) => {
  const pod = fakePod();
  t.after(() => pod.close());
  await pod.ready();
  pod.state.enabled = false;
  pod.command({ cmd: 'send', id: 'A', text: 'old fixture' });
  const deadline = Date.now() + 3000;
  while (pod.state.draft !== 'old fixture' && Date.now() < deadline) await wait(10);
  assert.equal(pod.state.draft, 'old fixture');
  pod.command({ cmd: 'stop', id: 'STOP', requestID: 'A' });
  await pod.until((r) => r.type === 'result' && r.id === 'STOP');
  pod.state.enabled = true;
  pod.command({ cmd: 'send', id: 'B', text: 'new fixture' });
  await pod.until((r) => r.type === 'stream' && r.id === 'B' && r.kind === 'finished');
  assert.deepEqual(pod.sent.map((s) => s.text), ['new fixture']);
});

test('Pod: stopping an unknown request does not press another user’s Stop button', async (t) => {
  const pod = fakePod();
  t.after(() => pod.close());
  await pod.ready();
  pod.state.stop = true;
  pod.command({ cmd: 'stop', id: 'STOP', requestID: 'not-owned' });
  const result = await pod.until((r) => r.type === 'result' && r.id === 'STOP');
  assert.equal(result.data.stopped, false);
  assert.equal(pod.state.stopClicks, 0);
});

async function sentBy(pod, count) {
  const deadline = Date.now() + 3000;
  while (pod.sent.length < count && Date.now() < deadline) await wait(10);
  assert.equal(pod.sent.length, count, 'Send pressed');
}

test('Pod: a Send the page posts only after Stop is blocked, never reaching ChatGPT or the next user', async (t) => {
  const pod = fakePod({ delayFetch: 300, holdResponse: true });
  t.after(() => pod.close());
  await pod.ready();
  pod.command({ cmd: 'send', id: 'A', text: 'first fixture' });
  await sentBy(pod, 1);
  assert.equal(pod.state.posts, 0, 'the page has not posted the pressed Send yet');
  pod.command({ cmd: 'stop', id: 'STOP', requestID: 'A' });
  const receipt = await pod.until((r) => r.type === 'result' && r.id === 'STOP', 1000);
  assert.equal(receipt.ok, true);
  // Swift frees the single slot on this receipt and dispatches the next user right away.
  pod.state.holdResponse = false;
  pod.state.delayFetch = 0;
  pod.command({ cmd: 'send', id: 'B', text: 'second fixture' });
  await pod.until((r) => r.type === 'stream' && r.id === 'B' && r.kind === 'finished');
  await wait(400);
  const texts = pod.reports.filter((r) => r.type === 'stream' && r.id === 'B' && r.kind === 'text').map((r) => r.full);
  assert.ok(texts.length > 0 && texts.every((full) => full === 'answer: second fixture'), 'B received: ' + texts.join(' | '));
  assert.equal(pod.state.posts, 2, 'the page did post the stopped Send later');
  assert.deepEqual(pod.state.served, ['second fixture'], 'only the next user reached ChatGPT');
  assert.equal(pod.state.aborted, 1, 'the page got an AbortError for the stopped Send');
});

test('Pod: a Stop pressed before the page posts cannot let that late request stream into the next user', async (t) => {
  // The page shows Stop right after Send; pressing it before the request only hides it and the page still posts.
  const pod = fakePod({ delayFetch: 400, holdResponse: true, stopOnSubmit: true });
  t.after(() => pod.close());
  await pod.ready();
  pod.command({ cmd: 'send', id: 'A', text: 'first fixture' });
  await sentBy(pod, 1);
  pod.command({ cmd: 'stop', id: 'STOP', requestID: 'A' });
  const receipt = await pod.until((r) => r.type === 'result' && r.id === 'STOP', 1500);
  assert.equal(receipt.ok, true);
  assert.equal(pod.state.stopClicks, 1, 'its own Stop (shown after its Send) was pressed');
  pod.state.holdResponse = false;
  pod.state.delayFetch = 0;
  pod.command({ cmd: 'send', id: 'B', text: 'second fixture' });
  await pod.until((r) => r.type === 'stream' && r.id === 'B' && r.kind === 'finished');
  await wait(500);
  const texts = pod.reports.filter((r) => r.type === 'stream' && r.id === 'B' && r.kind === 'text').map((r) => r.full);
  assert.ok(texts.length > 0 && texts.every((full) => full === 'answer: second fixture'), 'B received: ' + texts.join(' | '));
  assert.deepEqual(pod.state.served, ['second fixture']);
  assert.equal(pod.state.aborted, 1);
});

test('Pod: a pressed Send the page never posts is released at once, without closing the Pod or eating the next Send', async (t) => {
  const pod = fakePod({ delayFetch: Infinity });
  t.after(() => pod.close());
  await pod.ready();
  pod.command({ cmd: 'send', id: 'A', text: 'swallowed fixture' });
  await sentBy(pod, 1);
  pod.command({ cmd: 'stop', id: 'STOP', requestID: 'A' });
  const receipt = await pod.until((r) => r.type === 'result' && r.id === 'STOP', 1500);
  assert.equal(receipt.ok, true, 'an ok receipt frees the slot; a failed one would make Swift close the Pod and fail every queued user');
  pod.state.delayFetch = 0;
  pod.command({ cmd: 'send', id: 'B', text: 'second fixture' });
  await pod.until((r) => r.type === 'stream' && r.id === 'B' && r.kind === 'finished');
  // The same question asked again is the next user's own request, not the stopped one.
  pod.command({ cmd: 'send', id: 'C', text: 'swallowed fixture' });
  await pod.until((r) => r.type === 'stream' && r.id === 'C' && r.kind === 'finished');
  const textOf = (id) => pod.reports.filter((r) => r.type === 'stream' && r.id === id && r.kind === 'text').map((r) => r.full);
  assert.ok(textOf('B').every((full) => full === 'answer: second fixture') && textOf('B').length > 0);
  assert.ok(textOf('C').every((full) => full === 'answer: swallowed fixture') && textOf('C').length > 0);
  assert.deepEqual(pod.state.served, ['second fixture', 'swallowed fixture']);
  assert.equal(pod.state.aborted, 0);
});

test('Pod: a stopped Send the page posts after the next user already finished is still blocked', async (t) => {
  const pod = fakePod({ delayFetch: 1500 });
  t.after(() => pod.close());
  await pod.ready();
  pod.command({ cmd: 'send', id: 'A', text: 'late fixture' });
  await sentBy(pod, 1);
  pod.command({ cmd: 'stop', id: 'STOP', requestID: 'A' });
  await pod.until((r) => r.type === 'result' && r.id === 'STOP' && r.ok === true, 1000);
  pod.state.delayFetch = 0;
  pod.command({ cmd: 'send', id: 'B', text: 'second fixture' });
  await pod.until((r) => r.type === 'stream' && r.id === 'B' && r.kind === 'finished');
  const deadline = Date.now() + 3000;
  while (pod.state.posts < 2 && Date.now() < deadline) await wait(20);
  await wait(200);
  assert.equal(pod.state.posts, 2);
  assert.deepEqual(pod.state.served, ['second fixture']);
  assert.equal(pod.state.aborted, 1);
  assert.ok(!pod.reports.some((r) => r.type === 'stream' && r.kind === 'text' && r.full === 'answer: late fixture'));
});

test('Pod: Stop right after the request is posted waits for the page to show Stop and presses it', async (t) => {
  // Request posted, response headers and the page's Stop not there yet.
  const pod = fakePod({ holdResponse: true, stopAfterPost: 300, respondAfter: 900 });
  t.after(() => pod.close());
  await pod.ready();
  pod.command({ cmd: 'send', id: 'A', text: 'just posted fixture' });
  const deadline = Date.now() + 3000;
  while (pod.state.served.length < 1 && Date.now() < deadline) await wait(5);
  assert.equal(pod.state.served.length, 1);
  pod.command({ cmd: 'stop', id: 'STOP', requestID: 'A' });
  const receipt = await pod.until((r) => r.type === 'result' && r.id === 'STOP', 3000);
  assert.equal(receipt.ok, true);
  assert.equal(receipt.data.stopped, true);
  assert.equal(pod.state.stopClicks, 1, 'the Stop that appeared after the request was pressed before releasing');
});

test('Pod: a Stop press the page does not take is repeated until the answer stops', async (t) => {
  const pod = fakePod({ holdResponse: true, ignoreStopClicks: 1 });
  t.after(() => pod.close());
  await pod.ready();
  pod.command({ cmd: 'send', id: 'A', text: 'stubborn fixture' });
  await pod.until((r) => r.type === 'stream' && r.id === 'A' && r.kind === 'accepted');
  pod.command({ cmd: 'stop', id: 'STOP', requestID: 'A' });
  const receipt = await pod.until((r) => r.type === 'result' && r.id === 'STOP', 4000);
  assert.equal(receipt.ok, true);
  assert.equal(pod.state.stopClicks, 2);
  assert.equal(pod.state.stop, false, 'released only after the page stopped');
});

test('Pod: stopping a request that is still preparing never presses a Stop button it did not cause', async (t) => {
  const pod = fakePod();
  t.after(() => pod.close());
  await pod.ready();
  pod.state.stop = true;
  pod.command({ cmd: 'send', id: 'A', text: 'preparing fixture', conversationID: 'first' });
  pod.command({ cmd: 'stop', id: 'STOP', requestID: 'A' });
  const receipt = await pod.until((r) => r.type === 'result' && r.id === 'STOP');
  assert.equal(receipt.ok, true);
  assert.equal(pod.sent.length, 0);
  assert.equal(pod.state.stopClicks, 0);
});

test('Pod: stopping an answer that is already streaming presses its Stop and releases promptly', async (t) => {
  const pod = fakePod({ holdResponse: true });
  t.after(() => pod.close());
  await pod.ready();
  pod.command({ cmd: 'send', id: 'A', text: 'streaming fixture' });
  await pod.until((r) => r.type === 'stream' && r.id === 'A' && r.kind === 'accepted');
  pod.command({ cmd: 'stop', id: 'STOP', requestID: 'A' });
  const receipt = await pod.until((r) => r.type === 'result' && r.id === 'STOP', 1000);
  assert.equal(receipt.ok, true);
  assert.equal(receipt.data.stopped, true);
  assert.equal(pod.state.stopClicks, 1);
});

test('Pod: stopping a posted answer while the page hides Stop (server-side thinking) still releases promptly', async (t) => {
  const pod = fakePod({ holdResponse: true });
  t.after(() => pod.close());
  await pod.ready();
  pod.command({ cmd: 'send', id: 'A', text: 'thinking fixture' });
  await pod.until((r) => r.type === 'stream' && r.id === 'A' && r.kind === 'accepted');
  pod.state.stop = false;
  pod.command({ cmd: 'stop', id: 'STOP', requestID: 'A' });
  const receipt = await pod.until((r) => r.type === 'result' && r.id === 'STOP', 1000);
  assert.equal(receipt.ok, true);
  assert.equal(receipt.data.stopped, false);
  assert.equal(pod.state.stopClicks, 0);
});
