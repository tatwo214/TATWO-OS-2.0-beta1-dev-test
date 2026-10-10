import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture, makePage, h, MCP, queryAll } from './w185-pod-fixture.mjs';

const NAME = 'TATWO（Synthetic Device）';
const original = { id: 'asdk_app_original', name: NAME, url: MCP, authorized: false };

// The same shared browser fixture that exercises the production connector safety chain.
function connectorPage(records, { section = true, installed = [], paged = false, tab = false, deleteConfirmed = true, beforeConfirm } = {}) {
  let pod;
  let createdVisible = !tab;
  const clicks = { connect: [], delete: [], create: 0 };
  function render(body, path) {
    for (const child of [...body._kids]) child.remove();
    const record = records.find((r) => path === '/plugins/' + r.id);
    if (record) {
      const connect = h('button', {}, record.authorized ? 'Disconnect' : 'Connect');
      connect.onclick = () => { clicks.connect.push(record.id); record.authorized = true; };
      const remove = h('button', {}, 'Delete app');
      remove.onclick = () => {
        const confirm = h('button', {}, 'Delete');
        const dialog = h('div', { role: 'alertdialog' }, h('h2', {}, 'Delete app'), h('p', {}, record.name), h('p', {}, record.url), confirm);
        confirm.onclick = () => { clicks.delete.push(record.id); if (deleteConfirmed) records.splice(records.indexOf(record), 1); dialog.remove(); };
        body.appendChild(dialog);
        beforeConfirm?.(pod);
      };
      body.appendChild(h('main', {}, h('h1', {}, record.name), h('div', {}, h('h3', {}, 'About'), h('div', {}, h('p', {}, 'URL'), h('p', {}, record.url)), h('div', {}, h('p', {}, 'App ID'), h('p', {}, record.id))), h('p', {}, record.auth === 'none' ? 'Authentication: None' : 'Authentication: OAuth'),
        ...(record.authorized ? [h('section', {}, h('h3', {}, 'Connected accounts'), h('p', {}, 'Synthetic account row'))] : []), connect, remove));
      return;
    }
    const create = h('button', {}, '+'); create.onclick = () => { clicks.create++; };
    const children = [h('h2', {}, 'Created by you')];
    for (const record of records) {
      const link = h('a', { href: '/plugins/' + record.id }, record.name);
      link.onclick = () => pod.sandbox.history.pushState({}, '', '/plugins/' + record.id);
      children.push(link);
    }
    if (!records.length) children.push(h('p', {}, 'No apps created yet'));
    if (paged) children.push(h('button', {}, 'Load more'));
    const ownTab = h('button', { role: 'tab' }, 'Created by you');
    ownTab.onclick = () => { createdVisible = true; render(body, path); };
    body.appendChild(h('main', {}, h('h1', {}, 'Apps'), create, ...(!createdVisible ? [ownTab] : section ? [h('section', {}, ...children)] : [])));
  }
  pod = makePage({ installed: { status: 200, json: { items: installed } }, build(body) { render(body, '/plugins'); } });
  pod.pageState.pathname = '/plugins';
  pod.pageState.onNavigate = (path) => render(pod.body, path);
  return { pod, clicks, records };
}

test('unfinished self-created connector is included alongside installed entries without pressing Create', async () => {
  const { pod, clicks } = connectorPage([{ ...original }], { installed: [{ id: original.id, name: 'Old name', url: MCP, auth: 'none' }] });
  await pod.signIn();
  pod.run("Object.defineProperty(Object.prototype, 'connected', { configurable: true, get() { return true; }, set() { throw new Error('page metadata setter called'); } });");
  const scan = (await pod.command({ cmd: 'connectorScan', url: MCP })).data;
  assert.equal(scan.listKnown, true);
  assert.deepEqual(scan.matches, [{ id: original.id, name: NAME, auth: 'oauth', serverURL: MCP, detailPath: '/plugins/' + original.id, connected: false }]);
  assert.equal(clicks.create, 0);
  const reconnected = await pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: original.id, detailPath: scan.matches[0].detailPath });
  assert.equal(reconnected.data.status, 'pressed');
  assert.deepEqual(clicks.connect, [original.id]);
});

