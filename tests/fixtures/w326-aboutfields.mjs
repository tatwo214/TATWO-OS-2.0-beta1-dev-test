// Synthetic About section matching mini's 2026-10-09 AX/class evidence.
import { settingsPage as previousPage, installedRows, MCP } from './w325-pluginsettings-dom.mjs';
import { h } from '../w185-pod-fixture.mjs';
export { installedRows, MCP };
export function settingsPage({ nested = false, extraAbout = false, mutate, ...options } = {}) {
  return previousPage({ ...options, mutate({ about: oldAbout, ...context }) {
    const field = (label, value) => h('div', { class: 'grid items-center min-h-14 sm:gap-6' },
      h('div', { class: 'min-w-0 text-sm text-secondary' }, label),
      h('div', { class: 'min-w-0 break-words whitespace-normal' }, value));
    const about = h('section', { class: 'flex flex-col' }, h('div', { class: 'font-medium' }, 'About'),
      ...oldAbout._kids.slice(1).map(row => {
        const grid = field(row._kids[0].textContent, row._kids[1].textContent);
        return nested ? h('div', {}, grid) : grid;
      }));
    oldAbout.parentElement.appendChild(about); oldAbout.remove();
    if (extraAbout) context.main.appendChild(h('div', {}, h('div', {}, 'About'), h('p', {}, 'Other panel')));
    const row = label => about._kids.slice(1).map(x => nested ? x._kids[0] : x).find(x => x._kids[0].textContent === label);
    mutate?.({ ...context, about, field, row });
  } });
}
