// W316: 10-08 22:00 AX evidence, 1100×800; all requests stay in the synthetic DOM.
import { fixture } from '../w185-pod-fixture.mjs';
import { backend, labels } from './w312-composer-picker.mjs';
export async function realComposerPage({ selected = 'GPT-6', checked = 'aria-checked', delayed = 120, brokenSub = false, roleless = false, fadedIn = false, clickToggles = false, lateContent = false, catalog = backend } = {}) {
  const p = fixture({ allowNetwork: true, respond: async url => new Response(JSON.stringify(
    url.includes('/backend-api/models') ? catalog() : {}), { headers: { 'content-type': 'application/json' } }) });
  await p.sandbox.fetch('/backend-api/me', { headers: { authorization: 'Bearer synthetic-only' } });
  Object.assign(p.sandbox, { innerWidth: 1100, innerHeight: 800 });
  const el = (tag, attrs, parent, text) => { const n = new p.Element(tag, attrs, parent); if (text !== undefined) n.textContent = text; return n; };
  const trigger = el('button', { id: 'radix-_r_8v_', 'aria-label': 'Select ChatGPT model', 'aria-haspopup': 'menu',
    'aria-expanded': 'false', 'aria-controls': 'radix-_r_90_' }, p.form);
  const menu = el('div', { id: 'radix-_r_90_', role: 'menu', 'aria-label': 'Select ChatGPT model', 'aria-hidden': 'true' });
  // W346: 10-10 AX evidence — the panel is a plain div (class Menu-…) with no role, id or aria-controls link.
  if (roleless) { for (const key of ['id', 'role', 'aria-label']) delete menu.attrs[key]; delete trigger.attrs['aria-controls']; }
  const select = el('div', { role: 'menuitem', 'aria-label': 'Select model' }, menu, 'Select model GPT-6');
  const status = el('div', { id: '_r_ua_', role: 'status', 'aria-live': 'polite' }, menu, 'Medium, 2 of 5.');
  const help = el('div', { id: '_r_ub_' }, menu, 'Use Left and Right arrow keys to adjust power');
  const power = el('div', { role: 'menuitem', 'aria-label': 'Power', tabindex: '0' }, menu);
  for (let i = 0; i < 5; i++) el('div', {}, power);
  const announcement = el('div', { id: '_r_tp_', role: 'status', 'aria-live': 'polite' }, menu, 'Locked, opens access options');
  const items = ['GPT-6', 'GPT-5.6 Sol', 'GPT-5.5'].map(name => {
    const item = el('div', { role: 'menuitem', [checked]: checked === 'data-state' ? name === selected ? 'checked' : 'unchecked' : String(name === selected) }, menu);
    el('span', {}, item, name); if (name === 'GPT-5.5') el('span', {}, item, 'Leaving on October 14');
    item.onClick = () => {
      p.modelClicks.push(name); p.selected = name;
      for (const n of items) n.attrs[checked] = checked === 'data-state' ? n === item ? 'checked' : 'unchecked' : String(n === item);
      trigger.onClick();
    };
    return item;
  });
  const main = [select, status, help, power], models = [announcement, ...items];
  // Detached children model actual content replacement; the menu keeps the same ID and object.
  const show = modelPage => {
    for (const n of [...main, ...models]) {
      const connected = main.includes(n) ? !modelPage : modelPage;
      for (const child of p.nodes.filter(child => n.contains(child))) child.isConnected = connected;
      n.parentElement = connected ? menu : null;
    }
    p.modelPage = modelPage;
  };
  trigger.onClick = () => {
    const open = menu.attrs['aria-hidden'] === 'true';
    trigger.attrs['aria-expanded'] = String(open); menu.attrs['aria-hidden'] = String(!open); if (open) show(false);
  };
  // W346b: the background pod may leave the fade-in at opacity 0; some triggers toggle on pointerdown and click.
  if (fadedIn) menu.style.opacity = '0';
  if (clickToggles) {
    p.sandbox.PointerEvent = class { constructor(type, fields) { Object.assign(this, { type }, fields); } };
    trigger.dispatchEvent = event => { if (event.type === 'pointerdown') trigger.onClick(); return true; };
  }
  // W346c: the panel mounts first and draws its first view a moment later.
  if (lateContent) {
    const toggle = trigger.onClick;
    trigger.onClick = () => {
      const opening = menu.attrs['aria-hidden'] === 'true'; toggle();
      if (!opening) return;
      for (const n of [...main, ...models]) { for (const child of p.nodes.filter(c => n.contains(c))) child.isConnected = false; n.parentElement = null; }
      p.later(300, () => show(false));
    };
  }
  trigger.getClientRects = () => [{ width: trigger.attrs['aria-expanded'] === 'true' ? 155 : 107, height: 40 }];
  select.onClick = () => { if (!brokenSub) p.later(120, () => show(true)); };
  p.sandbox.KeyboardEvent = class { constructor(type, fields) { Object.assign(this, { type }, fields); } };
  p.doc.dispatchEvent = event => { if (event.key === 'Escape' && menu.attrs['aria-hidden'] === 'false') trigger.onClick(); };
  power.dispatchEvent = event => {
    p.powerKeys.push(event.key); if (p.modelPage || menu.attrs['aria-hidden'] === 'true') p.hiddenPowerKeys++;
    if (p.doc.activeElement !== power) throw new Error('Power must have focus');
    if (p.pending) throw new Error('Each arrow must wait for the live status update');
    p.pending = true;
    p.later(delayed, () => {
      p.level = Math.max(1, Math.min(5, p.level + (event.key === 'ArrowRight' ? 1 : -1)));
      status.textContent = labels[p.level - 1] + ', ' + p.level + ' of 5.'; p.pending = false;
    });
  };
  Object.assign(p, { trigger, menu, select, status, power, help, announcement, items, selected,
    modelClicks: [], powerKeys: [], hiddenPowerKeys: 0, level: 2, show });
  show(false);
  p.button.onClick = () => p.sandbox.fetch('/backend-api/f/conversation', { method: 'POST', body: JSON.stringify({
    model: p.selected === 'GPT-5.6 Sol' ? 'sol' : p.selected === 'GPT-5.5' ? 'five' : 'six-t',
    messages: [{ role: 'user', content: { parts: ['synthetic question'] } }] }) });
  return p;
}
