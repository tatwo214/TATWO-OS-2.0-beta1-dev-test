import test from 'node:test';
import assert from 'node:assert/strict';
import { settingsPage, installedRows, MCP } from './fixtures/w325-pluginsettings-dom.mjs';
import { h, queryAll } from './w185-pod-fixture.mjs';
import { manageInstalledPage } from './fixtures/w322-installed-managelink.mjs';
const scan = async w => { await w.pod.signIn(); return (await w.pod.command({ cmd: 'connectorScan', url: MCP }, 24000)).data; };
const safe = w => {
  assert.equal(w.clicks.create, 0); assert.deepEqual(w.clicks.delete, []); assert.deepEqual(w.forbidden, []);
  assert.deepEqual(w.octoberClicks.forbidden, []);
  assert.equal(JSON.stringify(w.pod.reports).includes('Fixture Person'), false);
};
for (const absolute of [true, false]) test('W325 real DOM reads identity and uniquely reconnects both Installed plugins: absolute=' + absolute, async () => {
  const w = settingsPage({ absolute }), got = await scan(w);
  assert.equal(got.listKnown, true, got.failure); assert.equal(got.failure, null);
  assert.equal(got.candidates.length, 26); assert.equal(got.matches.length, 2);
  for (const [i, record] of got.matches.entries()) {
    assert.equal(record.name, installedRows()[i].name); assert.equal(record.serverURL, MCP);
    assert.equal(record.id, installedRows()[i].id); assert.notEqual(record.id, 'asdk_app_v_' + 'e'.repeat(32));
    assert.equal(record.auth, 'oauth'); assert.equal(record.needsReconnect, true);
    assert.equal(record.detailPath, '/settings/plugins-settings/plugin_' + record.id);
    const c = { url: MCP, connectorID: record.id, detailPath: record.detailPath };
    assert.equal((await w.pod.command({ cmd: 'connectorInspect', ...c })).data.authorization, 'needs_reconnect');
    const main = queryAll(w.pod.body, 'main')[0];
    assert.equal(queryAll(main, 'nav')[0].getAttribute('aria-label'), 'Breadcrumb');
    assert.equal(queryAll(main, 'h1').length, 1); assert.equal(queryAll(main, 'h2, h3, h4, [role="heading"]').length, 0);
    assert.equal(queryAll(w.pod.body, '[role="complementary"]')[0].contains(main), false);
    assert.equal((await w.pod.command({ cmd: 'connectorReconnect', ...c })).data.status, 'pressed');
    assert.equal((await w.pod.command({ cmd: 'connectorGesture', url: MCP, name: record.name })).data.kind, 'continue');
    w.pod.userClick(queryAll(w.pod.body, 'button').find(b => b.textContent.startsWith('Continue to')));
  }
  assert.deepEqual(w.clicks.reconnect, got.matches.map(x => x.id)); assert.deepEqual(w.clicks.continue, w.clicks.reconnect); safe(w);
});
for (const useID of [true, false]) test('W325 accepts account label ending account through ' + (useID ? 'account ID' : 'leaf title'), async () => {
  const w = settingsPage({ mutate({ accounts, reconnect }) {
    if (useID) { accounts._kids[0].text = ''; accounts._kids[0].appendChild(h('span', {}, 'Connected accounts')); }
    else accounts.removeAttribute('id');
    reconnect.removeAttribute('aria-label'); reconnect.text = "Reconnect Fixture Person's TATWO（Mac mini）4 account";
  } }), got = await scan(w);
  assert.equal(got.listKnown, true, got.failure);
  assert.equal((await w.pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: got.matches[0].id })).data.status, 'pressed'); safe(w);
});
test('W325 left navigation and outside-account Reconnect cannot supply fields or actions', async () => {
  const w = settingsPage({ mutate({ settingsNavigation, header, field }) {
    settingsNavigation.appendChild(h('a', { href: '/settings/plugins-settings' }, 'Plugin settings'));
    settingsNavigation.appendChild(h('h1', {}, 'TATWO（Wrong device）'));
    settingsNavigation.appendChild(h('div', {}, h('div', {}, 'About'), field('URL', 'https://foreign.invalid/mcp'), field('App ID', 'asdk_app_' + 'f'.repeat(32))));
    for (const root of [settingsNavigation, header]) {
      const b = h('button', {}, "Reconnect Fixture Person's wrong account Primary");
      b.onclick = () => assert.fail('outside-account Reconnect pressed'); root.appendChild(b);
    }
  } }), got = await scan(w);
  assert.equal(got.listKnown, true, got.failure);
  assert.equal((await w.pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: got.matches[0].id })).data.status, 'pressed'); safe(w);
});
test('W325 two account Reconnect buttons refuse without creating or uninstalling', async () => {
  const w = settingsPage({ mutate({ accounts }) {
    const b = h('button', { 'aria-label': "Reconnect Fixture Person's other account Primary" });
    b.onclick = () => assert.fail('ambiguous Reconnect pressed'); accounts.appendChild(b);
  } }), got = await scan(w);
  assert.equal(got.listKnown, true, got.failure);
  assert.notEqual((await w.pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: got.matches[0].id })).data.status, 'pressed');
  assert.deepEqual(w.clicks.reconnect, []); safe(w);
});
for (const value of ['asdk_app_v_' + 'e'.repeat(32), 'asdk_app_' + 'f'.repeat(32)]) test('W325 rejects Version ID or mismatched App ID: ' + value, async () => {
  const w = settingsPage({ mutate({ about }) { queryAll(about, 'div').find(x => x.textContent === 'App ID').parentElement._kids[1].text = value; } });
  const got = await scan(w); assert.equal(got.listKnown, false); assert.match(got.failure, /About App ID/); assert.deepEqual(got.matches, []); safe(w);
});
test('W325 multiple main surfaces remain unconfirmed', async () => {
  const w = settingsPage({ mutate({ pod }) { pod.body.appendChild(h('main', {}, 'Other main')); } }), got = await scan(w);
  assert.equal(got.listKnown, false); assert.deepEqual(got.matches, []); safe(w);
});
test('W325 leaf About still requires both OAuth fields', async () => {
  const w = settingsPage({ mutate({ about }) { queryAll(about, 'div').find(x => x.textContent === 'Authorization used').parentElement._kids[1].text = 'None'; } });
  const got = await scan(w); assert.equal(got.listKnown, true, got.failure);
  assert.notEqual((await w.pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: got.matches[0].id })).data.status, 'pressed');
  assert.deepEqual(w.clicks.reconnect, []); safe(w);
});
test('W325 legacy heading dialog still reconnects with a background main', async () => {
  const w = manageInstalledPage({ items: installedRows().slice(0, 1), onSettings(pod) {
    queryAll(pod.body, '[role="group"]')[0].setAttribute('role', 'dialog');
    pod.body.appendChild(h('main', {}, h('h1', {}, 'Background')));
  } }), got = await scan(w);
  assert.equal(got.listKnown, true, got.failure); assert.equal(got.matches[0].id, installedRows()[0].id);
  assert.equal((await w.pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: got.matches[0].id })).data.status, 'pressed');
  assert.equal(w.clicks.create, 0); assert.deepEqual(w.clicks.delete, []); assert.deepEqual(w.octoberClicks.forbidden, []);
});
