import test from 'node:test';
import assert from 'node:assert/strict';
import { rowWhyPage, installedRows, MCP } from './fixtures/w320-installed-rowwhy.mjs';
import { h, queryAll } from './w185-pod-fixture.mjs';
const scan = async w => { await w.pod.signIn(); return (await w.pod.command({ cmd: 'connectorScan', url: MCP }, 24000)).data; };
const safe = w => {
  assert.equal(w.clicks.create, 0); assert.deepEqual(w.clicks.delete, []);
  assert.deepEqual(w.octoberClicks.forbidden, []);
  assert.equal(JSON.stringify(w.pod.reports).includes('Synthetic Account'), false);
};

for (const [absolute, hidden] of [[true, ''], [false, 'visibility'], [false, 'opacity'], [true, 'visibility'], [true, 'opacity']]) {
  test(`W320 Installed complete URLs=${absolute}, More actions=${hidden || 'visible'} find both TATWO rows without create`, async () => {
    const w = rowWhyPage({ absolute, hidden }), items = installedRows();
    const region = w.pod.body._kids[0]._kids[1];
    assert.deepEqual(queryAll(region, 'a').map(a => a.getAttribute('href')), items.map(x => (absolute ? 'https://chatgpt.com' : '') + x.path));
    assert.equal(queryAll(region, 'button').length, 26);
    for (const b of queryAll(region, 'button')) {
      assert.equal(b.getAttribute('aria-label'), 'More actions');
      if (hidden) assert.equal(b.style[hidden], hidden === 'visibility' ? 'hidden' : '0');
    }
    const got = await scan(w);
    assert.equal(got.listKnown, true, got.failure); assert.equal(got.failure, null);
    assert.deepEqual(got.candidates, items.map((x, i) => ({ name: x.name, verdict: i < 2 ? '相符' : '讀不到' })));
    assert.deepEqual(got.matches.map(x => [x.id, x.name, x.detailPath]), items.slice(0, 2).map(x =>
      [x.id, x.name, '/settings/plugins-settings/plugin_' + x.id]));
    assert.equal(w.octoberClicks.manage, 2);
    safe(w);
  });
}

for (const [reason, change] of [
  ['no-name', a => { for (const child of [...a._kids]) child.remove(); }],
  ['path-shape', a => a.setAttribute('href', '/plugins/extra/segment')],
  ['path-shape', a => a.setAttribute('href', 'https://foreign.invalid' + a.getAttribute('href'))],
  ['href-form:relative', a => a.setAttribute('href', a.getAttribute('href') + '?next=2')],
  ['href-form:absolute', a => a.setAttribute('href', 'https://chatgpt.com' + a.getAttribute('href') + '#detail')],
  ['href-form:other', a => a.setAttribute('href', '//chatgpt.com' + a.getAttribute('href'))],
  ['anchors:2', a => a.parentElement.appendChild(h('a', { href: '/plugins/private_extra' }, 'Private second link'))],
  ['no-actions', a => queryAll(a.parentElement, 'button')[0].remove()],
]) test('W320 invalid Installed row reports its 1-based row and private-safe condition: ' + reason, async () => {
  const w = rowWhyPage({ mutate(_region, links) { change(links[22]); } });
  const got = await scan(w);
  assert.equal(got.listKnown, false);
  assert.ok(got.failure.includes('Installed 載入逾時）；invalid-row:23:' + reason + ' path='), got.failure);
  assert.deepEqual(got.matches, []);
  assert.equal(w.octoberClicks.manage, 0);
  for (const text of [...installedRows().flatMap(x => [x.name, x.path]), 'private_extra', 'Private second link', 'foreign.invalid'])
    assert.equal(got.failure.includes(text), false, text);
  safe(w);
});

for (const [reason, options] of [
  ['action-count', { hidden: 'visibility', mutate(region) { region.appendChild(h('button', { 'aria-label': 'More actions', hidden: true })); } }],
  ['duplicate-row', { items: [...installedRows(), installedRows()[0]] }],
  ['row-limit', { items: Array.from({ length: 257 }, (_, i) => ({ id: 'fixture_' + i, name: 'Fixture ' + i, path: '/plugins/fixture_' + i })) }],
]) test('W320 Installed keeps the existing whole-list guard: ' + reason, async () => {
  const w = rowWhyPage(options), got = await scan(w);
  assert.equal(got.listKnown, false);
  assert.ok(got.failure.includes('Installed 載入逾時）；' + reason + ' path='), got.failure);
  assert.deepEqual(got.matches, []); safe(w);
});
