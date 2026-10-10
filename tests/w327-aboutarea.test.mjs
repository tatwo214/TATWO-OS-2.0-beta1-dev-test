import test from 'node:test';
import assert from 'node:assert/strict';
import { settingsPage, installedRows, MCP } from './fixtures/w327-aboutarea.mjs';
import { h, queryAll } from './w185-pod-fixture.mjs';
const scan = async w => { await w.pod.signIn(); return (await w.pod.command({ cmd: 'connectorScan', url: MCP }, 24000)).data; };
const safe = w => {
  assert.equal(w.clicks.create, 0); assert.deepEqual(w.clicks.delete, []);
  assert.deepEqual(w.forbidden, []); assert.deepEqual(w.octoberClicks.forbidden, []);
  for (const label of ['Delete app', 'Uninstall', 'Edit']) {
    const buttons = w.dangerous.filter(b => b.textContent === label);
    assert.ok(buttons.length > 0, label + ' must be present');
    assert.equal(buttons.reduce((sum, b) => sum + b.clicks, 0), 0, label);
  }
  assert.equal(JSON.stringify(w.pod.reports).includes('Fixture Person'), false);
};
for (const accountID of [true, false]) for (const titleDepth of [3, 4])
  test(`W327 plugins-settings one-press connection: accountID=${accountID}, depth=${titleDepth}`, async () => {
    const w = settingsPage({ accountID, titleDepth }), got = await scan(w);
    assert.equal(got.listKnown, true, got.failure); assert.equal(got.failure, null);
    assert.equal(got.matches.length, 2); assert.equal(got.candidates.length, 26);
    for (const [i, record] of got.matches.entries()) {
      assert.equal(record.serverURL, MCP); assert.equal(record.id, installedRows()[i].id);
      assert.notEqual(record.id, 'asdk_app_v_' + 'e'.repeat(32));
      assert.equal(record.auth, 'oauth'); assert.equal(record.needsReconnect, true);
      const command = { url: MCP, connectorID: record.id, detailPath: record.detailPath };
      assert.equal((await w.pod.command({ cmd: 'connectorInspect', ...command })).data.authorization, 'needs_reconnect');
      const sections = queryAll(queryAll(w.pod.body, 'main')[0], 'section');
      assert.equal(sections.length, 3); assert.match(sections[2].textContent, /Manage app.*Delete app/);
      assert.equal((await w.pod.command({ cmd: 'connectorReconnect', ...command })).data.status, 'pressed');
      assert.equal((await w.pod.command({ cmd: 'connectorGesture', url: MCP, name: record.name })).data.kind, 'continue');
      w.pod.userClick(queryAll(w.pod.body, 'button').find(b => b.textContent.startsWith('Continue to')));
    }
    assert.deepEqual(w.clicks.reconnect, got.matches.map(r => r.id));
    assert.deepEqual(w.clicks.continue, w.clicks.reconnect); safe(w);
  });
test('W327 plugins-settings uses nearest About area for fields and both OAuth labels', async () => {
  const w = settingsPage({ mutate({ manage, field }) {
    for (const [label, value] of [['URL', 'https://foreign.invalid/mcp'], ['App ID', 'asdk_app_' + 'f'.repeat(32)],
      ['Authorization supported', 'None'], ['Authorization used', 'None']]) manage.appendChild(field(label, value));
  } }), got = await scan(w);
  assert.equal(got.listKnown, true, got.failure); assert.equal(got.matches[0].auth, 'oauth');
  assert.equal((await w.pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: got.matches[0].id })).data.status, 'pressed'); safe(w);
});
for (const label of ['Authorization supported', 'Authorization used'])
  test('W327 plugins-settings cannot borrow ' + label + ' from Manage app', async () => {
    const w = settingsPage({ mutate({ row, manage, field }) {
      row(label)._kids[1].text = 'None'; manage.appendChild(field(label, 'OAuth'));
    } }), got = await scan(w);
    assert.equal(got.listKnown, true, got.failure); assert.equal(got.matches[0].auth, 'other');
    assert.notEqual((await w.pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: got.matches[0].id })).data.status, 'pressed'); safe(w);
  });
for (const mode of ['too-deep', 'missing-app-id', 'duplicate-about'])
  test('W327 plugins-settings refuses ' + mode + ' without clicking dangerous buttons', async () => {
    const w = settingsPage({ titleDepth: mode === 'too-deep' ? 5 : 3, mutate({ row, main, field, id }) {
      if (mode === 'missing-app-id') { row('App ID').remove(); main.appendChild(field('App ID', id)); }
      if (mode === 'duplicate-about') main.appendChild(h('section', {}, h('div', {}, h('div', {}, h('div', {}, 'About'))),
        h('div', {}, field('URL', MCP), field('App ID', id))));
    } }), got = await scan(w);
    assert.equal(got.listKnown, false); assert.deepEqual(got.matches, []);
    assert.match(got.failure, new RegExp('about-count:' + (mode === 'duplicate-about' ? 2 : 0)));
    safe(w);
  });