test('missing, paginated, or unreadable self-created section stays unknown even when installed is empty', async () => {
  for (const options of [{ section: false }, { paged: true }]) {
    const { pod, clicks } = connectorPage([], options); await pod.signIn();
    const scan = (await pod.command({ cmd: 'connectorScan', url: MCP })).data;
    assert.equal(scan.listKnown, false); assert.equal(clicks.create, 0);
  }
  const { pod } = connectorPage([]); await pod.signIn();
  assert.equal((await pod.command({ cmd: 'connectorScan', url: MCP })).data.listKnown, true);
});

test('20 reconnect cycles use one connector; transient failures never press Connect and expired authorization reuses its ID', async () => {
  const records = [{ ...original, authorized: true }];
  for (let round = 0; round < 20; round++) {
    // New fake document reproduces reload/restart, with the same server-side list.
    const { pod, clicks } = connectorPage(records); await pod.signIn();
    if (round % 5 === 3) records[0].authorized = false;
    const inspected = (await pod.command({ cmd: 'connectorInspect', url: MCP, connectorID: original.id, detailPath: '/plugins/' + original.id, connected: false })).data;
    assert.equal(inspected.connector.id, original.id);
    assert.equal(inspected.authorization, records[0].authorized ? 'connected' : 'not_connected');
    if (inspected.authorization === 'not_connected') {
      const result = await pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: original.id, detailPath: '/plugins/' + original.id, connected: false });
      assert.equal(result.data.status, 'pressed');
    } else assert.deepEqual(clicks.connect, []);
    assert.equal(records.length, 1); assert.equal(clicks.create, 0);
  }
});

test('namesake on another URL is reported as a conflict and cannot be reconnected or deleted', async () => {
  const foreign = { ...original, url: 'https://other.example.com/mcp' };
  const { pod, clicks } = connectorPage([foreign]); await pod.signIn();
  const scan = (await pod.command({ cmd: 'connectorScan', url: MCP })).data;
  assert.deepEqual(scan.matches, []); assert.deepEqual(scan.conflictingNames, [NAME]);
  const result = await pod.command({ cmd: 'connectorDelete', url: MCP, connectorID: foreign.id, name: NAME, keeping: 'active-connector' });
  assert.equal(result.data.deleted, false); assert.deepEqual(clicks.delete, []); assert.equal(clicks.create, 0);
});

test('cleanup deletes a same-URL numbered duplicate, never the active connector or another URL', async () => {
  const duplicate = { ...original, id: 'asdk_app_duplicate', name: NAME + '12', auth: 'none' };
  const { pod, records, clicks } = connectorPage([{ ...original, authorized: true }, duplicate]); await pod.signIn();
  const keep = await pod.command({ cmd: 'connectorDelete', url: MCP, connectorID: original.id, name: NAME, keeping: original.id });
  assert.notEqual(keep.data?.deleted, true);
  const removed = await pod.command({ cmd: 'connectorDelete', url: MCP, connectorID: duplicate.id, name: duplicate.name, keeping: original.id });
  assert.equal(removed.data.deleted, true);
  assert.deepEqual(clicks.delete, [duplicate.id]); assert.equal(records.length, 1); assert.equal(records[0].id, original.id);
});

const CID = '11111111-1111-4111-8111-111111111111';
async function settle(p, ms = 1200) {
  await p.advance(ms);
  for (let i = 0; i < 8; i++) { await new Promise(setImmediate); await p.advance(100); }
}

