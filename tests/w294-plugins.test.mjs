import test from 'node:test';
import assert from 'node:assert/strict';
import { pluginsPage, records, realRecords, MCP, NAME } from './fixtures/w294-plugins-page.mjs';
import { queryAll, makePage, h } from './w185-pod-fixture.mjs';
const scan = async world => { await world.pod.signIn(); return (await world.pod.command({ cmd: 'connectorScan', url: MCP }, 20000)).data; };

test('W294e nested Settings without its container routes to /settings and finds Plugins again', async () => {
  const world = pluginsPage(realRecords(), { initialPath: '/settings/general-settings', missingProfile: true, hashWorks: false });
  const got = await scan(world);
  assert.equal(got.listKnown, true); assert.equal(got.matches.length, 2);
  assert.equal(world.clicks.settingsRoute, 1); assert.equal(world.clicks.home, 0); assert.equal(world.clicks.hash, 0);
});

test('W294e account change during Settings recovery aborts before pressing Plugins', async () => {
  const world = pluginsPage(realRecords(), { initialPath: '/settings/general-settings', missingProfile: true, hashWorks: false, onSettingsRoute(pod) {
    void pod.sandbox.fetch('/backend-api/me', { headers: { authorization: 'Bearer SYNTHETIC-B' } });
  } });
  assert.equal((await scan(world)).status, 'aborted'); assert.equal(world.clicks.settingsRoute, 1);
  assert.equal(world.clicks.settingsTab, 0);
});

test('Plugins button rows read URL/App ID/dev mode and distinguish connected 4 from unfinished 2/3', async () => {
  const world = pluginsPage(); const got = await scan(world);
  assert.equal(got.listKnown, true); assert.equal(got.devMode, true); assert.equal(got.failure, null);
  assert.deepEqual(got.matches.map(x => [x.id, x.name, x.connected, x.auth, x.serverURL]), records().map(x => [x.id, x.name, x.authorized, 'oauth', MCP]));
  assert.equal(world.clicks.create, 0); assert.deepEqual(world.clicks.delete, []);
  assert.equal((await world.pod.command({ cmd: 'connectorOutline' })).data.outline.includes('Search installed plugins'), true);
  await world.pod.command({ cmd: 'connectorInspect', url: MCP, connectorID: 'asdk_app_fixture4' });
  const outline = (await world.pod.command({ cmd: 'connectorOutline' })).data.outline;
  assert.equal(outline.includes('dev mode'), true);
  assert.equal(outline.includes("Fixture's"), false, 'account display names stay inside the Pod');
  assert.equal(outline.includes('(account)'), true);
});

test('cleanup deletes only unfinished 2/3 through both Delete app buttons and checks disappearance', async () => {
  const world = pluginsPage(); const got = await scan(world), keep = got.matches[2];
  for (const record of got.matches.slice(0, 2)) {
    const removed = (await world.pod.command({ cmd: 'connectorDelete', url: MCP, connectorID: record.id, name: record.name, keeping: keep.id })).data;
    assert.equal(removed.deleted, true);
  }
  assert.deepEqual(world.clicks.delete, ['asdk_app_fixture2', 'asdk_app_fixture3']);
  assert.deepEqual(world.items.map(r => r.id), [keep.id]);
});

test('disconnected grant reuses connected 4 through account menu Reconnect and Continue; no Create', async () => {
  const world = pluginsPage(); await scan(world);
  const result = await world.pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: 'asdk_app_fixture4' });
  assert.equal(result.data.status, 'pressed');
  const gesture = (await world.pod.command({ cmd: 'connectorGesture', url: MCP, name: NAME + '4' })).data;
  assert.equal(gesture.status, 'found'); assert.equal(gesture.kind, 'continue');
  world.pod.userClick(queryAll(world.pod.body, 'button').find(b => b.textContent.startsWith('Continue to')));
  assert.deepEqual(world.clicks.reconnect, ['asdk_app_fixture4']); assert.deepEqual(world.clicks.continue, ['asdk_app_fixture4']);
  assert.deepEqual(world.clicks.connect, []); assert.equal(world.clicks.create, 0);
});

