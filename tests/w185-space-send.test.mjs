// Exact embedded Pod JS, synthetic DOM + virtual time only. No account, network, browser, or build.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

import { source, start, script, key, fixture } from './w185-pod-fixture.mjs';

const notSubmitted = (pod) => {
  const failure = pod.failure();
  assert.ok(failure, JSON.stringify(pod.reports));
  assert.equal(failure.submitted, false);
  assert.equal(pod.nodes.reduce((n, el) => n + el.clicks, 0), 0);
  assert.equal(pod.reports.filter((r) => r.id === 'S' && r.kind === 'failed').length, 1);
};

// Provider labels observed in the native comparison, not guessed transport-field semantics.
function nativeTemporary(p, mode = 'personalized', parent = null) {
  const toggle = new p.Element('button', { 'aria-label': mode === 'off' ? 'Temporary chat' : 'Turn off temporary chat' }, parent);
  const picker = new p.Element('button', { 'aria-label': mode === 'unpersonalized' ? 'Unpersonalized' : 'Personalized' }, parent);
  if (mode === 'off') picker.isConnected = false;
  return { toggle, picker };
}

const CID = '11111111-1111-4111-8111-111111111111';
const OTHER_CID = '22222222-2222-4222-8222-222222222222';
const nativeFlags = { history_and_training_disabled: true, is_do_not_remember: false };
const sendRequests = (p) => p.requests.filter((r) => /\/conversation$/.test(r.url) && r.init?.method === 'POST');
const settle = async (p) => {
  // Node Response.clone streams use the event loop as well as Promise microtasks.
  for (let i = 0; i < 8; i++) { await new Promise(setImmediate); await p.advance(150); }
};
async function provenChat({ initialFlags = nativeFlags, serverIDs = [CID], route = CID, pollAfterReadError = false,
  navigationEvents = true } = {}) {
  const p = fixture({ allowNetwork: true, navigationEvents, respond(url, init) {
    if (init?.method !== 'POST') return Response.json(pollAfterReadError && /\/conversation\//.test(url)
      ? { current_node: 'a1', mapping: { a1: { parent: null, message: {
        id: 'a1', author: { role: 'assistant' }, status: 'finished_successfully', end_turn: true,
        content: { content_type: 'text', parts: ['synthetic polled reply'] },
      } } } } : { models: [], mapping: {} });
    if (url.endsWith('/prepare')) return Response.json({});
    if (typeof route === 'function') route(p);
    else if (route) p.sandbox.history.pushState({}, '', '/c/' + route);
    if (pollAfterReadError) {
      // Deterministic synthetic reader: authoritative ID frame, then transport read-error.
      // Proof must be bound by real readStream parsing; poll supplies completion, never identity.
      return { ok: true, status: 200, headers: new Headers({ 'content-type': 'text/event-stream' }), body: {},
        clone: () => ({ body: { getReader() {
          let first = true;
          return { async read() {
            if (!first) throw new Error('synthetic read failure');
            first = false;
            return { done: false, value: new TextEncoder().encode(serverIDs.map((conversation_id) =>
              'data: ' + JSON.stringify({ conversation_id, type: 'synthetic', kind: 'token', token: 'PRIVATE_TOKEN' }) + '\n\n').join('')) };
          } };
        } } }) };
    }
    const frames = serverIDs.map((conversation_id) => ({ conversation_id,
      message: { id: 'synthetic-answer', author: { role: 'assistant' },
        content: { content_type: 'text', parts: ['synthetic reply'] } } }));
    return new Response(frames.map((x) => 'data: ' + JSON.stringify(x) + '\n\n').join('') + 'data: [DONE]\n\n',
      { headers: { 'content-type': 'text/event-stream' } });
  } });
  const ui = nativeTemporary(p);
  p.submit = (flags = nativeFlags, id = null, extra = {}) => p.sandbox.fetch(
    'https://chatgpt.com/backend-api/f/conversation', {
      method: 'POST', headers: { authorization: 'Bearer synthetic-fixture-only' },
      body: JSON.stringify({ model: 'auto', ...flags,
        ...(id ? { conversation_id: id } : {}), messages: [{ content: { parts: [p.box.value] } }] }),
      ...extra,
    }).catch(() => {});
  p.button.onClick = () => p.submit(initialFlags);
  p.send({ temporary: true, temporaryPersonalized: true });
  await p.advance(1000);
  await settle(p);
  p.box.value = '';
  ui.toggle.isConnected = ui.picker.isConnected = false;
  new p.Element('div', { 'data-message-author-role': 'assistant' });
  p.follow = async (extra = {}, flags = nativeFlags, requestID = CID) => {
    p.button.onClick = () => p.submit(flags, requestID);
    p.send({ id: 'F', conversationID: CID, temporary: true, temporaryPersonalized: true, ...extra });
    await p.advance(2000);
    await settle(p);
  };
  return p;
}

test('continuation: missing picker uses genuine original-flags + server-ID proof, not URL alone', async () => {
  const p = await provenChat();
  assert.ok(p.reports.some((r) => r.id === 'S' && r.kind === 'finished'));
  await p.follow();
  assert.equal(sendRequests(p).length, 2, JSON.stringify(p.reports));
  assert.ok(p.reports.some((r) => r.id === 'F' && r.kind === 'temporary'));
  assert.deepEqual(Object.fromEntries(Object.keys(nativeFlags).map((k) =>
    [k, JSON.parse(sendRequests(p)[1].init.body)[k]])), nativeFlags);
});

test('native-page continuation: completed proof stays at root; forced routing would destroy native state', async () => {
  const p = await provenChat({ route: null });
  assert.ok(p.reports.some((r) => r.id === 'S' && r.kind === 'finished'));
  p.sandbox.onNavigate = () => {
    nativeTemporary(p, 'off');
    p.nodes.filter((n) => n.attrs['data-message-author-role']).forEach((n) => { n.isConnected = false; });
  };
  await p.follow();
  await p.advance(20000);
  assert.equal(sendRequests(p).length, 2, 'same native page must send without routeTo');
  assert.deepEqual(p.navigations, []);
  assert.equal(p.sandbox.location.pathname, '/');
});

function regenerationButton(p, flags = nativeFlags, requestID = CID) {
  const group = new p.Element('div');
  p.nodes.find((n) => n.attrs['data-message-author-role'] === 'assistant').parentElement = group;
  new p.Element('button', { 'aria-label': 'Copy response' }, group);
  new p.Element('button', { 'aria-label': 'Share' }, group);
  const retry = new p.Element('button', { 'aria-label': 'Regenerate' }, group);
  retry.onClick = () => p.submit(flags, requestID);
  return retry;
}

test('native-page continuation: regenerate and edit retain the native page and exact request guards', async () => {
  for (const action of ['regenerate', 'edit']) {
    const p = await provenChat({ route: null });
    if (action === 'regenerate') {
      regenerationButton(p);
      p.command({ cmd: 'regenerate', id: 'R', conversationID: CID, temporary: true, temporaryPersonalized: true });
      await p.advance(3000);
      await settle(p);
    } else {
      await p.follow({ parentID: 'synthetic-edit-parent' }, { ...nativeFlags, parent_message_id: 'native-parent' });
      assert.equal(JSON.parse(sendRequests(p).at(-1).init.body).parent_message_id, 'synthetic-edit-parent');
    }
    assert.equal(sendRequests(p).length, 2, action);
    assert.deepEqual(p.navigations, [], action + ' must not call routeTo');
  }
});

test('native-page continuation: authoritative ID survives read-error then poll completion without a route', async () => {
  const p = await provenChat({ route: null, pollAfterReadError: true });
  assert.ok(p.reports.some((r) => r.id === 'S' && r.kind === 'finished' && /read-error/.test(r.shape)),
    'the first turn must really finish through the error/poll path');
  await p.follow();
  assert.equal(sendRequests(p).length, 2);
  assert.deepEqual(p.navigations, []);
});

test('native-page continuation: send/edit/regenerate still require original flags and matching original body ID', async () => {
  for (const action of ['send', 'edit', 'regenerate']) for (const bad of ['flags', 'body-id']) {
    const p = await provenChat({ route: null });
    const flags = bad === 'flags' ? { is_do_not_remember: false } : nativeFlags;
    const id = bad === 'body-id' ? OTHER_CID : CID;
    if (action === 'regenerate') {
      const retry = regenerationButton(p, flags, id);
      p.command({ cmd: 'regenerate', id: 'R', conversationID: CID, temporary: true, temporaryPersonalized: true });
      await p.advance(3000);
      assert.equal(retry.clicks, 1, 'must reach the original request guard, not a missing UI failure');
    } else await p.follow(action === 'edit' ? { parentID: 'synthetic-edit-parent' } : {}, flags, id);
    assert.equal(sendRequests(p).length, 1, action + '/' + bad);
    assert.deepEqual(p.navigations, []);
  }
});

test('native-page continuation: navigation out/back including the matching ID route, or mode change, revokes proof', async () => {
  for (const change of ['other-route', 'same-id-route', 'mode']) {
    const p = await provenChat({ route: null });
    if (change === 'mode') {
      const ui = nativeTemporary(p, 'unpersonalized');
      p.mutate();
      ui.picker.isConnected = ui.toggle.isConnected = false;
    } else {
      p.sandbox.history.pushState({}, '', change === 'same-id-route' ? '/c/' + CID : '/other');
      p.sandbox.history.pushState({}, '', '/');
    }
    const count = p.navigations.length;
    await p.follow();
    assert.equal(sendRequests(p).length, 1, change);
    assert.equal(p.navigations.length, count, 'failed proof must not fall back to routing');
  }
});

test('native-page regenerate: cancellation, navigation or mode reversal while opening retry menu cannot click Try again', async () => {
  for (const change of ['cancel', 'navigate', 'mode']) {
    const p = await provenChat({ route: null });
    const retry = regenerationButton(p);
    retry.attrs['aria-label'] = 'Switch model';
    let item;
    retry.onClick = () => {
      item = new p.Element('button', { role: 'menuitem', 'aria-label': 'Try again' });
      item.onClick = () => p.submit(nativeFlags, CID);
      Promise.resolve().then(() => {
        if (change === 'cancel') p.command({ cmd: 'stop', id: 'C', requestID: 'R' });
        if (change === 'navigate') p.sandbox.history.pushState({}, '', '/other');
        if (change === 'mode') nativeTemporary(p, 'unpersonalized');
      });
    };
    p.command({ cmd: 'regenerate', id: 'R', conversationID: CID, temporary: true, temporaryPersonalized: true });
    await p.advance(3000);
    assert.equal(retry.clicks, 1, change + ' really opened menu');
    assert.equal(item.clicks, 0, change);
    assert.equal(sendRequests(p).length, 1, change);
  }
});

async function proofDiagnostics(p) {
  const id = 'D' + p.reports.length;
  p.command({ cmd: 'diagnostics', id });
  await p.advance(1);
  return p.reports.find((r) => r.id === id).data;
}

const diagnosticFields = (text) => Object.fromEntries(text.split('; ').map((s) => s.split('=')));
const routeShapeFunction = vm.runInNewContext(script.slice(script.indexOf('const pendingPrefixTokens = '),
  script.indexOf('const routeShapeDiagnostic = ')) + '\nsafeRouteShape;');
const routeShape = (path) => JSON.parse(JSON.stringify(routeShapeFunction(path)));

// Synthetic shape, not an upstream literal. Its UUID suffix is deliberately NOT the server ID.
const LOCAL_PATH = '/c/Ab09_-Cd12_-Ef3_' + OTHER_CID;
async function localPendingChat({ route = LOCAL_PATH, flags = nativeFlags,
  consent = { temporary: true, temporaryPersonalized: true }, mode = 'personalized', navigationEvents = true,
  holdResponse = false, responseStatus = 200, webSocket = false, holdPoll = false } = {}) {
  const queued = [];
  let waiting = null, ended = false;
  const deliver = (value) => {
    if (waiting) { const resolve = waiting; waiting = null; resolve(value); }
    else queued.push(value);
  };
  const frame = (conversation_id, text = 'synthetic reply') => 'data: ' + JSON.stringify({
    ...(conversation_id ? { conversation_id } : {}),
    message: { id: 'synthetic-answer', author: { role: 'assistant' },
      content: { content_type: 'text', parts: [text] } },
  }) + '\n\n';
  const p = fixture({ allowNetwork: true, navigationEvents, webSocket, respond(url, init) {
    if (url.endsWith('/synthetic-side-stream')) return new Response(frame(OTHER_CID, 'SIDE_STREAM_POISON'),
      { headers: { 'content-type': 'text/event-stream' } });
    if (init?.method !== 'POST') {
      const response = Response.json({ current_node: 'a1', mapping: { a1: {
      parent: null, message: { id: 'a1', author: { role: 'assistant' }, status: 'finished_successfully',
        end_turn: true, content: { content_type: 'text', parts: ['synthetic polled reply'] } },
      } } });
      if (holdPoll && !p.releasePoll) return new Promise((resolve) => { p.releasePoll = () => resolve(response); });
      return response;
    }
    if (url.endsWith('/prepare')) return Response.json({});
    if (sendRequests(p).length > 1) return new Response(frame(CID),
      { headers: { 'content-type': 'text/event-stream' } });
    if (route) p.sandbox.history.pushState({}, '', route);
    const response = { ok: responseStatus === 200, status: responseStatus,
      headers: new Headers({ 'content-type': 'text/event-stream' }), body: {},
      clone: () => ({ body: { getReader: () => ({ read: () => (queued.length ? Promise.resolve(queued.shift())
        : ended ? Promise.resolve({ done: true }) : new Promise((resolve) => { waiting = resolve; }))
        .then((item) => { if (item.error) throw item.error; return item; }) }) } }) };
    if (holdResponse) return new Promise((resolve, reject) => {
      p.accept = () => resolve(response);
      p.rejectResponse = () => reject(new Error('synthetic fetch failure'));
    });
    return response;
  } });
  p.ui = mode === 'unknown' ? null : nativeTemporary(p, mode);
  p.submit = (bodyFlags, id) => p.sandbox.fetch('https://chatgpt.com/backend-api/f/conversation', {
    method: 'POST', headers: { authorization: 'Bearer synthetic-fixture-only' }, body: JSON.stringify({ ...bodyFlags,
      ...(id ? { conversation_id: id } : {}), messages: [{ content: { parts: [p.box.value] } }] }),
  }).catch(() => {});
  p.button.onClick = () => p.submit(flags);
  p.send(consent);
  await p.advance(1000);
  p.rawOriginal = async (data) => {
    deliver({ done: false, value: new TextEncoder().encode(data) });
    await p.advance(1);
  };
  p.original = (id = CID) => p.rawOriginal(frame(id));
  p.failOriginal = async () => {
    deliver({ error: new Error('synthetic stream read failure') });
    await settle(p);
  };
  p.end = async () => {
    ended = true; deliver({ done: true });
    await settle(p);
  };
  p.canonical = (id = CID) => p.sandbox.history.replaceState({}, '', '/c/' + id);
  p.follow = async (extra = {}, bodyFlags = nativeFlags, id = CID) => {
    p.box.value = '';
    if (p.ui) p.ui.toggle.isConnected = p.ui.picker.isConnected = false;
    p.button.onClick = () => p.submit(bodyFlags, id);
    p.send({ id: 'F', conversationID: CID, temporary: true, temporaryPersonalized: true, ...extra });
    await p.advance(2000); await settle(p);
  };
  return p;
}

