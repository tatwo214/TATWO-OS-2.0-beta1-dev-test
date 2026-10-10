import test from 'node:test';
import assert from 'node:assert/strict';
import { tildeInstalledPage, installedRows, MCP } from './fixtures/w319-installed-tilde.mjs';
import { queryAll } from './w185-pod-fixture.mjs';
const scan = async w => { await w.pod.signIn(); return (await w.pod.command({ cmd: 'connectorScan', url: MCP }, 24000)).data; };
const safe = w => {
  assert.equal(w.clicks.create, 0); assert.deepEqual(w.clicks.delete, []);
  assert.deepEqual(w.octoberClicks.forbidden, []);
  assert.equal(JSON.stringify(w.pod.reports).includes('Synthetic Account'), false);
};

test('W319 26 Installed rows include four tilde links and find both TATWO connectors without create', async () => {
  const items = installedRows(), w = tildeInstalledPage(items);
  assert.equal(items.length, 26);
  assert.equal(items.filter(x => x.path.includes('~')).length, 4);
  assert.equal(items.filter(x => x.path.startsWith('/plugins/Plugin_')).length, 4);
  assert.equal(items.filter(x => x.path.startsWith('/plugins/plugin_asdk_app_')).length, 4);
  assert.equal(items.filter(x => x.path.startsWith('/plugins/plugin_connector_')).length, 14);
  assert.equal(queryAll(w.pod.body, 'button').length, 137);
  assert.deepEqual(queryAll(w.pod.body._kids[0]._kids[1], 'a').map(a => a.getAttribute('href')), items.map(x => x.path));
  const got = await scan(w);
  assert.equal(got.listKnown, true, got.failure);
  assert.equal(got.failure, null);
  assert.deepEqual(got.candidates, items.map((x, i) => ({ name: x.name, verdict: i < 2 ? '相符' : '讀不到' })));
  assert.deepEqual(got.matches.map(x => [x.id, x.name, x.detailPath]), items.slice(0, 2).map(x =>
    [x.id, x.name, '/settings/plugins-settings/plugin_' + x.id]));
  assert.equal(w.octoberClicks.manage, 2);
  for (const row of got.matches) {
    assert.equal((await w.pod.command({ cmd: 'connectorInspect', url: MCP, connectorID: row.id,
      detailPath: row.detailPath })).data.connector.id, row.id);
    assert.equal((await w.pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: row.id,
      detailPath: row.detailPath })).data.status, 'pressed');
  }
  assert.deepEqual(w.clicks.reconnect, items.slice(0, 2).map(x => x.id));
  safe(w);
});

test('W319 tilde only widens the final path segment; invalid links still stop the whole list', async () => {
  const path = installedRows()[22].path;
  const invalid = ['https://foreign.invalid' + path,
    path + '/extra', path + '/', path + '?next=2', path + '#detail',
    path.replace('~', '%7E'), path.replace('~', '.'), path.replace('~', ':'),
    path.replace('/plugins/', '/skills/'), '/plugins/../plugins/' + path.split('/').pop(), '/plugins/'];
  await Promise.all(invalid.map(async href => {
    const w = tildeInstalledPage(undefined, { onInstalled(region) {
      queryAll(region, 'a')[22].setAttribute('href', href);
    } });
    const got = await scan(w);
    assert.equal(got.listKnown, false, href);
    assert.match(got.failure, /invalid-row/, href);
    assert.match(got.failure, /viewport=1100x800 buttons=137/);
    safe(w);
  }));
});

test('W319 row acceptance does not widen TATWO App ID or Plugin settings identity matching', async () => {
  await Promise.all(['asdk_app_v_' + '0'.repeat(32), 'asdk_app_' + '0'.repeat(32) + '~bad'].map(async id => {
    const items = installedRows(); items[0].id = id;
    items[0].path = '/plugins/plugin_' + id;
    const w = tildeInstalledPage(items), got = await scan(w);
    assert.equal(got.listKnown, false);
    assert.match(got.failure, /Manage/);
    assert.deepEqual(got.matches, []);
    safe(w);
  }));
  const w = tildeInstalledPage(undefined, { onSettings(pod) {
    const label = queryAll(pod.body, 'p').find(x => x.textContent === 'App ID');
    label.parentElement._kids[1].text = 'asdk_app_' + 'f'.repeat(32);
  } });
  const got = await scan(w);
  assert.equal(got.listKnown, false);
  assert.match(got.failure, /App ID/);
  assert.deepEqual(got.matches, []);
  safe(w);
});