test('unfinished plugin uses detail Connect and preserves its App ID', async () => {
  const world = pluginsPage(); await scan(world);
  const armed = await world.pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: 'asdk_app_fixture2' }, 12000, { press: false });
  assert.equal(armed.data.status, 'armed'); assert.equal(armed.data.connector.id, 'asdk_app_fixture2');
  const result = await world.pod.command({ cmd: 'connectorPress', form: armed.data.form });
  assert.equal(result.data.status, 'pressed');
  assert.deepEqual(world.clicks.connect, ['asdk_app_fixture2']); assert.equal(world.clicks.create, 0);
});

test('missing tab, zero rows, filtered/paged lists, missing URL/ID report precise failure', async () => {
  for (const [options, pattern] of [[{ missingTab: true }, /General／Plugins/], [{ emptyUnknown: true }, /清單 0 列/],
    [{ filtered: true }, /Plugins/], [{ paged: true }, /清單未完整/], [{ missingURL: true }, /URL/], [{ missingID: true }, /App ID/]]) {
    const world = pluginsPage(options.emptyUnknown ? [] : records(), options); const got = await scan(world);
    assert.equal(got.listKnown, false, JSON.stringify(options)); assert.match(got.failure, pattern);
    assert.equal(world.clicks.create, 0); assert.deepEqual(world.clicks.delete, []);
  }
});

test('explicit empty list is known and Add remains the new creation entry', async () => {
  const world = pluginsPage([]); const got = await scan(world);
  assert.equal(got.listKnown, true); assert.deepEqual(got.matches, []);
  const result = await world.pod.command({ cmd: 'connectorCreate', url: MCP, name: NAME }, 18000);
  assert.equal(result.data.status, 'pressed'); assert.equal(world.clicks.create, 1);
});

test('connected duplicate and foreign URL cannot be deleted; no confirmation click on account change', async () => {
  for (const options of [{}, { beforeConfirm(pod) { void pod.sandbox.fetch('/backend-api/me', { headers: { authorization: 'Bearer SYNTHETIC-B' } }); } }]) {
    const world = pluginsPage(records(), options); await scan(world);
    const active = (await world.pod.command({ cmd: 'connectorDelete', url: MCP, connectorID: 'asdk_app_fixture4', name: NAME + '4', keeping: 'asdk_app_fixture2' })).data;
    assert.equal(active.deleted, false);
    if (options.beforeConfirm) {
      const result = await world.pod.command({ cmd: 'connectorDelete', url: MCP, connectorID: 'asdk_app_fixture2', name: NAME + '2', keeping: 'asdk_app_fixture4' });
      assert.equal(result.data.deleted, false); assert.deepEqual(world.clicks.delete, []);
    }
  }
  const items = records(); items[0].url = 'https://other.example.com/mcp';
  const world = pluginsPage(items); const got = await scan(world);
  assert.deepEqual(got.conflictingNames, [NAME + '2']);
  const removed = await world.pod.command({ cmd: 'connectorDelete', url: MCP, connectorID: items[0].id, name: items[0].name, keeping: items[2].id });
  assert.equal(removed.data.deleted, false); assert.deepEqual(world.clicks.delete, []);
});

test('closing delete confirmation without deleting does not report success', async () => {
  const world = pluginsPage(records(), { deleteConfirmed: false }); await scan(world);
  assert.equal((await world.pod.command({ cmd: 'connectorDelete', url: MCP, connectorID: 'asdk_app_fixture2', name: NAME + '2', keeping: 'asdk_app_fixture4' })).data.deleted, false);
});

test('account changes during scanning or between arm and press stop without clicking', async () => {
  const scanning = pluginsPage(records(), { beforeDetail(pod) {
    void pod.sandbox.fetch('/backend-api/me', { headers: { authorization: 'Bearer SYNTHETIC-B' } });
  } });
  const interrupted = await scan(scanning); assert.equal(interrupted.status, 'aborted');
  assert.equal(scanning.clicks.create, 0); assert.deepEqual(scanning.clicks.reconnect, []);
  const world = pluginsPage(); await scan(world);
  const armed = (await world.pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: 'asdk_app_fixture4' }, 12000, { press: false })).data;
  await world.pod.sandbox.fetch('/backend-api/me', { headers: { authorization: 'Bearer SYNTHETIC-B' } });
  const result = (await world.pod.command({ cmd: 'connectorPress', form: armed.form })).data;
  assert.equal(result.reason, 'press_stale'); assert.deepEqual(world.clicks.reconnect, []);
});

