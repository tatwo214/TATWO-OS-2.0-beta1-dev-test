import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture } from './w185-pod-fixture.mjs';

const labels = ['Instant', 'Medium', 'High', 'Extra High', 'Pro'];
const presets = labels.map((label, i) => ({ label, model_slug: i === 0 ? 'six-i' : i === 4 ? 'six-p' : 'six-t',
  thinking_effort: i === 0 || i === 4 ? null : ['standard', 'extended', 'max'][i - 1] }));
const backend = () => ({ default_model_slug: 'gpt-5-5', models: [
  { slug: 'six-i', title: 'Incorrect backend title' }, { slug: 'six-t', title: 'Incorrect backend title' },
  { slug: 'six-p', title: 'Incorrect backend title' }, { slug: 'gpt-5-5', title: 'GPT-5.5' },
  { slug: 'gpt-5-6-t-mini', title: 'GPT-5.6 Luna' }, { slug: 'o3-pro', title: 'o3-pro' }],
  versions: [{ id: 'latest', display_text_full: 'Wrong backend model name', slugs: ['six-i', 'six-t', 'six-p'], intelligence_presets: presets },
    { id: '5.5', enabled: true, display_text_full: '舊版 • 5.5', slugs: ['gpt-5-5'], intelligence_presets: [{ label: 'Pro', model_slug: 'gpt-5-5' }] }] });

async function page({ locked = true, power = true, title = 'GPT-6', data = backend() } = {}) {
  const p = fixture({ allowNetwork: true, respond: async (url) =>
    new Response(JSON.stringify(url.includes('/backend-api/models') ? data : url.includes('/backend-api/settings/user') ? { settings: { last_used_model_config: { slugs: { web: 'six-t' }, juices: { web: { 'six-t': 'standard' } } } } } : {}), { headers: { 'content-type': 'application/json' } }) });
  // fetch is a synthetic stub; every response is supplied above, no socket is opened.
  await p.sandbox.fetch('/backend-api/me', { headers: { authorization: 'Bearer synthetic-only' } });
  const trigger = new p.Element('button', { 'data-testid': 'model-switcher-dropdown-button', 'aria-expanded': 'false' });
  trigger.textContent = title;
  const menu = new p.Element('div', { role: 'menu', id: 'model-panel' });
  trigger.attrs['aria-controls'] = 'model-panel';
  const select = new p.Element('button', { role: 'menuitem', 'aria-label': locked ? 'Locked, opens access options' : 'Select model' }, menu);
  select.textContent = 'Select model';
  let slider;
  if (power) {
    slider = new p.Element('div', { role: 'slider', 'aria-label': 'Power', 'aria-valuemin': '1', 'aria-valuemax': '5',
      'aria-valuenow': '2', 'aria-valuetext': 'Medium, 2 of 5' }, menu);
    p.sandbox.KeyboardEvent = class { constructor(type, fields) { Object.assign(this, { type }, fields); } };
    slider.dispatchEvent = (event) => {
      if (event.key === 'Home') slider.attrs['aria-valuenow'] = slider.attrs['aria-valuemin'];
      if (event.key === 'ArrowRight') slider.attrs['aria-valuenow'] = String(Number(slider.attrs['aria-valuenow']) + 1);
      slider.attrs['aria-valuetext'] = labels[Number(slider.attrs['aria-valuenow']) - 1] + ', ' + slider.attrs['aria-valuenow'] + ' of 5';
    };
  }
  trigger.onClick = () => { trigger.attrs['aria-expanded'] = trigger.attrs['aria-expanded'] === 'true' ? 'false' : 'true'; };
  return Object.assign(p, { trigger, menu, select, slider });
}
async function models(p, id = 'M') {
  p.command({ cmd: 'models', id });
  await p.advance(2000);
  const result = p.reports.find((r) => r.type === 'result' && r.id === id);
  assert.ok(result, JSON.stringify(p.reports));
  return result;
}

test('W297 locked Select model and Power five steps expose one current web name', async () => {
  const p = await page();
  const result = await models(p);
  assert.equal(result.ok, true);
  assert.deepEqual(result.data.models, []);
  assert.deepEqual(result.data.versions.map((v) => [v.id, v.title]), [['latest', 'GPT-6']]);
  assert.deepEqual(result.data.versions[0].presets.map((v) => v.title), labels);
  assert.equal(result.data.current.preset, 'six-t|standard');
  assert.equal(p.trigger.attrs['aria-expanded'], 'false', 'scan restores the menu');
  assert.doesNotMatch(JSON.stringify(result.data), /5\.5|gpt-5|Luna|o3-pro|Incorrect|Wrong/);
});

test('W297 names are copied from the web even when the backend title disagrees', async () => {
  const p = await page({ title: '網頁當前模型名稱' });
  assert.equal((await models(p)).data.versions[0].title, '網頁當前模型名稱');
});

