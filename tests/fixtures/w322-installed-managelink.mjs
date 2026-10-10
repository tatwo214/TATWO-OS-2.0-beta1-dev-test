// Synthetic rows mirror mini 2.0.22.037 AX evidence: name, Manage, hidden More actions.
import { tildeInstalledPage, installedRows, MCP } from './w319-installed-tilde.mjs';
import { h, queryAll, FakeRect } from '../w185-pod-fixture.mjs';
export { installedRows, MCP };
export function manageInstalledPage({ absolute = true, items = installedRows(), mutate, ...options } = {}) {
  const installedClicks = { names: 0, manage: 0, paths: [] };
  let mountSettings;
  const world = tildeInstalledPage(items, { ...options, onInstalled(region) {
    const links = queryAll(region, 'a');
    links.forEach((link, i) => {
      const path = link.getAttribute('href');
      if (absolute) link.setAttribute('href', 'https://chatgpt.com' + path);
      const open = link.onclick;
      mountSettings ??= open;
      link.onclick = () => { installedClicks.names++; open(); };
      const managePath = '/settings/plugins-settings/' + path.slice('/plugins/'.length);
      const manage = h('a', { href: (absolute ? 'https://chatgpt.com' : '') + managePath,
        'aria-label': 'Manage ' + items[i].name }, h('span', {}, 'Manage ' + items[i].name));
      manage.onclick = () => {
        installedClicks.manage++; installedClicks.paths.push(managePath);
        world.pod.navigateNatively(managePath);
      };
      const more = queryAll(link.parentElement, 'button')[0];
      more.remove(); more.style.visibility = 'hidden'; more._rect = new FakeRect(0, 0, 1, 1);
      more.setAttribute('id', 'radix-_r_fixture_' + i + '_');
      link.parentElement.appendChild(manage); link.parentElement.appendChild(more);
    });
    mutate?.(region, links);
  } });
  // The legacy fixture keeps its settings group detached while Installed is mounted.
  mountSettings();
  const settings = queryAll(world.pod.body, '[role="group"]')[0];
  world.render();
  const navigate = world.pod.pageState.onNavigate;
  world.pod.pageState.onNavigate = path => {
    if (items.some(x => path === '/settings/plugins-settings/' + x.path.slice(9))) {
      for (const child of [...world.pod.body._kids]) child.remove();
      world.pod.body.appendChild(settings);
    }
    navigate(path);
  };
  return { ...world, installedClicks };
}