test('identity/connection changes while confirming deletion prevent the final Delete app', async () => {
  for (const change of [r => { r.url = 'https://other.example.com/mcp'; }, r => { r.authorized = true; }]) {
    const items = records();
    const world = pluginsPage(items, { beforeConfirm() { change(items[0]); world.detail(items[0]); } }); await scan(world);
    const result = await world.pod.command({ cmd: 'connectorDelete', url: MCP, connectorID: items[0].id, name: items[0].name, keeping: items[2].id });
    assert.equal(result.data.deleted, false); assert.deepEqual(world.clicks.delete, []);
  }
});

test('duplicate App IDs or a list changing during detail reads stay unknown', async () => {
  const repeated = records(); repeated[1].id = repeated[0].id;
  assert.match((await scan(pluginsPage(repeated))).failure, /App ID 重複/);
  const items = records(); let read = 0;
  const world = pluginsPage(items, { beforeDetail() { if (++read === 3) items.push({ id: 'asdk_app_fixture5', name: NAME + '5', url: MCP, authorized: false }); } });
  const got = await scan(world); assert.equal(got.listKnown, false); assert.match(got.failure, /清單在讀取時改變/);
  assert.equal(world.clicks.create, 0);
});

test('delayed detail/confirmation rendering waits for the new surface, despite whole-page Settings already being open', async () => {
  const world = pluginsPage(records(), { detailDelay: 30, deleteDelay: 30 }); const got = await scan(world);
  assert.equal(got.listKnown, true);
  const result = await world.pod.command({ cmd: 'connectorDelete', url: MCP, connectorID: 'asdk_app_fixture2', name: NAME + '2', keeping: 'asdk_app_fixture4' });
  assert.equal(result.data.deleted, true); assert.deepEqual(world.clicks.delete, ['asdk_app_fixture2']);
});


test('old creation form stays open during scan; opening Settings must not replace its warning/consent surface', async () => {
  const pod = makePage({ build(body) {
    body.appendChild(h('div', { role: 'dialog' }, h('h2', {}, 'New Plugin'),
      h('label', { for: 'old-mcp' }, 'MCP Server URL'), h('input', { id: 'old-mcp', placeholder: 'https://example.com/mcp' })));
  } });
  pod.pageState.pathname = '/plugins'; await pod.signIn();
  const dialog = queryAll(pod.body, '[role="dialog"]')[0];
  await pod.command({ cmd: 'connectorScan', url: MCP });
  assert.equal(pod.sandbox.location.hash, undefined);
  assert.equal(queryAll(pod.body, '[role="dialog"]')[0], dialog);
});

test('W294b renamed Accounts with an inline Reconnect menu remains connected and cannot be deleted', async () => {
  const world = pluginsPage(records(), { accountHeading: 'Accounts', menuReconnect: true });
  const got = await scan(world); assert.equal(got.listKnown, true);
  assert.equal(got.matches[2].connected, true);
  const result = (await world.pod.command({ cmd: 'connectorDelete', url: MCP, connectorID: records()[2].id, name: NAME + '4', keeping: records()[0].id })).data;
  assert.equal(result.deleted, false); assert.deepEqual(world.clicks.delete, []);
});

test('W294b About /api/mcp identity ignores a description containing the target /mcp', async () => {
  const items = records(); items[0].url = MCP.replace('/mcp', '/api/mcp');
  const world = pluginsPage(items, { description: MCP }); const got = await scan(world);
  assert.equal(got.listKnown, true); assert.deepEqual(got.matches.map(x => x.id), items.slice(1).map(x => x.id));
  assert.deepEqual(got.conflictingNames, [items[0].name]);
  const removed = (await world.pod.command({ cmd: 'connectorDelete', url: MCP, connectorID: items[0].id, name: items[0].name, keeping: items[2].id })).data;
  assert.equal(removed.deleted, false); assert.deepEqual(world.clicks.delete, []);
});

