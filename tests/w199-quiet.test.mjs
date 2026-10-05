// W199 10-03 實際使用回饋：健康時安靜、專案清單明確載入／錯誤／重試；測試只用假 Pod。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
const read = path => readFileSync(new URL('../App/Sources/Tatwo2/' + path, import.meta.url), 'utf8');
const tap = read('TAP/ChatGPTTap.swift');
const between = (s, a, b) => { const i = s.indexOf(a); assert.ok(i >= 0); const j = s.indexOf(b, i + a.length); assert.ok(j > i); return s.slice(i, j); };

function handler(name, next, api) {
  const body = between(tap, `        ${name}: async`, `        ${next}:`);
  return vm.runInNewContext(`({${body}}).${name}`, { api, encodeURIComponent, diag: {}, keysOf: () => [] });
}

test('W199 actual project handler follows cursors without publishing a partial or malformed list', async () => {
  const calls = [];
  const project = handler('projectConversations', 'rename', async path => {
    calls.push(path);
    return calls.length === 1 ? { items: [{ id: 'one', title: 'One' }], cursor: 'next' }
      : { items: [{ id: 'two', title: 'Two' }] };
  });
  const result = await project({ projectID: 'g-p-fixture' });
  assert.deepEqual(Array.from(result.items, row => row.id), ['one', 'two']);
  assert.match(calls[1], /cursor=next$/);
  for (const broken of [{}, null, { items: {} }]) {
    await assert.rejects(handler('projectConversations', 'rename', async () => broken)({ projectID: 'g-p-fixture' }), /讀不到這個專案的對話/);
  }
  const laterFailure = handler('projectConversations', 'rename', async path => {
    if (path.endsWith('cursor=0')) return { items: [{ id: 'one' }], cursor: 'later' };
    throw new Error('fixture network failure');
  });
  await assert.rejects(laterFailure({ projectID: 'g-p-fixture' }), /fixture network failure/);
  const empty = await handler('projectConversations', 'rename', async () => ({ items: [] }))({ projectID: 'g-p-fixture' });
  assert.equal(empty.items.length, 0);
});

test('W199 actual main list and search handlers reject missing items rather than declaring an empty result', async () => {
  for (const [name, next] of [['list', 'get'], ['search', 'library']]) {
    // search 後面的正式 handler 名稱由原始碼取得，避免耦合其他功能。
    const after = name === 'search' ? tap.slice(tap.indexOf('        search: async')).match(/\n        ([A-Za-z]+): async/g)?.[0]?.match(/([A-Za-z]+):/)[1] : next;
    assert.ok(after);
    for (const broken of [{}, null, { items: 'invalid' }]) {
      await assert.rejects(handler(name, after, async () => broken)({ query: 'fixture' }), /讀不到/);
    }
    const result = await handler(name, after, async () => ({ items: [] }))({ query: 'fixture' });
    assert.equal(result.items.length, 0);
  }
});
