import test from 'node:test';
import assert from 'node:assert/strict';
import { octoberPage } from './fixtures/w304-pluginsettings-page.mjs';
import { h, queryAll } from './w185-pod-fixture.mjs';
import { installedPage, connector, MCP } from './fixtures/w304b-installed-sidebar.mjs';
const scan = async world => { await world.pod.signIn(); return (await world.pod.command({ cmd: 'connectorScan', url: MCP }, 24000)).data; };
test('W304b Installed links find mini4 through Manage and reconnect without creating', async () => {
  const world = installedPage([connector(), { ...connector(), id: 'asdk_app_air', name: 'TATWO（MacBook Air）', url: 'https://foreign.invalid/mcp' },
    { id: 'calendar', name: 'Google Calendar' }]);
  const got = await scan(world);
  assert.equal(got.listKnown, true); assert.equal(got.matches[0].id, connector().id);
  assert.deepEqual(got.candidates, [{ name: connector().name, verdict: '相符' }, { name: 'TATWO（MacBook Air）', verdict: '網址不同' }, { name: 'Google Calendar', verdict: '讀不到' }]);
  assert.equal((await world.pod.command({ cmd: 'connectorReconnect', url: MCP, connectorID: got.matches[0].id })).data.status, 'pressed'); assert.deepEqual(world.clicks.reconnect, [connector().id]);
  assert.equal(world.clicks.create, 0); assert.deepEqual(world.octoberClicks.forbidden, []);
  assert.equal(JSON.stringify(world.pod.reports).includes('Synthetic Account'), false);
});
test('W304b missing Installed always stops even with catalogue Install buttons', async () => {
  const world = installedPage([], { missingInstalled: true }), got = await scan(world);
  assert.equal(got.listKnown, false); assert.equal(world.clicks.create, 0);
});
test('W304b confirmed empty Installed alone permits create; catalogue is ignored', async () => {
  const world = installedPage([]), got = await scan(world);
  assert.equal(got.listKnown, true); assert.deepEqual(got.matches, []); assert.deepEqual(got.candidates, []);
  assert.equal((await world.pod.command({ cmd: 'connectorCreate', url: MCP, name: 'TATWO（Studio B）' })).data.status, 'pressed'); assert.equal(world.clicks.create, 1);
});
for (const options of [{ rowTag: 'button' }, { rowTag: 'div', missingMore: true }, { missingMore: true }, { href: 'https://foreign.invalid/plugins/mini' }, { href: '/plugins/mini?next=2' }, { paged: true }, { busy: true }, { filtered: true }])
  test('W304b uncertain Installed stops: ' + JSON.stringify(options), async () => {
    const world = installedPage(undefined, options), got = await scan(world);
    assert.equal(got.listKnown, false); assert.equal(world.clicks.create, 0);
  });
test('W304b unreadable identity stops and reports the candidate', async () => {
  const world = installedPage(undefined, { missingURL: true }), got = await scan(world);
  assert.equal(got.listKnown, false); assert.equal(got.candidates[0].verdict, '讀不到');
  assert.equal(world.clicks.create, 0);
});

test('W304b candidate summary masks account names before crossing the Pod boundary', async () => {
  const world = installedPage([{ id: 'private_calendar', name: "Synthetic Account's Calendar account Primary" }]);
  const got = await scan(world);
  assert.deepEqual(got.candidates, [{ name: '(account)', verdict: '讀不到' }]);
  assert.equal(JSON.stringify(world.pod.reports).includes('Synthetic Account'), false);
});

test('W304b legacy list with unrelated buttons cannot prove an empty installed list', async () => {
  const world = octoberPage([], { settingsOpen: true, emptyUnknown: true });
  world.list();
  queryAll(world.pod.body, 'input')[0].parentElement.appendChild(h('button', {}, 'Install Catalogue'));
  const got = await scan(world);
  assert.equal(got.listKnown, false); assert.equal(world.clicks.create, 0);
});

test('W304b installed scan uses captured helpers when the page replaces Array iteration', async () => {
  const world = installedPage();
  world.pod.run(`globalThis.iteratorReads = 0;
    const originalIterator = Array.prototype[Symbol.iterator];
    Array.prototype[Symbol.iterator] = function() {
      if ((new Error().stack.split('\\n')[2] ?? '').includes('tatwo-pod.js')) iteratorReads++;
      return Reflect.apply(originalIterator, this, []);
    };`);
  const got = await scan(world);
  assert.equal(got.listKnown, true); assert.equal(got.matches[0].id, connector().id);
  assert.equal(world.pod.run('iteratorReads'), 0);
});
