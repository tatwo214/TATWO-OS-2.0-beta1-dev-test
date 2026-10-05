import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
test('M14 DM assistant example matches the one press connection decision', () => {
  const fixture = readFileSync(new URL('../App/Sources/Tatwo2/DM/GlobalDMChatAcceptance.swift', import.meta.url), 'utf8');
  assert.doesNotMatch(fixture, /等你做三件事|勾一次風險|打 8 碼/);
  assert.match(fixture, /［連線］按一下就好/);
});
