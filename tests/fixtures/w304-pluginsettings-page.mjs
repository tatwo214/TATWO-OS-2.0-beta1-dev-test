// Three synthetic surfaces based on the read-only 2026-10 AX evidence.
import { pluginsPage, MCP } from './w294-plugins-page.mjs';
import { h, queryAll } from '../w185-pod-fixture.mjs';
export { MCP };
export const connector = () => ({ id: 'asdk_app_w304mini4', name: 'TATWO（Mac mini）4', url: MCP, authorized: true, needsReconnect: true });
export function octoberPage(items = [connector()], options = {}) {
  let world;
  const clicks = { manage: 0, apps: 0, close: 0, forbidden: [] };
  const forbidden = label => { const b = h('button', {}, label); b.onclick = () => clicks.forbidden.push(label); return b; };
  const overview = (record, pod) => {
    options.onOverview?.(pod);
    const group = queryAll(pod.body, '[role="group"]')[0];
    for (const child of [...group._kids]) child.remove();
    const manage = h('a', { href: options.manageHref ?? '/settings/plugins-settings/plugin_' + record.id }, 'Manage');
    manage.onclick = () => { clicks.manage++; options.onManage?.(pod); pod.navigateNatively(manage.getAttribute('href')); };
    const apps = h('button', {}, record.name + ' No description');
    apps.onclick = () => {
      clicks.apps++;
      const close = h('button', { 'aria-label': 'Close dialog' }, '');
      const dialog = h('div', { role: 'dialog' }, h('h2', {}, record.name), h('p', {}, 'apply_patch edit_file job_cancel'), close);
      close.onclick = () => { clicks.close++; dialog.remove(); }; pod.body.appendChild(dialog);
    };
    const reconnect = h('button', {}, 'Reconnect Synthetic Account\'s ' + record.name + ' account Primary');
    const main = h('main', {}, h('h1', {}, record.name + ' Your cloud plugin'), forbidden('More actions'),
      ...(options.missingManage ? [] : [manage]), ...(options.duplicateManage ? [h('a', { href: manage.getAttribute('href') }, 'Manage')] : []),
      h('button', {}, 'Try in chat'), h('section', {}, h('h3', {}, 'Apps 1'), apps),
      h('section', {}, h('h3', {}, 'Connected accounts'), ...(record.authorized ? [reconnect, forbidden('Actions for Synthetic Account')] : []), forbidden('Connect another account')),
      h('section', {}, h('h3', {}, 'Information'), ...['Developer', 'Category', 'Version', 'Website'].map(x => h('p', {}, x))));
    group.appendChild(main);
    if (options.toolsOpen) apps.onclick();
  };
  world = pluginsPage(items, { ...options, accountName: 'Synthetic Account', overview });
  const oldNavigate = world.pod.pageState.onNavigate;
  const renderSettings = record => {
    world.detail(record);
    options.onSettings?.(world.pod);
    for (const b of queryAll(world.pod.body, 'button')) {
      if (b.textContent.startsWith('Reconnect Synthetic Account')) b.text = "Reconnect Synthetic Account's " + record.name + ' account Primary';
      if (['Uninstall', 'Delete app', 'Connect another account', 'Edit'].includes(b.textContent)) b.onclick = () => clicks.forbidden.push(b.textContent);
    }
    if (!record.authorized) for (const b of queryAll(world.pod.body, 'button').filter(x => x.textContent === 'Connect')) b.remove();
  };
  world.pod.pageState.onNavigate = path => {
    const record = items.find(r => path === '/settings/plugins-settings/plugin_' + r.id);
    if (record) renderSettings(record); else oldNavigate(path);
  };
  return { ...world, settings: renderSettings, octoberClicks: clicks };
}
