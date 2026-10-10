// Synthetic W322 rows with the two Codex Manage URL shapes seen on mini 2.0.22.038.
import { manageInstalledPage, installedRows as baseRows, MCP } from './w322-installed-managelink.mjs';
import { queryAll } from '../w185-pod-fixture.mjs';
export { MCP };
export function installedRows() {
  const rows = baseRows();
  [rows[13], rows[19]] = [rows[19], rows[13]]; // Codex Security is Installed row 14.
  return rows;
}
export function codexInstalledPage({ items = installedRows(), mutate, ...options } = {}) {
  return manageInstalledPage({ ...options, items, mutate(region, links) {
    links.forEach((link, i) => {
      if (!['Codex Security', 'Build iOS Apps'].includes(items[i].name)) return;
      const manage = queryAll(link.parentElement, 'a')[1];
      manage.setAttribute('href', 'https://chatgpt.com/codex/open-app?target=plugin&plugin_id=' + items[i].path.slice(9));
      manage.onclick = () => { throw new Error('Codex Manage must not be opened during connector scan'); };
    });
    mutate?.(region, links);
  } });
}
