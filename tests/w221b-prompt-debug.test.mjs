import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

test('composedSystemPrompt testing wrapper is available only in DEBUG', () => {
  const source = fs.readFileSync('App/Sources/Tatwo2/Facade/ChatLiveEngine.swift', 'utf8');
  const wrapper = source.indexOf('    func composedSystemPrompt(threadID: UUID, systemPrompt: String? = nil)');
  assert.ok(wrapper > 0);
  const stack = [];
  for (const line of source.slice(0, wrapper).split('\n')) {
    if (/^\s*#if /.test(line)) stack.push(line.trim());
    else if (/^\s*#endif/.test(line)) stack.pop();
    else if (/^\s*#else/.test(line)) stack[stack.length - 1] += ' else';
  }
  assert.ok(stack.includes('#if DEBUG'), 'public testing wrapper must be inside #if DEBUG');
  const implementation = source.indexOf('    private func composedSystemPrompt');
  assert.ok(source.slice(wrapper, implementation).includes('#endif'), 'production implementation remains outside DEBUG');
});
