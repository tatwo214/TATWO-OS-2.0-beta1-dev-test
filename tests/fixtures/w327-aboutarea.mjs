// Synthetic mini 2026-10-09 outline: three sections, wrapped titles and sibling rows.
import { settingsPage as previousPage, installedRows, MCP } from './w326-aboutfields.mjs';
import { h, queryAll } from '../w185-pod-fixture.mjs';
export { installedRows, MCP };
export function settingsPage({ accountID = true, titleDepth = 3, mutate, ...options } = {}) {
  const dangerous = [];
  const world = previousPage({ ...options, mutate({ about, accounts: oldAccounts, header, ...context }) {
    const wrap = title => {
      let node = h('div', {}, title);
      for (let i = 1; i < titleDepth; i++) node = h('div', {}, node);
      return node;
    };
    const fields = h('div', {}, ...about._kids.slice(1));
    about._kids[0].remove(); about.appendChild(wrap('About')); about.appendChild(fields);
    const accounts = h('section', accountID ? { id: oldAccounts.getAttribute('id') } : {},
      wrap('Connected accounts'), h('div', {}, ...oldAccounts._kids.slice(1)));
    const scroll = oldAccounts.parentElement;
    about.remove(); oldAccounts.remove(); scroll.appendChild(accounts); scroll.appendChild(about);
    const action = label => h('button', {}, label);
    const manage = h('section', {}, wrap('Manage app'), h('div', {},
      h('div', {}, h('div', {}, 'App name'), action('Edit')),
      h('div', {}, h('div', {}, 'App description'), action('Edit')),
      h('div', {}, h('div', {}, 'Delete app'), action('Delete app'))));
    about.parentElement.appendChild(manage);
    for (const button of [...queryAll(header, 'button'), ...queryAll(manage, 'button')]) {
      if (['Uninstall', 'Edit', 'Delete app'].includes(button.textContent)) dangerous.push(button);
    }
    const row = label => fields._kids.find(x => x._kids[0].textContent === label);
    mutate?.({ ...context, about, accounts, header, manage, fields, row });
  } });
  return { ...world, dangerous };
}
