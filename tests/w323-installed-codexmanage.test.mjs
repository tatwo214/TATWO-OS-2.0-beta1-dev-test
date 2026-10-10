import test from 'node:test';
import assert from 'node:assert/strict';
import { codexInstalledPage, installedRows, MCP } from './fixtures/w323-installed-codexmanage.mjs';
import { queryAll } from './w185-pod-fixture.mjs';
const scan = async w => { await w.pod.signIn(); return (await w.pod.command({ cmd: 'connectorScan', url: MCP }, 24000)).data; };
const safe = w => {
  assert.equal(w.clicks.create, 0); assert.deepEqual(w.clicks.delete, []);
  assert.deepEqual(w.octoberClicks.forbidden, []);
  assert.equal(JSON.stringify(w.pod.reports).includes('Synthetic Account'), false);
};

for (const absolute of [true, false]) test('W323 all 26 Installed rows accept both Codex Manage shapes and find both TATWO connectors: absolute=' + absolute, async () => {
  const items = installedRows(), w = codexInstalledPage({ absolute, items });
  const region = w.pod.body._kids[0]._kids[1];
  assert.equal(items.length, 26); assert.equal(items[13].name, 'Codex Security');
  for (const name of ['Codex Security', 'Build iOS Apps']) {
    const i = items.findIndex(x => x.name === name), manage = queryAll(region._kids[i + 1], 'a')[1];
    assert.equal(manage.getAttribute('aria-label'), 'Manage ' + name);
    assert.equal(manage.getAttribute('href'), 'https://chatgpt.com/codex/open-app?target=plugin&plugin_id=' + items[i].path.slice(9));
  }
  const got = await scan(w);
  assert.equal(got.listKnown, true, got.failure); assert.equal(got.failure, null);
  assert.deepEqual(got.candidates, items.map((x, i) => ({ name: x.name, verdict: i < 2 ? '相符' : '讀不到' })));
  assert.deepEqual(got.matches.map(x => [x.id, x.name, x.detailPath]), items.slice(0, 2).map(x =>
    [x.id, x.name, '/settings/plugins-settings/' + x.path.slice(9)]));
  assert.equal(w.installedClicks.names, 0); assert.equal(w.installedClicks.manage, 2);
  assert.deepEqual(w.installedClicks.paths, got.matches.map(x => x.detailPath)); safe(w);
});

for (const href of ['/other', '/codex/open-app?target=plugin&plugin_id=unrelated', 'https://foreign.invalid/other', ''])
  test('W323 exact Manage label accepts other URL shapes without opening them: ' + href, async () => {
    const w = codexInstalledPage({ mutate(_region, links) {
      queryAll(links[13].parentElement, 'a')[1].setAttribute('href', href);
    } });
    const got = await scan(w);
    assert.equal(got.listKnown, true, got.failure); assert.equal(got.matches.length, 2); safe(w);
  });

test('W323 a non-settings Manage URL leaves no settings route and reads the name link instead', async () => {
  const items = installedRows();
  const w = codexInstalledPage({ items, mutate(_region, links) {
    links.slice(0, 2).forEach((link, i) => {
      const manage = queryAll(link.parentElement, 'a')[1], open = link.onclick;
      manage.setAttribute('href', 'https://chatgpt.com/codex/open-app?target=plugin&plugin_id=' + items[i].path.slice(9));
      manage.onclick = () => { throw new Error('A non-settings Manage link must not be opened'); };
      link.onclick = () => { open(); w.pod.navigateNatively('/settings/plugins-settings/' + items[i].path.slice(9)); };
    });
  } });
  const got = await scan(w);
  assert.equal(got.listKnown, true, got.failure); assert.equal(got.matches.length, 2);
  assert.equal(w.installedClicks.names, 2); assert.equal(w.installedClicks.manage, 0); safe(w);
});

for (const label of [null, 'Manage Build iOS Apps', 'Manage Codex Security ', 'manage Codex Security'])
  test('W323 row 14 requires an exact Manage label: ' + label, async () => {
    const w = codexInstalledPage({ mutate(_region, links) {
      const a = queryAll(links[13].parentElement, 'a')[1];
      if (label === null) a.removeAttribute('aria-label'); else a.setAttribute('aria-label', label);
    } });
    const got = await scan(w);
    assert.equal(got.listKnown, false); assert.match(got.failure, /invalid-row:14:anchors:2/);
    assert.deepEqual(got.matches, []); assert.equal(w.installedClicks.manage, 0); safe(w);
  });

test('W323 an exact Manage label still rejects a different settings segment', async () => {
  const w = codexInstalledPage({ mutate(_region, links) {
    queryAll(links[13].parentElement, 'a')[1].setAttribute('href', '/settings/plugins-settings/Plugin_' + 'f'.repeat(32));
  } });
  const got = await scan(w);
  assert.equal(got.listKnown, false); assert.match(got.failure, /invalid-row:14:manage-mismatch/);
  assert.deepEqual(got.matches, []); assert.equal(w.installedClicks.manage, 0); safe(w);
});
