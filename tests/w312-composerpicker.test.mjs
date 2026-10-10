import test from 'node:test';
import assert from 'node:assert/strict';
import { composerPage, readCatalog, labels } from './fixtures/w312-composer-picker.mjs';
import { installedPage, MCP } from './fixtures/w304b-installed-sidebar.mjs';
import { h, queryAll } from './w185-pod-fixture.mjs';

for (const label of ['Select ChatGPT model', '選擇 ChatGPT 模型', '选择 ChatGPT 模型', '選取模型'])
  test('W312 composer submenu reads selected model, Power and leaving description: ' + label, async () => {
    const p = await composerPage({ label });
    // A matching label outside the composer and an obsolete header never win.
    new p.Element('button', { 'aria-label': label });
    const stale = new p.Element('button', { 'data-testid': 'model-switcher-dropdown-button' }); stale.textContent = 'Stale';
    const result = await readCatalog(p);
    assert.equal(result?.ok, true, JSON.stringify(p.reports));
    assert.deepEqual(result.data.models.map(m => [m.slug, m.title]), [['sol', 'GPT-5.6 Sol'], ['five', 'GPT-5.5']]);
    assert.equal(result.data.models[1].description, 'Leaving on October 14');
    assert.equal(result.data.versions[0].title, 'GPT-6');
    assert.deepEqual(result.data.versions[0].presets.map(x => x.title), labels);
    assert.equal(result.data.current.preset, 'six-t|standard', 'web selection wins over stale settings');
    assert.equal(p.trigger.attrs['aria-expanded'], 'false'); assert.equal(p.sub.attrs['aria-hidden'], 'true');
    assert.equal(stale.clicks, 0); assert.equal(p.button.clicks, 0); assert.equal(p.accessClicks, 0);
  });

test('W312 an accessible GPT-6 item stays in the same W297 version and Power mapping', async () => {
  const p = await composerPage({ locked: false });
  const result = await readCatalog(p);
  assert.equal(result.ok, true); assert.equal(result.data.versions.length, 1);
  assert.deepEqual(result.data.models.map(x => x.slug), ['sol', 'five']);
});
test('W312 send switches models through the composer submenu and closes it', async () => {
  const p = await composerPage(); p.send({ model: 'five' }); await p.advance(8000);
  assert.deepEqual(p.modelClicks, ['GPT-5.5']); assert.equal(p.button.clicks, 1, JSON.stringify(p.reports));
  assert.equal(p.trigger.attrs['aria-expanded'], 'false'); assert.equal(p.accessClicks, 0);
  assert.equal(JSON.parse(p.requests.find(r => r.url.includes('/f/conversation')).init.body).model, 'five');
});
test('W312 send changes Power through the same menu and keeps the W297 slug/effort', async () => {
  const p = await composerPage(); p.send({ effort: 'six-t|extended' }); await p.advance(8000);
  assert.equal(p.slider.attrs['aria-valuenow'], '3'); assert.equal(p.button.clicks, 1, JSON.stringify(p.reports));
  const body = JSON.parse(p.requests.find(r => r.url.includes('/f/conversation')).init.body);
  assert.equal(body.model, 'six-t'); assert.equal(body.thinking_effort, 'extended');
  assert.equal(p.trigger.attrs['aria-expanded'], 'false'); assert.equal(p.accessClicks, 0);
});
test('W312 a locked model uses request overrides without opening access options', async () => {
  const p = await composerPage({ selected: 'GPT-5.6 Sol' }); p.send({ effort: 'six-t|extended' }); await p.advance(8000);
  assert.equal(p.button.clicks, 1); assert.equal(p.accessClicks, 0); assert.equal(p.trigger.attrs['aria-expanded'], 'false');
  const body = JSON.parse(p.requests.find(r => r.url.includes('/f/conversation')).init.body);
  assert.equal(body.model, 'six-t'); assert.equal(body.thinking_effort, 'extended');
});
for (const mutate of [p => { for (const n of p.items) n.attrs['aria-checked'] = 'false'; },
  p => { p.select.onClick = () => {}; }, p => { p.slider.attrs['aria-valuenow'] = '?'; }])
  test('W312 unreadable submenu/selection/Power closes the menu without submission', async () => {
    const p = await composerPage(); mutate(p); assert.equal((await readCatalog(p)).ok, false);
    assert.equal(p.trigger.attrs['aria-expanded'], 'false'); assert.equal(p.sub.attrs['aria-hidden'], 'true');
    assert.equal(p.button.clicks, 0); assert.equal(p.accessClicks, 0);
  });

