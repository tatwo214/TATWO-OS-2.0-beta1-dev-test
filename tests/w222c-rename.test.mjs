import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const source = readFileSync(new URL('../App/Sources/Tatwo2/TAP/ChatGPTTap.swift', import.meta.url), 'utf8');
test('W350 rename handler removed', () => {
  assert.doesNotMatch(source, /renameProject: async/);
});
