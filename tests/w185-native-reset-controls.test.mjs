// Exact embedded reset code, synthetic controls only; no UI, network, account or build.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../App/Sources/Tatwo2/TAP/ChatGPTTap.swift', import.meta.url), 'utf8');
function between(start, end) {
  const a = source.indexOf(start), b = source.indexOf(end, a);
  assert.ok(a >= 0 && b > a, `missing source boundary: ${start}`);
  return source.slice(a, b);
}
const helpers = between('const nativeResetControlClass = ', 'async function resetNativeChat(');
const { classify, render } = vm.runInNewContext(
  helpers + '\n({ classify: nativeResetControlClass, render: nativeResetControlDiagnostic });', { URL });
const origin = 'https://chatgpt.com';
const known = 'create-new-chat-button';
const fields = (s) => Object.fromEntries(s.split('; ').map((p) => p.split('=')));
const emptyFields = {
  scan_state: 'scanned', candidate_count: '0', testid_hit: 'false',
  anchor_semantic_count: '0', button_semantic_count: '0',
  native_button_count: '0', role_only_count: '0',
};

test('pure classifier: retains known testid and exact same-origin root-anchor semantics', () => {
  for (const label of ['New chat', '新聊天', '新對話']) {
    for (const href of ['/', origin + '/']) {
      const row = classify({ tag: 'A', href, label }, origin);
      assert.equal(row.candidate, true);
      assert.equal(row.testid_hit, false);
      assert.equal(row.semantic, 'anchor_new_chat');
    }
    const row = classify({ tag: 'BUTTON', testid: known, label }, origin);
    assert.equal(row.candidate, true);
    assert.equal(row.testid_hit, true);
    assert.equal(row.semantic, 'button_new_chat');
  }
});

test('pure classifier: native BUTTON and role-only are distinct, neither invents a legacy candidate', () => {
  for (const control of [
    { tag: 'BUTTON', label: 'New chat' },
    { tag: 'BUTTON', role: 'button', label: 'New chat' },
    { tag: 'DIV', role: 'button', label: '新聊天' },
    { tag: 'BUTTON', testid: 'unobserved-test-id', label: 'New chat' },
    { tag: 'BUTTON', href: '/', label: 'New chat' },
  ]) {
    const row = classify(control, origin);
    assert.equal(row.candidate, false);
    assert.equal(row.testid_hit, false);
    assert.equal(row.semantic, 'button_new_chat');
    assert.equal(row.native_button, control.tag === 'BUTTON');
    assert.equal(row.role_only, control.tag !== 'BUTTON' && control.role === 'button');
  }
});

test('pure classifier: unrelated labels and non-root/foreign/query/hash anchors are rejected', () => {
  for (const href of [
    '/c/PRIVATE_ID', '/g/PRIVATE_ID', '/?q=PRIVATE_TEXT', '/#PRIVATE_TEXT',
    'https://example.invalid/', '//example.invalid/', 'javascript:PRIVATE_TEXT',
    'https://[invalid', null, undefined,
  ]) assert.equal(classify({ tag: 'A', href, label: 'New chat' }, origin).candidate, false);
  for (const label of ['New chat PRIVATE_TEXT', 'Start new chat', 'PRIVATE_TEXT', '', null, undefined])
    assert.equal(classify({ tag: 'A', href: '/', label }, origin).candidate, false);
  for (const tag of ['DIV', 'SPAN', 'INPUT', undefined])
    assert.equal(classify({ tag, href: '/', label: 'New chat' }, origin).candidate, false);
});

