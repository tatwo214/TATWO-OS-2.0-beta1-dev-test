import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { MCP } from './w185-pod-fixture.mjs';
import { plugins202610 } from './fixtures/w303-plugins-2026-10.mjs';

const createCommand = { cmd: 'connectorCreate', url: MCP, name: 'TATWO（Studio B）' };
const begin = async options => {
  const page = plugins202610(options);
  await page.pod.signIn();
  const result = (await page.pod.command(createCommand)).data;
  return { ...page, result };
};

test('W303 2026-10: Add → only Add custom MCP server → fill form → wait for I understand', async () => {
  const { pod, state, result } = await begin();
  assert.equal(result.status, 'needs_user');
  assert.equal(result.reason, 'risk_ack');
  assert.match(result.form, /^f[a-z0-9]{6,20}$/);
  assert.deepEqual(state.picked, ['mcp']);
  assert.equal(state.name.value, createCommand.name);
  assert.equal(state.url.value, MCP);
  assert.equal(state.desc.value, '');
  assert.equal(state.auth.value, 'oauth');
  assert.equal(state.server.getAttribute('aria-checked'), 'true');
  assert.equal(state.tunnel.getAttribute('aria-checked'), 'false');
  assert.equal(state.ack.getAttribute('aria-checked'), 'false');
  for (const control of [state.server, state.tunnel, state.auth, state.ack, state.create, state.close]) assert.equal(control.clicks, 0);
  assert.equal(state.advanced + state.submitted + state.closed, 0);
  const again = (await pod.command({ ...createCommand, ack: { form: result.form, warning: result.warning } })).data;
  assert.equal(again.reason, 'risk_ack');
  assert.equal(state.ack.clicks + state.create.clicks, 0);
});

for (const [addLabel, mcpLabel, createLabel] of [
  ['Add', 'Add custom MCP server', 'Create as a plugin'],
  ['aDd ▾', 'ADD   CUSTOM MCP  SERVER', 'CREATE AS A PLUGIN'],
  ['New ▾', 'Create MCP app', 'Create'],
  ['新增 ▾', '建立 MCP 應用程式', '建立'],
  ['新增', '新增自訂 MCP 伺服器', '建立為外掛程式'],
  ['新增', '新增 自訂 MCP 服務器', '建立 為 外掛程式'],
]) test(`W303 labels: ${mcpLabel} / ${createLabel}; submit once after a trusted user tick`, async () => {
  const { pod, state, result } = await begin({ addLabel, mcpLabel, createLabel });
  assert.equal(result.reason, 'risk_ack');
  pod.userClick(state.ack);
  const command = { ...createCommand, ack: { form: result.form, warning: result.warning } };
  assert.equal((await pod.command(command)).data.status, 'pressed');
  assert.equal(state.submitted, 1);
  assert.equal(state.ack.clicks, 1);
  assert.equal((await pod.command(command)).data.reason, 'ack_replayed');
  assert.equal(state.submitted, 1);
});

for (const [options, status] of [
  [{ missingMCP: true }, 'not_found'], [{ duplicateMCP: true }, 'ambiguous'],
  [{ conflictingMCP: true }, 'not_found'], [{ mcpLabel: 'Add custom MCP server and upload plugin archive' }, 'not_found'],
  [{ mcpLabel: 'Add custom MCP servers' }, 'not_found'], [{ plainAdd: true }, 'not_found'],
]) test(`W303 rejects unsafe menu: ${JSON.stringify(options)}`, async () => {
  const { state, result } = await begin(options);
  assert.equal(result.status, status);
  assert.deepEqual(state.picked, []);
  assert.equal(state.submitted, 0);
});

test('W303 keeps Server URL readback, OAuth uniqueness, and form identity checks', async () => {
  const changed = await begin();
  changed.pod.userClick(changed.state.ack);
  changed.pod.userClick(changed.state.tunnel);
  assert.equal((await changed.pod.command({ ...createCommand, ack: { form: changed.result.form, warning: changed.result.warning } })).data.reason,
    'connection_not_server_url');
  assert.equal(changed.state.submitted, 0);
  const oauth = await begin({ duplicateAuth: true });
  assert.equal(oauth.result.status, 'ambiguous');
  assert.equal(oauth.result.step, 'auth');
  const replaced = await begin();
  replaced.state.name.remove();
  const result = (await replaced.pod.command({ ...createCommand, ack: { form: replaced.result.form, warning: replaced.result.warning } })).data;
  assert.equal(result.reason, 'form_replaced');
  assert.equal(replaced.state.submitted, 0);
});

test('W303 requires exactly one Create / Create as a plugin button', async () => {
  const { pod, state, result } = await begin({ duplicateCreate: true });
  assert.equal(result.reason, 'risk_ack');
  pod.userClick(state.ack);
  const continued = (await pod.command({ ...createCommand, ack: { form: result.form, warning: result.warning } })).data;
  assert.equal(continued.status, 'ambiguous');
  assert.equal(continued.step, 'create');
  assert.equal(state.submitted, 0);
});

test('W303 checkbox segments: choose and read back Server URL; an extra consent box still blocks', async () => {
  const { state, result } = await begin({ tunnelDefault: true });
  assert.equal(result.reason, 'risk_ack');
  assert.equal(state.server.clicks, 1);
  assert.equal(state.server.getAttribute('aria-checked'), 'true');
  assert.equal(state.tunnel.getAttribute('aria-checked'), 'false');
  assert.equal(state.ack.clicks + state.create.clicks, 0);
  const extra = await begin({ extraBox: true });
  assert.equal(extra.result.reason, 'checkbox');
  assert.equal(extra.state.submitted, 0);
});

test('W303 card errors describe the MCP action without pinning an obsolete label', () => {
  const source = readFileSync(new URL('../App/Sources/Tatwo2/Facade/HandsConnect.swift', import.meta.url), 'utf8');
  const errors = source.slice(source.indexOf('static let newMenuMissingText'), source.indexOf('static let formOpenText'));
  assert.match(errors, /新增選單裡找不到加 MCP 伺服器的那一項/);
  assert.doesNotMatch(errors, /建立 MCP 應用程式|Create MCP app/);
});