test('W297 unlocked list admits only enabled visible model items, never legacy versions', async () => {
  const p = await page({ locked: false });
  const visible = new p.Element('button', { role: 'menuitem', 'data-model-slug': 'gpt-5-6-t-mini' }, p.menu);
  visible.textContent = '網頁顯示名稱';
  const old = new p.Element('button', { role: 'menuitem', 'data-model-slug': 'version:5.5' }, p.menu);
  old.textContent = '舊版 • 5.5';
  const hidden = new p.Element('button', { role: 'menuitem', 'data-model-slug': 'o3-pro' }, p.menu);
  hidden.textContent = 'o3-pro'; hidden.style.display = 'none';
  const disabled = new p.Element('button', { role: 'menuitem', 'data-model-slug': 'gpt-5-5', 'aria-disabled': 'true' }, p.menu);
  disabled.textContent = 'GPT-5.5';
  const result = await models(p);
  assert.deepEqual(result.data.models.map((m) => [m.slug, m.title]), [['gpt-5-6-t-mini', '網頁顯示名稱']]);
  assert.equal(result.data.versions.length, 1);
});

test('W297 missing web name never falls back to backend title or slug', async () => {
  const p = await page({ title: 'Select model' });
  const result = await models(p);
  assert.equal(result.ok, false);
  assert.equal(result.data, undefined);
});

test('W297 Power count and current label override mismatched backend capabilities', async () => {
  const p = await page(); p.slider.attrs['aria-valuemax'] = '4';
  const result = await models(p);
  assert.equal(result.ok, true);
  assert.equal(result.data.versions[0].presets.length, 4);
  assert.equal(result.data.versions[0].presets[1].title, 'Medium');
  const renamed = await page(); renamed.slider.attrs['aria-valuetext'] = 'Different, 2 of 5';
  assert.equal((await models(renamed)).data.versions[0].presets[1].title, 'Different');
});

test('W297 locked menu without Power only names the current model shown by the web', async () => {
  const data = backend(); data.models.push({ slug: 'six', title: 'Web Model' });
  const p = await page({ power: false, title: 'Web Model', data });
  const result = await models(p);
  assert.deepEqual(result.data.models.map((m) => [m.slug, m.title]), [['six', 'Web Model']]);
  assert.deepEqual(result.data.versions, []);
});

test('W297 retired or invisible selections never appear in the returned catalog', async () => {
  const p = await page();
  const result = await models(p);
  const codes = result.data.models.map((m) => m.slug).concat(result.data.versions.flatMap((v) => v.presets.map((e) => e.id)));
  for (const id of ['version:5.5', 'gpt-5-5', 'o3-pro', 'gpt-5-5|standard', 'six-t|unavailable']) assert.ok(!codes.includes(id));
  assert.equal(p.button.clicks, 0, 'catalog reads do not submit');
});

test('W297 allowed current Power step submits its explicit slug/effort mapping', async () => {
  const p = await page();
  p.button.onClick = () => p.sandbox.fetch('/backend-api/f/conversation', { method: 'POST',
    body: JSON.stringify({ model: 'six-i', thinking_effort: 'old', messages: [{ role: 'user', content: { parts: ['synthetic question'] } }] }) });
  p.send({ effort: 'six-t|extended' }); await p.advance(6000);
  assert.equal(p.button.clicks, 1, JSON.stringify(p.reports));
  const request = p.requests.find((r) => r.url.includes('/backend-api/f/conversation'));
  assert.ok(request);
  const body = JSON.parse(request.init.body);
  assert.equal(body.model, 'six-t');
  assert.equal(body.thinking_effort, 'extended');
});

test('W297 listing models does not press the retry button', async () => {
  const p = await page();
  const retry = new p.Element('button', { 'aria-label': 'Regenerate' }, p.form);
  await models(p);
  assert.equal(retry.clicks, 0);
});

test('W297 unrelated open menus cannot expand the available models', async () => {
  const p = await page({ locked: false });
  const other = new p.Element('div', { role: 'menu', id: 'other-panel' });
  const old = new p.Element('button', { role: 'menuitem', 'data-model-slug': 'gpt-5-5' }, other);
  old.textContent = 'GPT-5.5';
  assert.deepEqual((await models(p)).data.models, []);
});

test('W297 ambiguous panel is rejected; plain backend labels cannot change web Power count', async () => {
  const p = await page(); delete p.trigger.attrs['aria-controls'];
  new p.Element('div', { role: 'menu', id: 'other-panel' });
  assert.equal((await models(p)).ok, false);
  const data = backend(); data.versions[0].intelligence_presets = ['Instant', 'Medium', 'High', 'Extra High', 'Pro'];
  const result = await models(await page({ data }));
  assert.equal(result.ok, true);
  assert.deepEqual(result.data.versions[0].presets.map((p) => p.title), labels);
  assert.deepEqual(result.data.versions[0].presets.map((p) => p.id), ['web-power|1', 'web-power|2', 'web-power|3', 'web-power|4', 'web-power|5']);
});

test('W297 backend containing only retired models still gives one web model and five Power steps', async () => {
  const p = await page({ data: { models: [{ slug: 'gpt-5-5', title: 'GPT-5.5' }] } });
  const result = await models(p);
  assert.equal(result.ok, true);
  assert.equal(result.data.models.length, 0);
  assert.equal(result.data.versions.length, 1);
  assert.equal(result.data.versions[0].title, 'GPT-6');
  assert.equal(result.data.versions[0].presets.length, 5);
  assert.doesNotMatch(JSON.stringify(result.data), /gpt-5|5\.5/);
});

test('W297 an unreadable Power value fails the catalog without pressing submit', async () => {
  const p = await page({ data: { models: [] } });
  p.slider.attrs['aria-valuenow'] = 'unreadable';
  assert.equal((await models(p)).ok, false);
  assert.equal(p.button.clicks, 0);
});