test('diagnostic: capped counts, strict booleans and enums only; no raw metadata', () => {
  assert.deepEqual(fields(render([])), emptyFields);
  const row = classify({ tag: 'BUTTON', testid: known, label: 'New chat' }, origin);
  assert.equal(fields(render([row])).candidate_count, '1');
  assert.equal(fields(render([row])).testid_hit, 'true');
  for (const n of [2, 3, 1000]) {
    const d = fields(render(Array(n).fill(row)));
    assert.equal(d.candidate_count, '2+');
    assert.equal(d.button_semantic_count, '2+');
    assert.equal(d.native_button_count, '2+');
  }
  const poison = {
    candidate: 'PRIVATE_TEXT', testid_hit: 1, semantic: 'PRIVATE_TEXT', native_button: 1, role_only: 'true',
    label: 'PRIVATE_LABEL', href: '/c/PRIVATE_ID', id: 'PRIVATE_ID', testid: 'PRIVATE_TESTID',
  };
  assert.deepEqual(fields(render([poison], 'PRIVATE_STAGE')), { ...emptyFields, scan_state: 'unknown' });
  assert.doesNotMatch(render([poison]), /PRIVATE|href=|label=|id=/);
  assert.equal(fields(render([], 'not_scanned')).scan_state, 'not_scanned');
  assert.equal(fields(render([], 'unknown')).scan_state, 'unknown');
});

