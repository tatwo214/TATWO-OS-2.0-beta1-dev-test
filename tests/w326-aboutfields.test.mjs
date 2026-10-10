import test from 'node:test';
import assert from 'node:assert/strict';
import { settingsPage, installedRows, MCP } from './fixtures/w326-aboutfields.mjs';
import { h } from './w185-pod-fixture.mjs';
const scan = async w => { await w.pod.signIn(); return (await w.pod.command({ cmd: 'connectorScan', url: MCP }, 24000)).data; };
const safe = w => {
  assert.equal(w.clicks.create, 0); assert.deepEqual(w.clicks.delete, []);
  assert.deepEqual(w.forbidden, []); assert.deepEqual(w.octoberClicks.forbidden, []);
  assert.equal(JSON.stringify(w.pod.reports).includes('Fixture Person'), false);
};
for (const nested of [false, true]) for (const extraAbout of [false, true])
  test(`W326 nine grid rows read URL and App ID: nested=${nested}, extraAbout=${extraAbout}`, async () => {
    const w = settingsPage({ nested, extraAbout }), got = await scan(w);
    assert.equal(got.listKnown, true, got.failure); assert.equal(got.failure, null);
    assert.equal(got.matches.length, 2);
    for (const [i, record] of got.matches.entries()) {
      assert.equal(record.serverURL, MCP); assert.equal(record.id, installedRows()[i].id);
      assert.notEqual(record.id, 'asdk_app_v_' + 'e'.repeat(32)); assert.equal(record.auth, 'oauth');
      assert.equal((await w.pod.command({ cmd: 'connectorInspect', url: MCP, connectorID: record.id, detailPath: record.detailPath })).data.connector.id, record.id);
    }
    safe(w);
  });
for (const tag of ['span', 'code', 'a']) test('W326 one ' + tag + ' layer ignores copy buttons and inputs', async () => {
  const w = settingsPage({ nested: true, extraAbout: true, mutate({ row }) {
    for (const label of ['URL', 'App ID', 'Authorization supported', 'Authorization used']) {
      const value = row(label)._kids[1], text = value.text;
      value.text = ''; value.appendChild(h(tag, {}, '\n  ' + text + ' \t', h('button', {}, 'COPY PRIVATE CONTENT')));
      value.appendChild(h('button', {}, h('span', {}, 'COPY PRIVATE CONTENT')));
      value.appendChild(h('input', { value: 'INPUT PRIVATE CONTENT' }, 'INPUT PRIVATE CONTENT'));
    }
  } }), got = await scan(w);
  assert.equal(got.listKnown, true, got.failure); assert.equal(got.matches.length, 2);
  assert.equal(got.matches[0].serverURL, MCP); assert.equal(got.matches[0].id, installedRows()[0].id);
  assert.equal(got.matches[0].auth, 'oauth');
  const record = got.matches[0];
  assert.equal((await w.pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: record.id, detailPath: record.detailPath })).data.status, 'pressed');
  assert.equal(JSON.stringify(w.pod.reports).includes('PRIVATE CONTENT'), false); safe(w);
});
test('W326 plain value text also ignores copy controls', async () => {
  const w = settingsPage({ mutate({ row }) { row('URL')._kids[1].appendChild(h('button', {}, 'Copy URL')); } }), got = await scan(w);
  assert.equal(got.listKnown, true, got.failure); assert.equal(got.matches[0].serverURL, MCP); safe(w);
});
const failures = [
  ['about-count:0', ({ about }) => { about._kids[0].text = 'Other'; }],
  ['about-count:0', ({ row, main }) => { row('App ID').remove(); main.appendChild(h('p', {}, 'App ID')); }],
  ['about-count:2', ({ main, field, id }) => { main.appendChild(h('section', {}, h('div', {}, 'About'), field('URL', MCP), field('App ID', id))); }],
  ['label-hits:2', ({ about, field }) => { about.appendChild(field('URL', MCP)); }],
  ['row-kids:3', ({ row }) => { row('URL').appendChild(h('div', {}, 'Other')); }],
  ['row-kids:1', ({ row }) => { row('URL')._kids[1].remove(); }],
  ['row-outside-about', ({ row }) => { const r = row('URL'); r.appendChild(r._kids[0]); }],
  ['value-kids:1', ({ row }) => { const v = row('URL')._kids[1]; v.text = ''; v.appendChild(h('div', {}, MCP)); }],
  ['value-kids:1', ({ row }) => { const v = row('URL')._kids[1]; v.text = ''; v.appendChild(h('span', {}, h('code', {}, MCP))); }],
  ['value-kids:2', ({ row }) => { const v = row('URL')._kids[1]; v.text = ''; v.appendChild(h('span', {}, MCP)); v.appendChild(h('code', {}, MCP)); }],
  ['value-empty', ({ row }) => { row('URL')._kids[1].text = ' \n\t '; }],
  ['value-empty', ({ row }) => { const v = row('URL')._kids[1]; v.text = ''; v.appendChild(h('button', {}, MCP)); }],
];
for (const [i, [reason, mutate]] of failures.entries()) test(`W326 refusal ${i} reports ${reason} without identity content`, async () => {
  const w = settingsPage({ extraAbout: true, mutate }), got = await scan(w);
  assert.equal(got.listKnown, false); assert.deepEqual(got.matches, []);
  assert.ok(got.failure.includes('About URL 不唯一或格式不對 ' + reason), got.failure);
  assert.equal(got.failure.includes(MCP), false); assert.equal(got.failure.includes('asdk_app_'), false); safe(w);
});
test('W326 App ID failure keeps its own cause', async () => {
  const w = settingsPage({ mutate({ row }) { row('App ID')._kids[1].text = ''; } }), got = await scan(w);
  assert.ok(got.failure.includes('About App ID 不唯一或格式不對 value-empty'), got.failure); safe(w);
});
test('W326 URL failure retains precedence when App ID also fails', async () => {
  const w = settingsPage({ mutate({ row }) {
    row('URL').appendChild(h('div', {}, 'Other')); row('App ID')._kids[1].text = '';
  } }), got = await scan(w);
  assert.ok(got.failure.includes('About URL 不唯一或格式不對 row-kids:3'), got.failure);
  assert.equal(got.failure.includes('value-empty'), false); safe(w);
});
for (const value of ['asdk_app_v_' + 'e'.repeat(32), 'asdk_app_' + 'f'.repeat(32)])
  test('W326 wrapped App ID must match route and cannot be Version ID: ' + value, async () => {
    const w = settingsPage({ mutate({ row }) { const v = row('App ID')._kids[1]; v.text = ''; v.appendChild(h('code', {}, value)); } }), got = await scan(w);
    assert.equal(got.listKnown, false); assert.deepEqual(got.matches, []);
    assert.match(got.failure, /About App ID/); assert.equal(got.failure.includes(value), false); safe(w);
  });