function chatPage({ thinking = false } = {}) {
  let p, round = 0;
  p = fixture({ allowNetwork: true, respond(url, init) {
    if (init?.method !== 'POST') return Response.json({ current_node: 'answer-' + round, mapping: {} });
    if (url.endsWith('/prepare')) return Response.json({});
    round++;
    p.sandbox.history.pushState({}, '', '/c/' + CID);
    const frame = { conversation_id: CID, message: { id: 'answer-' + round, author: { role: 'assistant' },
      content: { content_type: 'text', parts: ['synthetic answer ' + round] }, status: 'finished_successfully', end_turn: true } };
    if (thinking) return new Response('data: ' + JSON.stringify({ conversation_id: CID, message: { id: 'thought', author: { role: 'assistant' }, channel: 'analysis',
      content: { content_type: 'text', parts: ['synthetic thought'] } } }) + '\n\n', { headers: { 'content-type': 'text/event-stream' } });
    return new Response('data: ' + JSON.stringify(frame) + '\n\ndata: [DONE]\n\n', { headers: { 'content-type': 'text/event-stream' } });
  } });
  p.button.onClick = () => p.sandbox.fetch('https://chatgpt.com/backend-api/f/conversation', {
    method: 'POST', headers: { authorization: 'Bearer synthetic-only' },
    body: JSON.stringify({ model: 'auto', conversation_id: CID, messages: [{ content: { parts: [p.box.value] } }] }),
  }).catch(() => {});
  new p.Element('div', { 'data-message-author-role': 'assistant' });
  return p;
}

test('production browser script completes 200 turns in one conversation and releases each round', async () => {
  const p = chatPage();
  await p.sandbox.fetch('https://chatgpt.com/backend-api/me', { headers: { authorization: 'Bearer synthetic-only' } });
  p.sandbox.history.pushState({}, '', '/c/' + CID);
  for (let round = 1; round <= 200; round++) {
    p.send({ id: 'round-' + round, conversationID: CID });
    await settle(p);
    const events = p.reports.filter((r) => r.id === 'round-' + round);
    assert.ok(events.some((r) => r.kind === 'text' && r.full === 'synthetic answer ' + round), 'visible answer at round ' + round);
    assert.equal(events.filter((r) => r.kind === 'finished').length, 1, 'one terminal completion at round ' + round);
    assert.equal(events.some((r) => r.kind === 'failed'), false, 'no failed round ' + round);
    p.box.value = '';
  }
  assert.equal(p.requests.filter((r) => r.init?.method === 'POST' && /\/conversation$/.test(r.url)).length, 200);
});

test('minute-scale thinking reports progress instead of prematurely completing the turn', async () => {
  const p = chatPage({ thinking: true });
  const badge = new p.Element('div', { 'data-testid': 'reasoning-status' }); badge.textContent = 'Thinking';
  p.send({ id: 'long-thinking', conversationID: CID }); await settle(p);
  await settle(p, 240000);
  const events = p.reports.filter((r) => r.id === 'long-thinking');
  assert.ok(events.some((r) => r.kind === 'progress'));
  assert.equal(events.some((r) => r.kind === 'failed' || r.kind === 'finished'), false);
});


test('manual namesake card can point to the existing self-created entry without pressing it', async () => {
  const { pod, clicks } = connectorPage([{ ...original, url: 'https://other.example.com/mcp' }]); await pod.signIn();
  const result = await pod.command({ cmd: 'connectorHighlight', url: MCP, name: NAME });
  assert.equal(result.data.highlighted, true);
  assert.equal(queryAll(pod.body, '[data-tatwo-highlight]').length, 1);
  assert.deepEqual(clicks.connect, []); assert.equal(clicks.create, 0); assert.deepEqual(clicks.delete, []);
});


test('scan follows the visible Apps self-created tab and includes unfinished entries', async () => {
  const { pod, clicks } = connectorPage([{ ...original }], { tab: true }); await pod.signIn();
  const scan = (await pod.command({ cmd: 'connectorScan', url: MCP })).data;
  assert.equal(scan.listKnown, true); assert.equal(scan.matches[0].id, original.id);
  assert.equal(clicks.create, 0); assert.deepEqual(clicks.connect, []);
});

