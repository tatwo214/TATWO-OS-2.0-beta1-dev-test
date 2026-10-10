import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { makePage, h, MCP, queryAll } from './w185-pod-fixture.mjs';
import { pluginsPage, records } from './fixtures/w294-plugins-page.mjs';

const source = readFileSync(new URL('./w208-tap-stress.test.mjs', import.meta.url), 'utf8');
const factory = source.slice(source.indexOf('function connectorPage('), source.indexOf("\ntest('unfinished"));
const connectorPage = new Function('makePage', 'h', 'MCP', factory + '\nreturn connectorPage;')(makePage, h, MCP);
const foreign = { id: 'asdk_app_original', name: 'TATWO（Synthetic Device）', url: 'https://other.example.com/mcp', authorized: false };

test('W294f legacy list/tab/unfinished section bypass home and preserve unknown-list safety', async () => {
  for (const options of [{}, { tab: true }, { section: false }, { paged: true }]) {
    const { pod, clicks } = connectorPage([], options);
    await pod.signIn();
    const routes = [], navigate = pod.pageState.onNavigate;
    pod.pageState.onNavigate = path => { routes.push(path); navigate(path); };
    const got = (await pod.command({ cmd: 'connectorScan', url: MCP })).data;
    assert.equal(got.listKnown, options.section !== false && !options.paged);
    assert.deepEqual(routes, []);
    assert.equal(pod.sandbox.location.hash, undefined);
    assert.equal(clicks.create, 0);
  }
});

test('W294f legacy foreign URL refuses delete and reconnect from list or current detail without home', async () => {
  for (const cmd of ['connectorDelete', 'connectorReconnect']) for (const scanned of [false, true]) {
    const { pod, clicks } = connectorPage([{ ...foreign }]);
    await pod.signIn();
    if (scanned) await pod.command({ cmd: 'connectorScan', url: MCP });
    const routes = [], navigate = pod.pageState.onNavigate;
    pod.pageState.onNavigate = path => { routes.push(path); navigate(path); };
    const got = (await pod.command({ cmd, url: MCP, connectorID: foreign.id, name: foreign.name, keeping: 'active-connector' })).data;
    assert.notEqual(got.deleted, true); assert.notEqual(got.status, 'armed'); assert.notEqual(got.status, 'pressed');
    assert.deepEqual(routes, scanned ? [] : ['/plugins/' + foreign.id]);
    assert.equal(pod.sandbox.location.hash, undefined);
    assert.deepEqual(clicks.connect, []); assert.deepEqual(clicks.delete, []);
  }
});

test('W294f current modern foreign detail refuses before reopening Plugin settings', async () => {
  for (const cmd of ['connectorDelete', 'connectorReconnect']) {
    const items = records(); items[0].url = foreign.url;
    const world = pluginsPage(items);
    await world.pod.signIn();
    await world.pod.command({ cmd: 'connectorScan', url: MCP });
    world.detail(items[0]);
    const back = queryAll(world.pod.body, 'a[href]').find(a => a.textContent === 'Plugin settings');
    const settingsTabs = world.clicks.settingsTab;
    const got = (await world.pod.command({ cmd, url: MCP, connectorID: items[0].id, name: items[0].name, keeping: items[2].id })).data;
    assert.notEqual(got.deleted, true); assert.notEqual(got.status, 'armed'); assert.notEqual(got.status, 'pressed');
    assert.equal(world.clicks.settingsTab, settingsTabs);
    assert.ok(queryAll(world.pod.body, 'a[href]').includes(back), 'the current detail stays attached');
    assert.deepEqual(world.clicks.connect, []); assert.deepEqual(world.clicks.delete, []);
  }
});