function delayedInstalled(delay, options = {}) {
  const w = installedPage(undefined, options), { pod } = w;
  const render = w.render, previous = pod.pageState.onNavigate;
  pod.pageState.onNavigate = path => {
    if (path !== '/plugins') return previous(path);
    for (const n of [...pod.body._kids]) n.remove();
    pod.body.appendChild(h('main', {}, ...Array.from({ length: 9 }, () => h('button', {}, 'Loading'))));
    setTimeout(render, delay);
  };
  for (const n of [...pod.body._kids]) n.remove();
  pod.pageState.pathname = '/settings/plugins-settings';
  return w;
}
test('W312 scan waits for Installed beyond the old 1.5s and waits for stable buttons', async () => {
  const w = delayedInstalled(1900); await w.pod.signIn();
  let unstableAt = 0;
  const timer = setTimeout(() => { unstableAt = Date.now(); w.pod.body.appendChild(h('button', {}, 'Loaded')); }, 2150);
  const started = Date.now(), result = (await w.pod.command({ cmd: 'connectorScan', url: MCP }, 24000)).data;
  clearTimeout(timer);
  assert.equal(result.listKnown, true); assert.equal(result.matches.length, 1);
  assert.ok(Date.now() - started >= 2600); assert.ok(unstableAt > 0);
  assert.equal(w.clicks.create, 0);
});
test('W312 partial Installed with loading indication waits until its rows are ready', async () => {
  const options = { busy: true }, w = installedPage(undefined, options);
  await w.pod.signIn(); setTimeout(() => { options.busy = false; queryAll(w.pod.body, '[aria-busy="true"]').forEach(n => n.remove()); }, 900);
  const result = (await w.pod.command({ cmd: 'connectorScan', url: MCP }, 24000)).data;
  assert.equal(result.listKnown, true); assert.equal(result.matches.length, 1); assert.equal(w.clicks.create, 0);
});
test('W312 missing Installed times out safely without creating', async () => {
  const w = installedPage(undefined, { missingInstalled: true }); await w.pod.signIn();
  const started = Date.now(), result = (await w.pod.command({ cmd: 'connectorScan', url: MCP }, 24000)).data;
  assert.equal(result.listKnown, false); assert.match(result.failure, /清單未完整載入/);
  assert.ok(Date.now() - started >= 7900); assert.equal(w.clicks.create, 0);
});
test('W312 a menu already open before reading is closed afterwards', async () => {
  const p = await composerPage(); p.trigger.onClick();
  assert.equal((await readCatalog(p)).ok, true);
  assert.equal(p.trigger.attrs['aria-expanded'], 'false'); assert.equal(p.sub.attrs['aria-hidden'], 'true');
});
test('W312 another selected model never inherits GPT-6 backend Power slugs', async () => {
  const p = await composerPage({ selected: 'GPT-5.6 Sol' });
  const result = await readCatalog(p); assert.equal(result.ok, true);
  assert.equal(result.data.versions[0].title, 'GPT-5.6 Sol');
  assert.deepEqual(result.data.versions[0].presets.map(x => x.id), [1, 2, 3, 4, 5].map(i => 'web-power|' + i));
  p.send({ effort: 'web-power|3' }); await p.advance(8000);
  assert.equal(p.button.clicks, 1); assert.equal(p.slider.attrs['aria-valuenow'], '3');
  assert.equal(JSON.parse(p.requests.find(r => r.url.includes('/f/conversation')).init.body).model, 'sol');
});
test('W312 a nine-button skeleton without Installed stops after eight seconds', async () => {
  const w = installedPage(), { pod } = w;
  const loading = () => { for (const n of [...pod.body._kids]) n.remove(); pod.body.appendChild(h('main', {}, ...Array.from({ length: 9 }, () => h('button', {}, 'Loading')))); };
  pod.pageState.onNavigate = loading; pod.pageState.pathname = '/plugins'; loading();
  await pod.signIn(); const started = Date.now();
  const result = (await pod.command({ cmd: 'connectorScan', url: MCP }, 12000)).data;
  assert.equal(result.listKnown, false); assert.match(result.failure, /Installed 載入逾時/);
  assert.ok(Date.now() - started < 9500); assert.equal(w.clicks.create, 0);
});
test('W312 Installed with sidebar buttons that never stabilise times out without judging it empty', async () => {
  const w = installedPage([]); await w.pod.signIn();
  const timer = setInterval(() => w.pod.body._kids[0]._kids[0].appendChild(h('button', {}, '')), 120);
  try {
    const result = (await w.pod.command({ cmd: 'connectorScan', url: MCP }, 12000)).data;
    assert.equal(result.listKnown, false); assert.match(result.failure, /Installed 載入逾時）；unstable:\d+→\d+/); assert.equal(w.clicks.create, 0);
  } finally { clearInterval(timer); }
});
test('W312 stop while the model submenu loads cannot switch a model or submit', async () => {
  const p = await composerPage();
  p.select.onClick = () => { p.later(240, () => { p.sub.attrs['aria-hidden'] = 'false'; }); p.later(120, () => p.command({ cmd: 'stop', id: 'W312-stop', requestID: 'S' })); };
  p.send({ model: 'five' }); await p.advance(8000);
  assert.deepEqual(p.modelClicks, []); assert.equal(p.accessClicks, 0); assert.equal(p.button.clicks, 0);
  assert.equal(p.trigger.attrs['aria-expanded'], 'false');
});
test('W312 ambiguous checked items cannot supply the current model name', async () => {
  const p = await composerPage(); p.items[1].attrs['aria-checked'] = 'true';
  assert.equal((await readCatalog(p)).ok, false); assert.equal(p.trigger.attrs['aria-expanded'], 'false');
  assert.equal(p.button.clicks, 0);
});
test('W312 an ignored model click falls back to request rewriting and submission', async () => {
  const p = await composerPage(); p.items[2].onClick = () => {};
  p.send({ model: 'five' }); await p.advance(8000);
  assert.equal(p.button.clicks, 1); assert.equal(p.trigger.attrs['aria-expanded'], 'false');
  assert.equal(JSON.parse(p.requests.find(r => r.url.includes('/f/conversation')).init.body).model, 'five');
});
test('W312 stop while an existing conversation opens the submenu cannot switch its model', async () => {
  const p = await composerPage(), conversationID = '11111111-1111-4111-8111-111111111111';
  await readCatalog(p);
  p.command({ cmd: 'get', id: 'W312-cached-chat', conversationID }); await p.advance(200);
  assert.equal(p.reports.find(r => r.id === 'W312-cached-chat').ok, true);
  p.sandbox.location.pathname = '/c/' + conversationID;
  new p.Element('div', { 'data-message-author-role': 'assistant' });
  p.select.onClick = () => { p.later(240, () => { p.sub.attrs['aria-hidden'] = 'false'; }); p.later(120, () => p.command({ cmd: 'stop', id: 'W312-stop-old', requestID: 'S' })); };
  p.send({ model: 'five', conversationID }); await p.advance(8000);
  assert.ok(p.select.clicks >= 2, 'the existing conversation reaches the requested model submenu');
  assert.deepEqual(p.modelClicks, []); assert.equal(p.button.clicks, 0); assert.equal(p.trigger.attrs['aria-expanded'], 'false');
});
for (const [preset, value] of [['six-i', '1'], ['six-p', '5']])
  test('W312 Power presets without an effort suffix still move the slider: ' + preset, async () => {
    const p = await composerPage(); p.send({ effort: preset }); await p.advance(8000);
    assert.equal(p.slider.attrs['aria-valuenow'], value);
    assert.equal(p.button.clicks, 1); assert.equal(p.accessClicks, 0); assert.equal(p.trigger.attrs['aria-expanded'], 'false');
    const body = JSON.parse(p.requests.find(r => r.url.includes('/f/conversation')).init.body);
    assert.equal(body.model, preset); assert.equal(body.thinking_effort, undefined);
  });
