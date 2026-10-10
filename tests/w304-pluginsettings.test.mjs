import test from 'node:test';
import assert from 'node:assert/strict';
import { octoberPage, connector, MCP } from './fixtures/w304-pluginsettings-page.mjs';
import { queryAll } from './w185-pod-fixture.mjs';
const scan = async world => { await world.pod.signIn(); return (await world.pod.command({ cmd: 'connectorScan', url: MCP }, 24000)).data; };
const reconnect = world => world.pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: connector().id }, 20000);
const safe = world => {
  assert.equal(world.clicks.create, 0); assert.deepEqual(world.clicks.delete, []); assert.deepEqual(world.octoberClicks.forbidden, []);
  assert.equal(JSON.stringify(world.pod.reports).includes('Synthetic Account'), false);
};
test('W304 scan → recognize existing ID/URL/OAuth → account Reconnect → existing authorization', async () => {
  const world = octoberPage(), got = await scan(world);
  assert.equal(got.listKnown, true); assert.equal(got.failure, null); assert.equal(got.matches.length, 1);
  const record = got.matches[0];
  assert.equal(record.id, connector().id); assert.equal(record.serverURL, MCP); assert.equal(record.auth, 'oauth');
  assert.equal(record.connected, null); assert.equal(record.needsReconnect, true);
  assert.equal(record.detailPath, '/settings/plugins-settings/plugin_' + record.id);
  assert.equal((await world.pod.command({ cmd: 'connectorInspect', url: MCP, connectorID: record.id })).data.authorization, 'needs_reconnect');
  assert.equal((await reconnect(world)).data.status, 'pressed');
  assert.equal((await world.pod.command({ cmd: 'connectorGesture', url: MCP, name: record.name })).data.kind, 'continue');
  world.pod.userClick(queryAll(world.pod.body, 'button').find(x => x.textContent.startsWith('Continue to')));
  assert.deepEqual(world.clicks.reconnect, [record.id]); assert.deepEqual(world.clicks.continue, [record.id]);
  assert.equal(world.octoberClicks.apps, 0); assert.equal(world.octoberClicks.manage, 3); safe(world);
});
test('W304 tools dialog is a separate surface and contains no connector identity', async () => {
  // Open the Apps dialog manually, as in the evidence; the scanner itself never opens it.
  const populated = octoberPage(undefined, { settingsOpen: true }); await populated.pod.signIn(); populated.list();
  populated.pod.userClick(queryAll(populated.pod.body, 'button').find(x => x.textContent.startsWith(connector().name)));
  populated.pod.userClick(queryAll(populated.pod.body, 'button').find(x => x.textContent.endsWith('No description')));
  const dialog = queryAll(populated.pod.body, '[role="dialog"]')[0];
  assert.match(dialog.textContent, /apply_patch/); assert.doesNotMatch(dialog.textContent, /App ID|https:/);
  populated.pod.userClick(queryAll(dialog, 'button')[0]); assert.equal(populated.octoberClicks.close, 1);
});
test('W304 no account rows in Plugin settings proves not_connected', async () => {
  const world = octoberPage([{ ...connector(), authorized: false }]), got = await scan(world);
  assert.equal(got.listKnown, true); assert.equal(got.matches[0].connected, false);
  assert.equal((await world.pod.command({ cmd: 'connectorInspect', url: MCP, connectorID: connector().id })).data.authorization, 'not_connected'); safe(world);
});
test('W304 failures record layer and fixed field names with account values redacted', async () => {
  for (const [options, pattern] of [[{ missingManage: true }, /Manage.*layer=plugin fields=.*Information/],
    [{ duplicateManage: true }, /Manage/], [{ manageHref: 'https://foreign.invalid/settings/plugins-settings/plugin_' + connector().id }, /Manage/],
    [{ missingURL: true }, /URL.*layer=plugin_settings fields=.*App ID/], [{ missingID: true }, /App ID.*layer=plugin_settings/]]) {
    const world = octoberPage(undefined, options), got = await scan(world);
    assert.equal(got.listKnown, false); assert.match(got.failure, pattern); assert.match(got.outline, /\(account\)/); safe(world);
  }
});
test('W304 foreign URL refuses immediately on current settings; malformed App ID never matches', async () => {
  const world = octoberPage([{ ...connector(), url: 'https://foreign.invalid/mcp' }]), got = await scan(world);
  assert.equal(got.listKnown, true); assert.equal(got.matches.length, 0);
  world.pod.navigateNatively('/settings/plugins-settings/plugin_' + connector().id);
  const before = world.octoberClicks.manage;
  assert.equal((await reconnect(world)).data.status, 'not_found'); assert.equal(world.octoberClicks.manage, before); safe(world);
  const bad = octoberPage([{ ...connector(), id: 'asdk_app_v_version' }]);
  assert.equal((await scan(bad)).listKnown, false); safe(bad);
});
test('W304 account changes while opening Manage abort; ambiguous Reconnect never presses', async () => {
  const changed = octoberPage(undefined, { onManage(pod) { void pod.sandbox.fetch('/backend-api/me', { headers: { authorization: 'Bearer SYNTHETIC-B' } }); } });
  assert.equal((await scan(changed)).status, 'aborted'); assert.deepEqual(changed.clicks.reconnect, []); safe(changed);
  const ambiguous = octoberPage(undefined, { reconnectCount: 2 }); await scan(ambiguous);
  assert.equal((await reconnect(ambiguous)).data.status, 'not_found'); assert.deepEqual(ambiguous.clicks.reconnect, []); safe(ambiguous);
});
test('W304 settings App ID must match Manage route; OAuth remains required for reconnect', async () => {
  for (const [field, replacement] of [['App ID', 'asdk_app_different'], ['Authorization supported', 'None'], ['Authorization used', 'None']]) {
    const world = octoberPage(undefined, { onSettings(pod) {
      for (const label of queryAll(pod.body, 'p').filter(x => x.textContent === field)) {
        const siblings = label.parentElement._kids;
        // The synthetic About rows mix paired fields and adjacent text fields.
        siblings[siblings.indexOf(label) + 1].text = replacement;
      }
    } });
    const got = await scan(world);
    if (field === 'App ID') { assert.equal(got.listKnown, false); assert.match(got.failure, /App ID/); }
    assert.notEqual((await reconnect(world)).data.status, 'pressed');
    assert.deepEqual(world.clicks.reconnect, []); safe(world);
  }
});
test('W304 reads every candidate via Manage and keeps three authorization states distinct', async () => {
  const rows = [connector(), { ...connector(), id: 'asdk_app_w304mini5', name: 'TATWO（Mac mini）5', needsReconnect: false },
    { ...connector(), id: 'asdk_app_w304mini6', name: 'TATWO（Mac mini）6', authorized: false }];
  const world = octoberPage(rows), got = await scan(world);
  assert.equal(got.listKnown, true); assert.deepEqual(got.matches.map(x => x.connected), [null, true, false]);
  assert.deepEqual(got.matches.map(x => x.id), rows.map(x => x.id)); assert.equal(world.octoberClicks.manage, 3); safe(world);
});
