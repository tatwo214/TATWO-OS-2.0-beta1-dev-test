import test from 'node:test';
import assert from 'node:assert/strict';
import { installedPage, MCP, connector } from './fixtures/w304b-installed-sidebar.mjs';
import { h, queryAll } from './w185-pod-fixture.mjs';
import { nativeW298a } from './fixtures/w298a-native.mjs';
const scan = async w => { await w.pod.signIn(); return (await w.pod.command({ cmd: 'connectorScan', url: MCP }, 24000)).data; };
const sidebar = w => w.pod.body._kids[0];
const region = w => sidebar(w)._kids[1];

test('W317 moving main catalogue buttons cannot prevent stable Installed from loading', async () => {
  const w = installedPage([{ id: 'calendar', name: 'fixture' }], { narrow: true });
  let changes = 0;
  const timer = setInterval(() => { queryAll(w.pod.body, 'main')[0]?.appendChild(h('button', {}, 'Install')); changes++; }, 100);
  try {
    const got = await scan(w);
    assert.equal(got.listKnown, true, got.failure); assert.ok(changes >= 4);
    assert.deepEqual(got.candidates, [{ name: 'fixture', verdict: '讀不到' }]);
    assert.equal(w.clicks.create, 0);
  } finally { clearInterval(timer); }
});
for (const place of ['main', 'header', 'outside sidebar']) test('W317 aria-busy outside Installed row region is ignored: ' + place, async () => {
  const w = installedPage(undefined, { narrow: true });
  const parent = place === 'main' ? queryAll(w.pod.body, 'main')[0] : place === 'header' ? sidebar(w)._kids[0] : w.pod.body;
  parent.appendChild(h('div', { 'aria-busy': 'true' }));
  const got = await scan(w);
  assert.equal(got.listKnown, true, got.failure); assert.equal(got.matches[0].id, connector().id); assert.equal(w.clicks.create, 0);
});
for (const [label, mutate, reason] of [
  ['busy descendant', w => region(w).appendChild(h('div', { 'aria-busy': 'true' })), 'busy:[aria-busy="true"]'],
  ['busy region', w => region(w).setAttribute('aria-busy', 'true'), 'busy:[aria-busy="true"]'],
  ['progress', w => region(w).appendChild(h('div', { role: 'progressbar' })), 'busy:[role="progressbar"]'],
  ['virtualized', w => region(w).setAttribute('data-virtualized', ''), 'busy:[data-virtualized]'],
  ['rowcount', w => region(w).setAttribute('aria-rowcount', '35'), 'busy:[aria-rowcount]'],
  ['stray private text', w => region(w).appendChild(h('span', {}, 'Private account text')), 'stray-leaf:SPAN:20'],
  ['extra Installed', w => region(w).appendChild(h('div', {}, 'Installed')), 'marker-count:2'],
  ['filter value', w => sidebar(w).appendChild(h('input', { value: 'private search' })), 'input-has-value'],
  ['load more', w => region(w).appendChild(h('button', {}, 'Load more')), 'load-more'],
]) test('W317 uncertain list stops with private-safe reason: ' + label, async () => {
  const w = installedPage(undefined, { narrow: true }); mutate(w);
  const got = await scan(w);
  assert.equal(got.listKnown, false); assert.ok(got.failure.includes('Installed 載入逾時）；' + reason), got.failure);
  assert.equal(w.clicks.create, 0);
  assert.equal(got.failure.includes(connector().name), false);
  assert.equal(got.failure.includes('Private account text'), false);
  assert.equal(got.failure.includes('private search'), false);
});
for (const [name, scenarios] of [
  ['opening without cached latest only shows current versions', ['uncached-true', 'uncached-false']],
  ['cancel restores opening latest/update text for every row', ['newer', 'older', 'uncached-true', 'uncached-false']],
]) test('W317 AI text: ' + name, () => {
  const output = nativeW298a();
  for (const scenario of scenarios) {
    assert.ok(output.includes(`W298A PASS W315 ${scenario} page versionLine`));
    assert.ok(output.includes(`W298A PASS W317 ${scenario} cancel restores opening text`));
  }
});

test('W317 busy Installed on returning from plugin details preserves the timeout reason', async () => {
  let readDetail = false;
  const w = installedPage(undefined, { narrow: true, onSettings() { readDetail = true; } });
  const navigate = w.pod.pageState.onNavigate;
  w.pod.pageState.onNavigate = path => {
    navigate(path);
    if (path === '/plugins' && readDetail) region(w).setAttribute('aria-busy', 'true');
  };
  const got = await scan(w);
  assert.equal(got.listKnown, false);
  assert.match(got.failure, /Installed 載入逾時）；busy:\[aria-busy="true"\]/);
  assert.equal(got.failure.includes(connector().name), false); assert.equal(w.clicks.create, 0);
});