test('W312 a composer caption showing Power reads the model from its checked submenu item', async () => {
  const p = await composerPage({ text: 'Medium' }), result = await readCatalog(p);
  assert.equal(result.ok, true); assert.equal(result.data.versions[0].title, 'GPT-6');
  assert.equal(result.data.current.preset, 'six-t|standard'); assert.equal(p.trigger.attrs['aria-expanded'], 'false');
});
test('W312 a Power caption can update while switching intensity without changing model identity', async () => {
  const p = await composerPage({ text: 'Medium' }), previous = p.slider.dispatchEvent;
  p.slider.dispatchEvent = event => { previous(event); p.trigger.textContent = p.slider.attrs['aria-valuetext'].split(',')[0]; };
  p.send({ effort: 'six-t|extended' }); await p.advance(8000);
  assert.equal(p.trigger.textContent, 'High'); assert.equal(p.button.clicks, 1, JSON.stringify(p.reports));
  assert.equal(p.trigger.attrs['aria-expanded'], 'false');
});

for (const arrowLeftClosesRoot of [false, true])
  test('W312 Power succeeds when Escape would close the root; ArrowLeft closes root=' + arrowLeftClosesRoot, async () => {
    const p = await composerPage({ arrowLeftClosesRoot });
    // Reproduce the Radix Escape behavior before testing the send path.
    p.trigger.click(); p.select.click(); p.doc.dispatchEvent({ key: 'Escape' });
    assert.equal(p.menu.attrs['aria-hidden'], 'true'); p.escapeKeys = 0;
    p.send({ effort: 'six-t|extended' }); await p.advance(8000);
    assert.equal(p.slider.attrs['aria-valuenow'], '3'); assert.equal(p.hiddenPowerKeys, 0);
    assert.equal(p.button.clicks, 1); assert.equal(p.escapeKeys, 0);
    assert.equal(p.menu.attrs['aria-hidden'], 'true'); assert.equal(p.sub.attrs['aria-hidden'], 'true');
    assert.equal(p.select.clicks, 2, 'reopening the root does not reopen the submenu');
  });

