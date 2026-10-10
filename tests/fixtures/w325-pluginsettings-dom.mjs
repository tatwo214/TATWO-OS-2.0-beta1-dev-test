// Synthetic 1100×800 full-page DOM from mini's 2026-10-09 evidence; no real account data.
import { settingsPage as legacyPage, installedRows, MCP } from './w324-pluginsettings-page.mjs';
import { h, queryAll } from '../w185-pod-fixture.mjs';
export { installedRows, MCP };
export function settingsPage({ mutate, ...options } = {}) {
  return legacyPage({ ...options, mutate({ pod, content, about: oldAbout, accounts: oldAccounts, reconnect, name, id, settingsNavigation }) {
    const main = content.parentElement;
    main.setAttribute('role', 'main'); main.setAttribute('class', 'MainContentSurface-fixture');
    const back = queryAll(content, 'a')[0];
    back.setAttribute('href', '/settings/plugins-settings');
    const breadcrumb = h('nav', { 'aria-label': 'Breadcrumb' }, back, h('div', {}, name));
    const account = 'Fixture Person';
    reconnect.setAttribute('aria-label', `Reconnect ${account}'s ${name} account Primary`);
    reconnect.setAttribute('id', 'connector_' + id.slice(9) + '-reconnect');
    const rename = queryAll(oldAccounts, 'button')[0];
    rename.setAttribute('aria-label', `Rename ${account}'s ${name} account (Primary)`);
    const accounts = h('div', { id: 'plugin-connected-accounts-connector_' + id.slice(9), class: 'flex flex-col' },
      h('div', { class: 'font-medium text-default' }, 'Connected accounts'), h('div', {}, rename, reconnect),
      queryAll(oldAccounts, 'button').at(-1));
    const field = (label, value) => h('div', { class: 'grid' }, h('div', { class: 'text-secondary' }, label), h('div', {}, value));
    const about = h('div', { class: 'flex flex-col' }, h('div', { class: 'font-medium text-default' }, 'About'),
      ...oldAbout._kids.slice(1).map(row => field(row._kids[0].textContent, row._kids[1].textContent)));
    const header = h('header', {}, h('h1', {}, name), h('div', { id: '_r_fixture_', class: 'line-clamp-3' }, 'Synthetic plugin description'),
      queryAll(content, 'a')[0], queryAll(content, 'button').find(b => b.textContent === 'Uninstall'));
    // back was moved into Breadcrumb; the remaining link is View details.
    queryAll(header, 'a')[0].setAttribute('href', '/plugins/plugin_' + id);
    const scroll = h('div', { class: 'flex-1 overflow-y-auto' }, header, accounts, about);
    for (const child of [...content._kids]) child.remove();
    content.setAttribute('class', 'WorkspaceContent-fixture');
    content.appendChild(h('div', { class: 'MainContentViewport-fixture' }, h('div', { class: 'MainContentFrame-fixture' },
      h('div', {}, h('div', { class: 'relative isolate flex h-full' }, breadcrumb, scroll)))));
    mutate?.({ pod, main, content, breadcrumb, header, accounts, about, reconnect, settingsNavigation, name, id, field });
  } });
}
