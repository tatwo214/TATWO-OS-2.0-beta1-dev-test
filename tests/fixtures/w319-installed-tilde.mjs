// Synthetic IDs; four URL shapes from mini 2.0.22.035 AX evidence, 2026-10-09.
import { installedPage, connector, MCP } from './w304b-installed-sidebar.mjs';
import { h, queryAll } from '../w185-pod-fixture.mjs';
export { MCP };
const hex = n => n.toString(16).padStart(32, '0');
export function installedRows() {
  const names = ['TATWO（Mac mini）4', 'TATWO（Studio）', 'Notion', 'Binance',
    'Google Calendar', 'Figma', 'Google Drive', 'Gmail', 'Dropbox', 'Slack', 'GitHub',
    'Linear', 'Canva', 'Spotify', 'Booking', 'Expedia', 'Coursera', 'Microsoft Teams',
    'NVIDIA Skills', 'Codex Security', 'Creative Production', 'Product Design',
    'Remotion', 'Build Web Apps', 'Build macOS Apps', 'Build iOS Apps'];
  return names.map((name, i) => {
    const id = (i < 4 ? 'asdk_app_' : i < 11 ? 'plugin_connector_1p_'
      : i < 18 ? 'plugin_connector_' : i < 22 ? 'Plugin_' : 'plugins~Plugin_') + hex(i + 1);
    return { ...(i < 2 ? connector() : {}), id, name,
      path: '/plugins/' + (i < 4 ? 'plugin_' : '') + id };
  });
}
export function tildeInstalledPage(items = installedRows(), options = {}) {
  const world = installedPage(items, { narrow: true, viewport: { width: 1100, height: 800 }, ...options }), { pod } = world;
  const originalRender = world.render;
  const render = () => {
    originalRender();
    const region = pod.body._kids[0]._kids[1];
    queryAll(region, 'a').forEach((link, i) => {
      link.setAttribute('href', items[i].path);
      const open = link.onclick;
      link.onclick = () => { pod.pageState.pathname = link.getAttribute('href'); open(); };
    });
    const catalog = queryAll(pod.body, 'main')[0];
    while (queryAll(pod.body, 'button').length < 137) catalog.appendChild(h('button', {}, 'Install catalogue item'));
    options.onInstalled?.(region);
  };
  const navigate = pod.pageState.onNavigate;
  pod.pageState.onNavigate = path => path === '/plugins' ? render() : navigate(path);
  render();
  return { ...world, render };
}
