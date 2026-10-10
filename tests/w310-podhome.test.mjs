import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture, h, queryAll } from './w185-pod-fixture.mjs';
import { installedPage, MCP } from './fixtures/w304b-installed-sidebar.mjs';
import { nativeW298a } from './fixtures/w298a-native.mjs';

test('W310 scan leaves settings for /plugins Installed before reading', async () => {
  const w = installedPage();
  for (const child of [...w.pod.body._kids]) child.remove();
  w.pod.pageState.pathname = '/settings/plugins-settings';
  const routes = [], previous = w.pod.pageState.onNavigate;
  w.pod.pageState.onNavigate = path => { routes.push(path); previous(path); };
  await w.pod.signIn();
  const scan = (await w.pod.command({ cmd: 'connectorScan', url: MCP }, 24000)).data;
  assert.equal(routes[0], '/plugins');
  assert.equal(scan.listKnown, true); assert.equal(scan.matches.length, 1);
  assert.equal(w.clicks.create, 0);
});

test('W310 multiple Installed rows never fall back to the empty Settings list between detail reads', async () => {
  const w = installedPage(undefined, { onSettings(pod) {
    queryAll(pod.body, 'a').find(a => a.textContent === 'Plugin settings').onclick = () => {
      for (const child of [...pod.body._kids]) child.remove();
      pod.pageState.pathname = '/settings/plugins-settings';
      pod.body.appendChild(h('div', { role: 'group' }, h('button', {}, 'General'), h('button', {}, 'Plugins'),
        h('div', {}, h('p', {}, 'Manage your plugins, connected accounts, and permissions'),
          h('input', { placeholder: 'Search installed plugins' }), h('p', {}, 'No plugins installed'))));
    };
  } });
  w.items.push({ ...w.items[0], id: 'asdk_app_second', name: 'TATWO（Mac mini）5' }); w.render();
  await w.pod.signIn();
  const scan = (await w.pod.command({ cmd: 'connectorScan', url: MCP }, 24000)).data;
  assert.equal(scan.listKnown, true); assert.equal(scan.matches.length, 2);
  assert.equal(w.pod.pageState.pathname, '/plugins'); assert.equal(w.clicks.create, 0);
});

async function modelPage(preservePage = false, cmd = 'models', pageBusy = false) {
  const p = fixture({ allowNetwork: true, respond: async url => {
    if (url.includes('/backend-api/models')) assert.equal(p.sandbox.location.pathname, '/');
    return new Response(JSON.stringify(url.includes('/backend-api/models') ? { models: [{ slug: 'web-model', title: 'Web Model' }] } : {}), { headers: { 'content-type': 'application/json' } });
  } });
  await p.sandbox.fetch('/backend-api/me', { headers: { authorization: 'Bearer synthetic-only' } });
  p.sandbox.location.pathname = '/settings/plugins-settings';
  p.sandbox.onNavigate = () => {
    const trigger = new p.Element('button', { 'data-testid': 'model-switcher-dropdown-button', 'data-model-slug': 'web-model', 'aria-expanded': 'false', 'aria-controls': 'model-panel' });
    trigger.textContent = 'Web Model';
    const panel = new p.Element('div', { role: 'menu', id: 'model-panel' });
    const item = new p.Element('button', { role: 'menuitem', 'data-model-slug': 'web-model' }, panel); item.textContent = 'Web Model';
    trigger.onClick = () => { trigger.attrs['aria-expanded'] = trigger.attrs['aria-expanded'] === 'true' ? 'false' : 'true'; };
  };
  p.command({ cmd, id: 'home-read', preservePage, pageBusy, text: 'synthetic-only' });
  await p.advance(8000);
  return p;
}
test('W310 models() returns home before reading the real page selector', async () => {
  const p = await modelPage();
  const result = p.reports.find(r => r.type === 'result' && r.id === 'home-read');
  assert.equal(result?.ok, true, JSON.stringify(p.reports));
  assert.deepEqual(p.navigations, ['/']); assert.equal(result.data.models[0].title, 'Web Model');
  assert.equal(p.button.clicks, 0);
});
for (const cmd of ['models', 'send']) test('W310 shared Space refuses navigation with a prompt: ' + cmd, async () => {
  const p = await modelPage(true, cmd);
  assert.deepEqual(p.navigations, []); assert.equal(p.sandbox.location.pathname, '/settings/plugins-settings');
  assert.match(JSON.stringify(p.reports), /ChatGPT Space 正在使用這一頁/); assert.equal(p.button.clicks, 0);
});
test('W310 send from settings returns home before preparing a conversation', async () => {
  const p = await modelPage(false, 'send');
  assert.equal(p.navigations[0], '/');
});
test('W310 models cannot navigate away from an active connector operation', async () => {
  const p = await modelPage(false, 'models', true);
  assert.deepEqual(p.navigations, []);
  assert.match(JSON.stringify(p.reports), /ChatGPT 正在操作這一頁/);
  assert.equal(p.button.clicks, 0);
});
test('W310 native lifecycle restores success/failure/cancel, protects Space, merges Claude and fixes graph words', () => {
  const output = nativeW298a();
  assert.ok(output.includes('W298A PASS W310 model read during connector hold marks navigation busy and restores viewport'));
  for (const outcome of ['success', 'failure', 'cancel']) {
    assert.ok(output.includes(`W298A PASS W310 connector ${outcome} returns home before release`));
    assert.ok(output.includes(`W298A PASS W310 failed script home uses native restore ${outcome}`));
    assert.ok(output.includes(`W298A PASS W310 shared Space URL stays unchanged ${outcome}`));
  }
  for (const label of ['Claude second catalog excludes six old IDs', 'menu sources retain Claude engine only', 'graph node words agree with connection state']) assert.ok(output.includes('W298A PASS W310 ' + label));
});