function control(tag, attrs = {}, parent = null) {
  return {
    tagName: tag.toUpperCase(), attrs, parentElement: parent, isConnected: true,
    disabled: false, hidden: false, inert: false, textContent: '',
    style: { display: 'block', visibility: 'visible', opacity: '1' }, clicks: 0,
    getAttribute(name) { return this.attrs[name] ?? null; },
    getClientRects() { return this.style.display === 'none' ? [] : [{}]; },
    matches(selector) {
      return selector.split(',').some((s) => {
        s = s.trim();
        if (s === ':disabled') return this.disabled || !!this.closest('fieldset[disabled]');
        const m = /^([a-z]+)?(?:\[([\w-]+)(?:="([^"]*)")?\])?$/.exec(s);
        return !!m && (!m[1] || this.tagName === m[1].toUpperCase())
          && (!m[2] || (m[2] === 'inert' ? this.inert
            : m[3] === undefined ? m[2] in this.attrs : this.attrs[m[2]] === m[3]));
      });
    },
    closest(selector) {
      for (let n = this; n; n = n.parentElement) if (n.matches(selector)) return n;
      return null;
    },
  };
}

function resetFixture(nodes, { blocked = false, queryThrows = false, resetWorks = true,
  draft = false, dialog = false, mode = 'off', afterPress, afterSettle } = {}) {
  const box = {}, diag = { '新聊天控制': 'PRIVATE_STALE' }, location = { origin, pathname: '/c/fixture' };
  const command = {};
  const context = {
    URL, diag, location, window: { getComputedStyle: (el) => el.style },
    document: {
      querySelectorAll(selector) {
        if (selector === '[data-message-author-role]') return [];
        if (queryThrows) throw new Error('PRIVATE_EXCEPTION');
        return nodes.filter((el) => el.matches(selector));
      },
      querySelector() { return null; },
    },
    composer: () => box, stopVisible: () => blocked,
    shapeState: draft ? 'draft' : 'empty', dialogBlocking: dialog, mode,
    nativeResetComposerShape: () => ({ state: context.shapeState }),
    nativeResetDialogState: () => ({ dialog_blocking_or_unknown: context.dialogBlocking }),
    nativeResetBlockDiagnostic: () => 'fixed',
    revokePersonalizedProof() {}, nativeNewChatRequired: false, nativeResetWatch: null, newChatEpoch: 1,
    nativeTemporaryUI: () => ({ mode: context.mode }),
    press(el) { el.clicks++; if (resetWorks) location.pathname = '/'; afterPress?.(context, command); },
    waitFor: async (predicate) => predicate(), sleep: async () => { afterSettle?.(context, command); },
  };
  const visibility = between('const chatVisible = ', 'const chatForm = ');
  const controls = between('const temporaryControlLabel = ', 'const temporaryPersonalization = ');
  const reset = between('async function resetNativeChat(', 'const personalizedPrepareSnapshot = ');
  const run = vm.runInNewContext(visibility + controls + helpers + reset + '\nresetNativeChat;', context);
  return { run: () => run(command), diag, context, command };
}

test('exact reset: zero/duplicate controls fail closed; single existing candidate clicks once', async () => {
  for (const n of [0, 1, 2, 8]) {
    const nodes = Array.from({ length: n }, () => control('button', { 'data-testid': known, 'aria-label': 'New chat' }));
    const p = resetFixture(nodes);
    assert.equal(await p.run(), n === 1);
    assert.equal(nodes.reduce((sum, n) => sum + n.clicks, 0), n === 1 ? 1 : 0);
    assert.equal(fields(p.diag['新聊天控制']).candidate_count, n > 1 ? '2+' : String(n));
    assert.equal(p.diag['新聊天重設'], n === 1 ? 'confirmed' : 'control_unconfirmed');
  }
});

test('exact reset: unique native BUTTON fallback clicks once and must confirm reset', async () => {
  for (const label of ['New chat', '新聊天', '新對話']) for (const labelSource of ['aria', 'text', 'native-role']) {
    const button = control('button', labelSource === 'text' ? {} : {
      'aria-label': label, ...(labelSource === 'native-role' ? { role: 'button' } : {}),
    });
    if (labelSource === 'text') button.textContent = label;
    const p = resetFixture([button]);
    assert.equal(await p.run(), true);
    assert.equal(button.clicks, 1);
    assert.equal(p.diag['新聊天重設'], 'confirmed');
    assert.equal(p.command.nativeReset.origin, origin);
    assert.equal(p.context.nativeNewChatRequired, false);
    assert.deepEqual(fields(p.diag['新聊天控制']), {
      ...emptyFields, button_semantic_count: '1', native_button_count: '1',
    });
  }
});

test('exact reset: role-only semantics are observable but never a fallback', async () => {
  for (const tag of ['div', 'a', 'span']) {
    const el = control(tag, { role: 'button', 'aria-label': 'New chat' });
    const p = resetFixture([el]);
    assert.equal(await p.run(), false);
    assert.equal(el.clicks, 0);
    assert.deepEqual(fields(p.diag['新聊天控制']), {
      ...emptyFields, button_semantic_count: '1', role_only_count: '1',
    });
  }
});

test('exact reset: duplicate fallback, anchor ambiguity and legacy/role-only conflicts all refuse clicks', async () => {
  const fallback = () => control('button', { 'aria-label': 'New chat' });
  const legacy = () => control('button', { 'data-testid': known });
  const anchor = () => control('a', { href: '/', 'aria-label': 'New chat' });
  const role = () => control('div', { role: 'button', 'aria-label': 'New chat' });
  for (const nodes of [
    [fallback(), fallback()], [fallback(), anchor()], [fallback(), legacy()],
    [fallback(), role()], [anchor(), legacy()], [legacy(), legacy()], [legacy(), role()],
    [role(), role()], [fallback(), fallback(), legacy()],
  ]) {
    const p = resetFixture(nodes);
    assert.equal(await p.run(), false);
    assert.equal(p.diag['新聊天重設'], 'control_unconfirmed');
    assert.ok(nodes.every((el) => el.clicks === 0));
    assert.equal(p.command.nativeReset, undefined);
  }
});

test('exact reset: exact label rejects suffix, prefix, case and invisible spoofing; ARIA takes precedence', async () => {
  for (const label of ['New chat PRIVATE_TEXT', 'PRIVATE_TEXT New chat', 'new chat', 'New chat…',
    'New\u200b chat', '新聊天 PRIVATE_TEXT', '新對話\u200b', 'Start new chat', '']) {
    const el = control('button', { 'aria-label': label });
    const p = resetFixture([el]);
    assert.equal(await p.run(), false, label);
    assert.equal(el.clicks, 0);
    assert.doesNotMatch(p.diag['新聊天控制'], /PRIVATE/);
  }
  const el = control('button', { 'aria-label': 'PRIVATE_OTHER_ACTION' });
  el.textContent = 'New chat';
  const p = resetFixture([el]);
  assert.equal(await p.run(), false);
  assert.equal(el.clicks, 0);
});

test('exact reset: fallback cannot confirm no-op, wrong mode, retained messages, restored draft or changed origin', async () => {
  for (const options of [
    { resetWorks: false }, { mode: 'unknown' }, { mode: 'personalized' },
    { afterPress: (c) => { c.document.querySelector = () => ({}); } },
    { afterPress: (c) => { c.shapeState = 'draft'; } },
    { afterPress: (c) => { c.dialogBlocking = true; } },
    { afterPress: (c) => { c.location.origin = 'https://example.invalid'; } },
    { afterPress: (c, command) => { command.cancelled = true; } },
    { afterSettle: (c) => { c.shapeState = 'draft'; } },
    { afterSettle: (c) => { c.mode = 'unknown'; } },
    { afterSettle: (c) => { c.location.pathname = '/c/other'; } },
  ]) {
    const el = control('button', { 'aria-label': 'New chat' }), p = resetFixture([el], options);
    assert.equal(await p.run(), false);
    assert.equal(el.clicks, 1);
    assert.equal(p.diag['新聊天重設'], 'unconfirmed');
    assert.equal(p.command.nativeReset, undefined);
    assert.equal(p.context.nativeNewChatRequired, true);
  }
  for (const options of [{ draft: true }, { dialog: true }, { blocked: true }]) {
    const el = control('button', { 'aria-label': 'New chat' }), p = resetFixture([el], options);
    assert.equal(await p.run(), false);
    assert.equal(el.clicks, 0);
    assert.equal(p.diag['新聊天重設'], 'blocked');
  }
  const el = control('button', { 'aria-label': 'New chat' }), p = resetFixture([el]);
  p.context.location.pathname = '/'; // Already off/root with the same box is not reset evidence.
  assert.equal(await p.run(), false);
  assert.equal(el.clicks, 1);
  assert.equal(p.command.nativeReset, undefined);
});

test('exact reset: existing visibility/enabled/message/form/dialog exclusions still apply', async () => {
  for (const useTestid of [true, false]) for (const kind of [
    'hidden', 'detached', 'disabled', 'aria-disabled', 'inert', 'ancestor-hidden', 'message', 'form', 'dialog',
  ]) {
    const parent = control(kind === 'form' ? 'form' : 'div',
      kind === 'message' ? { 'data-message-author-role': 'user' } : kind === 'dialog' ? { role: 'dialog' } : {});
    const el = control('button', { ...(useTestid ? { 'data-testid': known } : {}), 'aria-label': 'New chat' }, parent);
    if (kind === 'hidden') el.hidden = true;
    if (kind === 'detached') el.isConnected = false;
    if (kind === 'disabled') el.disabled = true;
    if (kind === 'aria-disabled') el.attrs['aria-disabled'] = 'true';
    if (kind === 'inert') parent.inert = true;
    if (kind === 'ancestor-hidden') parent.style.display = 'none';
    const p = resetFixture([el]);
    assert.equal(await p.run(), false, kind);
    assert.equal(el.clicks, 0, kind);
    assert.deepEqual(fields(p.diag['新聊天控制']), emptyFields, kind);
  }
});

test('exact reset: blocked entry clears stale diagnostics; scan errors remain unknown and never click', async () => {
  for (const options of [{ blocked: true }, { queryThrows: true }, { getterThrows: true }]) {
    const el = control('button', { 'data-testid': known, 'aria-label': 'New chat' });
    if (options.getterThrows) el.getAttribute = () => { throw new Error('PRIVATE_EXCEPTION'); };
    const p = resetFixture([el], options);
    assert.equal(await p.run(), false);
    assert.equal(el.clicks, 0);
    assert.equal(fields(p.diag['新聊天控制']).scan_state, options.blocked ? 'not_scanned' : 'unknown');
    assert.doesNotMatch(p.diag['新聊天控制'], /PRIVATE/);
  }
});
