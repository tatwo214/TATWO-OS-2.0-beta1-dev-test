import test from 'node:test';
import assert from 'node:assert/strict';
import { manageInstalledPage, installedRows, MCP } from './fixtures/w322-installed-managelink.mjs';
import { h, queryAll } from './w185-pod-fixture.mjs';
const scan = async w => { await w.pod.signIn(); return (await w.pod.command({ cmd: 'connectorScan', url: MCP }, 24000)).data; };
const safe = w => {
  assert.equal(w.clicks.create, 0); assert.deepEqual(w.clicks.delete, []);
  assert.deepEqual(w.octoberClicks.forbidden, []);
  assert.equal(JSON.stringify(w.pod.reports).includes('Synthetic Account'), false);
};

for (const absolute of [true, false]) test('W322 26 Installed rows with Manage and hidden actions read both TATWO rows and reconnect: absolute=' + absolute, async () => {
  const items = installedRows(), w = manageInstalledPage({ absolute, items });
  const region = w.pod.body._kids[0]._kids[1];
  assert.equal(items.length, 26); assert.equal(items.filter(x => x.path.includes('~')).length, 4);
  assert.equal(items.filter(x => x.path.startsWith('/plugins/Plugin_')).length, 4);
  assert.equal(queryAll(region, 'a').length, 52);
  for (const [i, row] of region._kids.slice(1).entries()) {
    assert.deepEqual(row._kids.map(x => x.tagName), ['A', 'A', 'BUTTON']);
    assert.equal(row._kids[1].getAttribute('aria-label'), 'Manage ' + items[i].name);
    assert.equal(row._kids[2].style.visibility, 'hidden');
    assert.equal(row._kids[2].getBoundingClientRect().width, 1);
  }
  const got = await scan(w);
  assert.equal(got.listKnown, true, got.failure); assert.equal(got.failure, null);
  assert.deepEqual(got.candidates, items.map((x, i) => ({ name: x.name, verdict: i < 2 ? '相符' : '讀不到' })));
  assert.deepEqual(got.matches.map(x => [x.id, x.name, x.detailPath]), items.slice(0, 2).map(x =>
    [x.id, x.name, '/settings/plugins-settings/' + x.path.slice(9)]));
  assert.equal(w.installedClicks.names, 0); assert.equal(w.installedClicks.manage, 2);
  assert.equal(w.octoberClicks.manage, 0);
  assert.deepEqual(w.installedClicks.paths, got.matches.map(x => x.detailPath));
  for (const row of got.matches) {
    assert.equal((await w.pod.command({ cmd: 'connectorInspect', url: MCP, connectorID: row.id,
      detailPath: row.detailPath })).data.connector.id, row.id);
    assert.equal((await w.pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: row.id,
      detailPath: row.detailPath })).data.status, 'pressed');
  }
  assert.deepEqual(w.clicks.reconnect, items.slice(0, 2).map(x => x.id)); safe(w);
});

for (const [reason, change] of [
  ['manage-mismatch', a => a.setAttribute('href', '/settings/plugins-settings/plugin_asdk_app_' + 'f'.repeat(32))],
  ['manage-mismatch', a => a.setAttribute('href', 'https://foreign.invalid' + new URL(a.getAttribute('href')).pathname)],
  ['manage-mismatch', a => a.setAttribute('href', a.getAttribute('href') + '?next=2')],
  ['manage-mismatch', a => a.setAttribute('href', a.getAttribute('href') + '#detail')],
  ['manage-mismatch', a => a.setAttribute('href', '//chatgpt.com' + new URL(a.getAttribute('href')).pathname)],
  ['anchors:2', a => { a.removeAttribute('aria-label'); a.setAttribute('href', '/plugins/private_extra'); }],
  ['anchors:3', a => a.parentElement.appendChild(h('a', { href: a.getAttribute('href'), 'aria-label': a.getAttribute('aria-label') }, 'Manage'))],
  ['anchors:3', a => a.parentElement.appendChild(h('a', { href: '/other', hidden: true }, 'Private extra'))],
  ['no-actions', a => queryAll(a.parentElement, 'button')[0].remove()],
]) test('W322 invalid Manage row stops without exposing names or paths: ' + reason, async () => {
  const w = manageInstalledPage({ mutate(_region, links) { change(queryAll(links[22].parentElement, 'a')[1]); } });
  const got = await scan(w);
  assert.equal(got.listKnown, false);
  assert.ok(got.failure.includes('invalid-row:23:' + reason + ' path='), got.failure);
  assert.deepEqual(got.matches, []); assert.equal(w.installedClicks.manage, 0);
  for (const text of [...installedRows().flatMap(x => [x.name, x.path]), 'private_extra', 'foreign.invalid'])
    assert.equal(got.failure.includes(text), false, text);
  safe(w);
});

test('W322 matching settings path requires the exact Manage aria-label', async () => {
  const w = manageInstalledPage({ mutate(region) { queryAll(region, 'a').forEach(a => a.removeAttribute('aria-label')); } });
  const got = await scan(w);
  assert.equal(got.listKnown, false); assert.match(got.failure, /invalid-row:1:anchors:2/);
  assert.deepEqual(got.matches, []); assert.equal(w.installedClicks.names, 0); safe(w);
});
test('W322 direct settings navigation falls back to routing when Manage does not handle clicks', async () => {
  const w = manageInstalledPage({ mutate(region) {
    queryAll(region, 'a').filter(a => a.getAttribute('aria-label')).forEach(a => { a.onclick = null; });
  } });
  assert.equal((await scan(w)).listKnown, true); assert.equal(w.installedClicks.names, 0);
  assert.equal(w.octoberClicks.manage, 0); safe(w);
});
test('W322 About App ID must still match settings identity', async () => {
  const w = manageInstalledPage({ onSettings(pod) {
    const label = queryAll(pod.body, 'p').find(x => x.textContent === 'App ID');
    label.parentElement._kids[1].text = 'asdk_app_' + 'f'.repeat(32);
  } });
  const got = await scan(w);
  assert.equal(got.listKnown, false); assert.match(got.failure, /About App ID/);
  assert.deepEqual(got.matches, []); safe(w);
});
for (const [reason, options] of [
  ['action-count', { mutate(region) { region.appendChild(h('button', { 'aria-label': 'More actions', hidden: true })); } }],
  ['duplicate-row', { items: [...installedRows(), installedRows()[0]] }],
  ['row-limit', { items: Array.from({ length: 257 }, (_, i) => ({ id: 'fixture_' + i, name: 'Fixture ' + i, path: '/plugins/fixture_' + i })) }],
]) test('W322 Manage rows retain whole-list guard: ' + reason, async () => {
  const w = manageInstalledPage(options), got = await scan(w);
  assert.equal(got.listKnown, false);
  assert.ok(got.failure.includes('Installed 載入逾時）；' + reason + ' path='), got.failure);
  assert.deepEqual(got.matches, []); safe(w);
});
