import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture } from './w185-pod-fixture.mjs';

// Execute the production Pod script with synthetic fetch; no socket or account.
async function readModels(status = 200) {
  const p = fixture({ allowNetwork: true, respond: async url => new Response(
    JSON.stringify(url.includes('/backend-api/models') ? { models: [] } : {}),
    { status: url.includes('/backend-api/models') ? status : 200,
      headers: { 'content-type': 'application/json' } }) });
  await p.sandbox.fetch('/backend-api/me', { headers: { authorization: 'Bearer synthetic-only' } });
  p.command({ cmd: 'models', id: 'W305' });
  await p.advance(2000);
  return { p, result: p.reports.find(r => r.type === 'result' && r.id === 'W305') };
}

test('W305 ready page without a model selector returns the specific cause without sending', async () => {
  const { p, result } = await readModels();
  assert.equal(result?.ok, false);
  assert.equal(result.message, '讀不到網頁目前模型');
  assert.equal(p.button.clicks, 0);
  assert.ok(!p.requests.some(r => /\/conversation(?:\?|$)/.test(r.url)));
});

test('W305 catalog API rejection keeps the status as its cause without page content or sending', async () => {
  const { p, result } = await readModels(401);
  assert.equal(result?.ok, false);
  assert.equal(result.message, 'HTTP 401');
  assert.equal(p.button.clicks, 0);
});

test('W305 cold ready reads models when the web selector appears after the authentication event', async () => {
  const p = fixture({ allowNetwork: true, respond: async url => new Response(JSON.stringify(
    url.includes('/backend-api/models') ? { models: [{ slug: 'gpt-6', title: 'GPT-6' }] } : {}),
    { headers: { 'content-type': 'application/json' } }) });
  await p.sandbox.fetch('/backend-api/me', { headers: { authorization: 'Bearer synthetic-only' } });
  let trigger;
  p.sandbox.setTimeout(() => {
    trigger = new p.Element('button', { 'data-testid': 'model-switcher-dropdown-button',
      'data-model-slug': 'gpt-6', 'aria-expanded': 'false', 'aria-controls': 'w305-panel' });
    trigger.textContent = 'GPT-6';
    const panel = new p.Element('div', { role: 'menu', id: 'w305-panel' });
    const item = new p.Element('button', { role: 'menuitem', 'data-model-slug': 'gpt-6' }, panel);
    item.textContent = 'GPT-6';
    trigger.onClick = () => { trigger.attrs['aria-expanded'] = trigger.attrs['aria-expanded'] === 'true' ? 'false' : 'true'; };
  }, 300);
  p.command({ cmd: 'models', id: 'W305-cold' });
  await p.advance(2000);
  const result = p.reports.find(r => r.type === 'result' && r.id === 'W305-cold');
  assert.equal(result?.ok, true, JSON.stringify(result));
  assert.deepEqual(result.data.models.map(m => m.title), ['GPT-6']);
  assert.equal(trigger.attrs['aria-expanded'], 'false');
  assert.equal(p.button.clicks, 0);
});