for (const alreadyOpen of [false, true])
for (const controls of [false, true])
  test('W312 missing aria-expanded closes the catalog, already open=' + alreadyOpen + ', aria-controls=' + controls, async () => {
    const p = await composerPage({ expanded: false }); if (alreadyOpen) p.trigger.click();
    if (!controls) delete p.trigger.attrs['aria-controls'];
    assert.equal((await readCatalog(p)).ok, true);
    assert.equal(p.trigger.getAttribute('aria-expanded'), null);
    assert.equal(p.menu.attrs['aria-hidden'], 'true'); assert.equal(p.sub.attrs['aria-hidden'], 'true');
  });

test('W312 reopens only the root when closing the submenu hides Power', async () => {
  const p = await composerPage(), closeSub = p.sub.dispatchEvent, toggleRoot = p.trigger.onClick;
  p.sub.dispatchEvent = event => { closeSub(event); if (event.key === 'ArrowLeft') p.slider.hidden = true; };
  p.trigger.onClick = () => { toggleRoot(); if (p.menu.attrs['aria-hidden'] === 'false') p.slider.hidden = false; };
  p.send({ effort: 'six-t|extended' }); await p.advance(8000);
  assert.equal(p.slider.attrs['aria-valuenow'], '3'); assert.equal(p.hiddenPowerKeys, 0);
  assert.equal(p.button.clicks, 1); assert.equal(p.select.clicks, 1);
  assert.equal(p.menu.attrs['aria-hidden'], 'true'); assert.equal(p.escapeKeys, 0);
});

test('W312 missing aria-expanded never reopens a menu closed after a model change', async () => {
  const p = await composerPage({ expanded: false }); p.send({ model: 'five' }); await p.advance(8000);
  assert.equal(p.button.clicks, 1); assert.equal(p.menu.attrs['aria-hidden'], 'true');
  assert.equal(p.sub.attrs['aria-hidden'], 'true'); assert.equal(p.trigger.clicks, 3);
});

for (const [reason, options, mutate, request, model, effort] of [
  ['backend read', { backendFailure: true }, () => {}, { model: 'five' }, 'five'],
  ['submenu read', { brokenSub: true }, () => {}, { model: 'five' }, 'five'],
  ['selected model read', {}, p => p.items.forEach(n => n.attrs['aria-checked'] = 'false'), { model: 'five' }, 'five'],
  ['missing model', {}, () => {}, { model: 'pending-only' }, 'pending-only'],
  ['Power read', {}, p => p.slider.attrs['aria-valuenow'] = '?', { effort: 'six-t|extended' }, 'six-t', 'extended'],
  ['Power update', {}, p => p.slider.dispatchEvent = () => {}, { effort: 'six-t|extended' }, 'six-t', 'extended'],
  ['missing aria-expanded submenu read', { expanded: false, brokenSub: true }, () => {}, { model: 'five' }, 'five'],
]) test('W312 send falls back with a diagnostic after ' + reason + ' failure', async () => {
  const p = await composerPage(options); mutate(p); p.send(request); await p.advance(8000);
  assert.equal(p.button.clicks, 1, JSON.stringify(p.reports)); assert.equal(p.accessClicks, 0);
  const body = JSON.parse(p.requests.find(r => r.url.includes('/f/conversation')).init.body);
  assert.equal(body.model, model); assert.equal(body.thinking_effort, effort);
  assert.equal(p.menu.attrs['aria-hidden'], 'true'); assert.equal(p.sub.attrs['aria-hidden'], 'true');
  p.command({ cmd: 'diagnostics', id: 'W312-fallback' }); await p.advance(100);
  const diag = p.reports.find(r => r.id === 'W312-fallback').data;
  assert.match('送出選模型失敗：' + diag['送出選模型失敗'], /^送出選模型失敗：.+/);
  assert.notEqual(diag['送出選模型失敗'], undefined);
});
