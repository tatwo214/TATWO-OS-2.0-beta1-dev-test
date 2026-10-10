// Synthetic Installed rows; complete URLs and hover-only nested More actions.
import { tildeInstalledPage, installedRows, MCP } from './w319-installed-tilde.mjs';
import { h, queryAll } from '../w185-pod-fixture.mjs';
export { installedRows, MCP };
export function rowWhyPage({ absolute = false, hidden = '', items = installedRows(), mutate } = {}) {
  return tildeInstalledPage(items, { onInstalled(region) {
    const links = queryAll(region, 'a');
    for (const link of links) {
      if (absolute) link.setAttribute('href', 'https://chatgpt.com' + link.getAttribute('href'));
      const more = queryAll(link.parentElement, 'button')[0];
      more.remove();
      if (hidden === 'visibility') more.style.visibility = 'hidden';
      if (hidden === 'opacity') more.style.opacity = '0';
      link.parentElement.appendChild(h('div', {}, h('span', {}, h('div', { role: 'presentation' }, more))));
    }
    mutate?.(region, links);
  } });
}
