import test from 'node:test';
import assert from 'node:assert/strict';
import { settingsPage, installedRows, MCP } from './fixtures/w324-pluginsettings-page.mjs';
import { h, queryAll } from './w185-pod-fixture.mjs';
const scan = async w => { await w.pod.signIn(); return (await w.pod.command({ cmd: 'connectorScan', url: MCP }, 24000)).data; };
const safe = w => {
  assert.equal(w.clicks.create, 0); assert.deepEqual(w.clicks.delete, []); assert.deepEqual(w.forbidden, []);
  assert.deepEqual(w.octoberClicks.forbidden, []);
  assert.equal(JSON.stringify(w.pod.reports).includes('Synthetic Account'), false);
};
for (const absolute of [true, false]) test('W324 Installed → full Plugin settings → identity → unique account Reconnect, absolute=' + absolute, async () => {
  const w = settingsPage({ absolute }), got = await scan(w);
  assert.equal(got.listKnown, true, got.failure); assert.equal(got.failure, null);
  assert.equal(got.matches.length, 2); assert.equal(got.candidates.length, 26);
  for (const [i, record] of got.matches.entries()) {
    assert.equal(record.id, installedRows()[i].id); assert.equal(record.serverURL, MCP);
    assert.equal(record.auth, 'oauth'); assert.equal(record.needsReconnect, true); assert.equal(record.connected, null);
    assert.equal(record.detailPath, '/settings/plugins-settings/plugin_' + record.id);
    const c = { url: MCP, connectorID: record.id, detailPath: record.detailPath };
    const inspected = (await w.pod.command({ cmd: 'connectorInspect', ...c })).data;
    assert.equal(inspected.authorization, 'needs_reconnect'); assert.equal(inspected.connector.id, record.id);
    assert.equal(queryAll(w.pod.body, '[role="navigation"]').length, 2);
    assert.equal((await w.pod.command({ cmd: 'connectorReconnect', ...c })).data.status, 'pressed');
    assert.equal((await w.pod.command({ cmd: 'connectorGesture', url: MCP, name: record.name })).data.kind, 'continue');
    w.pod.userClick(queryAll(w.pod.body, 'button').find(b => b.textContent.startsWith('Continue to')));
  }
  assert.deepEqual(w.clicks.reconnect, got.matches.map(x => x.id)); assert.deepEqual(w.clicks.continue, w.clicks.reconnect);
  assert.equal(w.installedClicks.names, 0); assert.equal(w.octoberClicks.manage, 0); safe(w);
});
test('W324 name link landing on settings also skips Manage and uses route identity', async () => {
  const w = settingsPage({ onInstalled(_region, links) {
    for (const [i, link] of links.slice(0, 2).entries()) {
      queryAll(link.parentElement, 'a')[1].setAttribute('href', '/codex/open-app');
      link.onclick = () => { w.installedClicks.names++; w.pod.navigateNatively('/settings/plugins-settings/plugin_' + installedRows()[i].id); };
    }
  } });
  const got = await scan(w);
  assert.equal(got.listKnown, true, got.failure); assert.equal(got.matches.length, 2);
  assert.equal(w.installedClicks.names, 2); assert.equal(w.installedClicks.manage, 0); safe(w);
});
test('W324 left navigation cannot supply identity, About fields or Reconnect', async () => {
  const w = settingsPage({ mutate({ settingsNavigation, field }) {
    settingsNavigation.appendChild(h('a', { href: '/plugins' }, 'Plugin settings'));
    settingsNavigation.appendChild(h('h1', {}, 'TATWO（Wrong device）'));
    settingsNavigation.appendChild(h('section', {}, h('h3', {}, 'About'), field('URL', 'https://foreign.invalid/mcp'), field('App ID', 'asdk_app_' + 'f'.repeat(32))));
    settingsNavigation.appendChild(h('section', {}, h('h3', {}, 'Connected accounts'), h('button', {}, 'Reconnect')));
  } });
  const got = await scan(w);
  assert.equal(got.listKnown, true, got.failure);
  assert.equal((await w.pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: got.matches[0].id })).data.status, 'pressed'); safe(w);
});
for (const id of ['asdk_app_v_' + 'e'.repeat(32), 'asdk_app_' + 'f'.repeat(32)])
  test('W324 App ID must be an app identity matching the settings route: ' + id, async () => {
    const w = settingsPage({ mutate({ about }) {
      queryAll(about, 'p').find(x => x.textContent === 'App ID').parentElement._kids[1].text = id;
    } });
    const got = await scan(w);
    assert.equal(got.listKnown, false); assert.match(got.failure, /About App ID/); assert.deepEqual(got.matches, []); safe(w);
  });
test('W324 multiple account Reconnect buttons stop without pressing', async () => {
  const w = settingsPage({ mutate({ accounts }) {
    accounts.appendChild(h('button', { 'aria-label': "Reconnect Synthetic Account's other account Primary" }));
  } }), got = await scan(w);
  assert.equal(got.listKnown, true, got.failure);
  assert.notEqual((await w.pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: got.matches[0].id })).data.status, 'pressed');
  assert.deepEqual(w.clicks.reconnect, []); safe(w);
});
test('W324 full settings requires both OAuth fields before Reconnect', async () => {
  const w = settingsPage({ mutate({ about }) {
    queryAll(about, 'p').find(x => x.textContent === 'Authorization used').parentElement._kids[1].text = 'None';
  } });
  const got = await scan(w); assert.equal(got.listKnown, true, got.failure);
  assert.notEqual((await w.pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: installedRows()[0].id })).data.status, 'pressed');
  assert.deepEqual(w.clicks.reconnect, []); safe(w);
});