test('W294b custom account text and aria/title/alt stay out of all Pod reports and snapshots', async () => {
  const accountName = 'Custom Display Persona', accountEmail = 'custom-persona' + '@' + 'example.invalid';
  const world = pluginsPage(records(), { accountHeading: 'Accounts', accountName, accountEmail });
  await scan(world);
  await world.pod.command({ cmd: 'connectorInspect', url: MCP, connectorID: records()[2].id });
  const snapshot = (await world.pod.command({ cmd: 'connectorOutline' })).data;
  assert.match(snapshot.outline, /\(account\)/);
  for (const value of [accountName, accountEmail]) assert.equal(JSON.stringify(world.pod.reports).includes(value), false);
});

test('W294b normal not_connected duplicates delete and keeping App ID never receives Delete', async () => {
  const world = pluginsPage(); const got = await scan(world);
  const inspected = (await world.pod.command({ cmd: 'connectorInspect', url: MCP, connectorID: records()[0].id })).data;
  assert.equal(inspected.authorization, 'not_connected');
  const kept = (await world.pod.command({ cmd: 'connectorDelete', url: MCP, connectorID: got.matches[2].id, name: got.matches[2].name, keeping: got.matches[2].id })).data;
  assert.notEqual(kept.deleted, true);
  for (const record of got.matches.slice(0, 2)) assert.equal((await world.pod.command({ cmd: 'connectorDelete', url: MCP, connectorID: record.id, name: record.name, keeping: got.matches[2].id })).data.deleted, true);
  assert.deepEqual(world.items.map(x => x.id), [got.matches[2].id]);
});

test('W294b missing/duplicate/invalid fixed fields and empty account area remain unknown with the blocked item', async () => {
  for (const [options, field] of [[{ duplicateURL: true }, 'URL'], [{ duplicateID: true }, 'App ID'], [{ duplicateTitle: true }, '名稱'],
    [{ missingURL: true, description: MCP }, 'URL'], [{ accountRows: false }, '帳號區']]) {
    const world = pluginsPage(records(), options), got = await scan(world);
    assert.equal(got.listKnown, false); assert.ok(got.failure.includes(NAME)); assert.ok(got.failure.includes(field), got.failure);
    const result = (await world.pod.command({ cmd: 'connectorDelete', url: MCP, connectorID: records()[2].id, name: NAME + '4', keeping: records()[0].id })).data;
    assert.equal(result.deleted, false); assert.deepEqual(world.clicks.delete, []);
  }
});


test('W294b Reconnect-only, disabled Connect never prove not_connected', async () => {
  for (const options of [{ connectLabel: 'Reconnect' }, { connectDisabled: true }]) {
    const world = pluginsPage(records(), options), got = await scan(world);
    assert.equal(got.listKnown, false); assert.ok(got.failure.includes(NAME + '2'));
    const inspected = (await world.pod.command({ cmd: 'connectorInspect', url: MCP, connectorID: records()[0].id })).data;
    assert.equal(inspected.authorization, 'unknown');
    const result = (await world.pod.command({ cmd: 'connectorDelete', url: MCP, connectorID: records()[0].id, name: NAME + '2', keeping: records()[2].id })).data;
    assert.equal(result.deleted, false); assert.deepEqual(world.clicks.delete, []);
  }
});

test('W294b malformed About URL/App ID cannot be replaced by a valid description value', async () => {
  for (const field of ['url', 'id']) {
    const items = records(); items[0][field] = field === 'url' ? 'not-a-url' : 'asdk_app_v_version';
    const world = pluginsPage(items, { description: field === 'url' ? MCP : records()[0].id });
    const got = await scan(world);
    assert.equal(got.listKnown, false); assert.match(got.failure, field === 'url' ? /URL/ : /App ID/);
    assert.deepEqual(world.clicks.delete, []);
  }
});


test('W294b description headings never replace a missing detail title', async () => {
  const world = pluginsPage(records(), { missingTitle: true, description: h('div', {}, h('h2', {}, NAME + '2')) });
  const got = await scan(world);
  assert.equal(got.listKnown, false); assert.match(got.failure, /名稱標題/);
  assert.deepEqual(world.clicks.delete, []);
});


