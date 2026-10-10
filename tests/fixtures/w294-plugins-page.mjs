// Local DOM built from the 2026-10-08 AX excerpt. IDs and URLs are synthetic.
// The settings list deliberately has button rows, no href/IDs, and no developer switch.
import { makePage, h, FakeRect } from '../w185-pod-fixture.mjs';
export const MCP = 'https://os-for-chatgpt.example.com/mcp';
export const NAME = 'TATWO（Primary One）';
export const records = () => [2, 3, 4].map(n => ({ id: 'asdk_app_fixture' + n, name: NAME + n, url: MCP, authorized: n === 4 }));
export const realRecords = () => [{ id: 'asdk_app_mini4', name: 'TATWO（Mac mini）4', url: MCP, authorized: true, needsReconnect: true, realLayout: true },
  { id: 'asdk_app_air', name: 'TATWO（MacBook Air）', url: MCP, authorized: true, realLayout: true }];
export function pluginsPage(items = records(), { missingURL = false, missingID = false, paged = false, filtered = false,
  missingTab = false, deleteConfirmed = true, beforeConfirm, beforeDetail, overview, portal = true, emptyUnknown = false, deleteDelay = 0, detailDelay = 0, accountHeading = 'Connected accounts', accountName, accountEmail,
  accountRows = true, menuReconnect = false, duplicateURL = false, duplicateID = false, duplicateTitle = false, description = '', connectLabel = 'Connect', connectDisabled = false, missingTitle = false, settingsOpen = false, missingProfile = false, duplicateProfile = false, missingSettings = false, duplicateSettings = false, hashWorks = true, duplicateTab = false, tabWorks = true, reconnectCount = 1, reconnectLabel = 'Reconnect',
  initialPath = '/plugins', collapsedSidebar = false, sidebarLabel = 'Open sidebar', sidebarCount = 1, skeletonStore = false, homeDelay = 0, onHome, sidebarWorks = true, settingsRoute = true, onSettingsRoute, viewport } = {}) {
  let pod, settings, page = 'store';
  const clicks = { connect: [], reconnect: [], more: [], delete: [], create: 0, continue: [], sidebarPlugins: 0, profile: 0, settings: 0, settingsTab: 0, hash: 0, openSidebar: 0, home: 0, settingsRoute: 0 };
  const removeChildren = root => { for (const child of [...root._kids]) child.remove(); };
  function authorize(record) {
    const cont = h('button', {}, 'Continue to ' + record.name + ' ↗'); cont._rect = new FakeRect(40, 300, 320, 40);
    const dialog = h('div', { role: 'dialog' }, h('h2', {}, 'Connect ' + record.name),
      h('p', {}, 'Connect your account to use this plugin.'), cont);
    cont.onclick = () => { clicks.continue.push(record.id); dialog.remove(); };
    pod.body.appendChild(dialog);
  }
  function list() {
    page = 'list'; removeChildren(settings);
    const tab = h('button', {}, 'Plugins'); tab.onclick = () => { clicks.settingsTab++; if (tabWorks) list(); };
    const search = h('input', { placeholder: 'Search installed plugins' }); search._value = filtered ? 'TATWO' : '';
    const browse = h('button', {}, 'Browse directory'); browse.onclick = store;
    const rows = items.map(record => {
      const row = h('button', {}, record.name + ' ' + record.name + (record.needsReconnect ? ' Reconnect' : record.authorized ? ' Allow all tools' : ''));
      // AX clipping can report 0 height for rows below the scroll viewport.
      row._rect = new FakeRect(737, 894, 587, 0);
      row.onclick = () => { beforeDetail?.(pod); if (overview) { overview(record, pod, () => detail(record)); return; } if (detailDelay) setTimeout(() => detail(record), detailDelay); else detail(record); };
      return row;
    });
    settings.appendChild(h('button', {}, 'General')); settings.appendChild(tab);
    if (duplicateTab) settings.appendChild(h('button', {}, 'Plugins'));
    settings.appendChild(h('div', {}, h('p', {}, 'Plugins'), h('p', {}, 'Manage your plugins, connected accounts, and permissions'), browse,
      h('span', {}, 'Search installed plugins'), search, h('p', {}, 'Default permission'), h('a', { href: '/permissions' }, 'Learn more about plugin permissions'),
      ...rows, ...(!items.length && !emptyUnknown ? [h('p', {}, 'No plugins installed')] : []), ...(paged ? [h('button', {}, 'Load more')] : [])));
  }
  function detail(record) {
    page = 'detail'; removeChildren(settings);
    const back = h('a', { href: '#settings/plugins' }, 'Plugin settings'); back.onclick = list;
    const del = h('button', {}, 'Delete app');
    del.onclick = () => {
      const confirm = h('button', {}, 'Delete app');
      const dialog = h('div', { role: 'alertdialog' }, h('h2', {}, 'Delete app'),
        h('p', {}, "Permanently delete " + record.name + " and its connections? This can't be undone"), h('button', {}, 'Cancel'), confirm);
      confirm.onclick = () => { clicks.delete.push(record.id); if (deleteConfirmed) items.splice(items.indexOf(record), 1); dialog.remove(); list(); };
      const show = () => { pod.body.appendChild(dialog); beforeConfirm?.(pod); };
      if (deleteDelay) setTimeout(show, deleteDelay); else show();
    };
    const connect = h('button', { disabled: connectDisabled }, connectLabel); connect.onclick = () => { clicks.connect.push(record.id); authorize(record); };
    const more = h('button', {}, '⋯');
    more.onclick = () => {
      clicks.more.push(record.id);
      const reconnect = h('div', { role: 'menuitem' }, 'Reconnect');
      const menu = h('div', { role: 'menu' }, h('div', { role: 'menuitem' }, 'Rename account'), reconnect);
      reconnect.onclick = () => { clicks.reconnect.push(record.id); menu.remove(); authorize(record); };
      (portal ? pod.body : settings).appendChild(menu);
    };
    const direct = Array.from({ length: reconnectCount }, () => {
      const button = h('button', {}, reconnectLabel + ' ' + (accountName ?? 'Fixture Persona') + ' account');
      button.onclick = () => { clicks.reconnect.push(record.id); authorize(record); }; return button;
    });
    settings.appendChild(h('button', {}, 'General'));
    const tab = h('button', {}, 'Plugins'); tab.onclick = list; settings.appendChild(tab);
    settings.appendChild(h('div', {}, back, h('span', {}, missingTitle ? '' : record.name), ...(duplicateTitle ? [h('h2', {}, record.name)] : []), h('button', {}, 'View details'), h('button', {}, 'Uninstall'),
      h('p', {}, record.name), h('p', {}, description), ...(record.authorized ? [...(record.needsReconnect ? [] : [h('button', {}, 'Permission Allow all tools')]),
        h('section', {}, h('h3', {}, accountHeading), ...(accountRows ? [h('div', {}, h('button', { 'aria-label': accountName, title: accountName }, 'Rename ' + (accountName ?? "Fixture's " + record.name) + ' account' + (record.needsReconnect ? '' : ' (Primary)')), h('img', { alt: accountName }), h('p', {}, accountEmail ?? 'Primary'), ...(record.needsReconnect ? direct : [more]))] : [])), h('button', {}, 'Connect another account')] : [connect]),
      h('section', {}, h('h3', {}, 'About'), h('p', {}, record.authorized ? 'Connected on' : 'Created at'), h('p', {}, '2026-10-08'), h('p', {}, 'Developer'), h('p', {}, 'App developer'), h('p', {}, 'Version'), h('p', {}, 'dev mode'),
        ...(menuReconnect ? [h('div', { role: 'menu' }, h('button', {}, 'Reconnect'))] : []), h('div', {}, h('p', {}, 'URL'), ...(missingURL ? [] : [h('p', {}, record.url)])), ...(duplicateURL ? [h('div', {}, h('p', {}, 'URL'), h('p', {}, record.url))] : []), h('p', {}, 'Authorization supported'), h('p', {}, 'OAuth'), h('p', {}, 'Authorization used'), h('p', {}, 'OAuth'),
        h('p', {}, 'Version ID'), h('p', {}, 'asdk_app_v_fixture'), h('div', {}, h('p', {}, 'App ID'), ...(missingID ? [] : [h('p', {}, record.id)])), ...(duplicateID ? [h('div', {}, h('p', {}, 'App ID'), h('p', {}, record.id))] : []),
        h('p', {}, 'Review status'), h('p', {}, 'DEVELOPMENT')), ...(!record.realLayout ? [h('h3', {}, 'Manage app'), h('p', {}, 'App name'), h('button', {}, 'Edit'), h('p', {}, 'App description'), h('button', {}, 'Edit'), del] : [])));
  }
  function store() {
    page = 'store'; removeChildren(pod.body);
    if (skeletonStore && pod.pageState.pathname.startsWith('/plugins')) {
      pod.body.appendChild(h('main', {}, h('div', {}, h('div', {})))); return;
    }
    const add = h('button', { 'aria-haspopup': 'menu' }, 'Add');
    add.onclick = () => {
      const createMCP = h('div', { role: 'menuitem' }, 'Create MCP app');
      const menu = h('div', { role: 'menu' }, createMCP); pod.body.appendChild(menu);
      createMCP.onclick = () => {
        menu.remove();
        const create = h('button', {}, 'Create'); create.onclick = () => { clicks.create++; };
        pod.body.appendChild(h('div', { role: 'dialog' }, h('h2', {}, 'New Plugin'),
          h('label', { for: 'new-name' }, 'Name'), h('input', { id: 'new-name' }),
          h('p', {}, 'Connection'), h('div', { role: 'radiogroup' }, h('button', { role: 'radio', 'aria-checked': 'true' }, 'Server URL'),
          h('button', { role: 'radio', 'aria-checked': 'false' }, 'Tunnel')),
          h('label', { for: 'new-url' }, 'MCP Server URL'), h('input', { id: 'new-url', placeholder: 'https://example.com/mcp' }),
          h('label', { for: 'new-auth' }, 'Authentication'), h('select', { id: 'new-auth' }, h('option', { value: 'oauth' }, 'OAuth')), create));
      };
    };
    const sidebar = h('button', {}, 'Plugins'); sidebar.onclick = () => { clicks.sidebarPlugins++; store(); };
    const aside = h('aside', {}, h('button', {}, 'Home'), h('button', {}, 'Space'), h('button', {}, 'Scheduled'), sidebar);
    pod.body.appendChild(aside);
    if (!missingProfile) for (let i = 0; i < (duplicateProfile ? 2 : 1); i++) {
      const profile = h('button', { 'aria-label': 'Open profile menu' }, 'Profile');
      profile.onclick = () => {
        clicks.profile++; const menu = h('div', { role: 'menu' });
        if (!missingSettings) for (let j = 0; j < (duplicateSettings ? 2 : 1); j++) {
          const entry = h('div', { role: 'menuitem' }, 'Settings'); entry.onclick = () => { clicks.settings++; menu.remove(); openSettings(); }; menu.appendChild(entry);
        }
        pod.body.appendChild(menu);
      }; aside.appendChild(profile);
    }
    if (collapsedSidebar) {
      aside._hidden = true;
      for (let i = 0; i < sidebarCount; i++) {
        const open = h('button', { 'aria-label': sidebarLabel }, '');
        open.onclick = () => { clicks.openSidebar++; if (sidebarWorks) { aside._hidden = false; open.remove(); } };
        pod.body.appendChild(open);
      }
    }
    pod.body.appendChild(h('main', {}, h('h1', {}, 'Plugins'), h('input', { placeholder: 'Search plugins' }), add,
      h('button', {}, 'Plugin directory'), h('button', {}, 'Popular'), h('button', {}, 'New & Noteworthy')));
  }
  pod = makePage({ viewport: viewport ?? { width: collapsedSidebar ? 480 : 1400, height: 1000 }, installed: { status: 404, json: {} } });
  function openSettings() {
    page = 'settings';
    for (const main of [...pod.body._kids].filter(x => x.tagName === 'MAIN')) main.remove();
    settings?.remove(); settings = h('div', { role: 'group' }); pod.body.appendChild(settings);
    settings.appendChild(h('button', {}, 'General'));
    if (!missingTab) {
      const tab = h('button', {}, 'Plugins'); tab.onclick = () => { clicks.settingsTab++; if (tabWorks) list(); }; settings.appendChild(tab);
      if (duplicateTab) settings.appendChild(h('button', {}, 'Plugins'));
    }
  }
  Object.defineProperty(pod.sandbox.location, 'hash', { set(value) {
    if (value === 'settings') { clicks.hash++; if (hashWorks && page !== 'list') openSettings(); }
  } });
  pod.pageState.pathname = initialPath;
  pod.pageState.onNavigate = path => {
    if (path === '/settings') { clicks.settingsRoute++; onSettingsRoute?.(pod); if (settingsRoute) { openSettings(); return; } }
    if (path === '/') { clicks.home++; onHome?.(pod); }
    if (path === '/' && homeDelay) { removeChildren(pod.body); setTimeout(store, homeDelay); } else store();
  };
  store(); if (settingsOpen) openSettings();
  return { pod, items, clicks, list, detail, get page() { return page; } };
}
