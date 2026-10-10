// Synthetic full-page layout from the 2026-10-09 1100×800 AX evidence.
import { manageInstalledPage, installedRows, MCP } from './w322-installed-managelink.mjs';
import { h, queryAll } from '../w185-pod-fixture.mjs';
export { installedRows, MCP };
export function settingsPage({ mutate, onInstalled, ...options } = {}) {
  const forbidden = [];
  let content;
  const world = manageInstalledPage({ ...options, mutate: onInstalled, onSettings(pod) {
    const name = queryAll(pod.body, 'span').find(x => x.textContent.startsWith('TATWO（')).textContent;
    const oldAbout = queryAll(pod.body, 'h3').find(x => x.textContent === 'About').parentElement;
    const id = queryAll(oldAbout, 'p').find(x => x.textContent === 'App ID').parentElement._kids[1].textContent;
    const oldReconnect = queryAll(pod.body, 'button').find(x => x.textContent.startsWith('Reconnect Synthetic Account'));
    const action = (label, attrs = {}) => {
      const b = h('button', attrs, label); b.onclick = () => forbidden.push(label || attrs['aria-label']); return b;
    };
    const field = (label, value) => h('div', {}, h('p', {}, label), h('p', {}, value));
    const back = h('a', { href: '/plugins' }, h('span', {}, 'Plugin settings'));
    back.onclick = () => pod.navigateNatively('/plugins');
    const reconnect = h('button', { 'aria-label': "Reconnect Synthetic Account's " + name + ' account Primary' });
    reconnect.onclick = oldReconnect.onclick;
    const accounts = h('section', {}, h('h2', {}, 'Connected accounts'), h('div', {},
      action('', { 'aria-label': "Rename Synthetic Account's " + name + ' account (Primary)' }), h('p', {}, 'Primary'), reconnect),
      action('Connect another account'));
    const about = h('section', {}, h('h2', {}, 'About'), field('Connected on', 'Oct 2, 2026'), field('Developer', 'App developer'),
      field('Version', 'dev mode'), field('URL', MCP), field('Authorization supported', 'OAuth'), field('Authorization used', 'OAuth'),
      field('Version ID', 'asdk_app_v_' + 'e'.repeat(32)), field('App ID', id), field('Review status', 'DEVELOPMENT'));
    content = h('div', { 'data-fixture': 'plugin-content' }, h('div', {}, back, h('div', {}, h('h1', {}, name))),
      h('p', {}, name), h('a', { href: '/plugins/plugin_' + id }, 'View details'), action('Uninstall'), accounts, about);
    const appNavigation = h('div', { role: 'navigation', 'aria-label': 'App navigation' },
      ...['Home', 'Space', 'Scheduled', 'Plugins', 'Explore', 'Sites'].map(label => h('a', { href: '/' + label.toLowerCase() }, label)));
    const settingsNavigation = h('nav', { role: 'navigation', 'aria-label': 'Settings' }, h('h1', {}, 'Settings'),
      h('input', { id: 'settings-search', placeholder: 'Search settings' }),
      ...['Personal', 'Integrations', 'Coding'].map(label => h('section', {}, h('h2', {}, label), action(label + ' settings'))));
    for (const child of [...pod.body._kids]) child.remove();
    pod.body.appendChild(h('aside', { role: 'complementary' }, appNavigation, settingsNavigation));
    pod.body.appendChild(h('main', {}, content));
    mutate?.({ pod, content, about, accounts, reconnect, settingsNavigation, id, name, field });
  } });
  return { ...world, forbidden, get content() { return content; } };
}