test('W294c whole-page Settings scopes both Plugins buttons and recognizes direct account Reconnect', async () => {
  for (const settingsOpen of [false, true]) {
    const world = pluginsPage(realRecords(), { settingsOpen, hashWorks: false });
    const got = await scan(world);
    assert.equal(got.listKnown, true); assert.equal(got.matches.length, 2);
    assert.equal(world.clicks.sidebarPlugins, 0); assert.equal(world.clicks.hash, 0);
    assert.equal(world.clicks.profile, settingsOpen ? 0 : 1); assert.equal(world.clicks.settings, settingsOpen ? 0 : 1);
    assert.equal(queryAll(world.pod.body, 'button').filter(b => b.textContent === 'Plugins').length, 2);
    const bad = got.matches[0], good = got.matches[1];
    assert.equal(bad.needsReconnect, true);
    assert.equal((await world.pod.command({ cmd: 'connectorInspect', url: MCP, connectorID: bad.id })).data.authorization, 'needs_reconnect');
    assert.equal(bad.connected, null); assert.deepEqual(got.matches.filter(x => x.connected === false), []);
    assert.equal((await world.pod.command({ cmd: 'connectorDelete', url: MCP, connectorID: bad.id, name: bad.name, keeping: good.id })).data.deleted, false);
    assert.equal((await world.pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: bad.id })).data.status, 'pressed');
    assert.deepEqual(world.clicks.reconnect, [bad.id]); assert.deepEqual(world.clicks.more, []);
    assert.equal((await world.pod.command({ cmd: 'connectorInspect', url: MCP, connectorID: good.id })).data.authorization, 'connected');
    assert.equal((await world.pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: good.id })).data.status, 'pressed');
    assert.deepEqual(world.clicks.more, [good.id]); assert.equal(world.clicks.sidebarPlugins, 0);
  }
});

test('W294c Chinese direct reconnect is recognized and multiple direct buttons never get pressed', async () => {
  const world = pluginsPage(realRecords(), { reconnectLabel: '重新連線' }); await scan(world);
  assert.equal((await world.pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: realRecords()[0].id })).data.status, 'pressed');
  const ambiguous = pluginsPage(realRecords(), { reconnectCount: 2 }); await scan(ambiguous);
  assert.equal((await ambiguous.pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: realRecords()[0].id })).data.status, 'not_found');
  assert.deepEqual(ambiguous.clicks.reconnect, []);
});

test('W294c profile failures use hash only as fallback and report each blocked step', async () => {
  for (const [options, pattern] of [[{ missingProfile: true }, /Open profile menu 按鈕數=0/],
    [{ duplicateProfile: true }, /Open profile menu 按鈕數=2/], [{ missingSettings: true }, /Settings 選單項數=0/],
    [{ duplicateSettings: true }, /Settings 選單項數=2/], [{ missingTab: true }, /Settings 選單按下後/],
    [{ duplicateTab: true }, /Plugins 按鈕數=2/], [{ tabWorks: false }, /Plugins 分頁按下後/]]) {
    const world = pluginsPage(realRecords(), { ...options, hashWorks: false }); const got = await scan(world);
    assert.equal(got.listKnown, false); assert.match(got.failure, pattern); assert.equal(world.clicks.sidebarPlugins, 0);
    if (options.duplicateTab || options.tabWorks === false) assert.match((await world.pod.command({ cmd: 'connectorOutline' })).data.outline, /General/);
  }
  const fallback = pluginsPage(realRecords(), { missingProfile: true }); assert.equal((await scan(fallback)).listKnown, true);
  assert.equal(fallback.clicks.hash, 1); assert.equal(fallback.clicks.sidebarPlugins, 0);
});

test('W294c scan failure returns the failing settings structure with the entire account area redacted', async () => {
  const secret = 'Synthetic Private Persona';
  const world = pluginsPage(realRecords(), { duplicateURL: true, accountName: secret }); const got = await scan(world);
  assert.match(got.failure, /URL/); assert.match(got.outline, /About/); assert.match(got.outline, /\(account\)/);
  assert.equal(JSON.stringify(world.pod.reports).includes(secret), false);
});

test('W294d store/home/project pages read Settings Plugins through the sidebar profile', async () => {
  for (const initialPath of ['/', '/plugins', '/plugins/directory', '/g/g-p-fixture/project']) {
    const world = pluginsPage(realRecords(), { initialPath, hashWorks: false });
    const got = await scan(world);
    assert.equal(got.listKnown, true); assert.equal(got.failure, null);
    assert.deepEqual(got.matches.map(x => x.id), realRecords().map(x => x.id));
    assert.equal(world.clicks.profile, 1); assert.equal(world.clicks.settings, 1);
    assert.equal(world.clicks.home, 0); assert.equal(world.clicks.hash, 0);
    assert.equal(world.clicks.sidebarPlugins, 0); assert.equal(world.clicks.create, 0);
  }
});