test('bounded pending: exact 52-character unencoded ASCII-pchar prefix/UUID shape is not identity; diagnostics contain no prefix', () => {
  assert.equal(routeShape(LOCAL_PATH).bounded_pending_shape, true);
  assert.equal(routeShape(LOCAL_PATH).segment_length, 52);
  assert.equal(routeShape(LOCAL_PATH).kind, 'c_nonuuid');
  for (const path of ['/c/local-temporary-' + CID, '/c/local-temporaryX' + CID,
    '/c/Local-temporary-' + CID]) assert.equal(routeShape(path).bounded_pending_shape, true);
  const invalid = ['/c/pending', '/c/PRIVATE-' + CID,
    '/c/local-temporary--' + CID, LOCAL_PATH + '/',
    LOCAL_PATH + '\n', LOCAL_PATH + '?x=1', LOCAL_PATH + '#x', '/g/x' + LOCAL_PATH,
    LOCAL_PATH.replace('Ab', '%41b'), LOCAL_PATH.replace('-', '%2D'),
    LOCAL_PATH.replace('A', 'é'), LOCAL_PATH.replace('A', '\\'), LOCAL_PATH.replace('A', '/'),
    LOCAL_PATH.replace(OTHER_CID, OTHER_CID.slice(1)), '/c/local-temporary-' + 'x'.repeat(36)];
  for (const path of invalid) assert.equal(routeShape(path).bounded_pending_shape, false, path);
  assert.doesNotMatch(JSON.stringify(routeShape(LOCAL_PATH)), /Ab09|local-temporary|11111111|22222222|\/c\//);
});

test('bounded pending: pchar classification is exact over ASCII and prefix diagnostics are booleans only', () => {
  const allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~!$&'()*+,;=:@-";
  for (let code = 0; code < 128; code++) {
    const char = String.fromCharCode(code), prefix = char.repeat(16);
    const shape = routeShape('/c/' + prefix + OTHER_CID);
    assert.equal(shape.bounded_pending_shape, allowed.includes(char), 'ASCII ' + code);
    assert.equal(shape.prefix_pchar, allowed.includes(char), 'prefix ASCII ' + code);
    for (const key of ['prefix_pchar', 'prefix_has_colon', 'prefix_has_percent'])
      assert.equal(typeof shape[key], 'boolean');
    if (char === ':' || char === '%') {
      assert.equal(shape.prefix_has_colon, char === ':');
      assert.equal(shape.prefix_has_percent, char === '%');
    }
  }
  for (const prefix of ['a'.repeat(15), 'a'.repeat(17), 'é'.repeat(16), '中'.repeat(16),
    '%2F' + 'a'.repeat(13)]) {
    const shape = routeShape('/c/' + prefix + OTHER_CID);
    assert.equal(shape.bounded_pending_shape, false);
    assert.equal(shape.prefix_pchar, false);
    assert.equal(shape.prefix_has_percent, prefix.includes('%'));
  }
  for (const path of ['/', '/c/' + CID, '/other', '/g/x/c/' + ':'.repeat(16) + OTHER_CID]) {
    const shape = routeShape(path);
    assert.equal(shape.prefix_pchar, false);
    assert.equal(shape.prefix_has_colon, false);
    assert.equal(shape.prefix_has_percent, false);
  }
});

test('bounded pending: percent tokenizer accepts only ASCII pchar bytes, never decoded-length or UUID-boundary repair', () => {
  const allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~!$&'()*+,;=:@-";
  const enums = new Set(['none', 'pchar', 'delimiter', 'percent', 'control_space',
    'non_ascii', 'other_ascii', 'malformed', 'mixed', 'not_16', 'not_applicable']);
  for (let byte = 0; byte < 256; byte++) {
    const hex = byte.toString(16).padStart(2, '0');
    for (const token of ['%' + hex, '%' + hex.toUpperCase()]) {
      const shape = routeShape('/c/' + token + 'a'.repeat(13) + OTHER_CID);
      assert.equal(shape.bounded_pending_shape, allowed.includes(String.fromCharCode(byte)), 'byte ' + byte);
      assert.equal(shape.prefix_pchar, false, 'raw encoded prefix is not unencoded pchar');
      assert.equal(shape.prefix_has_percent, true);
      assert.ok(enums.has(shape.prefix_percent_type));
      if (shape.bounded_pending_shape) assert.equal(shape.prefix_percent_type, 'pchar');
      assert.doesNotMatch(JSON.stringify(shape), /%[0-9a-f]{2}|22222222|11111111|\/c\//i);
    }
  }
  for (const [prefix, type] of [
    ['a'.repeat(15) + '%', 'malformed'], ['a'.repeat(14) + '%4', 'malformed'],
    ['%GG' + 'a'.repeat(13), 'malformed'], ['%u003A' + 'a'.repeat(10), 'malformed'],
    ['%252F' + 'a'.repeat(11), 'percent'], ['%3A%2F' + 'a'.repeat(10), 'mixed'],
    ['%3A' + 'a'.repeat(15), 'not_16'], // Decoded length 16 is insufficient: raw length is 18.
    ['%3A' + 'a'.repeat(12), 'not_16'],
  ]) {
    const shape = routeShape('/c/' + prefix + OTHER_CID);
    assert.equal(shape.bounded_pending_shape, false);
    assert.equal(shape.prefix_percent_type, type);
  }
  assert.equal(routeShape('/').prefix_percent_type, 'not_applicable');
  assert.equal(routeShape(LOCAL_PATH).prefix_percent_type, 'none');
});

test('bounded pending: forbidden/malformed/double-encoded prefixes revoke without content pollution or late revival', async () => {
  for (const [token, type] of [
    ['%2F', 'delimiter'], ['%5c', 'delimiter'], ['%3F', 'delimiter'], ['%23', 'delimiter'],
    ['%25', 'percent'], ['%252F', 'percent'], ['%253A', 'percent'],
    ['%00', 'control_space'], ['%09', 'control_space'], ['%20', 'control_space'], ['%7f', 'control_space'],
    ['%80', 'non_ascii'], ['%C3%A9', 'non_ascii'], ['%C0%AF', 'non_ascii'],
    ['%22', 'other_ascii'], ['%5B', 'other_ascii'], ['%60', 'other_ascii'],
    ['%G0', 'malformed'], ['%u003A', 'malformed'], ['%3A%2F', 'mixed'],
    ['a'.repeat(15) + '%', 'malformed'], ['a'.repeat(14) + '%4', 'malformed'],
  ]) {
    const prefix = token.padEnd(16, 'a');
    const p = await localPendingChat({ route: '/c/' + prefix + OTHER_CID, webSocket: true });
    const d = await proofDiagnostics(p);
    assert.match(d['個人化續聊證據'], /proof=revoked; reason=route_changed/);
    assert.equal(d['個人化首句過渡'], undefined);
    const fields = diagnosticFields(d['個人化路由撤銷']);
    assert.equal(fields.observed_bounded_pending_shape, 'false');
    assert.equal(fields.observed_prefix_percent_type, type);
    assert.doesNotMatch(d['個人化路由撤銷'], /%[0-9a-f]{2}|22222222|11111111|\/c\//i);
    let reads = 0;
    const foreign = new p.Element('div', { 'data-message-author-role': 'assistant' });
    Object.defineProperty(foreign, 'innerText', { get() { reads++; return 'DOM_POISON'; } });
    await p.sandbox.fetch('https://chatgpt.com/backend-api/synthetic-side-stream');
    const ws = new p.sandbox.WebSocket('wss://chatgpt.com/synthetic-socket');
    ws.dispatchEvent({ type: 'message', data: JSON.stringify({ conversation_id: OTHER_CID,
      message: { id: 'foreign', author: { role: 'assistant' },
        content: { content_type: 'text', parts: ['WS_POISON'] } } }) });
    await settle(p);
    assert.equal(reads, 0);
    assert.ok(!p.reports.some((r) => r.kind === 'conversation' || /POISON/.test(r.full || '')));
    assert.ok(!p.requests.some((r) => /\/conversation\//.test(r.url)));
    await p.original(); p.canonical(); await p.end(); await p.follow();
    assert.equal(sendRequests(p).length, 1, type);
    assert.match((await proofDiagnostics(p))['個人化續聊證據'], /proof=revoked/);
  }
});

test('bounded pending: equivalent decoded prefix is still a second raw route and permanently revokes', async () => {
  const p = await localPendingChat({ route: '/c/%3A' + 'a'.repeat(13) + OTHER_CID });
  assert.match((await proofDiagnostics(p))['個人化續聊證據'], /proof=pending/);
  p.sandbox.history.replaceState({}, '', '/c/%3a' + 'a'.repeat(13) + OTHER_CID);
  assert.match((await proofDiagnostics(p))['個人化續聊證據'], /proof=revoked; reason=route_changed/);
  await p.original(); p.canonical(); await p.end(); await p.follow();
  assert.equal(sendRequests(p).length, 1);
});

test('bounded pending: raw and percent-token pchar prefixes stay isolated until original ID and exact canonical intersect', async () => {
  const prefixes = [':'.repeat(16), '.'.repeat(16), '@'.repeat(16), "_~!$&'()*+,;=:@-",
    LOCAL_PATH.slice(3, 19).replace('A', '.'),
    '%3A' + 'a'.repeat(13), '%2e' + 'a'.repeat(13), '%40' + 'a'.repeat(13),
    '%21%24%26%27%28a', '%41%7e' + 'a'.repeat(10)]; // Raw prefix length, never decoded length.
  for (const prefix of prefixes) for (const idFirst of [false, true]) {
    assert.equal(prefix.length, 16);
    const p = await localPendingChat({ route: '/c/' + prefix + OTHER_CID, webSocket: true });
    assert.equal(p.sandbox.location.pathname, '/c/' + prefix + OTHER_CID, 'fixture must not normalize the candidate');
    let domReads = 0;
    const foreign = new p.Element('div', { 'data-message-author-role': 'assistant' });
    Object.defineProperty(foreign, 'innerText', { get() { domReads++; return 'DOM_POISON'; } });
    const ws = new p.sandbox.WebSocket('wss://chatgpt.com/synthetic-socket');
    const isolated = async () => {
      await p.sandbox.fetch('https://chatgpt.com/backend-api/synthetic-side-stream');
      ws.dispatchEvent({ type: 'message', data: JSON.stringify({ conversation_id: OTHER_CID,
        message: { id: 'foreign', author: { role: 'assistant' },
          content: { content_type: 'text', parts: ['WS_POISON'] } } }) });
      await p.advance(400); await settle(p);
      assert.equal(domReads, 0);
      assert.ok(!p.requests.some((r) => /\/conversation\//.test(r.url)));
      assert.ok(!p.reports.some((r) => /POISON|polled reply/.test(r.full || '')));
      assert.ok(!p.reports.some((r) => r.id === 'S' && ['finished', 'failed'].includes(r.kind)));
      assert.match((await proofDiagnostics(p))['個人化續聊證據'], /proof=pending/);
    };
    const diag = (await proofDiagnostics(p))['個人化目前路由'];
    const fields = diagnosticFields(diag);
    assert.equal(fields.current_bounded_pending_shape, 'true');
    assert.equal(fields.current_prefix_pchar, String(!prefix.includes('%')));
    assert.equal(fields.current_prefix_has_colon, String(prefix.includes(':')));
    assert.equal(fields.current_prefix_has_percent, String(prefix.includes('%')));
    assert.equal(fields.current_prefix_percent_type, prefix.includes('%') ? 'pchar' : 'none');
    assert.ok(!diag.includes(prefix));
    assert.doesNotMatch(diag, /11111111|22222222|\/c\//);
    await isolated();
    if (idFirst) await p.original(); else p.canonical();
    await isolated();
    assert.equal(p.reports.filter((r) => r.kind === 'conversation').length, idFirst ? 1 : 0);
    if (idFirst) p.canonical(); else await p.original();
    await p.end();
    assert.equal(domReads, 0);
    assert.match((await proofDiagnostics(p))['個人化續聊證據'], /proof=complete/);
    await p.follow();
    assert.equal(sendRequests(p).length, 2);
    assert.ok(p.reports.some((r) => r.id === 'F' && r.kind === 'finished'));
  }
});

test('bounded pending: original SSE ID before/after canonical works only after first-turn completion', async () => {
  for (const idFirst of [true, false]) for (const navigationEvents of [true, false]) {
    const p = await localPendingChat({ navigationEvents });
    let d = await proofDiagnostics(p);
    assert.equal(d['個人化路由撤銷'], undefined);
    assert.equal(d['個人化首句過渡'], 'bounded_pending_shape=true');
    assert.match(d['個人化續聊證據'], /proof=pending/);
    assert.match(d['個人化目前路由'], /current_bounded_pending_shape=true/);
    // A continuation while pending is refused, without cancelling the legitimate initial turn.
    p.send({ id: 'EARLY', conversationID: CID, temporary: true, temporaryPersonalized: true });
    await p.advance(1);
    assert.ok(p.reports.some((r) => r.id === 'EARLY' && r.kind === 'failed'));
    assert.equal(sendRequests(p).length, 1);
    if (idFirst) {
      await p.original();
      assert.match((await proofDiagnostics(p))['個人化續聊證據'], /serverID=true; routeID=false/);
      p.canonical();
    } else {
      p.canonical();
      // Stage diagnostics are event snapshots, not a live getter. Recheck the denied continuation at canonical.
      p.send({ id: 'EARLY_CANONICAL', conversationID: CID, temporary: true, temporaryPersonalized: true });
      await p.advance(1);
      assert.ok(p.reports.some((r) => r.id === 'EARLY_CANONICAL' && r.kind === 'failed'));
      assert.match((await proofDiagnostics(p))['個人化續聊證據'], /serverID=false; routeID=true/);
      await p.original();
    }
    assert.match((await proofDiagnostics(p))['個人化續聊證據'], /proof=pending/);
    await p.end();
    d = await proofDiagnostics(p);
    assert.match(d['個人化續聊證據'], /proof=complete/);
    assert.match(d['個人化原始ID'], /first_proof_revoked=false; first_bind_result=bound/);
    assert.equal(d['個人化首句過渡'], 'bounded_pending_shape=true', 'frozen shape boolean survives canonical');
    assert.doesNotMatch(JSON.stringify([d['個人化首句過渡'], d['個人化目前路由'], d['個人化原始ID']]),
      /Ab09|local-temporary|11111111|22222222/);
    await p.follow();
    assert.equal(sendRequests(p).length, 2, JSON.stringify(p.reports.filter((r) => r.kind === 'failed')));
    assert.ok(p.reports.some((r) => r.id === 'F' && r.kind === 'finished'));
  }
});

test('bounded pending: repeated identical path notifications are allowed, not a second local ID', async () => {
  const p = await localPendingChat();
  for (const path of [LOCAL_PATH, '/c/' + CID]) {
    p.sandbox.history.pushState({}, '', path);
    p.sandbox.history.replaceState({}, '', path);
    p.command({ cmd: 'connectorNavigated', id: 'NAV', path });
    p.mutate();
    await p.advance(200); // includes tick and URL observation, neither grants authoritative identity.
    assert.equal((await proofDiagnostics(p))['個人化路由撤銷'], undefined);
  }
  await p.original(); await p.end(); await p.follow();
  assert.equal(sendRequests(p).length, 2, JSON.stringify(p.reports.filter((r) => r.kind === 'failed')));
});

test('bounded pending: local pending finish cannot complete even with original ID; late canonical cannot revive it', async () => {
  for (const hasOriginalID of [true, false]) {
    const p = await localPendingChat();
    await p.original(hasOriginalID ? CID : null);
    await p.end();
    assert.ok(p.reports.some((r) => r.id === 'S' && r.kind === 'finished'));
    assert.match((await proofDiagnostics(p))['個人化續聊證據'], /proof=revoked; reason=turn_failed/);
    p.canonical();
    await p.follow();
    assert.equal(sendRequests(p).length, 1);
  }
});

test('bounded pending: canonical URL, poll completion or unrelated SSE cannot supply the original ID', async () => {
  for (const source of ['url', 'poll', 'other-sse']) {
    const p = await localPendingChat();
    p.canonical();
    if (source === 'other-sse') {
      await p.sandbox.fetch('https://chatgpt.com/backend-api/synthetic-side-stream');
      await settle(p);
      assert.ok(!p.reports.some((r) => r.kind === 'finished'), 'side SSE cannot finish the original turn');
      await p.end();
    } else {
      if (source === 'url') await p.original(null); // text only: canonical URL is not server proof.
      await p.end(); // no original ID: completion revokes without reading canonical via poll.
      if (source === 'poll') { await p.advance(1500); await settle(p); }
    }
    const d = await proofDiagnostics(p);
    assert.match(d['個人化原始ID'], /^seen=false;/);
    assert.match(d['個人化續聊證據'], /proof=revoked/, source);
    assert.ok(!p.requests.some((r) => /\/conversation\//.test(r.url)), 'quarantine must not poll');
    await p.follow();
    assert.equal(sendRequests(p).length, 1, source);
  }
});

test('bounded pending: DOM, URL, poll, side SSE and wrapped WS cannot contaminate unjoined or revoked first turn', async () => {
  for (const stage of ['root', 'pending', 'canonical-only', 'original-only', 'revoked']) {
    const p = await localPendingChat({ route: stage === 'root' ? null : LOCAL_PATH, webSocket: true });
    if (stage === 'canonical-only') p.canonical();
    if (stage === 'original-only') await p.original();
    if (stage === 'revoked') p.sandbox.history.replaceState({}, '', '/other');
    let domReads = 0;
    const foreign = new p.Element('div', { 'data-message-author-role': 'assistant' });
    Object.defineProperty(foreign, 'innerText', { get() { domReads++; return 'DOM_POISON'; } });
    await p.sandbox.fetch('https://chatgpt.com/backend-api/synthetic-side-stream');
    const ws = new p.sandbox.WebSocket('wss://chatgpt.com/synthetic-socket');
    ws.dispatchEvent({ type: 'message', data: JSON.stringify({ conversation_id: OTHER_CID,
      message: { id: 'foreign', author: { role: 'assistant' },
        content: { content_type: 'text', parts: ['WS_POISON'] } } }) });
    await p.advance(2000); await settle(p);
    assert.equal(domReads, 0, stage + ': must not even read DOM content');
    assert.ok(!p.requests.some((r) => /\/conversation\//.test(r.url)), stage + ': no poll');
    assert.ok(!p.reports.some((r) => /POISON|polled reply/.test(r.full || '')), stage);
    assert.equal(p.reports.filter((r) => r.kind === 'conversation').length,
      stage === 'original-only' ? 1 : 0, stage + ': no URL/side ID');
    assert.ok(!p.reports.some((r) => r.id === 'S' && ['finished', 'failed'].includes(r.kind)),
      stage + ': unrelated stream EOF cannot finish original');
    assert.equal(sendRequests(p).length, 1);
    await p.end();
  }
});

test('bounded pending: an already in-flight root poll cannot publish after entering quarantine or revocation', async () => {
  for (const revoke of [false, true]) {
    const p = await localPendingChat({ route: null, holdPoll: true });
    await p.rawOriginal('data: ' + JSON.stringify({ conversation_id: CID }) + '\n\n'
      + 'data: {"type":"stream_handoff"}\n\n');
    await p.advance(1800);
    assert.equal(typeof p.releasePoll, 'function', 'existing ID-proven root genuinely started polling');
    p.sandbox.history.replaceState({}, '', LOCAL_PATH);
    if (revoke) p.sandbox.history.replaceState({}, '', '/');
    p.releasePoll();
    await settle(p);
    assert.ok(!p.reports.some((r) => r.full === 'synthetic polled reply'));
    assert.ok(!p.reports.some((r) => r.id === 'S' && r.kind === 'finished'));
    p.canonical(); await p.end(); await p.advance(2500); await settle(p);
    const d = await proofDiagnostics(p);
    assert.match(d['個人化續聊證據'], revoke ? /proof=revoked/ : /proof=complete/);
    if (!revoke) assert.ok(p.reports.some((r) => r.full === 'synthetic polled reply'),
      'a new poll may resume only after the identity intersection');
    else assert.ok(!p.reports.some((r) => r.full === 'synthetic polled reply'));
  }
});

test('bounded pending: send/edit/regenerate remain denied at both unjoined and joined-but-unfinished stages', async () => {
  for (const stage of ['pending', 'canonical-only', 'original-only', 'joined']) {
    const p = await localPendingChat();
    if (stage === 'canonical-only' || stage === 'joined') p.canonical();
    if (stage === 'original-only' || stage === 'joined') await p.original();
    new p.Element('div', { 'data-message-author-role': 'assistant' });
    const retry = regenerationButton(p);
    const insertions = p.insertions.length;
    p.send({ id: 'EARLY_SEND', conversationID: CID, temporary: true, temporaryPersonalized: true });
    p.send({ id: 'EARLY_EDIT', conversationID: CID, parentID: 'synthetic-parent',
      temporary: true, temporaryPersonalized: true });
    p.command({ cmd: 'regenerate', id: 'EARLY_REGEN', conversationID: CID,
      temporary: true, temporaryPersonalized: true });
    await p.advance(100);
    for (const id of ['EARLY_SEND', 'EARLY_EDIT', 'EARLY_REGEN'])
      assert.ok(p.reports.some((r) => r.id === id && r.kind === 'failed'), stage + '/' + id);
    assert.equal(retry.clicks, 0);
    assert.equal(p.insertions.length, insertions);
    assert.equal(sendRequests(p).length, 1);
    await p.end();
  }
});

test('bounded pending: original read-error before identity intersection revokes and late bytes/route cannot revive', async () => {
  for (const stage of ['pending', 'canonical-only', 'original-only']) {
    const p = await localPendingChat();
    if (stage === 'canonical-only') p.canonical();
    if (stage === 'original-only') await p.original();
    await p.failOriginal();
    assert.ok(p.failure(), stage);
    assert.match((await proofDiagnostics(p))['個人化續聊證據'], /proof=revoked/);
    await p.original(); p.canonical(); await p.end(); await p.follow();
    assert.equal(sendRequests(p).length, 1);
    assert.ok(!p.requests.some((r) => /\/conversation\//.test(r.url)));
  }
});

test('bounded pending: original ID plus canonical, message_stream_complete then read-error retains poll completion', async () => {
  for (const idFirst of [false, true]) {
    const p = await localPendingChat();
    if (!idFirst) p.canonical();
    await p.rawOriginal('data: ' + JSON.stringify({ conversation_id: CID }) + '\n\n');
    if (idFirst) p.canonical();
    await p.rawOriginal('data: {"type":"message_stream_complete"}\n\n');
    await p.failOriginal();
    await p.advance(2500); await settle(p);
    assert.equal(p.failure(), undefined);
    assert.ok(p.requests.some((r) => /\/conversation\//.test(r.url)), 'real poll path ran');
    assert.ok(p.reports.some((r) => r.full === 'synthetic polled reply'));
    const finished = p.reports.find((r) => r.id === 'S' && r.kind === 'finished');
    assert.ok(finished);
    assert.match(finished.shape, /message_stream_complete×1/);
    assert.match(finished.shape, /read-error×1/);
    assert.match((await proofDiagnostics(p))['個人化續聊證據'], /proof=complete/);
    await p.follow();
    assert.equal(sendRequests(p).length, 2);
  }
});

test('bounded pending: joined side-stream completion before original ends revokes; late original cannot revive', async () => {
  const p = await localPendingChat();
  p.canonical(); await p.original();
  // Original SSE is still open. A non-original stream may not prematurely grant complete.
  await p.sandbox.fetch('https://chatgpt.com/backend-api/synthetic-side-stream');
  await settle(p);
  assert.match((await proofDiagnostics(p))['個人化續聊證據'], /proof=revoked/);
  await p.end(); await p.original(); await p.follow();
  assert.equal(sendRequests(p).length, 1);
});

test('bounded pending: former similar-prefix counterexamples now only qualify as quarantined shapes, not proof', async () => {
  for (const route of ['/c/local-temporaryX' + CID, '/c/Local-temporary-' + CID]) {
    const p = await localPendingChat({ route });
    assert.match((await proofDiagnostics(p))['個人化續聊證據'], /proof=pending/);
    assert.equal(routeShape(route).bounded_pending_shape, true);
    await p.end(); p.canonical(); await p.original(); await p.follow();
    assert.match((await proofDiagnostics(p))['個人化續聊證據'], /proof=revoked/);
    assert.equal(sendRequests(p).length, 1);
  }
});

test('bounded pending: different local/canonical, root return, mode reversal, cancel or origin change permanently revoke', async () => {
  for (const change of ['local-id', 'root-return', 'other-route', 'canonical-id-before-SSE',
    'canonical-id-after-SSE', 'canonical-switch', 'back-to-local', 'mode', 'mode-reversal', 'cancel', 'origin']) {
    const p = await localPendingChat();
    if (change === 'local-id') p.sandbox.history.replaceState({}, '', '/c/local-temporary-' + CID);
    if (change === 'root-return') p.sandbox.history.replaceState({}, '', '/');
    if (change === 'other-route') p.sandbox.history.replaceState({}, '', '/other');
    if (change === 'canonical-id-before-SSE') p.canonical(OTHER_CID);
    if (change === 'canonical-id-after-SSE') { await p.original(); p.canonical(OTHER_CID); }
    if (change === 'canonical-switch') { p.canonical(); p.canonical(OTHER_CID); }
    if (change === 'back-to-local') { p.canonical(); p.sandbox.history.replaceState({}, '', LOCAL_PATH); }
    if (change === 'mode') { p.ui.picker.attrs['aria-label'] = 'Unpersonalized'; p.mutate(); }
    if (change === 'mode-reversal') p.mutate([
      { type: 'attributes', attributeName: 'aria-label', target: p.ui.picker, oldValue: 'Unpersonalized' },
    ]);
    if (change === 'cancel') p.command({ cmd: 'stop', id: 'C', requestID: 'S' });
    if (change === 'origin') {
      p.sandbox.location.origin = 'https://unrelated.invalid'; p.mutate();
      p.sandbox.location.origin = 'https://chatgpt.com';
    }
    await p.original();
    p.canonical();
    if (p.ui) p.ui.picker.attrs['aria-label'] = 'Personalized';
    await p.end();
    assert.match((await proofDiagnostics(p))['個人化續聊證據'], /proof=revoked/, change);
    await p.follow();
    assert.equal(sendRequests(p).length, 1, change);
  }
});

test('bounded pending: popstate, traverse/reload/unknown Navigation type revoke even at identical pathname', async () => {
  for (const kind of ['popstate', 'traverse', 'reload', null, 'unknown', 'throwing']) {
    for (const stage of ['root', 'local', 'canonical', 'complete']) {
      const p = await localPendingChat({ route: stage === 'root' ? null : LOCAL_PATH });
      if (stage === 'canonical' || stage === 'complete') p.canonical();
      if (stage === 'complete') { await p.original(); await p.end(); }
      if (kind === 'popstate') p.sandbox.dispatchEvent(new p.sandbox.PopStateEvent('popstate'));
      else {
        const event = new p.sandbox.NavigationCurrentEntryChangeEvent('currententrychange', { navigationType: kind });
        if (kind === 'throwing') Object.defineProperty(event, 'navigationType', { get() { throw new Error('synthetic'); } });
        p.sandbox.navigation.dispatchEvent(event);
      }
      const d = await proofDiagnostics(p);
      assert.match(d['個人化續聊證據'], /proof=revoked; reason=route_changed/, kind + '/' + stage);
      assert.equal(diagnosticFields(d['個人化路由撤銷']).navigation_type,
        kind === 'popstate' ? 'none' : ['traverse', 'reload'].includes(kind) ? kind : 'unknown');
      await p.original(); p.canonical(); await p.end(); await p.follow();
      assert.equal(sendRequests(p).length, 1, kind + '/' + stage);
    }
  }
});

test('bounded pending: arbitrary/wrong-length/encoded/trailing routes remain denied by the real guard', async () => {
  for (const route of ['/c/pending', '/c/PRIVATE-' + CID,
    '/c/local-temporary--' + CID, LOCAL_PATH + '/',
    LOCAL_PATH.replace('Ab', '%41b'), LOCAL_PATH.replace('-', '%2D'), '/g/x' + LOCAL_PATH,
    LOCAL_PATH.replace('A', 'é'), LOCAL_PATH.replace('A', '\\'), LOCAL_PATH + '\n',
    '/c/' + '%2F' + 'a'.repeat(13) + OTHER_CID,
    '/c/' + 'a'.repeat(15) + OTHER_CID, '/c/' + 'a'.repeat(17) + OTHER_CID,
    '/c/extra/' + ':'.repeat(16) + OTHER_CID,
    '/c/local-temporary-' + 'x'.repeat(36)]) {
    // URL parsing removes a newline; test the raw observed pathname instead of a normalized URL.
    const p = await localPendingChat({ route: route.endsWith('\n') ? null : route });
    if (route.endsWith('\n')) { p.sandbox.location.pathname = route; p.mutate(); }
    const d = await proofDiagnostics(p);
    assert.equal(d['個人化首句過渡'], undefined, route);
    assert.equal(diagnosticFields(d['個人化路由撤銷']).observed_bounded_pending_shape, 'false');
    await p.original(); p.canonical(); await p.end(); await p.follow();
    assert.equal(sendRequests(p).length, 1, route);
  }
});

test('bounded pending: Navigation type uses the captured native getter, never a rewritten getter or plain object', async () => {
  for (const forged of ['prototype', 'own', 'plain']) {
    const p = await localPendingChat();
    const Event = p.sandbox.NavigationCurrentEntryChangeEvent;
    let event = new Event('currententrychange', { navigationType: 'traverse' });
    if (forged === 'prototype') Object.defineProperty(Event.prototype, 'navigationType', { get() { return 'push'; } });
    if (forged === 'own') Object.defineProperty(event, 'navigationType', { value: 'push' });
    if (forged === 'plain') event = { type: 'currententrychange', navigationType: 'push' };
    p.sandbox.navigation.dispatchEvent(event);
    const d = await proofDiagnostics(p);
    assert.match(d['個人化續聊證據'], /proof=revoked; reason=route_changed/);
    assert.equal(diagnosticFields(d['個人化路由撤銷']).navigation_type, forged === 'plain' ? 'unknown' : 'traverse');
    await p.original(); p.canonical(); await p.end(); await p.follow();
    assert.equal(sendRequests(p).length, 1);
  }
});

test('bounded pending: canonical must be the entire path and exactly match the original SSE ID', async () => {
  for (const path of ['/g/x/c/' + CID, '/c/' + CID + '/', '/c/' + CID + '/extra',
    '/c/' + CID.replace('-', '%2D'), '/c/' + OTHER_CID]) {
    const p = await localPendingChat();
    await p.original();
    p.sandbox.history.replaceState({}, '', path);
    await p.end(); p.canonical(); await p.follow();
    assert.equal(sendRequests(p).length, 1, path);
  }
  const p = await localPendingChat();
  await p.original(); await p.original(OTHER_CID);
  assert.ok(p.failure(), 'conflicting original SSE IDs stop the actual first turn');
  p.canonical(); await p.end(); await p.follow();
  assert.equal(sendRequests(p).length, 1);
});

test('bounded pending: normal/unknown/no-consent and invalid native body cannot borrow a proof', async () => {
  for (const options of [
    { consent: {}, mode: 'off' }, { consent: {}, mode: 'personalized' },
    { mode: 'unknown' }, { consent: { temporaryPersonalized: true } },
    { consent: { temporary: true } }, { flags: { history_and_training_disabled: true } },
    { flags: { ...nativeFlags, is_do_not_remember: true } },
  ]) {
    const p = await localPendingChat(options);
    const before = sendRequests(p).length;
    assert.equal((await proofDiagnostics(p))['個人化首句過渡'], undefined);
    await p.original(); p.canonical(); await p.end(); await p.follow();
    assert.equal(sendRequests(p).length, before, JSON.stringify(options));
  }
});

test('bounded pending: completed candidate retains exact per-command consent and original body guards', async () => {
  for (const bad of ['consent', 'flags', 'body-id']) {
    const p = await localPendingChat();
    await p.original(); p.canonical(); await p.end();
    await p.follow(bad === 'consent' ? { temporaryPersonalized: false } : {},
      bad === 'flags' ? { history_and_training_disabled: true } : nativeFlags,
      bad === 'body-id' ? OTHER_CID : CID);
    assert.equal(sendRequests(p).length, 1, bad);
  }
});

test('bounded pending: pending is possible before HTTP acceptance but ID binding is not', async () => {
  const p = await localPendingChat({ holdResponse: true });
  assert.equal((await proofDiagnostics(p))['個人化首句過渡'], 'bounded_pending_shape=true');
  assert.ok(!p.reports.some((r) => r.kind === 'accepted'));
  await p.original(); // queued bytes are not read until the actual original response is accepted.
  assert.match((await proofDiagnostics(p))['個人化原始ID'], /^seen=false;/);
  p.canonical(); p.accept();
  await p.advance(1);
  assert.ok(p.reports.some((r) => r.kind === 'accepted'));
  assert.match((await proofDiagnostics(p))['個人化原始ID'], /first_bind_result=bound/);
  await p.end(); await p.follow();
  assert.equal(sendRequests(p).length, 2);
});

test('bounded pending: HTTP/fetch failure or cancellation before acceptance cannot revive via late original bytes', async () => {
  for (const failure of ['http', 'fetch', 'cancel', 'route']) {
    const p = await localPendingChat({ holdResponse: true, responseStatus: failure === 'http' ? 500 : 200 });
    await p.original(); // arrived transport bytes are still gated by the response.
    if (failure === 'fetch') p.rejectResponse();
    else {
      if (failure === 'cancel') p.command({ cmd: 'stop', id: 'C', requestID: 'S' });
      if (failure === 'route') p.sandbox.history.replaceState({}, '', '/');
      p.accept();
    }
    await p.advance(200);
    await p.end(); p.canonical(); await p.follow();
    const d = await proofDiagnostics(p);
    assert.match(d['個人化續聊證據'], /proof=revoked/, failure);
    assert.doesNotMatch(d['個人化原始ID'], /bind_result=bound/);
    assert.equal(sendRequests(p).length, 1, failure);
  }
});

test('bounded pending: direct non-local /g/.../c path retains the pre-existing behavior', async () => {
  const p = await provenChat({ route(p) { p.sandbox.history.replaceState({}, '', '/g/example/c/' + CID); } });
  assert.equal((await proofDiagnostics(p))['個人化首句過渡'], undefined);
  assert.match((await proofDiagnostics(p))['個人化續聊證據'], /proof=complete/);
  await p.follow();
  assert.equal(sendRequests(p).length, 2);
});

function localProofHarness() {
  const guard = script.slice(script.indexOf('const proofPageOK = '), script.indexOf('const personalizedContextOK = '));
  const local = script.slice(script.indexOf('const pendingPrefixTokens = '), script.indexOf('// 純函式，只回固定分類'));
  const finish = script.slice(script.indexOf('function finishTurn('), script.indexOf('function tick('));
  return vm.runInNewContext(`
    const location = { pathname: ${JSON.stringify(LOCAL_PATH)}, origin: 'https://chatgpt.com' }, diag = {};
    const UUID_IN_PATH = /\\/c\\/([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})/i;
    const proof = { rootStart: true, path: '/', origin: location.origin, sent: true, complete: false,
      initialTurnID: 'S', revoked: false, localPath: null, routeID: null, conversationID: null };
    let personalizedProof = proof, reason = '', pendingSend = null;
    const turn = { id: 'S', personalizedProof: proof, submitted: true, personalizedOriginal: true,
      temporary: true, temporaryConfirmed: true, originalSendStarted: true, originalSSEEnded: false, accepted: false,
      cancelled: false, finished: false, requestConversationID: null };
    const turns = { S: turn }; let active = turn;
    const activeTurn = () => active, nativeTemporaryUI = () => ({ mode: 'personalized' });
    const freezePersonalizedRouteDiagnostic = () => {}, personalizedDiagnostic = () => {};
    const clearInterval = () => {}, setConversation = () => {}, postTerminal = () => {}, shapeText = () => '';
    const conversationFromURL = () => null;
    const localText = (v) => v;
    const revokePersonalizedProof = (r) => {
      if (!personalizedProof) return;
      reason = r; proof.revoked = true; personalizedProof = null;
    };
    ${local} ${guard} ${finish}
    ({ proof, turn, turns, location, otherActive() { active = {}; }, reason: () => reason,
      finish: (failure) => finishTurn(turn, failure),
      check: () => proofPageOK(proof, location.pathname, 'currententrychange', 'push') });`);
}

test('bounded pending: eligibility requires the same live initial turn, root origin and real send dispatch', () => {
  const positive = localProofHarness();
  assert.equal(positive.check(), true);
  assert.equal(positive.proof.localPath, LOCAL_PATH);
  for (const [target, field, value] of [
    ['proof', 'rootStart', false], ['proof', 'path', '/g/example'], ['proof', 'sent', false],
    ['proof', 'complete', true], ['proof', 'initialTurnID', 'OTHER'], ['proof', 'revoked', true],
    ['proof', 'routeID', CID], ['proof', 'origin', 'https://unrelated.invalid'],
    ['turn', 'submitted', false], ['turn', 'personalizedOriginal', false], ['turn', 'temporaryConfirmed', false],
    ['turn', 'originalSendStarted', false], ['turn', 'cancelled', true], ['turn', 'finished', true],
    ['turn', 'requestConversationID', CID], ['turn', 'personalizedProof', {}],
  ]) {
    const h = localProofHarness(); h[target][field] = value;
    assert.equal(h.check(), false, target + '.' + field);
    assert.equal(h.proof.localPath, null);
  }
  const inactive = localProofHarness(); inactive.otherActive();
  assert.equal(inactive.check(), false);
});

test('bounded pending: finish-time route/origin/cancel/failure cannot complete or dereference a revoked proof', () => {
  for (const change of ['none', 'path', 'origin', 'cancel', 'failure', 'not-accepted', 'local', 'no-original-id', 'different-turn', 'original-still-open']) {
    const h = localProofHarness();
    assert.equal(h.check(), true);
    h.proof.conversationID = CID;
    h.turn.accepted = true;
    h.turn.originalSSEEnded = change !== 'original-still-open';
    if (change !== 'local') {
      h.location.pathname = '/c/' + CID;
      assert.equal(h.check(), true);
    }
    // Change state without firing an observer: the actual finishTurn must perform its own final check.
    if (change === 'path') h.location.pathname = '/other';
    if (change === 'origin') h.location.origin = 'https://unrelated.invalid';
    if (change === 'cancel') h.turn.cancelled = true;
    if (change === 'not-accepted') h.turn.accepted = false;
    if (change === 'no-original-id') h.proof.conversationID = null;
    if (change === 'different-turn') h.otherActive();
    assert.doesNotThrow(() => h.finish(change === 'failure' ? 'synthetic failure' : undefined), change);
    assert.equal(h.proof.complete, change === 'none', change);
    assert.equal(h.proof.revoked, change !== 'none', change);
    assert.equal(h.turn.finished, true);
    h.location.pathname = '/c/' + CID;
    assert.doesNotThrow(() => h.finish(), 'duplicate finish cannot renew proof');
    assert.equal(h.proof.complete, change === 'none', change);
  }
});

test('route diagnostics: pure shape function preserves empty/encoded/trailing segments and only emits bounded structure', () => {
  const checks = [
    ['', 'other', 0, 0], ['/', 'root', 0, 0], ['/c/' + CID, 'c_uuid', 2, 36],
    ['/c/pending', 'c_nonuuid', 2, 7], ['/c/' + CID + '/', 'other', 3, 0],
    ['/c//pending', 'other', 3, 7], ['/g/PRIVATE/c/' + CID, 'g', 4, 36],
    ['/g', 'g', 1, 1], ['/PRIVATE_PATH', 'other', 1, 12],
    ['/c/%50%52%49%56%41%54%45', 'c_nonuuid', 2, 21],
    ['/c/' + 'x'.repeat(257), 'c_nonuuid', 2, '256+'],
    ['/' + Array(9).fill('PRIVATE').join('/'), 'other', '8+', 7],
  ];
  for (const [path, kind, count, length] of checks) {
    const shape = routeShape(path);
    assert.deepEqual(Object.keys(shape), ['kind', 'pathnameString', 'empty', 'segment_count', 'segment_length',
      'last_uuid_suffix', 'last_uuid_prefix', 'last_has_hyphen', 'trailingSlash', 'bounded_pending_shape',
      'prefix_pchar', 'prefix_has_colon', 'prefix_has_percent', 'prefix_percent_type']);
    assert.equal(shape.kind, kind);
    assert.equal(shape.segment_count, count);
    assert.equal(shape.segment_length, length);
    assert.equal(shape.empty, path === '');
    assert.equal(shape.trailingSlash, path.endsWith('/'));
    assert.equal(shape.pathnameString, true);
    assert.doesNotMatch(JSON.stringify(shape), /PRIVATE|11111111|%50|\/c\/pending/);
  }
  for (const value of [null, undefined, 1, { toString() { assert.fail('must not coerce'); } }]) {
    const shape = routeShape(value);
    assert.equal(shape.pathnameString, false);
    assert.equal(shape.empty, false);
    assert.equal(shape.kind, 'other');
  }
  for (const [last, prefix, suffix] of [[CID, true, true], ['PRIVATE-' + CID, false, true],
    [CID + '-PRIVATE', true, false], ['PRIVATE-' + CID + '-PRIVATE', false, false]]) {
    const shape = routeShape('/c/' + last);
    assert.equal(shape.last_uuid_prefix, prefix);
    assert.equal(shape.last_uuid_suffix, suffix);
    assert.equal(shape.last_has_hyphen, true);
  }
});

test('route diagnostics: transient empty/non-UUID route precedes original ID; first revoke survives return and denied follow-up', async () => {
  for (const path of ['', '/c/pending', '/c/PRIVATE-' + CID]) {
    const p = await provenChat({ route(p) {
      // Deliberately inject a synthetic empty pathname: this is not a claim that live browsers emit it.
      p.sandbox.location.pathname = path;
      p.sandbox.navigation.dispatchEvent(new p.sandbox.NavigationCurrentEntryChangeEvent(
        'currententrychange', { navigationType: 'push' }));
      p.sandbox.history.replaceState({}, '', '/c/' + CID);
    } });
    const first = await proofDiagnostics(p);
    const fields = diagnosticFields(first['個人化路由撤銷']);
    assert.equal(fields.source, 'currententrychange');
    assert.equal(fields.observed_kind, path ? 'c_nonuuid' : 'other');
    assert.equal(fields.observed_empty, String(!path));
    assert.equal(fields.current_kind, fields.observed_kind);
    assert.equal(fields.proof_kind, 'root');
    assert.equal(fields.observed_eq_current, 'true');
    assert.equal(fields.sent, 'true');
    assert.equal(fields.complete, 'false');
    assert.equal(fields.server_bound, 'false');
    assert.equal(fields.route_bound, 'false');
    assert.match(first['個人化目前路由'], /current_kind=c_uuid/);
    assert.deepEqual(diagnosticFields(first['個人化原始ID']), {
      seen: 'true', first_id_shape: 'uuid', first_proof_revoked: 'true',
      first_bind_result: 'proof_missing', bind_result: 'proof_missing',
    });
    assert.ok(p.reports.some((r) => r.id === 'S' && r.kind === 'finished'));
    await p.follow();
    const final = await proofDiagnostics(p);
    assert.equal(sendRequests(p).length, 1, 'diagnostics never permit the intermediate route or renew proof');
    assert.equal(final['個人化路由撤銷'], first['個人化路由撤銷']);
    assert.equal(final['個人化原始ID'], first['個人化原始ID']);
    assert.doesNotMatch(JSON.stringify([final['個人化路由撤銷'], final['個人化原始ID'], final['個人化目前路由']]),
      /PRIVATE|\/c\/pending|11111111|22222222|Bearer|%50|https:|\//);
  }
});

test('route diagnostics: navigation sources stay distinct; observed need not equal current, and native empty remains rejected', async () => {
  for (const source of ['history_push', 'history_replace', 'popstate', 'native', 'observer', 'send']) {
    const p = await provenChat({ route: null, navigationEvents: false });
    const path = '/c/PRIVATE-' + CID;
    if (source === 'history_push') p.sandbox.history.pushState({}, '', path);
    if (source === 'history_replace') p.sandbox.history.replaceState({}, '', path);
    if (source === 'native') {
      p.command({ cmd: 'connectorNavigated', id: 'EMPTY', path: '' });
      assert.equal((await proofDiagnostics(p))['個人化路由撤銷'], undefined);
      p.sandbox.location.pathname = '/c/' + CID;
      p.command({ cmd: 'connectorNavigated', id: 'NAV', path });
    }
    if (source === 'popstate' || source === 'observer') {
      p.sandbox.location.pathname = path;
      if (source === 'popstate') p.sandbox.dispatchEvent({ type: 'popstate' });
      else p.mutate();
    }
    if (source === 'send') {
      p.sandbox.location.pathname = path;
      p.send({ id: 'F', conversationID: CID, temporary: true, temporaryPersonalized: true });
    }
    const snapshot = (await proofDiagnostics(p))['個人化路由撤銷'];
    assert.ok(snapshot, 'missing route snapshot from ' + source);
    const fields = diagnosticFields(snapshot);
    assert.equal(fields.source, source);
    assert.equal(fields.observed_kind, 'c_nonuuid');
    assert.equal(fields.current_kind, source === 'native' ? 'c_uuid' : 'c_nonuuid');
    assert.equal(fields.observed_eq_current, String(source !== 'native'));
    assert.equal(fields.server_bound, 'true');
    assert.equal(fields.complete, 'true');
  }
});

test('route diagnostics: original ID binds before mid-stream route revoke, unlike revoke before ID parsing', async () => {
  const p = fixture({ allowNetwork: true, respond() {
    return { ok: true, status: 200, headers: new Headers({ 'content-type': 'text/event-stream' }), body: {},
      clone: () => ({ body: { getReader() {
        let first = true;
        return { async read() {
          if (first) {
            first = false;
            return { done: false, value: new TextEncoder().encode('data: ' + JSON.stringify({
              conversation_id: CID, message: { id: 'synthetic', author: { role: 'assistant' },
                content: { content_type: 'text', parts: ['synthetic reply'] } },
            }) + '\n\n') };
          }
          p.sandbox.history.pushState({}, '', '/c/pending');
          return { done: true };
        } };
      } } }) };
  } });
  nativeTemporary(p);
  p.button.onClick = () => p.sandbox.fetch('https://chatgpt.com/backend-api/f/conversation',
    { method: 'POST', body: JSON.stringify(nativeFlags) });
  p.send({ temporary: true, temporaryPersonalized: true });
  await p.advance(2000); await settle(p);
  const diag = await proofDiagnostics(p);
  assert.match(diag['個人化路由撤銷'], /sent=true; complete=false; server_bound=true/);
  assert.deepEqual(diagnosticFields(diag['個人化原始ID']), {
    seen: 'true', first_id_shape: 'uuid', first_proof_revoked: 'false',
    first_bind_result: 'bound', bind_result: 'bound',
  });
});

test('route diagnostics: direct/root successes and conflicting original IDs retain existing decisions', async () => {
  for (const route of [CID, null]) {
    const p = await provenChat({ route });
    const diag = await proofDiagnostics(p);
    assert.equal(diag['個人化路由撤銷'], undefined);
    assert.match(diag['個人化原始ID'], /first_bind_result=bound; bind_result=bound/);
    await p.follow();
    assert.equal(sendRequests(p).length, 2);
  }
  for (const serverIDs of [[CID, OTHER_CID], ['PRIVATE_ID']]) {
    const p = await provenChat({ route: null, serverIDs });
    const diag = await proofDiagnostics(p);
    assert.match(diag['個人化原始ID'], /bind_result=id_conflict$/);
    assert.doesNotMatch(diag['個人化原始ID'], /PRIVATE|11111111|22222222/);
    assert.ok(p.failure());
    await p.follow();
    assert.equal(sendRequests(p).length, 1);
  }
});

test('route diagnostics: UUID tail mismatch and tick/response callers remain fail-closed', async () => {
  const p = await provenChat({ route(p) { p.sandbox.history.pushState({}, '', '/c/' + CID + '/'); } });
  const snapshot = diagnosticFields((await proofDiagnostics(p))['個人化路由撤銷']);
  assert.equal(snapshot.observed_kind, 'other');
  assert.equal(snapshot.observed_trailingSlash, 'true');
  assert.equal(snapshot.observed_segment_length, '0');
  assert.equal(snapshot.uuid_match, 'true');
  assert.equal(snapshot.uuid_tail, 'false');
  await p.follow();
  assert.equal(sendRequests(p).length, 1);

  for (const source of ['tick', 'response']) {
    let release;
    const waiting = new Promise((resolve) => { release = resolve; });
    const q = fixture({ allowNetwork: true, respond: () => ({
      ok: true, status: 200, headers: new Headers({ 'content-type': 'text/event-stream' }), body: {},
      clone: () => ({ body: { getReader() {
        let first = true;
        return { async read() {
          if (!first) return { done: true };
          first = false;
          await waiting;
          if (source === 'response') q.sandbox.location.pathname = '/c/pending';
          return { done: false, value: new TextEncoder().encode('data: ' + JSON.stringify({ conversation_id: CID }) + '\n\n') };
        } };
      } } }),
    }) });
    nativeTemporary(q);
    q.button.onClick = () => q.sandbox.fetch('https://chatgpt.com/backend-api/f/conversation',
      { method: 'POST', body: JSON.stringify(nativeFlags) });
    q.send({ temporary: true, temporaryPersonalized: true });
    await q.advance(1000);
    if (source === 'tick') {
      q.sandbox.location.pathname = '/c/pending';
      await q.advance(200);
    }
    release();
    await q.advance(500); await settle(q);
    const diag = await proofDiagnostics(q);
    assert.equal(diagnosticFields(diag['個人化路由撤銷']).source, source);
    const id = diagnosticFields(diag['個人化原始ID']);
    assert.equal(id.first_proof_revoked, String(source === 'tick'));
    assert.equal(id.bind_result, source === 'tick' ? 'proof_missing' : 'page_rejected');
  }
});

test('route diagnostics: same-turn ID records ignore non-authoritative and stale turns, preserve first binding, and reset on new proof', async () => {
  // Execute the actual diagnostic helpers independently; no production debug interface is added.
  const helpers = script.slice(script.indexOf('const beginPersonalizedIDDiagnostic = '),
    script.indexOf('// 固定狀態＋布林值'));
  const d = vm.runInNewContext(`let personalizedIDDiagnostic = null, personalizedProof = null; const diag = {};
    ${helpers}
    ({ diag, begin: beginPersonalizedIDDiagnostic, seen: notePersonalizedOriginalID, finish: finishPersonalizedIDDiagnostic,
      proof(p) { personalizedProof = p; personalizedIDDiagnostic = null; } });`);
  const proof = { revoked: false };
  d.proof(proof);
  const old = { personalizedProof: proof };
  d.begin(old);
  d.finish(d.seen(old, CID), 'bound');
  const next = { personalizedProof: proof };
  d.begin(next);
  const before = d.diag['個人化原始ID'];
  d.finish(d.seen(old, OTHER_CID), 'id_conflict');
  assert.equal(d.diag['個人化原始ID'], before, 'old turn cannot overwrite the newer turn on the same proof');
  d.finish(d.seen(next, CID), 'bound');
  proof.revoked = true;
  d.finish(d.seen(next, OTHER_CID), 'id_conflict');
  assert.match(d.diag['個人化原始ID'], /first_proof_revoked=false; first_bind_result=bound; bind_result=id_conflict$/);
  const final = d.diag['個人化原始ID'];
  d.proof({ revoked: false });
  d.finish(d.seen(next, CID), 'bound');
  assert.equal(d.diag['個人化原始ID'], final, 'old proof remains stale even before the new turn starts');

  // A real new-proof lifecycle clears the previous frozen revoke and ID result.
  const ids = [CID];
  const p = await provenChat({ route: null, serverIDs: ids });
  p.sandbox.history.pushState({}, '', '/c/pending');
  assert.ok((await proofDiagnostics(p))['個人化路由撤銷']);
  nativeReset(p);
  ids.length = 0;
  p.button.onClick = () => p.submit(nativeFlags);
  p.send({ id: 'NEW', temporary: true, temporaryPersonalized: true });
  await p.advance(1600);
  let diag = await proofDiagnostics(p);
  assert.equal(diag['個人化路由撤銷'], undefined);
  assert.match(diag['個人化原始ID'], /^seen=false;/);
  // An unrelated event stream parsed during NEW is not its original send response.
  const sendGuard = script.slice(script.indexOf('const setConversation = '), script.indexOf('function finishTurn('));
  assert.match(sendGuard, /fromSendResponse \? notePersonalizedOriginalID\(turn, conversationID\) : null/);
  assert.match(sendGuard, /else if \(fromSendResponse\)/);
});

test('proof diagnostics: before-continuation snapshot and revocation reasons contain only fixed states/booleans', async () => {
  const empty = await proofDiagnostics(fixture());
  assert.match(empty['個人化續聊證據'], /proof=none; reason=none/);
  const pending = fixture();
  nativeTemporary(pending);
  pending.send({ temporary: true, temporaryPersonalized: true });
  await pending.advance(1000);
  assert.match((await proofDiagnostics(pending))['個人化續聊證據'], /proof=pending/);
  const p = await provenChat({ route: null, pollAfterReadError: true });
  await p.follow();
  let diag = await proofDiagnostics(p);
  assert.match(diag['個人化續聊前'], /proof=complete; reason=none; stage=before_continuation; path=root/);
  assert.match(diag['個人化續聊前'], /serverID=true; routeID=false; nativeOriginal=true/);
  assert.match(diag['個人化續聊前'], /commandMatch=true; consent=true/);
  p.sandbox.history.pushState({}, '', '/PRIVATE_PATH');
  await p.follow();
  diag = await proofDiagnostics(p);
  assert.match(diag['個人化續聊前'], /proof=revoked; reason=route_changed/);
  assert.match(diag['個人化續聊證據'], /stage=continuation_denied/);
  for (const name of ['個人化續聊前', '個人化續聊證據']) {
    assert.doesNotMatch(diag[name], /PRIVATE|11111111|22222222|synthetic|Bearer|\/|body|token/);
    const fields = Object.fromEntries(diag[name].split('; ').map((s) => s.split('=')));
    assert.deepEqual(Object.keys(fields), ['proof', 'reason', 'stage', 'path', 'samePage',
      'serverID', 'routeID', 'nativeOriginal', 'routeMatch', 'commandID', 'commandMatch', 'consent', 'ui']);
    assert.ok(['none', 'pending', 'complete', 'revoked'].includes(fields.proof));
    assert.ok(['none', 'response_id_conflict', 'turn_failed', 'cancelled', 'request_guard',
      'origin_changed', 'route_changed', 'mode_changed', 'mode_reversal', 'new_initial', 'other'].includes(fields.reason));
    assert.ok(['idle', 'created', 'response_bound', 'completed', 'revoked', 'before_continuation',
      'continuation_allowed', 'continuation_denied', 'prepare_validated', 'send_validated', 'other'].includes(fields.stage));
    assert.ok(['root', 'conversation', 'other'].includes(fields.path));
    assert.ok(['personalized', 'unpersonalized', 'off', 'missing', 'unknown'].includes(fields.ui));
    for (const name of ['samePage', 'serverID', 'routeID', 'nativeOriginal', 'routeMatch', 'commandID', 'commandMatch', 'consent'])
      assert.ok(['true', 'false'].includes(fields[name]));
  }
});

test('native-page continuation: missing proof or consent rejects send/edit/regenerate before navigation', async () => {
  for (const action of ['send', 'edit', 'regenerate']) for (const bad of ['server-id', 'consent', 'command-id']) {
    const p = await provenChat({ route: null, ...(bad === 'server-id' ? { serverIDs: [] } : {}) });
    const extra = { conversationID: bad === 'command-id' ? OTHER_CID : CID,
      temporary: true, temporaryPersonalized: bad !== 'consent' };
    const retry = action === 'regenerate' ? regenerationButton(p) : null;
    const before = sendRequests(p).length;
    if (retry) {
      p.command({ cmd: 'regenerate', id: 'R', ...extra });
      await p.advance(3000);
    } else await p.follow({ ...extra, ...(action === 'edit' ? { parentID: 'synthetic-edit-parent' } : {}) });
    assert.equal(sendRequests(p).length, before, action + '/' + bad);
    assert.deepEqual(p.navigations, [], action + '/' + bad);
    if (retry) assert.equal(retry.clicks, 0);
  }
});

test('continuation: wrong command ID, original body ID or contradictory route fail closed', async () => {
  for (const wrong of ['command', 'body', 'route']) {
    const p = await provenChat();
    if (wrong === 'route') p.sandbox.history.pushState({}, '', '/c/' + OTHER_CID);
    await p.follow(wrong === 'command' ? { conversationID: OTHER_CID } : {}, nativeFlags,
      wrong === 'body' ? OTHER_CID : CID);
    assert.equal(sendRequests(p).length, 1, wrong);
  }
});

test('continuation: every original send must contain exact native true/false, before rewriting', async () => {
  for (const flags of [{}, { is_do_not_remember: false },
    { history_and_training_disabled: false, is_do_not_remember: false },
    { history_and_training_disabled: true }, { history_and_training_disabled: true, is_do_not_remember: true },
    { history_and_training_disabled: 'true', is_do_not_remember: false }]) {
    const p = await provenChat();
    await p.follow({}, flags);
    assert.equal(sendRequests(p).length, 1, JSON.stringify(flags));
  }
});

test('continuation: initial rewritten flags and URL/DOM completion never mint genuine proof', async () => {
  for (const options of [{ initialFlags: { is_do_not_remember: false } }, { serverIDs: [] },
    { serverIDs: [OTHER_CID] }, { serverIDs: [CID, OTHER_CID] }]) {
    const p = await provenChat(options);
    const count = sendRequests(p).length;
    await p.follow();
    assert.equal(sendRequests(p).length, count, JSON.stringify(options));
  }
});

test('continuation: off/unpersonalized/ambiguous native controls contradict missing-picker proof', async () => {
  for (const mode of ['off', 'unpersonalized', 'ambiguous']) {
    const p = await provenChat();
    nativeTemporary(p, mode === 'ambiguous' ? 'personalized' : mode);
    if (mode === 'ambiguous') nativeTemporary(p);
    await p.follow();
    assert.equal(sendRequests(p).length, 1, mode);
  }
});

test('continuation: same ID without explicit per-command consent cannot use old proof', async () => {
  for (const extra of [{ temporaryPersonalized: false }, { temporaryPersonalized: undefined },
    { temporary: false }, { temporaryPersonalized: 'true' }]) {
    const p = await provenChat();
    await p.follow(extra);
    assert.equal(sendRequests(p).length, 1, JSON.stringify(extra));
  }
});

test('continuation: leaving and returning to same route permanently revokes proof', async () => {
  const p = await provenChat();
  p.sandbox.history.pushState({}, '', '/');
  p.sandbox.history.pushState({}, '', '/c/' + CID);
  await p.follow();
  assert.equal(sendRequests(p).length, 1);
});

test('continuation: reload loses proof even with matching URL and explicit consent', async () => {
  for (const path of ['/', '/c/' + CID]) {
    const p = fixture();
    p.sandbox.location.pathname = path;
    new p.Element('div', { 'data-message-author-role': 'assistant' });
    p.send({ conversationID: CID, temporary: true, temporaryPersonalized: true });
    await p.advance(2000);
    notSubmitted(p);
    assert.deepEqual(p.navigations, []);
  }
});

test('continuation: original prepare flags are checked too, even without a model rewrite', async () => {
  for (const route of [CID, null]) for (const flags of [nativeFlags, {}, { is_do_not_remember: false },
    { history_and_training_disabled: false, is_do_not_remember: false },
    { history_and_training_disabled: true, is_do_not_remember: true }]) {
    const p = await provenChat({ route });
    const good = flags === nativeFlags, before = p.requests.length;
    p.button.onClick = () => (async () => {
      await p.sandbox.fetch('https://chatgpt.com/backend-api/f/conversation/prepare', {
        method: 'POST', body: JSON.stringify(flags),
      });
      await p.submit(nativeFlags, CID);
    })().catch(() => {});
    p.send({ id: 'F', conversationID: CID, temporary: true, temporaryPersonalized: true });
    await p.advance(2000);
    await settle(p);
    assert.equal(p.requests.slice(before).filter((r) => r.init?.method === 'POST').length, good ? 2 : 0);
    assert.equal(sendRequests(p).length, good ? 2 : 1);
  }
});

test('continuation: observed mode reversal revokes proof even when the picker vanishes again', async () => {
  for (const transient of [false, true]) {
    const p = await provenChat();
    const ui = nativeTemporary(p, transient ? 'personalized' : 'unpersonalized');
    p.mutate([{ type: 'attributes', attributeName: 'aria-label', target: ui.picker,
      oldValue: transient ? 'Unpersonalized' : 'Personalized' }]);
    ui.toggle.isConnected = ui.picker.isConnected = false;
    await p.follow();
    assert.equal(sendRequests(p).length, 1);
  }
});

test('continuation: excluded elements and unrelated attributes cannot revoke native proof', async () => {
  for (const kind of ['message', 'form', 'dialog', 'hidden', 'disabled', 'non-control', 'other-attribute']) {
    const p = await provenChat();
    const parent = kind === 'message' ? new p.Element('div', { 'data-message-author-role': 'assistant' })
      : kind === 'form' ? p.form : kind === 'dialog' ? new p.Element('div', { role: 'dialog' }) : null;
    const target = new p.Element(kind === 'non-control' ? 'div' : 'button',
      { 'aria-label': 'unrelated' }, parent);
    if (kind === 'hidden') target.hidden = true;
    if (kind === 'disabled') target.disabled = true;
    p.mutate([{ type: 'attributes', attributeName: kind === 'other-attribute' ? 'aria-pressed' : 'aria-label',
      target, oldValue: 'Unpersonalized' }]);
    await p.follow();
    assert.equal(sendRequests(p).length, 2, kind);
  }
});

test('personalized temporary: queued toggle-on mutation predating proof cannot revoke the first turn', async () => {
  const p = fixture({ allowNetwork: true });
  const ui = nativeTemporary(p, 'off');
  ui.toggle.onClick = () => {
    ui.toggle.attrs['aria-label'] = 'Turn off temporary chat';
    ui.picker.isConnected = true;
    p.queueMutation({ type: 'attributes', attributeName: 'aria-label', target: ui.toggle, oldValue: 'Temporary chat' });
  };
  p.doc.onInsert = (_cmd, text) => { p.box.value = text; p.mutate(); return true; };
  p.button.onClick = () => p.sandbox.fetch('https://chatgpt.com/backend-api/f/conversation', {
    method: 'POST', body: JSON.stringify(nativeFlags),
  }).catch(() => {});
  p.send({ temporary: true, temporaryPersonalized: true });
  await p.advance(2000);
  assert.equal(sendRequests(p).length, 1, JSON.stringify(p.reports));
});

test('continuation: cancellation/navigation/mode changes during Blob or Request decoding cannot dispatch or renew proof', async () => {
  for (const route of [CID, null]) for (const kind of ['Blob', 'Request']) for (const change of ['cancel', 'navigate', 'mode']) {
    const p = await provenChat({ route });
    let resolveBody, decoding = false;
    const body = new Promise((resolve) => { resolveBody = resolve; });
    if (kind === 'Blob') {
      p.sandbox.Blob = class { text() { decoding = true; return body; } };
      p.button.onClick = () => p.submit(nativeFlags, CID, { body: new p.sandbox.Blob() });
    } else {
      p.sandbox.Request = class extends Request { clone() { return { text: () => { decoding = true; return body; } }; } };
      p.button.onClick = () => p.sandbox.fetch(new p.sandbox.Request(
        'https://chatgpt.com/backend-api/f/conversation', { method: 'POST', body: '{}' })).catch(() => {});
    }
    p.send({ id: 'F', conversationID: CID, temporary: true, temporaryPersonalized: true });
    await p.advance(1200);
    assert.equal(decoding, true, kind + ' must really be awaiting body decode');
    if (change === 'cancel') p.command({ cmd: 'stop', id: 'cancel', requestID: 'F' });
    if (change === 'navigate') {
      p.sandbox.history.pushState({}, '', '/');
      p.sandbox.history.pushState({}, '', '/c/' + CID);
    }
    let ui;
    if (change === 'mode') ui = nativeTemporary(p, 'unpersonalized');
    resolveBody(JSON.stringify({ ...nativeFlags, conversation_id: CID }));
    await p.advance(2500);
    await settle(p);
    assert.equal(sendRequests(p).length, 1, kind + '/' + change);
    assert.ok(!p.reports.some((r) => r.id === 'F' && r.kind === 'temporary'), kind + '/' + change);
    if (ui) ui.toggle.isConnected = ui.picker.isConnected = false;
    await p.follow({ id: 'AFTER' });
    assert.equal(sendRequests(p).length, 1, 'revoked proof must not return');
  }
});

test('continuation: valid decoded Blob/Request bodies still work and cannot borrow another origin', async () => {
  for (const kind of ['Blob', 'Request', 'foreign-origin']) {
    const p = await provenChat();
    const body = JSON.stringify({ ...nativeFlags, conversation_id: CID });
    if (kind === 'Blob') {
      p.sandbox.Blob = class { async text() { return body; } };
      p.button.onClick = () => p.submit(nativeFlags, CID, { body: new p.sandbox.Blob() });
    } else {
      p.button.onClick = () => p.sandbox.fetch(new Request(
        (kind === 'Request' ? 'https://chatgpt.com' : 'https://example.invalid') + '/backend-api/f/conversation',
        { method: 'POST', body })).catch(() => {});
    }
    p.send({ id: 'F', conversationID: CID, temporary: true, temporaryPersonalized: true });
    await p.advance(2000);
    await settle(p);
    assert.equal(sendRequests(p).length, kind === 'foreign-origin' ? 1 : 2, kind + JSON.stringify(p.reports));
  }
});

// A NEW Swift command does not reset the provider's retained root-page context.
// Only the actual native new-chat control changes these synthetic native fields.
function nativeReset(p, { works = true, delay = 0 } = {}) {
  const reset = new p.Element('button', { 'data-testid': 'create-new-chat-button', 'aria-label': 'New chat' });
  let ui;
  reset.onClick = () => {
    if (!works) return;
    const apply = () => {
      for (const e of p.nodes) if (e.getAttribute('data-message-author-role')) e.isConnected = false;
      for (const e of p.nodes) if (['Temporary chat', 'Turn off temporary chat', 'Personalized', 'Unpersonalized'].includes(e.getAttribute('aria-label')))
        e.isConnected = false;
      p.sandbox.history.pushState({}, '', '/');
      ui = nativeTemporary(p, 'off');
      ui.toggle.onClick = () => {
        ui.toggle.attrs['aria-label'] = 'Turn off temporary chat';
        ui.picker.isConnected = true;
      };
      p.nativeWasReset = true;
    };
    if (delay) p.later(delay, apply); else apply();
  };
  return reset;
}

function resetEditable(p, shape = 'p_br') {
  p.box.isConnected = false;
  p.box = new p.Element('div', { id: 'prompt-textarea', contenteditable: 'true' }, p.form);
  delete p.box.value;
  p.box.select = undefined;
  if (shape === 'p_br') {
    const para = new p.Element('p', {}, p.box);
    new p.Element('br', {}, para);
  }
  p.box.innerText = shape === 'p_br' ? '\n' : '';
  p.doc.onInsert = (_cmd, text) => {
    assert.equal(p.doc.selected, p.box);
    p.box.innerText = p.box.textContent = text;
    return true;
  };
  return p.box;
}
const draftNode = (text) => ({ nodeType: 3, textContent: text });

for (const shape of ['empty', 'p_br']) for (const personalized of [false, true]) {
  test(`reset exact DOM: ${shape} with hidden skeleton supports new ${personalized ? 'personalized' : 'normal'}`, async () => {
    const p = await provenChat();
    resetEditable(p, shape);
    const parent = new p.Element('div'); parent.style.display = 'none';
    new p.Element('div', { role: 'dialog' }, parent);
    const reset = nativeReset(p);
    p.button.onClick = () => p.submit(personalized ? nativeFlags : { is_do_not_remember: false });
    p.send({ id: 'NEW', temporary: personalized, temporaryPersonalized: personalized });
    await p.advance(6500); await settle(p);
    assert.equal(reset.clicks, 1);
    assert.equal(sendRequests(p).length, 2, JSON.stringify(p.reports));
    const body = JSON.parse(sendRequests(p)[1].init.body);
    assert.equal(body.conversation_id, undefined);
    assert.equal(body.history_and_training_disabled, personalized ? true : undefined);
    assert.equal((await proofDiagnostics(p))['新聊天請求'], 'send:validated');
  });
}

for (const text of [' ', '\n', '\t', '\u00a0', '\u200b', '\ufeff']) {
  test(`reset exact DOM: preserves real text node U+${text.charCodeAt(0).toString(16)}`, async () => {
    const p = await provenChat();
    const box = resetEditable(p);
    box.childrenOverride = [draftNode(text), ...box.childNodes];
    const reset = nativeReset(p), before = p.insertions.length;
    p.send({ id: 'NEW' }); await p.advance(6500); await settle(p);
    assert.equal(reset.clicks, 0);
    assert.equal(box.textContent, text);
    assert.equal(p.insertions.length, before);
    assert.equal(sendRequests(p).length, 1);
    const flags = diagnosticFields((await proofDiagnostics(p))['新聊天重設阻擋']);
    assert.equal(flags.text_node_nonempty, 'true');
    assert.equal(flags.composer_structure, 'other');
  });
}

for (const kind of ['double-br', 'attachment', 'noneditable', 'text-getter', 'children-getter']) {
  test(`reset exact DOM: ${kind} cannot authorize clearing`, async () => {
    const p = await provenChat(), box = resetEditable(p);
    if (kind === 'double-br') new p.Element('br', {}, box.childNodes[0]);
    if (kind === 'attachment') new p.Element('img', { 'data-file-id': 'PRIVATE' }, box);
    if (kind === 'noneditable') box.childNodes[0].attrs.contenteditable = 'false';
    if (kind.endsWith('-getter')) Object.defineProperty(box, kind === 'text-getter' ? 'textContent' : 'childNodes',
      { get() { throw new Error('PRIVATE /c/' + CID); } });
    const reset = nativeReset(p), before = p.insertions.length;
    p.send({ id: 'NEW' }); await p.advance(6500); await settle(p);
    assert.equal(reset.clicks, 0);
    assert.equal(p.insertions.length, before);
    assert.equal(sendRequests(p).length, 1);
    const diag = (await proofDiagnostics(p))['新聊天重設阻擋'];
    assert.doesNotMatch(diag, /PRIVATE|11111111|\/c\//);
    assert.equal(diagnosticFields(diag).composer_structure, kind.endsWith('-getter') ? 'unknown' : 'other');
  });
}

for (const kind of ['opacity', 'aria-hidden', 'inert', 'zero-rect', 'display-contents', 'style-error']) {
  test(`reset dialogs: ${kind} is not proof of a hidden skeleton`, async () => {
    const p = await provenChat(), d = new p.Element('div', { role: 'dialog' });
    if (kind === 'opacity') d.style.opacity = '0';
    if (kind === 'aria-hidden') d.attrs['aria-hidden'] = 'true';
    if (kind === 'inert') d.inert = true;
    if (kind === 'zero-rect') d.getClientRects = () => [];
    if (kind === 'display-contents') d.style.display = 'contents';
    if (kind === 'style-error') Object.defineProperty(d, 'style', { get() { throw new Error('PRIVATE_DIALOG'); } });
    const reset = nativeReset(p), before = p.insertions.length;
    p.send({ id: 'NEW' }); await p.advance(6500); await settle(p);
    assert.equal(reset.clicks, 0);
    assert.equal(p.insertions.length, before);
    assert.equal(sendRequests(p).length, 1);
    const diag = (await proofDiagnostics(p))['新聊天重設阻擋'];
    assert.doesNotMatch(diag, /PRIVATE/);
    assert.equal(diagnosticFields(diag).dialog_blocking_or_unknown, 'true');
    assert.equal(diagnosticFields(diag).dialog_definitely_hidden_only, 'false');
  });
}

test('reset dialogs: native open/modal or unknown getters block even with display none', async () => {
  for (const kind of ['open', 'modal', 'open-getter', 'modal-getter']) {
    const p = await provenChat(), d = new p.Element('dialog');
    d.style.display = 'none';
    d.open = kind === 'open';
    const matches = d.matches.bind(d);
    d.matches = (selector) => {
      if (selector !== ':modal') return matches(selector);
      if (kind === 'modal-getter') throw new Error('PRIVATE_MODAL');
      return kind === 'modal';
    };
    if (kind === 'open-getter') Object.defineProperty(d, 'open', { get() { throw new Error('PRIVATE_OPEN'); } });
    const reset = nativeReset(p), before = p.insertions.length;
    p.send({ id: 'NEW' }); await p.advance(6500); await settle(p);
    assert.equal(reset.clicks, 0, kind);
    assert.equal(p.insertions.length, before);
    assert.equal(sendRequests(p).length, 1);
    const diag = (await proofDiagnostics(p))['新聊天重設阻擋'];
    assert.doesNotMatch(diag, /PRIVATE/);
    assert.equal(diagnosticFields(diag).dialog_state, kind.endsWith('-getter') ? 'unknown' : 'blocking');
  }
});

test('reset dialogs: only proven hidden nodes are ignored, including multiple dialogs and query failures', async () => {
  for (const kind of ['self-hidden', 'closed-native-hidden', 'hidden-and-active', 'query-error']) {
    const p = await provenChat(), d = new p.Element(kind === 'closed-native-hidden' ? 'dialog' : 'div', { role: 'dialog' });
    d.style.display = 'none'; d.open = false;
    if (kind === 'hidden-and-active') new p.Element('div', { role: 'dialog' });
    if (kind === 'query-error') {
      const query = p.doc.querySelectorAll.bind(p.doc);
      p.doc.querySelectorAll = (s) => {
        if (s === '[role="dialog"], dialog') throw new Error('PRIVATE_QUERY');
        return query(s);
      };
    }
    const reset = nativeReset(p, { works: false });
    p.send({ id: 'NEW' }); await p.advance(6500); await settle(p);
    const hidden = kind === 'self-hidden' || kind === 'closed-native-hidden';
    assert.equal(reset.clicks, hidden ? 1 : 0, kind);
    const diag = (await proofDiagnostics(p))['新聊天重設阻擋'];
    assert.equal(diagnosticFields(diag).dialog_definitely_hidden_only, String(hidden));
    assert.equal(diagnosticFields(diag).dialog_blocking_or_unknown, String(!hidden));
    assert.doesNotMatch(diag, /PRIVATE/);
    assert.equal(sendRequests(p).length, 1);
  }
});

test('reset rechecks: focus cannot restore a draft, attachment or active dialog before insertion', async () => {
  for (const kind of ['space', 'nbsp', 'attachment', 'dialog']) {
    const p = await provenChat(), box = resetEditable(p);
    nativeReset(p);
    const before = p.insertions.length;
    box.onFocus = () => {
      if (kind === 'space' || kind === 'nbsp') {
        const text = kind === 'space' ? ' ' : '\u00a0';
        box.childrenOverride = [draftNode(text)]; box.innerText = text;
      } else if (kind === 'attachment') new p.Element('img', {}, box);
      else new p.Element('div', { role: 'dialog' }).style.opacity = '0';
    };
    p.send({ id: 'NEW' }); await p.advance(6500); await settle(p);
    assert.equal((await proofDiagnostics(p))['新聊天重設'], 'confirmed', kind);
    assert.equal(p.insertions.length, before, kind);
    assert.equal(sendRequests(p).length, 1, kind);
  }
});

test('reset rechecks: observed dialog latches invalid after it becomes hidden again', async () => {
  const p = await provenChat();
  nativeReset(p, { delay: 1000 });
  p.send({ id: 'NEW' }); await p.advance(100);
  const dialog = new p.Element('div', { role: 'dialog' });
  await p.advance(200); // ready() observes the blocking dialog.
  dialog.style.display = 'none';
  await p.advance(6500); await settle(p);
  const flags = diagnosticFields((await proofDiagnostics(p))['新聊天重設阻擋']);
  assert.equal(flags.dialog_definitely_hidden_only, 'true');
  assert.equal(flags.watch_invalid, 'true');
  assert.equal(sendRequests(p).length, 1);
});

test('reset exact DOM: textarea whitespace and non-text extra structure are preserved', async () => {
  for (const kind of ['textarea-space', 'textarea-newline', 'textarea-getter', 'two-p', 'comment', 'empty-text']) {
    const p = await provenChat();
    if (kind.startsWith('textarea')) {
      p.box.value = kind === 'textarea-space' ? ' ' : '\n';
      if (kind === 'textarea-getter') Object.defineProperty(p.box, 'value', { get() { throw new Error('PRIVATE_VALUE'); } });
    } else {
      const box = resetEditable(p);
      if (kind === 'two-p') new p.Element('p', {}, box);
      else box.childrenOverride = [...box.childNodes, { nodeType: kind === 'comment' ? 8 : 3, textContent: '' }];
    }
    const reset = nativeReset(p), before = p.insertions.length;
    p.send({ id: 'NEW' }); await p.advance(6500); await settle(p);
    assert.equal(reset.clicks, 0, kind);
    assert.equal(p.insertions.length, before);
    assert.equal(sendRequests(p).length, 1);
    assert.doesNotMatch((await proofDiagnostics(p))['新聊天重設阻擋'], /PRIVATE/);
  }
});

test('new chat reset diagnostics: fixed booleans/enums for every combination, no unknown values', () => {
  const helper = script.slice(script.indexOf('const nativeResetBlockDiagnostic = '),
    script.indexOf('async function resetNativeChat('));
  const render = vm.runInNewContext(helper + '\nnativeResetBlockDiagnostic;');
  const keys = ['cancelled', 'origin_changed', 'stop', 'dialog', 'composer_missing', 'has_draft', 'watch_invalid'];
  for (let mask = 0; mask < 128; mask++) {
    const flags = Object.fromEntries(keys.map((key, i) => [key, !!(mask & (1 << i))]));
    flags.PRIVATE_UNKNOWN_KEY = 'PRIVATE_DRAFT /c/' + CID;
    const fields = diagnosticFields(render(flags));
    assert.deepEqual(Object.keys(fields), [...keys, 'composer_kind', 'composer_text_shape', 'composer_textcontent_empty',
      'composer_structure', 'text_node_nonempty', 'dialog_any', 'dialog_definitely_hidden_only',
      'dialog_blocking_or_unknown', 'dialog_state']);
    for (const key of keys) assert.equal(fields[key], String(flags[key]));
    assert.equal(fields.composer_kind, 'missing');
    assert.equal(fields.composer_text_shape, 'unknown');
    assert.equal(fields.composer_textcontent_empty, 'false');
    assert.equal(fields.composer_structure, 'unknown');
    assert.equal(fields.dialog_state, 'unknown');
    assert.doesNotMatch(render(flags), /PRIVATE|11111111|\/c\//);
  }
  const fields = diagnosticFields(render({ cancelled: 'PRIVATE_TOKEN', stop: 1, dialog: { raw: CID },
    composer_kind: 'PRIVATE_KIND', composer_text_shape: CID, composer_textcontent_empty: 'PRIVATE',
    composer_structure: 'PRIVATE', text_node_nonempty: 'PRIVATE', dialog_any: 'PRIVATE',
    dialog_definitely_hidden_only: 'PRIVATE', dialog_blocking_or_unknown: 'PRIVATE', dialog_state: 'PRIVATE' }));
  assert.ok(keys.every((k) => fields[k] === 'false'), 'never serialize arbitrary values or coerce them to strings');
  assert.equal(fields.composer_kind, 'missing');
  assert.equal(fields.composer_text_shape, 'unknown');
  assert.equal(fields.composer_textcontent_empty, 'false');
  assert.equal(fields.composer_structure, 'unknown');
  assert.equal(fields.dialog_state, 'unknown');
  assert.doesNotMatch(JSON.stringify(fields), /PRIVATE|11111111/);
  for (const kind of ['value', 'contenteditable', 'missing']) for (const shape of ['empty', 'whitespace', 'nonempty']) {
    const f = diagnosticFields(render({ composer_kind: kind, composer_text_shape: shape, composer_textcontent_empty: true }));
    assert.equal(f.composer_kind, kind);
    assert.equal(f.composer_text_shape, shape);
    assert.equal(f.composer_textcontent_empty, 'true');
  }
});

test('new chat reset diagnostics: blocked/control-unconfirmed/unconfirmed exits expose booleans without changing refusal', async () => {
  for (const bad of ['missing-control', 'ambiguous-control', 'no-op', 'draft', 'stop', 'dialog', 'composer_missing']) {
    const p = await provenChat();
    const reset = bad === 'missing-control' ? null : nativeReset(p, { works: bad !== 'no-op' });
    if (bad === 'ambiguous-control') nativeReset(p);
    if (bad === 'draft') p.box.value = 'PRIVATE RESTORED DRAFT';
    if (bad === 'stop') new p.Element('button', { 'data-testid': 'stop-button' });
    if (bad === 'dialog') new p.Element('div', { role: 'dialog', 'aria-label': 'PRIVATE_DIALOG' });
    if (bad === 'composer_missing') p.box.isConnected = false;
    const before = p.insertions.length;
    p.send({ id: 'NEW' });
    await p.advance(6500); await settle(p);
    const d = await proofDiagnostics(p);
    assert.equal(d['新聊天重設'], /control/.test(bad) ? 'control_unconfirmed' : bad === 'no-op' ? 'unconfirmed' : 'blocked', bad);
    assert.deepEqual(diagnosticFields(d['新聊天重設阻擋']), {
      cancelled: 'false', origin_changed: 'false', stop: String(bad === 'stop'), dialog: String(bad === 'dialog'),
      composer_missing: String(bad === 'composer_missing'), has_draft: String(bad === 'draft'),
      watch_invalid: String(['draft', 'stop', 'dialog'].includes(bad)),
      composer_kind: bad === 'composer_missing' ? 'missing' : 'value',
      composer_text_shape: bad === 'composer_missing' ? 'unknown' : bad === 'draft' ? 'nonempty' : 'empty',
      composer_textcontent_empty: String(bad !== 'composer_missing'),
      composer_structure: bad === 'composer_missing' ? 'unknown' : bad === 'draft' ? 'other' : 'empty',
      text_node_nonempty: 'false', dialog_any: String(bad === 'dialog'), dialog_definitely_hidden_only: 'false',
      dialog_blocking_or_unknown: String(bad === 'dialog'), dialog_state: bad === 'dialog' ? 'blocking' : 'none',
    }, bad);
    assert.doesNotMatch(d['新聊天重設阻擋'], /PRIVATE|11111111|22222222|https:|\/|Bearer/);
    assert.equal(p.insertions.length, before);
    assert.equal(sendRequests(p).length, 1);
    assert.equal(reset?.clicks ?? 0, bad === 'no-op' ? 1 : 0);
    if (bad === 'draft') assert.equal(p.box.value, 'PRIVATE RESTORED DRAFT');
  }
});

test('new chat reset diagnostics: cancellation/origin/latching during reset are observable, and the next reset clears stale flags', async () => {
  for (const change of ['cancel', 'origin', 'watch']) {
    const p = await provenChat();
    nativeReset(p, { delay: 1000 });
    p.send({ id: 'NEW' });
    await p.advance(100);
    if (change === 'cancel') p.command({ cmd: 'stop', id: 'C', requestID: 'NEW' });
    if (change === 'origin') p.sandbox.location.origin = 'https://unrelated.invalid';
    if (change === 'watch') {
      p.sandbox.history.replaceState({}, '', '/other');
      p.sandbox.history.replaceState({}, '', '/c/' + CID);
    }
    await p.advance(6500); await settle(p);
    const d = await proofDiagnostics(p);
    assert.equal(d['新聊天重設'], 'unconfirmed');
    const fields = diagnosticFields(d['新聊天重設阻擋']);
    assert.equal(fields.cancelled, String(change === 'cancel'));
    assert.equal(fields.origin_changed, String(change === 'origin'));
    assert.equal(fields.watch_invalid, 'true');
    assert.equal(sendRequests(p).length, 1);
  }
  const p = await provenChat();
  nativeReset(p);
  p.box.value = 'PRIVATE_DRAFT';
  p.send({ id: 'BLOCKED' });
  await p.advance(1);
  assert.equal(diagnosticFields((await proofDiagnostics(p))['新聊天重設阻擋']).has_draft, 'true');
  p.box.value = '';
  p.button.onClick = () => p.submit({ is_do_not_remember: false });
  p.send({ id: 'NORMAL' });
  await p.advance(2000); await settle(p);
  const d = await proofDiagnostics(p);
  assert.equal(d['新聊天重設'], 'confirmed');
  assert.equal(d['新聊天重設阻擋'], undefined, 'success cannot inherit the prior reset diagnostic');
  assert.equal(sendRequests(p).length, 2);
});

test('new chat reset diagnostics: exact placeholder is distinguished from real or inconsistent whitespace', async () => {
  const helper = script.slice(script.indexOf('const nativeResetComposerShape = '),
    script.indexOf('const nativeResetBlockDiagnostic = '));
  const shape = vm.runInNewContext(helper + '\nnativeResetComposerShape;');
  for (const [current, kind, textShape, contentEmpty, state, structure, nodeText] of [
    [null, 'missing', 'unknown', false, 'unknown', 'unknown', false],
    [{ tagName: 'TEXTAREA', value: '', textContent: '' }, 'value', 'empty', true, 'empty', 'empty', false],
    [{ tagName: 'TEXTAREA', value: ' \n', textContent: '' }, 'value', 'whitespace', true, 'draft', 'other', false],
    [{ isContentEditable: true, innerText: '\n', textContent: '', childNodes: [] },
      'contenteditable', 'whitespace', true, 'draft', 'other', false],
    [{ isContentEditable: true, innerText: '', textContent: '', childNodes: [] },
      'contenteditable', 'empty', true, 'empty', 'empty', false],
    [{ isContentEditable: true, innerText: 'PRIVATE_DRAFT', textContent: 'PRIVATE_DRAFT', childNodes: [draftNode('PRIVATE_DRAFT')] },
      'contenteditable', 'nonempty', false, 'draft', 'other', true],
    // An incomplete synthetic object is UNKNOWN, never accepted as a real empty DOM.
    [{ isContentEditable: true, innerText: '', textContent: '' },
      'contenteditable', 'empty', true, 'unknown', 'unknown', false],
  ]) {
    assert.deepEqual(JSON.parse(JSON.stringify(shape(current))), {
      composer_kind: kind, composer_text_shape: textShape, composer_textcontent_empty: contentEmpty,
      state, composer_structure: structure, text_node_nonempty: nodeText,
    });
  }
  // Deliberate fixture: not evidence that live Chromium/ChatGPT renders an empty placeholder this way.
  for (const text of ['', '\n', ' \t', 'PRIVATE_DRAFT']) {
    const p = await provenChat();
    p.box.isConnected = false;
    p.box = new p.Element('div', { id: 'prompt-textarea', class: 'ProseMirror', contenteditable: 'true' }, p.form);
    delete p.box.value;
    p.box.innerText = text;
    p.box.textContent = text === 'PRIVATE_DRAFT' ? text : '';
    const para = new p.Element('p', {}, p.box);
    new p.Element('br', {}, para);
    const reset = nativeReset(p, { works: false });
    const before = p.insertions.length;
    p.send({ id: 'NEW' });
    await p.advance(6500); await settle(p);
    const d = await proofDiagnostics(p), f = diagnosticFields(d['新聊天重設阻擋']);
    const placeholder = text === '' || text === '\n';
    assert.equal(d['新聊天重設'], placeholder ? 'unconfirmed' : 'blocked');
    assert.equal(f.composer_kind, 'contenteditable');
    assert.equal(f.composer_text_shape, text === '' ? 'empty' : text === 'PRIVATE_DRAFT' ? 'nonempty' : 'whitespace');
    assert.equal(f.composer_textcontent_empty, String(text !== 'PRIVATE_DRAFT'));
    assert.equal(f.has_draft, String(!placeholder));
    assert.equal(f.composer_structure, placeholder ? 'p_br' : 'other');
    assert.equal(reset.clicks, placeholder ? 1 : 0, 'only exact empty P/BR, not arbitrary trimmed whitespace');
    assert.equal(p.box.innerText, text);
    assert.equal(p.insertions.length, before);
    assert.equal(sendRequests(p).length, 1);
    assert.doesNotMatch(d['新聊天重設阻擋'], /PRIVATE|11111111|\/c\//);
  }
});

test('new chat reset diagnostics: whitespace restored at selectComposer after a confirmed reset is still preserved', async () => {
  const p = await provenChat();
  p.box.isConnected = false;
  p.box = new p.Element('div', { id: 'prompt-textarea', class: 'ProseMirror', contenteditable: 'true' }, p.form);
  delete p.box.value;
  p.box.innerText = p.box.textContent = '';
  p.box.onFocus = () => {
    p.box.innerText = '\n';
    p.box.childrenOverride = [draftNode('\n')];
    delete p.box.textOverride;
  };
  nativeReset(p);
  const before = p.insertions.length;
  p.send({ id: 'NEW' });
  await p.advance(6500); await settle(p);
  const d = await proofDiagnostics(p);
  assert.equal(d['新聊天重設'], 'confirmed');
  assert.equal(d['新聊天重設阻擋'], undefined, 'this is not evidence of a reset-time block');
  assert.equal(p.box.innerText, '\n');
  assert.equal(p.insertions.length, before);
  assert.equal(sendRequests(p).length, 1);
  assert.ok(p.reports.some((r) => r.id === 'NEW' && r.kind === 'failed'));
});

test('new chat: retained root temporary context cannot receive a normal new command', async () => {
  for (const flags of [nativeFlags, { is_do_not_remember: false }]) {
    const p = await provenChat({ route: null });
    p.button.onClick = () => p.submit(flags, CID);
    p.send({ id: 'NEW', conversationID: null, temporary: false, temporaryPersonalized: false });
    await p.advance(6500); await settle(p);
    assert.equal(sendRequests(p).length, 1, 'no native reset: never dispatch old CID/history');
    assert.ok(p.reports.some((r) => r.id === 'NEW' && r.kind === 'failed'));
  }
});

test('new chat: root and routed prior proof require real native reset before normal or personalized new', async () => {
  for (const route of [null, CID]) for (const personalized of [false, true]) {
    const p = await provenChat({ route });
    const reset = nativeReset(p);
    p.button.onClick = () => p.submit(p.nativeWasReset
      ? personalized ? nativeFlags : { is_do_not_remember: false } : nativeFlags, p.nativeWasReset ? null : CID);
    p.send({ id: 'NEW', temporary: personalized, temporaryPersonalized: personalized });
    await p.advance(2000); await settle(p);
    assert.equal(reset.clicks, 1, 'root URL alone is not a new conversation');
    assert.equal(sendRequests(p).length, 2);
    const body = JSON.parse(sendRequests(p)[1].init.body);
    assert.equal(body.conversation_id, undefined);
    assert.equal(body.history_and_training_disabled, personalized ? true : undefined);
    assert.equal(p.reports.some((r) => r.id === 'NEW' && r.kind === 'temporary'), personalized);
    const diag = await proofDiagnostics(p);
    assert.equal(diag['新聊天重設'], 'confirmed');
    assert.equal(diag['新聊天請求'], 'send:validated');
  }
});

test('new chat: missing/ambiguous/ineffective native reset, existing draft or Stop preserve page and refuse send', async () => {
  for (const bad of ['missing', 'ambiguous', 'no-op', 'draft', 'stop', 'dialog']) {
    const p = await provenChat({ route: null });
    const reset = bad === 'missing' ? null : nativeReset(p, { works: bad !== 'no-op' });
    if (bad === 'ambiguous') nativeReset(p);
    if (bad === 'draft') p.box.value = 'PRIVATE EXISTING DRAFT';
    if (bad === 'stop') new p.Element('button', { 'data-testid': 'stop-button' });
    if (bad === 'dialog') new p.Element('div', { role: 'dialog' });
    p.send({ id: 'NEW' });
    await p.advance(6500); await settle(p);
    assert.equal(sendRequests(p).length, 1, bad);
    assert.equal(p.button.clicks, 1, bad);
    assert.equal(reset?.clicks ?? 0, bad === 'no-op' ? 1 : 0, bad);
    if (bad === 'draft') assert.equal(p.box.value, 'PRIVATE EXISTING DRAFT');
  }
});

test('new chat: native reset cancellation cannot insert or send after the native UI settles', async () => {
  const p = await provenChat({ route: null });
  const reset = nativeReset(p, { delay: 1000 });
  const before = p.insertions.length;
  p.send({ id: 'NEW' });
  await p.advance(100);
  p.command({ cmd: 'stop', id: 'CANCEL', requestID: 'NEW' });
  await p.advance(6500); await settle(p);
  assert.equal(reset.clicks, 1);
  assert.equal(p.insertions.length, before);
  assert.equal(sendRequests(p).length, 1);
});

test('new chat: even after confirmed reset original prepare/send must have no old CID or normal temporary flags', async () => {
  for (const prepare of [false, true]) for (const bad of ['id', 'history', 'remember', 'is_temporary', 'temporary_chat', 'array']) {
    const p = await provenChat({ route: null });
    nativeReset(p);
    const body = bad === 'array' ? [] : {
      ...(bad === 'id' ? { conversation_id: CID } : {}),
      ...(bad === 'history' ? { history_and_training_disabled: true } : {}),
      ...(bad === 'remember' ? { is_do_not_remember: true } : {}),
      ...(bad === 'is_temporary' ? { is_temporary: true } : {}),
      ...(bad === 'temporary_chat' ? { temporary_chat: true } : {}),
    };
    p.button.onClick = () => p.sandbox.fetch('https://chatgpt.com/backend-api/f/conversation' + (prepare ? '/prepare' : ''),
      { method: 'POST', body: JSON.stringify(body) }).catch(() => {});
    const before = p.requests.filter((r) => r.init?.method === 'POST').length;
    p.send({ id: 'NEW', model: 'synthetic-selected-model' });
    await p.advance(2000); await settle(p);
    assert.equal(p.requests.filter((r) => r.init?.method === 'POST').length, before, `${prepare}/${bad}`);
    assert.ok(p.reports.some((r) => r.id === 'NEW' && r.kind === 'failed'), `${prepare}/${bad}`);
  }
});

test('new chat: reset navigation away/back cannot become ready again, including after reset confirmation', async () => {
  for (const route of [null, CID]) for (const late of [false, true]) {
    const p = await provenChat({ route });
    const reset = nativeReset(p, { delay: late ? 0 : 1000 });
    const before = p.insertions.length;
    p.send({ id: 'NEW' });
    await p.advance(late ? 200 : 100);
    p.sandbox.history.pushState({}, '', '/unrelated');
    p.sandbox.history.pushState({}, '', late || !route ? '/' : '/c/' + route);
    await p.advance(6500); await settle(p);
    assert.equal(reset.clicks, 1);
    assert.equal(p.insertions.length, before);
    assert.equal(sendRequests(p).length, 1);
    assert.ok(p.reports.some((r) => r.id === 'NEW' && r.kind === 'failed'));
  }
});

test('new chat: a draft restored after reset is preserved rather than replaced by the new send', async () => {
  for (const when of ['settling', 'focus']) {
  const p = await provenChat({ route: null });
  nativeReset(p);
  if (when === 'focus') p.box.onFocus = () => { p.box.value = 'PRIVATE RESTORED DRAFT'; };
  p.send({ id: 'NEW' });
  await p.advance(200); // native reset confirmed; openConversation is settling
  if (when === 'settling') p.box.value = 'PRIVATE RESTORED DRAFT';
  const before = p.insertions.length;
  await p.advance(2500); await settle(p);
  assert.equal(p.box.value, 'PRIVATE RESTORED DRAFT');
  assert.equal(p.insertions.length, before);
  assert.equal(sendRequests(p).length, 1);
  }
});

test('new chat: original prepare at insertion is guarded before pendingSend exists', async () => {
  for (const body of [{ conversation_id: CID }, { history_and_training_disabled: true }]) {
    const p = await provenChat({ route: null });
    nativeReset(p);
    const before = p.requests.filter((r) => r.init?.method === 'POST').length;
    p.doc.onInsert = (_cmd, text) => {
      p.box.value = text;
      p.sandbox.fetch('https://chatgpt.com/backend-api/f/conversation/prepare',
        { method: 'POST', body: JSON.stringify(body) }).catch(() => {});
      return true;
    };
    p.send({ id: 'NEW', model: 'synthetic-model' });
    await p.advance(2500); await settle(p);
    assert.equal(p.requests.filter((r) => r.init?.method === 'POST').length, before);
    assert.equal(p.button.clicks, 1);
    assert.equal(p.reports.filter((r) => r.id === 'NEW' && r.kind === 'failed').length, 1);
  }
});

test('new chat: Blob/Request decode cannot outlive cancel, navigation return or native mode reversal', async () => {
  for (const kind of ['Blob', 'Request']) for (const prepare of [false, true])
    for (const change of ['cancel', 'navigate', 'mode']) {
      const p = await provenChat({ route: null });
      nativeReset(p);
      let resolveBody, decoding = false;
      const body = new Promise((resolve) => { resolveBody = resolve; });
      const url = 'https://chatgpt.com/backend-api/f/conversation' + (prepare ? '/prepare' : '');
      if (kind === 'Blob') {
        p.sandbox.Blob = class { text() { decoding = true; return body; } };
        p.button.onClick = () => p.sandbox.fetch(url, { method: 'POST', body: new p.sandbox.Blob() }).catch(() => {});
      } else {
        p.sandbox.Request = class extends Request { clone() { return { text: () => { decoding = true; return body; } }; } };
        p.button.onClick = () => p.sandbox.fetch(new p.sandbox.Request(url, { method: 'POST', body: '{}' })).catch(() => {});
      }
      const before = p.requests.filter((r) => r.init?.method === 'POST').length;
      p.send({ id: 'NEW' });
      await p.advance(1200);
      assert.equal(decoding, true, `${kind}/${prepare}/${change}`);
      if (change === 'cancel') p.command({ cmd: 'stop', id: 'CANCEL', requestID: 'NEW' });
      if (change === 'navigate') {
        p.sandbox.history.pushState({}, '', '/unrelated');
        p.sandbox.history.pushState({}, '', '/');
      }
      if (change === 'mode') {
        const ui = nativeTemporary(p);
        p.mutate();
        ui.toggle.isConnected = ui.picker.isConnected = false;
      }
      resolveBody('{}');
      await p.advance(2500); await settle(p);
      assert.equal(p.requests.filter((r) => r.init?.method === 'POST').length, before, `${kind}/${prepare}/${change}`);
    }
});

test('new chat: accepted first send may route before a later unrelated internal prepare', async () => {
  const p = fixture({ allowNetwork: true, respond(url) {
    if (url.endsWith('/prepare')) return Response.json({});
    return new Response('data: ' + JSON.stringify({ conversation_id: CID,
      message: { id: 'synthetic-answer', author: { role: 'assistant' },
        content: { content_type: 'text', parts: ['synthetic reply'] } } }) + '\n\ndata: [DONE]\n\n',
      { headers: { 'content-type': 'text/event-stream' } });
  } });
  let acceptedBeforeInternalPrepare = false;
  p.button.onClick = () => {
    p.sandbox.fetch('https://chatgpt.com/backend-api/f/conversation', { method: 'POST', body: '{}' }).then(() => {
      acceptedBeforeInternalPrepare = p.reports.some((r) => r.id === 'S' && r.kind === 'accepted');
      p.sandbox.history.pushState({}, '', '/c/' + CID);
      return p.sandbox.fetch('https://chatgpt.com/backend-api/f/conversation/prepare',
        { method: 'POST', body: JSON.stringify({ conversation_id: CID }) });
    }).catch(() => {});
  };
  p.send();
  await p.advance(2000); await settle(p);
  assert.equal(acceptedBeforeInternalPrepare, true);
  assert.equal(p.requests.length, 2);
  assert.ok(p.reports.some((r) => r.id === 'S' && r.kind === 'finished'));
  assert.ok(!p.failure());
});

test('new chat: root normal after normal with DOM gone still rejects original old ID, without claiming reset', async () => {
  const p = fixture({ allowNetwork: true, respond: () => new Response(
    'data: ' + JSON.stringify({ conversation_id: CID, message: { id: 'a', author: { role: 'assistant' },
      content: { content_type: 'text', parts: ['synthetic reply'] } } }) + '\n\ndata: [DONE]\n\n',
    { headers: { 'content-type': 'text/event-stream' } }) });
  p.button.onClick = () => p.sandbox.fetch('https://chatgpt.com/backend-api/f/conversation',
    { method: 'POST', body: '{}' }).catch(() => {});
  p.send();
  await p.advance(2000); await settle(p);
  assert.ok(p.reports.some((r) => r.id === 'S' && r.kind === 'finished'));
  p.box.value = '';
  p.button.onClick = () => p.sandbox.fetch('https://chatgpt.com/backend-api/f/conversation',
    { method: 'POST', body: JSON.stringify({ conversation_id: CID, is_do_not_remember: false }) }).catch(() => {});
  p.send({ id: 'NEW' });
  await p.advance(2000); await settle(p);
  assert.equal(sendRequests(p).length, 1);
  assert.equal(p.navigations.length, 0);
  const diag = await proofDiagnostics(p);
  assert.equal(diag['新聊天重設'], undefined);
  assert.equal(diag['新聊天請求'], 'send:blocked');
  assert.ok(p.reports.some((r) => r.id === 'NEW' && r.kind === 'failed'));
});

test('new chat: valid one-shot stream bodies are inspected once and remain dispatchable', async () => {
  for (const temporary of [false, true]) {
    const p = fixture({ allowNetwork: true });
    let read = 0;
    p.button.onClick = () => p.sandbox.fetch('https://chatgpt.com/backend-api/f/conversation', {
      method: 'POST', body: new ReadableStream({ pull(controller) {
        read++;
        controller.enqueue(new TextEncoder().encode('{"model":"auto"}'));
        controller.close();
      } }),
    }).catch(() => {});
    p.send({ temporary });
    await p.advance(1000); await settle(p);
    assert.equal(read, 1);
    assert.equal(sendRequests(p).length, 1);
    assert.equal(JSON.parse(sendRequests(p)[0].init.body).history_and_training_disabled, temporary ? true : undefined);
    assert.ok(!p.failure());
  }
});

test('personalized temporary: missing native evidence or URL-only evidence blocks before insertion', async () => {
  for (const search of ['', '?temporary-chat=true']) {
    const p = fixture();
    p.sandbox.location.search = search;
    p.send({ temporary: true, temporaryPersonalized: true });
    await p.advance(1000);
    notSubmitted(p);
    assert.equal(p.insertions.length, 0);
  }
});

test('personalized temporary: prior native personalization never implies this conversation consent', async () => {
  for (const consent of [undefined, false, 'true']) {
    const p = fixture();
    nativeTemporary(p);
    p.send({ temporary: true, temporaryPersonalized: consent });
    await p.advance(1000);
    notSubmitted(p);
    assert.equal(p.insertions.length, 0);
  }
});

test('personalized temporary: explicit consent without temporary flag still blocks', async () => {
  const p = fixture();
  nativeTemporary(p);
  p.send({ temporaryPersonalized: true });
  await p.advance(1000);
  notSubmitted(p);
});

test('personalized temporary: empty new page and visible native mode allow one bounded send', async () => {
  const p = fixture();
  nativeTemporary(p);
  p.send({ temporary: true, temporaryPersonalized: true });
  await p.advance(1000);
  assert.equal(p.button.clicks, 1);
  assert.equal(p.insertions.length, 1);
  assert.equal(p.failure(), undefined);
});

test('personalized temporary: message content, forms, hidden controls and ambiguous buttons are not mode evidence', async () => {
  for (const kind of ['message', 'form', 'hidden', 'duplicate']) {
    const p = fixture();
    const parent = kind === 'message' ? new p.Element('div', { 'data-message-author-role': 'assistant' })
      : kind === 'form' ? p.form : null;
    const ui = nativeTemporary(p, 'personalized', parent);
    if (kind === 'hidden') ui.toggle.hidden = true;
    if (kind === 'duplicate') nativeTemporary(p);
    p.send({ temporary: true, temporaryPersonalized: true });
    await p.advance(1000);
    notSubmitted(p);
    assert.equal(p.insertions.length, 0, kind);
  }
});

test('personalized temporary: native draft or existing message is preserved rather than switching its mode', async () => {
  for (const kind of ['draft', 'message']) {
    const p = fixture();
    const ui = nativeTemporary(p, 'off');
    if (kind === 'draft') p.box.value = 'existing synthetic draft';
    else new p.Element('div', { 'data-message-author-role': 'user' });
    p.send({ temporary: true, temporaryPersonalized: true });
    await p.advance(1000);
    notSubmitted(p);
    assert.equal(ui.toggle.clicks, 0);
    assert.equal(p.insertions.length, 0);
    if (kind === 'draft') assert.equal(p.box.value, 'existing synthetic draft');
  }
});

test('personalized temporary: native toggle must settle before any insertion or submit', async () => {
  const p = fixture();
  const ui = nativeTemporary(p, 'off');
  ui.toggle.onClick = () => p.later(900, () => {
    ui.toggle.attrs['aria-label'] = 'Turn off temporary chat';
    ui.picker.isConnected = true;
  });
  p.send({ temporary: true, temporaryPersonalized: true });
  await p.advance(500);
  assert.equal(ui.toggle.clicks, 1);
  assert.equal(p.insertions.length, 0);
  assert.equal(p.button.clicks, 0);
  await p.advance(1600);
  assert.equal(p.button.clicks, 1);
});

// Only native controls replace the composer; neither the Pod nor the test clears an old draft.
function prepareRerender(p, phase, shape = 'textarea', change = () => {}) {
  const original = p.box, ui = nativeTemporary(p, phase === 'toggle' ? 'off' : 'unpersonalized');
  const menu = new p.Element('div', { role: 'menuitemradio', 'aria-label': 'Personalized' });
  menu.isConnected = false;
  const replace = () => {
    if (shape === 'textarea') {
      p.box.isConnected = false;
      p.box = new p.Element('textarea', { id: 'prompt-textarea' }, p.form);
    } else resetEditable(p, shape);
    change(p.box);
  };
  ui.toggle.onClick = () => {
    replace();
    ui.toggle.attrs['aria-label'] = 'Turn off temporary chat';
    ui.picker.isConnected = true;
  };
  ui.picker.onClick = () => {
    if (phase === 'picker') replace();
    menu.isConnected = true;
  };
  menu.onClick = () => {
    if (phase === 'selection') replace();
    menu.isConnected = false;
    ui.picker.attrs['aria-label'] = 'Personalized';
  };
  return { original, ui, menu };
}

for (const phase of ['toggle', 'picker', 'selection']) for (const shape of ['textarea', 'empty', 'p_br']) {
  test(`prepare rerender: ${phase} accepts exact empty ${shape} without touching detached box`, async () => {
    const p = fixture(), { original } = prepareRerender(p, phase, shape);
    p.send({ temporary: true, temporaryPersonalized: true });
    await p.advance(6000);
    assert.equal(p.button.clicks, 1);
    assert.equal(p.failure(), undefined);
    assert.equal(original.value, '');
    assert.equal(original.textContent, '');
    assert.equal(p.insertions.length, 1);
    assert.equal(p.insertions[0].target, p.box);
    assert.equal((await proofDiagnostics(p))['個人化準備阻擋'], undefined);
  });
}

for (const phase of ['toggle', 'picker', 'selection']) {
  test(`prepare rerender: ${phase} rejects unsafe replacement without altering either box`, async () => {
    for (const kind of ['draft', 'space', 'newline', 'nbsp', 'zero-width', 'value-getter',
      'text-getter', 'children-getter', 'attachment', 'double-br', 'dialog', 'transparent-dialog',
      'open-hidden-dialog', 'dialog-getter', 'cancel', 'origin', 'route', 'route-return', 'stop', 'message']) {
      const p = fixture();
      const editable = ['text-getter', 'children-getter', 'attachment', 'double-br'].includes(kind);
      const { original } = prepareRerender(p, phase, editable ? 'p_br' : 'textarea', (box) => {
        const drafts = { draft: 'PRIVATE_NEW_DRAFT', space: ' ', newline: '\n', nbsp: '\u00a0', 'zero-width': '\u200b' };
        if (kind in drafts) box.value = drafts[kind];
        if (kind === 'value-getter') Object.defineProperty(box, 'value', { get() { throw new Error('PRIVATE_GETTER'); } });
        if (kind === 'text-getter') Object.defineProperty(box, 'textContent', { get() { throw new Error('PRIVATE_GETTER'); } });
        if (kind === 'children-getter') Object.defineProperty(box, 'childNodes', { get() { throw new Error('PRIVATE_GETTER'); } });
        if (kind === 'attachment') new p.Element('img', {}, box);
        if (kind === 'double-br') new p.Element('br', {}, box.childNodes[0]);
        if (kind.includes('dialog')) {
          const d = new p.Element(kind === 'open-hidden-dialog' ? 'dialog' : 'div', { role: 'dialog' });
          if (kind === 'transparent-dialog') d.style.opacity = '0';
          if (kind === 'open-hidden-dialog') { d.open = true; d.style.display = 'none'; }
          if (kind === 'dialog-getter') Object.defineProperty(d.style, 'display', { get() { throw new Error('PRIVATE_STYLE'); } });
        }
        if (kind === 'cancel') p.command({ cmd: 'stop', id: 'cancel', requestID: 'S' });
        if (kind === 'origin') p.sandbox.location.origin = 'https://example.invalid';
        if (kind === 'route' || kind === 'route-return') {
          p.sandbox.history.pushState({}, '', '/c/' + OTHER_CID);
          if (kind === 'route-return') p.sandbox.history.pushState({}, '', '/');
        }
        if (kind === 'stop') new p.Element('button', { 'data-testid': 'stop-button' });
        if (kind === 'message') new p.Element('div', { 'data-message-author-role': 'assistant' });
      });
      p.send({ temporary: true, temporaryPersonalized: true });
      await p.advance(6000);
      assert.equal(p.button.clicks, 0, kind);
      assert.equal(p.insertions.length, 0, kind);
      assert.equal(original.value, '', kind);
      if (kind === 'draft') assert.equal(p.box.value, 'PRIVATE_NEW_DRAFT');
      const diag = await proofDiagnostics(p), fields = diagnosticFields(diag['個人化準備阻擋']);
      assert.equal(fields.composer_same, 'false', kind);
      assert.equal(fields.watch_invalid, 'true', kind);
      assert.equal(fields.stage, phase === 'toggle' ? 'toggle_wait' : phase === 'picker' ? 'picker_wait' : 'selection_wait', kind);
      if (kind.endsWith('getter') && kind !== 'dialog-getter') assert.equal(fields.read_failed, 'true');
      if (kind.includes('dialog')) assert.equal(fields.dialog_blocking_or_unknown, 'true');
      if (kind.startsWith('route')) assert.equal(fields.route_changed, 'true');
      if (kind === 'origin') assert.equal(fields.origin_changed, 'true');
      for (const key of ['個人化準備阻擋', '個人化目前頁面'])
        assert.doesNotMatch(diag[key], /PRIVATE_|example\.invalid|11111111|22222222|\/c\//);
    }
  });
}

test('prepare rerender: hidden role-dialog skeleton is allowed; detached old box is never cleared', async () => {
  const p = fixture();
  const { original } = prepareRerender(p, 'toggle', 'p_br', () => {
    original.value = 'PRIVATE_DETACHED_DRAFT';
    const parent = new p.Element('div'); parent.style.display = 'none';
    new p.Element('div', { role: 'dialog' }, parent);
  });
  p.send({ temporary: true, temporaryPersonalized: true });
  await p.advance(6000);
  assert.equal(p.button.clicks, 1);
  assert.equal(original.value, 'PRIVATE_DETACHED_DRAFT');
  assert.equal(p.insertions[0].target, p.box);
});

test('prepare diagnostics: current safe snapshot does not erase block, later successful prepare clears it', async () => {
  const p = fixture(), ui = nativeTemporary(p, 'off');
  const d = new p.Element('div', { role: 'dialog' });
  p.send({ temporary: true, temporaryPersonalized: true });
  await p.advance(1000);
  const blocked = (await proofDiagnostics(p))['個人化準備阻擋'];
  assert.equal(diagnosticFields(blocked).stage, 'entry');
  d.isConnected = false;
  const current = await proofDiagnostics(p);
  assert.equal(current['個人化準備阻擋'], blocked);
  assert.equal(diagnosticFields(current['個人化目前頁面']).dialog_state, 'none');
  ui.toggle.onClick = () => {
    ui.toggle.attrs['aria-label'] = 'Turn off temporary chat';
    ui.picker.isConnected = true;
  };
  p.send({ id: 'next', temporary: true, temporaryPersonalized: true });
  await p.advance(1000);
  assert.equal(p.button.clicks, 1);
  assert.equal((await proofDiagnostics(p))['個人化準備阻擋'], undefined);
});

test('prepare diagnostics: renderer only emits allowlisted enums and strict booleans', () => {
  const render = vm.runInNewContext(
    script.slice(script.indexOf('const nativeResetBlockDiagnostic = '), script.indexOf('async function resetNativeChat'))
    + script.slice(script.indexOf('const personalizedPrepareDiagnostic = '), script.indexOf('async function prepareNativePersonalizedTemporary'))
    + '\npersonalizedPrepareDiagnostic;');
  const fields = diagnosticFields(render('PRIVATE_STAGE', { current: { textContent: 'PRIVATE_BODY' },
    composer_same: 'PRIVATE_TOKEN', route_changed: CID, composer_structure: OTHER_CID,
    dialog_state: 'PRIVATE_DIALOG', read_failed: 1 }));
  assert.equal(fields.stage, 'unknown');
  assert.equal(fields.composer_same, 'false');
  assert.equal(fields.read_failed, 'false');
  assert.doesNotMatch(JSON.stringify(fields), /PRIVATE_|11111111|22222222/);
});

test('personalized temporary: deliberate native menu choice is read back, not inferred from a click', async () => {
  for (const works of [true, false]) {
    const p = fixture();
    const ui = nativeTemporary(p, 'unpersonalized');
    const menu = new p.Element('div', { role: 'menuitemradio', 'aria-label': 'Personalized' });
    menu.isConnected = false;
    ui.picker.onClick = () => { menu.isConnected = true; };
    menu.onClick = () => {
      menu.isConnected = false;
      if (works) ui.picker.attrs['aria-label'] = 'Personalized';
    };
    p.send({ temporary: true, temporaryPersonalized: true });
    await p.advance(5000);
    assert.equal(menu.clicks, 1);
    assert.equal(p.button.clicks, works ? 1 : 0);
    assert.equal(p.insertions.length, works ? 1 : 0);
    if (!works) assert.equal(p.failure()?.submitted, false);
  }
});

test('personalized temporary: mode changing after insertion is checked again before submit', async () => {
  const p = fixture();
  const ui = nativeTemporary(p);
  p.doc.onInsert = (_cmd, text) => {
    p.box.value = text;
    ui.picker.attrs['aria-label'] = 'Unpersonalized';
    return true;
  };
  p.send({ temporary: true, temporaryPersonalized: true });
  await p.advance(1000);
  assert.equal(p.button.clicks, 0);
  assert.equal(p.failure()?.submitted, false);
});

test('personalized temporary: native mode cannot replace the original body privacy guard', async () => {
  for (const bad of [false, true]) {
    const p = fixture({ allowNetwork: true });
    nativeTemporary(p);
    p.button.onClick = () => p.sandbox.fetch('https://chatgpt.com/backend-api/f/conversation', {
      method: 'POST', body: bad ? 'bad JSON' : JSON.stringify({ model: 'auto', ...nativeFlags }),
    }).catch(() => {});
    p.send({ temporary: true, temporaryPersonalized: true });
    await p.advance(1000);
    assert.equal(p.requests.length, bad ? 0 : 1);
    if (!bad) {
      const sent = JSON.parse(p.requests[0].init.body);
      assert.equal(sent.history_and_training_disabled, true, 'original native flag and legacy final guard both retained');
      assert.equal(sent.is_do_not_remember, false, 'never guess or overwrite native private-field semantics');
      assert.ok(p.reports.some((r) => r.kind === 'temporary'));
    } else {
      assert.ok(p.failure());
      assert.ok(!p.reports.some((r) => r.kind === 'temporary'));
    }
  }
});

test('legacy unpersonalized temporary still adds history guard without guessing the native do-not-remember flag', async () => {
  const p = fixture({ allowNetwork: true });
  p.button.onClick = () => p.sandbox.fetch('https://chatgpt.com/backend-api/f/conversation', {
    method: 'POST', body: JSON.stringify({ model: 'auto', is_do_not_remember: true }),
  }).catch(() => {});
  p.send({ temporary: true });
  await p.advance(1000);
  assert.equal(sendRequests(p).length, 1);
  assert.equal(JSON.parse(sendRequests(p)[0].init.body).history_and_training_disabled, true);
  assert.equal(JSON.parse(sendRequests(p)[0].init.body).is_do_not_remember, true);
  assert.ok(p.reports.some((r) => r.kind === 'temporary'));
});

test('privacy diagnostics: only allowlisted booleans/types, never prompt, body, tokens or unknown values', async () => {
  const p = fixture({ allowNetwork: true });
  await p.sandbox.fetch('https://chatgpt.com/backend-api/f/conversation/prepare', {
    method: 'POST', body: JSON.stringify({
      history_and_training_disabled: false, is_do_not_remember: true,
      is_temporary: 'PRIVATE_SENTINEL', messages: [{ content: 'PRIVATE_SENTINEL' }],
    }),
  });
  p.command({ cmd: 'diagnostics', id: 'D' });
  await p.advance(1);
  const report = p.reports.find((r) => r.id === 'D');
  assert.ok(report?.ok);
  const text = JSON.stringify(report);
  assert.match(text, /history_and_training_disabled=false/);
  assert.match(text, /is_do_not_remember=true/);
  assert.match(text, /is_temporary=other/);
  assert.doesNotMatch(text, /PRIVATE_SENTINEL|"messages"\s*:|"content"\s*:/);
});

test('personalized temporary: cancellation during native mode wait never inserts or submits later', async () => {
  const p = fixture();
  const ui = nativeTemporary(p, 'off');
  ui.toggle.onClick = () => p.later(1500, () => {
    ui.toggle.attrs['aria-label'] = 'Turn off temporary chat';
    ui.picker.isConnected = true;
  });
  p.send({ temporary: true, temporaryPersonalized: true });
  await p.advance(500);
  p.command({ cmd: 'stop', id: 'cancel', requestID: 'S' });
  await p.advance(7000);
  assert.equal(p.button.clicks, 0);
  assert.equal(p.insertions.length, 0);
  assert.ok(p.reports.some((r) => r.id === 'cancel' && r.ok));
});

test('personalized temporary: asynchronous body decoding cannot bypass the last native mode recheck', async () => {
  const p = fixture({ allowNetwork: true });
  const ui = nativeTemporary(p);
  p.sandbox.Blob = class {
    async text() {
      ui.picker.attrs['aria-label'] = 'Unpersonalized';
      return JSON.stringify({ model: 'auto' });
    }
  };
  p.button.onClick = () => p.sandbox.fetch('https://chatgpt.com/backend-api/f/conversation', {
    method: 'POST', body: new p.sandbox.Blob(),
  }).catch(() => {});
  p.send({ temporary: true, temporaryPersonalized: true });
  await p.advance(1000);
  assert.equal(p.requests.length, 0);
  assert.ok(p.failure());
  assert.ok(!p.reports.some((r) => r.kind === 'temporary'));
});

test('personalization is an explicit per-chat opt-in in both clients, not a global default or tool inference', () => {
  const read = (name) => readFileSync(new URL('../App/Sources/Tatwo2/' + name, import.meta.url), 'utf8');
  const space = read('TAP/ChatGPTSpace.swift'), session = read('TAP/ChatGPTConversationSession.swift');
  const nav = read('DM/GlobalDMChatGPTNavigation.swift'), pages = read('TAP/ChatGPTPages.swift');
  for (const client of [space, session]) {
    assert.match(client, /@Published var temporaryPersonalized = false/);
    assert.match(client, /temporary = false\s*temporaryPersonalized = false|temporaryChat = false\s*temporaryPersonalized = false/);
    assert.doesNotMatch(client, /UserDefaults[^\n]*temporaryPersonalized|set\([^\n]*temporaryPersonalized/);
  }
  // W184 already gives the DM choice a bounded width. Pin each consent callback
  // to its actual call and guard; neither client may personalize a busy/existing chat.
  for (const [client, consent] of [
    [space, /ChatGPTTemporaryPersonalizationChoice \{\s*guard !model\.isSending, model\.messages\.isEmpty else \{ return \}\s*model\.temporaryChat = true\s*model\.temporaryPersonalized = true/],
    [nav, /ChatGPTTemporaryPersonalizationChoice\(width: min\(290, width\)\) \{\s*guard store\.chatGPTSwitchBlocker == nil, session\.conversationID == nil,\s*session\.isTemporary, session\.messages\.isEmpty else \{ return \}\s*session\.temporary = true\s*session\.temporaryPersonalized = true/],
  ]) {
    assert.match(client, consent);
    assert.match(client, /temporaryPersonalized = true/);
    assert.match(client, /messages\.isEmpty/);
  }
  assert.match(pages, /Button\("允許個人化，僅此聊天", action: allow\)/);
  assert.match(pages, /Button\("保持不個人化", action: dismiss\)/);
  assert.match(source, /if temporary && temporaryPersonalized \{ payload\["temporaryPersonalized"\] = true \}/);
  assert.match(space, /temporaryPersonalized = saved\.temporaryPersonalized/);
  assert.match(space, /temporaryPersonalized: startedPersonalized/);
});

test('busy then ready: waits for hydration without removing disabled and clicks exactly once', async () => {
  const p = fixture();
  p.form.attrs['aria-busy'] = 'true';
  p.button.disabled = true;
  p.send();
  await p.advance(1000);
  assert.equal(p.button.clicks, 0);
  assert.equal(p.insertions.length, 0);
  delete p.form.attrs['aria-busy']; // page hydration, NOT Pod
  p.button.disabled = false;
  await p.advance(600);
  assert.equal(p.box.value, 'synthetic question');
  assert.equal(p.button.clicks, 1);
  await p.advance(22000);
  assert.equal(p.button.clicks, 1);
  assert.equal(p.failure().submitted, undefined, 'unknown after click never authorizes replay');
  assert.match(p.failure().message, /結果不明/);
});

test('failed insertion leaving blank is explicit not-submitted even when execCommand returns true', async () => {
  for (const returnValue of [false, true]) {
    const p = fixture();
    p.doc.onInsert = () => returnValue;
    p.send();
    await p.advance(800);
    notSubmitted(p);
    assert.match(p.failure().message, /打不進/);
    assert.equal(p.insertions.length, 2);
  }
});

test('old disabled/hidden/aria-disabled candidates never mask the valid current send button', async () => {
  for (const blocked of ['disabled', 'hidden', 'aria-disabled', 'detached', 'other-form-owner']) {
    for (const sameSelector of [false, true]) {
    const p = fixture();
    const valid = new p.Element('button', sameSelector ? { 'data-testid': 'send-button' } : { id: 'composer-submit-button' }, p.form);
    if (blocked === 'disabled') p.button.disabled = true;
    if (blocked === 'hidden') p.button.hidden = true;
    if (blocked === 'aria-disabled') p.button.attrs['aria-disabled'] = 'true';
    if (blocked === 'detached') p.button.isConnected = false;
    if (blocked === 'other-form-owner') p.button.owner = new p.Element('form');
    p.send();
    await p.advance(800);
    assert.equal(p.button.clicks, 0, blocked);
    assert.equal(valid.clicks, 1, blocked);
    }
  }
});

test('other forms are never clicked, including a global dedicated ID before the current form', async () => {
  const p = fixture();
  const otherForm = new p.Element('form');
  p.button.parentElement = otherForm;
  const current = new p.Element('button', { type: 'submit' }, p.form);
  p.send();
  await p.advance(800);
  assert.equal(current.clicks, 1);
  assert.equal(p.button.clicks, 0);
  const q = fixture();
  q.button.parentElement = new q.Element('form');
  q.send();
  await q.advance(6000);
  notSubmitted(q);
});

test('formless composer refuses other-form buttons and generic unrelated submit', async () => {
  const p = fixture();
  p.box.parentElement = null;
  new p.Element('button', { type: 'submit', 'aria-label': 'Send' });
  p.send();
  await p.advance(6000);
  notSubmitted(p);
});

test('disabled, read-only, noneditable, hidden and detached composers are not selected', async () => {
  for (const blocked of ['disabled', 'readOnly', 'aria-disabled', 'hidden-parent', 'css-hidden', 'inert', 'noneditable', 'detached']) {
    const p = fixture();
    if (blocked === 'disabled' || blocked === 'readOnly') p.box[blocked] = true;
    if (blocked === 'aria-disabled') p.box.attrs['aria-disabled'] = 'true';
    if (blocked === 'hidden-parent') p.form.hidden = true;
    if (blocked === 'css-hidden') p.box.style.visibility = 'hidden';
    if (blocked === 'inert') p.box.inert = true;
    if (blocked === 'noneditable') p.box.tagName = 'DIV';
    if (blocked === 'detached') p.box.isConnected = false;
    // The second composer/form is the only valid candidate.
    const form = new p.Element('form');
    const current = new p.Element('textarea', {}, form);
    // This is the real DOM selector attribute, not a fixture account name.
    current.attrs.name = 'prompt-textarea';
    const button = new p.Element('button', { type: 'submit' }, form);
    p.send();
    await p.advance(800);
    assert.equal(button.clicks, 1, blocked);
    assert.equal(p.box.value, '', blocked);
    assert.equal(current.value, 'synthetic question', blocked);
    assert.equal(p.button.clicks, 0, blocked);
  }
});

test('detached composer after focus is re-resolved before any insertion', async () => {
  const p = fixture();
  let replacement;
  p.box.onFocus = () => {
    p.box.isConnected = false;
    replacement = new p.Element('textarea', { id: 'prompt-textarea' }, p.form);
  };
  p.send();
  await p.advance(800);
  // Fail closed rather than inserting through a stale selected range.
  notSubmitted(p);
  assert.equal(p.insertions.length, 0);
  assert.equal(replacement.value, '');
});

test('composer replacement while waiting can only send if current text still matches', async () => {
  for (const preserve of [false, true]) {
    const p = fixture();
    p.button.disabled = true;
    p.send();
    await p.advance(800);
    p.box.isConnected = false;
    const replacement = new p.Element('textarea', { id: 'prompt-textarea' }, p.form);
    if (preserve) replacement.value = p.box.value;
    p.button.disabled = false;
    await p.advance(400);
    if (preserve) assert.equal(p.button.clicks, 1);
    else notSubmitted(p);
  }
});

test('cancel during busy wait or immediately before click never clicks or emits retryable failure', async () => {
  for (const phase of ['busy', 'final-check', 'last-check']) {
    const p = fixture();
    if (phase === 'busy') p.button.disabled = true;
    else {
      const getRects = p.button.getClientRects.bind(p.button);
      let calls = 0;
      p.button.getClientRects = () => {
        if (++calls === (phase === 'last-check' ? 3 : 2)) p.command({ cmd: 'stop', id: 'cancel', requestID: 'S' });
        return getRects();
      };
    }
    p.send();
    if (phase === 'busy') {
      await p.advance(800);
      p.command({ cmd: 'stop', id: 'cancel', requestID: 'S' });
    }
    await p.advance(6000);
    assert.equal(p.button.clicks, 0, phase);
    assert.ok(p.reports.some((r) => r.id === 'cancel' && r.ok), phase);
    assert.ok(!p.reports.some((r) => r.submitted === false), phase);
  }
});

test('last-moment text or button changes are rechecked rather than submitting a stale candidate', async () => {
  for (const change of ['text', 'button']) {
    for (const at of [2, 3]) {
    const p = fixture();
    const getRects = p.button.getClientRects.bind(p.button);
    let calls = 0;
    p.button.getClientRects = () => {
      if (++calls === at) {
        if (change === 'text') p.box.value = 'different draft';
        else p.button.disabled = true;
      }
      return getRects();
    };
    p.send();
    await p.advance(800);
    notSubmitted(p);
    }
  }
});

test('click throwing is still unknown, never marked not-submitted', async () => {
  const p = fixture();
  p.button.onClick = () => { throw new Error('synthetic click outcome unknown'); };
  p.send();
  await p.advance(800);
  assert.equal(p.button.clicks, 1);
  assert.equal(p.failure().submitted, undefined);
});

test('attachment-only blank text is allowed, text-only whitespace is rejected', async () => {
  const p = fixture();
  p.box.value = 'old draft';
  const upload = new p.Element('input', { type: 'file' }, p.form);
  p.send({ text: '', files: [{ name: 'fixture', mime: 'text/plain', base64: 'eA==' }] });
  await p.advance(800);
  assert.equal(upload.files.length, 1);
  assert.deepEqual(upload.events, ['change']);
  assert.equal(p.box.value, '');
  assert.equal(p.button.clicks, 1);
  const q = fixture();
  q.send({ text: ' \n ' });
  await q.advance(800);
  notSubmitted(q);
});

test('attachment busy hydration can take longer than five seconds, still one bounded send', async () => {
  const p = fixture();
  const upload = new p.Element('input', { type: 'file' }, p.form);
  upload.dispatchEvent = () => { p.form.attrs['aria-busy'] = 'true'; };
  p.send({ text: '', files: [{ name: 'fixture', base64: 'eA==' }] });
  await p.advance(7000);
  assert.equal(p.button.clicks, 0);
  assert.equal(p.failure(), undefined);
  delete p.form.attrs['aria-busy'];
  await p.advance(500);
  assert.equal(p.button.clicks, 1);
});

test('contenteditable composer uses an in-box range and verifies innerText', async () => {
  const p = fixture();
  p.box.tagName = 'DIV';
  p.box.attrs.contenteditable = 'true';
  delete p.box.value;
  p.box.innerText = '';
  p.box.select = undefined;
  p.doc.onInsert = (cmd, text) => {
    assert.equal(p.doc.selected, p.box);
    p.box.innerText = text;
    return true;
  };
  p.send();
  await p.advance(800);
  assert.equal(p.button.clicks, 1);
  assert.equal(p.box.innerText, 'synthetic question');
});

test('composer detached by the first insert is never reused on the bounded insertion retry', async () => {
  const p = fixture();
  let replacement;
  p.doc.onInsert = (cmd, text) => {
    if (!replacement) {
      p.box.isConnected = false;
      replacement = new p.Element('textarea', { id: 'prompt-textarea' }, p.form);
    } else {
      assert.equal(p.doc.activeElement, replacement);
      replacement.value = text;
    }
    return true;
  };
  p.send();
  await p.advance(800);
  assert.equal(p.insertions.length, 2);
  assert.equal(p.insertions[1].target, replacement);
  assert.equal(p.button.clicks, 1);
});

test('permanently disabled send times out without overriding page limits or attempting replay', async () => {
  const p = fixture();
  p.button.disabled = true;
  p.send();
  await p.advance(6000);
  notSubmitted(p);
  assert.equal(p.button.disabled, true);
  await p.advance(30000);
  assert.equal(p.button.clicks, 0);
});

test('native mapping source: strict JSON false and website evidence, not queue acceptance; terminal cleanup', () => {
  // Source contract only: no Swift build in this bounded task. Native fake-Pod execution belongs to lead.
  const native = source.slice(0, start);
  const drain = native.slice(native.indexOf('private func drainQueue()'), native.indexOf('private func expireUnanswered'));
  assert.match(drain, /yield\(\.accepted\)/);
  assert.doesNotMatch(drain, /websiteSubmittedStreams\.insert/);
  const receive = native.slice(native.indexOf('case "stream":'), native.indexOf('private func failPending'));
  assert.match(receive, /\["accepted", "conversation", "text", "title", "progress", "activity"\]\.contains\(kind\)[\s\S]*?websiteSubmittedStreams\.insert\(id\)/);
  assert.match(receive, /object\["submitted"\] as\? NSNumber,[\s\S]*?CFGetTypeID\(submitted\) == CFBooleanGetTypeID\(\), !submitted\.boolValue,[\s\S]*?!websiteSubmittedStreams\.contains\(id\)[\s\S]*?yield\(\.notSubmitted\(message\)\)[\s\S]*?else \{[\s\S]*?yield\(\.failed\(message, reason: object\["reason"\] as\? String\)\)/);
  const body = name => {
    const at = native.indexOf(name);
    assert.ok(at >= 0, `missing native declaration: ${name}`);
    return native.slice(at, native.indexOf('\n    }', at));
  };
  const finish = body('private func finishStream');
  assert.match(finish, /streams\.removeValue\(forKey: id\)\?\.finish\(\)/);
  assert.match(finish, /websiteSubmittedStreams\.remove\(id\)/);
  assert.match(finish, /activeRequestID = nil[\s\S]*?drainQueue\(\)/);
  const stop = body('func stop(requestID:');
  // W194: queued sends finish immediately; active sends retain evidence and the consumer until the receipt.
  assert.match(stop, /if activeRequestID != requestID \{\s*sendQueue\.removeAll \{ \$0\.id == requestID \}\s*streams\[requestID\]\?\.yield\(\.notSubmitted\([^\n]+\)\)\s*finishStream\(requestID\)\s*return\s*\}/);
  const activeStop = stop.slice(stop.indexOf('streamWatchdog?.cancel()'));
  assert.doesNotMatch(activeStop, /streams\.removeValue|websiteSubmittedStreams\.remove|finishStream\(|activeRequestID = nil|drainQueue\(/);
  assert.match(activeStop, /stoppingRequestID = requestID[\s\S]*?stopAcknowledgementID = acknowledgement/);
  assert.match(activeStop, /Task\.sleep\(for: stopDeadline\)[\s\S]*?self\.stopAcknowledgementID == acknowledgement[\s\S]*?self\.resetAfterUnconfirmedStop\(\)/);
  assert.match(activeStop, /keyedCommandScript\(\["cmd": "stop", "id": acknowledgement, "requestID": requestID\]\)/);
  const result = native.slice(native.indexOf('case "result":'), native.indexOf('case "stream":'));
  assert.match(result, /if id == stopAcknowledgementID[\s\S]*?guard \(object\["ok"\] as\? Bool\) == true, state\?\["preparationPending"\] as\? Bool != true else \{\s*resetAfterUnconfirmedStop\(\)\s*return/);
  assert.match(result, /let submitted = state\?\["submitted"\] as\? NSNumber,\s*CFGetTypeID\(submitted\) == CFBooleanGetTypeID\(\), !submitted\.boolValue,\s*!websiteSubmittedStreams\.contains\(stopped\) \{\s*streams\[stopped\]\?\.yield\(\.notSubmitted\([^\n]+\)\)\s*\}\s*finishStream\(stopped\)/);
  assert.match(receive, /id == activeRequestID, stoppingRequestID == nil/);
  assert.match(body('private func resetAfterUnconfirmedStop'), /transport\.stop\(\)\s*if let stopped = stoppingRequestID \{ streams\.removeValue\(forKey: stopped\)\?\.finish\(\) \}[\s\S]*?failPending\(/);
  const failPending = native.slice(native.indexOf('private func failPending'));
  assert.match(failPending, /websiteSubmittedStreams\.removeAll\(\)/);
});

test('W200 quarantined empty original stream fails after three minutes without reading another conversation', async () => {
  const p = await localPendingChat();
  await p.end();
  assert.ok(!p.reports.some(r => r.id === 'S' && r.kind === 'finished'));
  await p.advance(181000);
  assert.equal(p.reports.find(r => r.id === 'S' && r.kind === 'failed')?.reason, 'no_progress');
  assert.ok(!p.requests.some(r => /\/conversation\//.test(r.url)));
  assert.match((await proofDiagnostics(p))['個人化續聊證據'], /proof=revoked/);
});
