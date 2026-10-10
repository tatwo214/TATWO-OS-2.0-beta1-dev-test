import test from 'node:test';
import assert from 'node:assert/strict';
import { settingsPage, installedRows, MCP } from './fixtures/w327-aboutarea.mjs';
import { fixture, source } from './w185-pod-fixture.mjs';
import { readFileSync } from 'node:fs';

const probeText = 'OS呼叫請回答（請用「TATWO（Mac mini）4」這個 app 的唯讀狀態工具 tatwo_status 回一句，不要做任何修改）';
function probePage({ project = false, projectDelay = 0 } = {}) {
  const f = fixture({ allowNetwork: true, respond(url) {
    if (String(url).endsWith('/backend-api/me')) return Response.json({ id: 'synthetic-probe-user' });
    assert.match(String(url), /\/backend-api\/gizmos\/snorlax\/sidebar/, 'only project list may be read');
    const response = () => Response.json({ items: project ? [{ gizmo: { id: 'g-p-fixture', display: { name: 'TATWO · 收件匣' } } }] : [] });
    return projectDelay ? new Promise(resolve => f.later(projectDelay, () => resolve(response()))) : response();
  } });
  f.doc.onInsert = (_cmd, text) => { f.box.value = text; return true; };
  f.button.onClick = () => { f.box.value = ''; };
  f.probe = async () => {
    await f.sandbox.fetch('https://chatgpt.com/backend-api/me', { headers: { authorization: 'Bearer synthetic-probe-fixture' } });
    f.command({ cmd: 'connectorProbe', id: 'P', text: probeText });
    await f.advance(16000);
    return f.reports.find(r => r.id === 'P')?.data?.probe;
  };
  return f;
}

for (const project of [false, true]) {
  test(`W332 probe submits one new conversation; inbox project=${project}; no reply stream or turn storage`, async () => {
    const f = probePage({ project });
    assert.equal(await f.probe(), 'sent');
    assert.equal(f.button.clicks, 1);
    assert.equal(f.insertions.length, 1);
    assert.equal(f.reports.some(r => r.type === 'stream'), false);
    assert.equal(f.sandbox.location.pathname, project ? '/g/g-p-fixture/project' : '/');
  });
}

for (const why of ['input', 'send_button', 'unconfirmed', 'busy', 'aborted', 'changed_text', 'focus']) {
  test(`W332 probe failure ${why} does not retry send`, async () => {
    const f = probePage();
    if (why === 'input') f.doc.onInsert = () => true;
    if (why === 'send_button') f.button.disabled = true;
    if (why === 'unconfirmed') f.button.onClick = () => {};
    if (why === 'busy') f.box.value = 'existing user draft';
    if (why === 'aborted') f.doc.onInsert = (_cmd, text) => { f.box.value = text; f.command({ cmd: 'connectorAbort', id: 'A' }); return true; };
    if (why === 'changed_text') {
      f.button.disabled = true;
      f.later(600, () => { f.box.value = 'different user text'; f.button.disabled = false; });
    }
    if (why === 'focus') f.box.focus = () => {};
    const result = await f.probe();
    assert.equal(result, 'failed:' + ({ aborted: 'input', changed_text: 'send_button' }[why] || why));
    assert.equal(f.button.clicks, why === 'unconfirmed' ? 1 : 0);
    await f.advance(30000);
    assert.equal(f.button.clicks, why === 'unconfirmed' ? 1 : 0);
    assert.equal(f.reports.some(r => r.type === 'stream'), false);
    if (why === 'busy') assert.equal(f.box.value, 'existing user draft');
  });
}

test('W332 probe uses existing L0 read-only tatwo_status, outside Coder/TAP send and answer tracking', () => {
  const tools = readFileSync(new URL('../App/Sources/Tatwo2/Facade/HandsTools.swift', import.meta.url), 'utf8');
  assert.match(tools, /id: "tatwo_status", level: 0,[\s\S]*?properties: \[:\], required: \[\], mutates: false, readOnly: true, destructive: false/);
  const probe = source.slice(source.indexOf('connectorProbe: async'), source.indexOf('list: async', source.indexOf('connectorProbe: async')));
  assert.doesNotMatch(probe, /startTurn|pendingSend|assistantNodes|postTerminal|handlers\.get|apiSend/);
  assert.match(source, /"connectorDelete", "connectorProbe"\]/);
  assert.doesNotMatch(source.match(/static let connectorReads[^\n]+/)[0], /connectorProbe/);
});

test('W332 cancelled probe cannot navigate to an inbox after a late project response', async () => {
  const f = probePage({ project: true, projectDelay: 2000 });
  f.later(1000, () => {
    f.command({ cmd: 'connectorAbort', id: 'A' });
    f.sandbox.location.pathname = '/c/user-later';
    f.box.value = 'later user draft';
  });
  assert.equal(await f.probe(), 'failed:project');
  assert.equal(f.sandbox.location.pathname, '/c/user-later');
  assert.equal(f.box.value, 'later user draft');
  assert.equal(f.insertions.length, 0);
  assert.equal(f.button.clicks, 0);
});

for (const state of ['connected', 'reconnect', 'missing-account', 'wrong-app', 'wrong-url']) {
  test(`W332 granted evidence: ${state}; inspection never presses account or management buttons`, async () => {
    const w = settingsPage({ mutate({ accounts, reconnect, row }) {
      if (state === 'connected') reconnect.remove();
      if (state === 'missing-account') accounts.remove();
      if (state === 'wrong-app') row('App ID')._kids[1].text = 'asdk_app_' + 'f'.repeat(32);
      if (state === 'wrong-url') row('URL')._kids[1].text = 'https://foreign.invalid/mcp';
    } });
    await w.pod.signIn();
    const target = installedRows()[0];
    const result = (await w.pod.command({ cmd: 'connectorInspect', url: MCP, connectorID: target.id,
      detailPath: '/settings/plugins-settings/plugin_' + target.id }, 24000)).data;
    assert.equal(result.authorization, state === 'connected' ? 'connected' : state === 'reconnect' ? 'needs_reconnect'
      : 'unknown', result.reason);
    if (state === 'connected') {
      assert.equal(result.connector.id, target.id);
      assert.equal(result.connector.serverURL, MCP);
      assert.equal(result.connector.auth, 'oauth');
    }
    assert.deepEqual(w.clicks.reconnect, []);
    assert.deepEqual(w.clicks.delete, []);
    assert.equal(w.clicks.create, 0);
    assert.deepEqual(w.forbidden, []);
    assert.deepEqual(w.octoberClicks.forbidden, []);
    assert.ok(w.dangerous.length > 0);
    assert.ok(w.dangerous.every(button => button.clicks === 0));
    assert.equal(JSON.stringify(w.pod.reports).includes('Fixture Person'), false);
  });
}