test('W294d narrow pages reveal profile only after pressing the unique Open sidebar', async () => {
  for (const initialPath of ['/', '/plugins', '/g/g-p-fixture/project']) {
    for (const sidebarLabel of ['Open sidebar', '開啟側邊欄']) {
      const world = pluginsPage(realRecords(), { initialPath, collapsedSidebar: true, sidebarLabel, hashWorks: false });
      assert.equal(queryAll(world.pod.body, 'aside')[0]._hidden, true);
      const got = await scan(world);
      assert.equal(got.listKnown, true); assert.equal(got.matches.length, 2);
      assert.equal(world.clicks.openSidebar, 1); assert.equal(world.clicks.profile, 1);
      assert.equal(world.clicks.settings, 1); assert.equal(world.clicks.home, 0); assert.equal(world.clicks.hash, 0);
    }
  }
});

test('W294d skeleton store routes home and waits for a delayed profile, including the next scan', async () => {
  const world = pluginsPage(realRecords(), { initialPath: '/plugins/directory', skeletonStore: true, homeDelay: 360, hashWorks: false });
  for (let i = 1; i <= 2; i++) {
    const got = await scan(world);
    assert.equal(got.listKnown, true); assert.equal(got.matches.length, 2);
    assert.equal(world.clicks.home, i); assert.equal(world.clicks.profile, i);
    assert.equal(world.clicks.settings, i); assert.equal(world.clicks.hash, 0);
    if (i === 1) world.pod.navigateNatively('/plugins');
  }
});

test('W294d narrow skeleton store opens the sidebar after returning home', async () => {
  const world = pluginsPage(realRecords(), { skeletonStore: true, collapsedSidebar: true, homeDelay: 360, hashWorks: false });
  const got = await scan(world);
  assert.equal(got.listKnown, true); assert.equal(got.matches.length, 2);
  assert.equal(world.clicks.home, 1); assert.equal(world.clicks.openSidebar, 1);
  assert.equal(world.clicks.profile, 1); assert.equal(world.clicks.settings, 1); assert.equal(world.clicks.hash, 0);
});

test('W294d ambiguous sidebar is not pressed and failure reports only path/viewport/button counts', async () => {
  const world = pluginsPage(realRecords(), { collapsedSidebar: true, sidebarCount: 2, hashWorks: false });
  world.pod.sandbox.location.search = '?private=SyntheticQuerySecret';
  world.pod.body.appendChild(h('p', {}, 'SyntheticPageSecret'));
  const got = await scan(world);
  assert.equal(got.listKnown, false); assert.equal(world.clicks.openSidebar, 0);
  assert.match(got.failure, /path=\/ viewport=480x1000 buttons=6 openSidebar=2 profileMenu=0$/);
  assert.equal(got.failure.includes('SyntheticQuerySecret'), false);
  assert.equal(got.failure.includes('SyntheticPageSecret'), false);
});

test('W294d failed sidebar retries home; account changes on the home route abort before Settings', async () => {
  const world = pluginsPage(realRecords(), { collapsedSidebar: true, sidebarWorks: false, hashWorks: false, onHome(pod) {
    void pod.sandbox.fetch('/backend-api/me', { headers: { authorization: 'Bearer SYNTHETIC-B' } });
  } });
  assert.equal((await scan(world)).status, 'aborted');
  assert.equal(world.clicks.openSidebar, 1); assert.equal(world.clicks.home, 1);
  assert.equal(world.clicks.profile, 0); assert.equal(world.clicks.settings, 0); assert.equal(world.clicks.hash, 0);
});

test('W294d detail failures carry the same scene fields without account or page text', async () => {
  const world = pluginsPage(realRecords(), { duplicateURL: true, accountName: 'SyntheticSceneSecret' });
  const got = await scan(world);
  assert.equal(got.listKnown, false);
  assert.match(got.failure, / path=\/plugins viewport=1400x1000 buttons=\d+ openSidebar=0 profileMenu=1$/);
  assert.equal(got.failure.includes('SyntheticSceneSecret'), false);
});
