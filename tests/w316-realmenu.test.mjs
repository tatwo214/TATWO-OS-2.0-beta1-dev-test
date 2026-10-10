import test from 'node:test';
import assert from 'node:assert/strict';
import { realComposerPage } from './fixtures/w316-realmenu.mjs';
import { readCatalog, labels } from './fixtures/w312-composer-picker.mjs';
import { installedPage, MCP, connector } from './fixtures/w304b-installed-sidebar.mjs';
import { h, queryAll } from './w185-pod-fixture.mjs';
const bodyOf = p => JSON.parse(p.requests.find(r => r.url.includes('/f/conversation')).init.body);
const closed = p => { assert.equal(p.menu.attrs['aria-hidden'], 'true'); assert.equal(p.trigger.attrs['aria-expanded'], 'false'); };
for (const checked of ['aria-checked', 'data-state']) test('W316 same container catalog reads checked model and five Power steps: ' + checked, async () => {
  const p = await realComposerPage({ checked }), result = await readCatalog(p);
  assert.equal(result?.ok, true, JSON.stringify(p.reports));
  assert.deepEqual(result.data.models.map(m => [m.slug, m.title]), [['sol', 'GPT-5.6 Sol'], ['five', 'GPT-5.5']]);
  assert.equal(result.data.models[1].description, 'Leaving on October 14');
  assert.equal(result.data.versions[0].title, 'GPT-6');
  assert.deepEqual(result.data.versions[0].presets.map(x => x.title), labels);
  assert.equal(result.data.current.preset, 'six-t|standard');
  assert.deepEqual(p.modelClicks, []); assert.equal(p.button.clicks, 0); closed(p);
  assert.equal(p.menu.querySelectorAll('[role="slider"], input[type="range"]').length, 0);
});
test('W346 role-less model panel still reads the catalog and closes', async () => {
  const p = await realComposerPage({ roleless: true }), result = await readCatalog(p);
  assert.equal(result?.ok, true, JSON.stringify(p.reports));
  assert.deepEqual(result.data.models.map(m => m.slug), ['sol', 'five']);
  assert.equal(result.data.current.preset, 'six-t|standard'); closed(p);
  p.send({ model: 'five' }); await p.advance(8000);
  assert.deepEqual(p.modelClicks, ['GPT-5.5']); assert.equal(bodyOf(p).model, 'five'); closed(p);
});
for (const options of [{ roleless: true, fadedIn: true }, { roleless: true, clickToggles: true }, { lateContent: true }, { roleless: true, lateContent: true }]) test('W346b model panel opens and reads despite ' + Object.keys(options).join('+'), async () => {
  const p = await realComposerPage(options); p.command({ cmd: 'models', id: 'W346b' }); await p.advance(12000);
  const result = p.reports.find(r => r.type === 'result' && r.id === 'W346b');
  assert.equal(result?.ok, true, JSON.stringify(p.reports));
  assert.deepEqual(result.data.models.map(m => m.slug), ['sol', 'five']); closed(p);
});
test('W346b unreadable panel leaves a shape diagnostic', async () => {
  const p = await realComposerPage({ roleless: true }); p.trigger.onClick = () => {};
  assert.equal((await readCatalog(p)).ok, false);
  p.command({ cmd: 'diagnostics', id: 'diag' }); await p.advance(100);
  assert.match(p.reports.find(r => r.id === 'diag').data['模型選單'], /^expanded=false controls=no owned=none panels=0 items=/);
});
for (const [preset, keys, level, model, effort] of [
  ['six-p', ['ArrowRight', 'ArrowRight', 'ArrowRight'], 5, 'six-p'],
  ['six-i', ['ArrowLeft'], 1, 'six-i'],
  ['six-t|standard', [], 2, 'six-t', 'standard'],
  ['six-t|extended', ['ArrowRight'], 3, 'six-t', 'extended'],
]) test('W316 Power waits after every arrow and uses the W297 mapping: ' + preset, async () => {
  const p = await realComposerPage(); p.send({ effort: preset }); await p.advance(8000);
  assert.deepEqual(p.powerKeys, keys); assert.equal(p.level, level); assert.equal(p.hiddenPowerKeys, 0);
  assert.equal(p.button.clicks, 1); assert.equal(bodyOf(p).model, model); assert.equal(bodyOf(p).thinking_effort, effort); closed(p);
});
for (const [model, clicks] of [['five', ['GPT-5.5']], ['six-t', []]]) test('W316 send switches models unless already checked: ' + model, async () => {
  const p = await realComposerPage(); p.send({ model }); await p.advance(8000);
  assert.deepEqual(p.modelClicks, clicks); assert.equal(p.button.clicks, 1); assert.equal(bodyOf(p).model, model); closed(p);
});
for (const [label, mutate] of [
  ['description reference', p => { p.items[1].attrs['aria-describedby'] = '_r_tp_'; }],
  ['aria-disabled', p => { p.items[1].attrs['aria-disabled'] = 'true'; }],
  ['data-disabled', p => { p.items[1].attrs['data-disabled'] = ''; }],
  ['lock icon', p => { new p.Element('svg', { 'aria-label': 'Locked' }, p.items[1]); }],
  ['highlighted live announcement', p => { p.items[1].attrs['data-highlighted'] = ''; }],
  ['focused live announcement', p => { p.doc.activeElement = p.items[1]; }],
]) test('W316 locking is limited to the item: ' + label, async () => {
  const p = await realComposerPage(); mutate(p); const result = await readCatalog(p);
  assert.equal(result.ok, true); assert.deepEqual(result.data.models.map(m => m.slug), ['five']);
  assert.equal(result.data.versions[0].title, 'GPT-6'); closed(p);
  p.send({ model: 'sol' }); await p.advance(8000); assert.deepEqual(p.modelClicks, []);
  assert.equal(p.button.clicks, 1); assert.equal(bodyOf(p).model, 'sol'); closed(p);
});
for (const status of ['Medium', 'Medium, 0 of 5.', 'Medium, 6 of 5.', 'Medium, 2 of 21.']) test('W316 unreadable Power fails the catalog and send records fallback: ' + status, async () => {
  const p = await realComposerPage(); p.status.textContent = status;
  assert.equal((await readCatalog(p)).ok, false); closed(p);
  p.send({ effort: 'six-t|extended' }); await p.advance(8000);
  assert.equal(p.button.clicks, 1); assert.equal(bodyOf(p).thinking_effort, 'extended'); closed(p);
  p.command({ cmd: 'diagnostics', id: 'diag' }); await p.advance(100);
  assert.match(p.reports.find(r => r.id === 'diag').data['送出選模型失敗'], /Power/);
});
for (const mode of ['ignored', 'wrong step', 'wrong count']) test('W316 failed Power update throws and send records fallback: ' + mode, async () => {
  const p = await realComposerPage();
  p.power.dispatchEvent = () => { if (mode !== 'ignored') p.status.textContent = mode === 'wrong step' ? 'Pro, 5 of 5.' : 'High, 3 of 4.'; };
  p.send({ effort: 'six-t|extended' }); await p.advance(8000);
  assert.equal(p.button.clicks, 1); assert.equal(bodyOf(p).model, 'six-t'); assert.equal(bodyOf(p).thinking_effort, 'extended'); closed(p);
  p.command({ cmd: 'diagnostics', id: 'diag' }); await p.advance(100);
  assert.match(p.reports.find(r => r.id === 'diag').data['送出選模型失敗'], /網頁模型選單已變更/);
});
test('W316 submenu that never replaces its contents fails safely', async () => {
  const p = await realComposerPage({ brokenSub: true }); assert.equal((await readCatalog(p)).ok, false); closed(p);
  assert.equal(p.button.clicks, 0); assert.deepEqual(p.modelClicks, []);
});
for (const items of [[connector()], []]) test('W316 narrow Installed without search/toggle proves rows including empty list: ' + items.length, async () => {
  const w = installedPage(items, { narrow: true });
  Object.defineProperty(w.pod.sandbox, 'innerWidth', { get: () => 1100 });
  Object.defineProperty(w.pod.sandbox, 'innerHeight', { get: () => 800 });
  const catalog = queryAll(w.pod.body, 'main')[0];
  while (queryAll(w.pod.body, 'button').length < 137) catalog.appendChild(h('button', {}, 'Install catalogue item'));
  assert.equal(queryAll(w.pod.body, 'button').length, 137);
  assert.equal(queryAll(w.pod.body, 'h1')[0].textContent, 'Customize');
  assert.equal(queryAll(w.pod.body, 'button').some(b => ['Toggle sidebar', 'Search installed plugins'].includes(b.getAttribute('aria-label'))), false);
  await w.pod.signIn(); const got = (await w.pod.command({ cmd: 'connectorScan', url: MCP }, 24000)).data;
  assert.equal(got.listKnown, true); assert.equal(got.matches.length, items.length); assert.equal(w.clicks.create, 0);
  if (items.length) {
    assert.equal((await w.pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: got.matches[0].id })).data.status, 'pressed');
    assert.deepEqual(w.clicks.reconnect, [connector().id]);
  }
});
for (const missing of ['Customize', 'Plugins', 'Skills', 'Installed']) test('W316 narrow Installed missing required marker stops: ' + missing, async () => {
  const w = installedPage(undefined, { narrow: true }), render = w.render;
  const incomplete = () => { render(); queryAll(w.pod.body, 'h1, a, div').filter(n => n.textContent === missing).forEach(n => n.remove()); };
  w.pod.pageState.onNavigate = incomplete; incomplete(); await w.pod.signIn();
  const got = (await w.pod.command({ cmd: 'connectorScan', url: MCP }, 24000)).data;
  assert.equal(got.listKnown, false); assert.equal(w.clicks.create, 0);
});
test('W316 the checked submenu model overrides a misleading trigger caption', async () => {
  const p = await realComposerPage({ selected: 'GPT-5.6 Sol' }); p.trigger.textContent = 'GPT-6';
  const result = await readCatalog(p); assert.equal(result.ok, true);
  assert.equal(result.data.versions[0].title, 'GPT-5.6 Sol');
  assert.deepEqual(result.data.versions[0].presets.map(x => x.id), [1, 2, 3, 4, 5].map(i => 'web-power|' + i)); closed(p);
});
for (const ambiguous of [false, true]) test('W316 missing or ambiguous checked item fails: ' + ambiguous, async () => {
  const p = await realComposerPage();
  p.items[ambiguous ? 1 : 0].attrs['aria-checked'] = String(ambiguous);
  assert.equal((await readCatalog(p)).ok, false); assert.equal(p.button.clicks, 0); closed(p);
});
test('W316 the slider remains supported when its parent has the Power label', async () => {
  const { composerPage } = await import('./fixtures/w312-composer-picker.mjs');
  const p = await composerPage(); p.slider.parentElement.attrs['aria-label'] = 'Power';
  assert.equal((await readCatalog(p)).ok, true);
  p.send({ effort: 'six-t|extended' }); await p.advance(8000);
  assert.equal(p.slider.attrs['aria-valuenow'], '3'); assert.equal(bodyOf(p).thinking_effort, 'extended'); closed(p);
});

