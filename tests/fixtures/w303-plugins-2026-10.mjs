// 10-08 實機 AX 結構：英文文案已讀回；中文變體僅驗候選比對，尚未實機核對。
import { h, makePage } from '../w185-pod-fixture.mjs';

export function plugins202610({ addLabel = 'Add', mcpLabel = 'Add custom MCP server',
  createLabel = 'Create as a plugin', duplicateMCP = false, missingMCP = false,
  conflictingMCP = false, duplicateCreate = false, duplicateAuth = false,
  plainAdd = false, tunnelDefault = false, extraBox = false } = {}) {
  const state = { picked: [], submitted: 0, closed: 0, advanced: 0 };
  const pod = makePage({ viewport: { width: 1100, height: 800 }, build(body) {
    const openForm = () => {
      const name = h('input', { id: 'mcp-name' });
      const desc = h('textarea', { id: 'mcp-desc' });
      const url = h('input', { id: 'mcp-url' });
      const server = h('button', { role: 'checkbox', 'aria-checked': String(!tunnelDefault) }, 'Server URL');
      const tunnel = h('button', { role: 'checkbox', 'aria-checked': String(tunnelDefault) }, 'Tunnel');
      server.onclick = () => { server.setAttribute('aria-checked', 'true'); tunnel.setAttribute('aria-checked', 'false'); };
      tunnel.onclick = () => { server.setAttribute('aria-checked', 'false'); tunnel.setAttribute('aria-checked', 'true'); };
      const auth = h('select', { id: 'mcp-auth' }, h('option', { value: 'oauth' }, 'OAuth'));
      auth.value = 'oauth';
      const create = h('button', { disabled: true, onclick() { state.submitted++; } }, createLabel);
      const ack = h('button', { role: 'checkbox', 'aria-label': 'I understand and want to continue', 'aria-checked': 'false',
        onclick() { const on = this.getAttribute('aria-checked') !== 'true'; this.setAttribute('aria-checked', String(on)); create.disabled = !on; } },
      'I understand and want to continue');
      const advanced = h('button', { onclick() { state.advanced++; } }, 'Advanced OAuth settings');
      const close = h('button', { 'aria-label': 'Close dialog', onclick() { state.closed++; dialog.remove(); } }, '');
      const dialog = h('div', { role: 'dialog' },
        h('label', { for: 'mcp-name' }, 'Name'), name,
        h('label', { for: 'mcp-desc' }, 'Description (optional)'), desc,
        h('div', {}, h('p', {}, 'Connection'), server, tunnel),
        h('label', { for: 'mcp-url' }, 'Server URL'), url,
        h('label', { for: 'mcp-auth' }, 'Authentication'), auth,
        ...(duplicateAuth ? [h('button', { role: 'combobox', 'aria-label': 'Authentication' }, 'OAuth')] : []), advanced, ack,
        ...(extraBox ? [h('button', { role: 'checkbox', 'aria-checked': 'false' }, 'Share data')] : []),
        h('button', {}, 'Cancel'), create,
        ...(duplicateCreate ? [h('button', {}, 'Create')] : []), close);
      Object.assign(state, { dialog, name, desc, url, server, tunnel, auth, ack, create, close });
      body.appendChild(dialog);
    };
    const add = h('button', plainAdd ? {} : { 'aria-haspopup': 'menu', 'aria-label': addLabel }, addLabel);
    add.onclick = () => {
      const item = (key, text) => h('div', { role: 'menuitem',
        ...(key === 'mcp' && conflictingMCP ? { 'aria-label': 'Create plugin' } : {}),
        onclick() { state.picked.push(key); menu.remove(); if (key === 'mcp') openForm(); } }, text);
      const menu = h('div', { role: 'menu', 'aria-label': addLabel },
        item('plugin', 'Create plugin'), item('archive', 'Upload plugin archive'),
        ...(!missingMCP ? [item('mcp', mcpLabel)] : []), ...(duplicateMCP ? [item('mcp', mcpLabel)] : []));
      body.appendChild(menu);
    };
    body.appendChild(h('main', {}, h('h1', {}, 'Plugins'), add));
    body.document.addEventListener('keydown', e => {
      if (e.key === 'Escape') for (const menu of [...body.querySelectorAll('[role="menu"]')]) menu.remove();
    });
    state.add = add;
    return state;
  } });
  return { pod, state };
}