test('installed namesake on another server stops creation even with an empty self-created list', async () => {
  const { pod, clicks } = connectorPage([], { installed: [{ id: original.id, name: NAME, url: 'https://other.example.com/mcp', auth: 'oauth' }] });
  await pod.signIn(); const scan = (await pod.command({ cmd: 'connectorScan', url: MCP })).data;
  assert.equal(scan.listKnown, true); assert.deepEqual(scan.matches, []); assert.deepEqual(scan.conflictingNames, [NAME]);
  assert.equal(clicks.create, 0); assert.deepEqual(clicks.delete, []);
});

test('closing the delete dialog is not success while the connector still appears in the complete list', async () => {
  const duplicate = { ...original, id: 'asdk_app_duplicate', name: NAME + '2' };
  const { pod, records, clicks } = connectorPage([{ ...original, authorized: true }, duplicate], { deleteConfirmed: false });
  await pod.signIn();
  const result = await pod.command({ cmd: 'connectorDelete', url: MCP, connectorID: duplicate.id, name: duplicate.name, keeping: original.id });
  assert.equal(result.data.deleted, false); assert.equal(records.length, 2);
  assert.deepEqual(clicks.delete, [duplicate.id]);
});

test('scan exposes the actual connected detail state for migration instead of assuming installed means connected', async () => {
  const active = { ...original, name: NAME + '4', authorized: true };
  const unfinished = { ...original, id: 'asdk_app_unfinished', name: NAME + '2' };
  const { pod, clicks } = connectorPage([active, unfinished]); await pod.signIn();
  const scan = (await pod.command({ cmd: 'connectorScan', url: MCP })).data;
  assert.equal(scan.listKnown, true);
  assert.deepEqual(scan.matches.filter((r) => r.connected).map((r) => r.id), [original.id]);
  assert.equal(clicks.create, 0); assert.deepEqual(clicks.delete, []);
});


test('W210-1 account A to B while connectorDelete waits never presses final Delete', async () => {
  const duplicate = { ...original, id: 'asdk_app_duplicate', name: NAME + '2' };
  const { pod, clicks } = connectorPage([{ ...original, authorized: true }, duplicate], {
    beforeConfirm(p) { void p.sandbox.window.fetch('https://chatgpt.com/backend-api/me', {
      headers: { authorization: 'Bearer ACCOUNT-B-SYNTHETIC' },
    }); },
  });
  await pod.signIn();
  const result = await pod.command({ cmd: 'connectorDelete', url: MCP, connectorID: duplicate.id, name: duplicate.name, keeping: original.id });
  assert.equal(result.data.deleted, false);
  assert.deepEqual(clicks.delete, []);
});

test('account A to B and back to A while connectorDelete waits still voids the deletion', async () => {
  const duplicate = { ...original, id: 'asdk_app_duplicate', name: NAME + '2' };
  const { pod, clicks } = connectorPage([{ ...original, authorized: true }, duplicate], {
    beforeConfirm(p) {   // the page wrapper records each header synchronously
      void p.sandbox.window.fetch('https://chatgpt.com/backend-api/me', { headers: { authorization: 'Bearer ACCOUNT-B-SYNTHETIC' } });
      void p.sandbox.window.fetch('https://chatgpt.com/backend-api/me', { headers: { authorization: 'Bearer SECRET-TOKEN' } });   // back to the signed-in account
    },
  });
  await pod.signIn();
  const result = await pod.command({ cmd: 'connectorDelete', url: MCP, connectorID: duplicate.id, name: duplicate.name, keeping: original.id });
  assert.equal(result.data.deleted, false);
  assert.deepEqual(clicks.delete, []);
});