for (const mode of ['ignored', 'unreadable', 'missing trigger']) test('W350 failed web-power does not send: ' + mode, async () => {
  const p = await realComposerPage();
  if (mode === 'ignored') p.power.dispatchEvent = () => {};
  if (mode === 'unreadable') p.status.textContent = 'Medium';
  if (mode === 'missing trigger') delete p.trigger.attrs['data-testid'];
  p.send({ effort: 'web-power|5' }); await p.advance(12000);
  assert.equal(p.button.clicks, 0);
  assert.equal(p.requests.some(r => r.url.includes('/f/conversation')), false);
  assert.equal(p.reports.find(r => r.kind === 'failed')?.message, 'Power 段數未能設定，這句未送出');
});

test('W350 known connector skips four foreign settings within deadline', async () => {
  const own = connector(), items = ['Drive', 'Slack', 'GitHub', 'Calendar'].map((name, i) => ({ ...own, id: 'foreign_' + i, name }));
  const opened = [];
  const w = installedPage([...items, own], { onOverview(pod) {
    opened.push(pod.pageState.pathname);
  } });
  await w.pod.signIn();
  const result = await w.pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: own.id }, 12000);
  assert.equal(result.data.status, 'pressed');
  assert.equal(opened.length, 1);
  assert.equal(w.octoberClicks.manage, 1);
  assert.deepEqual(w.clicks.reconnect, [own.id]);
});
