// Synthetic DOM mirrors evidence/w304b/plugins-sidebar-ax.txt; no live account data.
import { octoberPage, connector, MCP } from './w304-pluginsettings-page.mjs';
import { h, queryAll } from '../w185-pod-fixture.mjs';
export { connector, MCP };
export function installedPage(items = [connector()], options = {}) {
  let render;
  const world = octoberPage(items, { onSettings(pod) {
    queryAll(pod.body, 'a').find(a => a.textContent === 'Plugin settings').onclick = () => render();
  }, ...options });
  const { pod } = world;
  const catalog = queryAll(pod.body, 'main')[0];
  catalog.appendChild(h('button', {}, 'Install TATWO（Catalogue）'));
  pod.userClick(queryAll(pod.body, 'button').find(b => b.getAttribute('aria-label') === 'Open profile menu'));
  pod.userClick(queryAll(pod.body, '[role="menuitem"]')[0]);
  world.list();
  const group = queryAll(pod.body, '[role="group"]')[0];
  render = () => {
    for (const child of [...pod.body._kids]) child.remove();
    pod.pageState.pathname = '/plugins';
    const rows = items.map(record => {
      const link = h(options.rowTag ?? 'a', { href: options.href ?? '/plugins/' + record.id }, ...(options.narrow ? [h('span', {}, ''), h('span', {}, record.name)] : [record.name]));
      link.onclick = () => {
        for (const child of [...pod.body._kids]) child.remove();
        pod.body.appendChild(group); world.list();
        queryAll(group, 'button').find(b => b.textContent.startsWith(record.name)).onclick();
      };
      const more = h('button', { 'aria-label': 'More actions' }, '');
      more.onclick = () => world.octoberClicks.forbidden.push('More actions');
      return h('div', {}, link, ...(options.missingMore ? [] : [more]));
    });
    const sidebar = options.narrow ? h('div', {}, h('div', {}, h('h1', {}, 'Customize'),
      h('a', { href: '/plugins' }, 'Plugins'), h('a', { href: '/skills' }, 'Skills')), h('div', {},
      ...(!options.missingInstalled ? [h('div', {}, 'Installed')] : []), ...rows,
      ...(options.busy ? [h('div', { 'aria-busy': 'true' })] : [])))
      : h('div', {}, h('div', {}, h('h2', {}, 'Customize'), h('button', { 'aria-label': 'Search installed plugins' }, ''),
      h('button', { 'aria-label': 'Toggle sidebar' }, '')), h('div', {},
        h('a', { href: '/plugins' }, 'Plugins'), h('a', { href: '/skills' }, 'Skills'),
        ...(!options.missingInstalled ? [h('div', {}, h('span', {}, 'Installed'))] : []),
        ...rows, ...(options.paged ? [h('button', {}, 'Load more')] : []), ...(options.busy ? [h('div', { 'aria-busy': 'true' })] : [])));
    if (options.filtered) sidebar.appendChild(h('input', { value: 'TATWO' }));
    pod.body.appendChild(sidebar); pod.body.appendChild(catalog);
  };
  const oldNavigate = pod.pageState.onNavigate;
  pod.pageState.onNavigate = path => path === '/plugins' ? render() : oldNavigate(path);
  render();
  return { ...world, render };
}
