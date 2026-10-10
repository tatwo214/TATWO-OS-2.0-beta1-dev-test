// Synthetic DOM from the W312 2026-10-08 AX evidence. No sockets or live account.
import { fixture } from '../w185-pod-fixture.mjs';
export const labels = ['Instant', 'Medium', 'High', 'Extra High', 'Pro'];
export const backend = () => ({ default_model_slug: 'six-t', models: [
  { slug: 'six-i', title: 'GPT-6', reasoning_type: 'none' },
  { slug: 'six-t', title: 'GPT-6', reasoning_type: 'reasoning' },
  { slug: 'six-p', title: 'GPT-6', reasoning_type: 'pro' },
  { slug: 'sol', title: 'GPT-5.6 Sol' }, { slug: 'five', title: 'GPT-5.5' }],
  versions: [{ id: 'latest', display_text_full: 'GPT-6', slugs: ['six-i', 'six-t', 'six-p'],
    intelligence_presets: labels.map((label, i) => ({ label, model_slug: i === 0 ? 'six-i' : i === 4 ? 'six-p' : 'six-t',
      thinking_effort: i === 0 || i === 4 ? null : ['standard', 'extended', 'max'][i - 1] })) }] });
export async function composerPage({ label = 'Select ChatGPT model', selected = 'GPT-6', locked = true, text = '', brokenSub = false,
  expanded = true, escapeClosesRoot = true, arrowLeftClosesRoot = false, backendFailure = false } = {}) {
  const p = fixture({ allowNetwork: true, respond: async url => backendFailure && url.includes('/backend-api/models')
    ? new Response('{}', { status: 500 }) : new Response(JSON.stringify(
    url.includes('/backend-api/models') ? backend() : url.includes('/settings/user')
      ? { settings: { last_used_model_config: { slugs: { web: 'six-i' } } } } : {}),
    { headers: { 'content-type': 'application/json' } }) });
  await p.sandbox.fetch('/backend-api/me', { headers: { authorization: 'Bearer synthetic-only' } });
  const el = (tag, attrs, parent, text) => { const n = new p.Element(tag, attrs, parent); if (text !== undefined) n.textContent = text; return n; };
  el('div', { role: 'group', 'aria-label': 'Composer mode' });
  el('button', { 'aria-label': 'Temporary chat' });
  el('h1', {}, null, 'Ready when you are.'); p.box.attrs.placeholder = 'Ask ChatGPT';
  const row = el('div', {}, p.form);
  el('button', { 'aria-label': 'Add files and more' }, row);
  const trigger = el('button', { 'aria-label': label, 'aria-haspopup': 'menu', ...(expanded ? { 'aria-expanded': 'false' } : {}), 'aria-controls': 'composer-menu' }, row, text);
  el('button', { 'aria-label': 'Dictate' }, row); el('button', { 'aria-label': 'Start Voice' }, row);
  const menu = el('div', { role: 'menu', id: 'composer-menu', 'aria-hidden': 'true' });
  const select = el('button', { role: 'menuitem', 'aria-haspopup': 'menu', 'aria-controls': 'model-sub' }, menu, 'Select model');
  const power = el('div', { role: 'menuitem' }, menu); el('span', {}, power, 'Power');
  const slider = el('div', { role: 'slider', 'aria-label': 'Power', 'aria-valuemin': '1', 'aria-valuemax': '5',
    'aria-valuenow': '2', 'aria-valuetext': 'Medium, 2 of 5.', 'aria-description': 'Use Left and Right arrow keys to adjust power' }, power);
  const sub = el('div', { role: 'menu', id: 'model-sub', 'aria-hidden': 'true' });
  const items = ['GPT-6', 'GPT-5.6 Sol', 'GPT-5.5'].map(name => {
    const item = el('button', { role: 'menuitemradio', 'aria-checked': String(name === selected),
      ...(name === 'GPT-6' && locked ? { 'aria-description': 'Locked, opens access options' } : {}) }, sub);
    el('span', {}, item, name);
    if (name === 'GPT-5.5') el('span', {}, item, 'Leaving on October 14');
    item.onClick = () => {
      if (name === 'GPT-6' && locked) { p.accessClicks++; return; }
      for (const x of items) x.attrs['aria-checked'] = String(x === item);
      p.selected = name; p.modelClicks.push(name);
      closeRoot();
    };
    return item;
  });
  const closeRoot = () => {
    menu.attrs['aria-hidden'] = sub.attrs['aria-hidden'] = 'true';
    if (expanded) trigger.attrs['aria-expanded'] = 'false';
  };
  trigger.onClick = () => {
    const open = menu.attrs['aria-hidden'] === 'true'; if (expanded) trigger.attrs['aria-expanded'] = String(open);
    menu.attrs['aria-hidden'] = String(!open); sub.attrs['aria-hidden'] = 'true';
  };
  select.onClick = () => { if (!brokenSub) sub.attrs['aria-hidden'] = 'false'; };
  p.sandbox.KeyboardEvent = class { constructor(type, fields) { Object.assign(this, { type }, fields); } };
  p.doc.dispatchEvent = ev => { if (ev.key === 'Escape') { p.escapeKeys++; if (escapeClosesRoot) closeRoot(); else sub.attrs['aria-hidden'] = 'true'; } };
  sub.dispatchEvent = ev => { if (ev.key === 'ArrowLeft') { if (arrowLeftClosesRoot) closeRoot(); else sub.attrs['aria-hidden'] = 'true'; } };
  slider.dispatchEvent = ev => {
    if (menu.attrs['aria-hidden'] === 'true' || sub.attrs['aria-hidden'] !== 'true') { p.hiddenPowerKeys++; return; }
    if (ev.key === 'Home') slider.attrs['aria-valuenow'] = '1';
    if (ev.key === 'ArrowRight') slider.attrs['aria-valuenow'] = String(Number(slider.attrs['aria-valuenow']) + 1);
    slider.attrs['aria-valuetext'] = labels[Number(slider.attrs['aria-valuenow']) - 1] + ', ' + slider.attrs['aria-valuenow'] + ' of 5.';
  };
  Object.assign(p, { trigger, menu, sub, select, slider, items, selected, accessClicks: 0, modelClicks: [], escapeKeys: 0, hiddenPowerKeys: 0 });
  p.button.onClick = () => p.sandbox.fetch('/backend-api/f/conversation', { method: 'POST', body: JSON.stringify({
    model: p.selected === 'GPT-5.6 Sol' ? 'sol' : p.selected === 'GPT-5.5' ? 'five' : 'six-t',
    messages: [{ role: 'user', content: { parts: ['synthetic question'] } }] }) });
  return p;
}
export async function readCatalog(p) {
  p.command({ cmd: 'models', id: 'W312-models' }); await p.advance(4000);
  return p.reports.find(r => r.type === 'result' && r.id === 'W312-models');
}
