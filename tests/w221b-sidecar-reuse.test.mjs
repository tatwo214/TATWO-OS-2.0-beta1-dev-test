import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

test('W181 reuse assertion rejects runtime and memory checks split across returns', () => {
  const source = fs.readFileSync('tests/w181-apikey.test.mjs', 'utf8');
  const checks = source.split('\n').filter(line => line.includes('assert.match(ensure,') && (line.includes('runtimeMatches') || line.includes('startedWithoutMemory'))).join('\n');
  assert.ok(checks);
  const safe = 'if modelMatches && apiKeyOptOutMatches && runtimeMatches && s.startedWithoutMemory == (memoryPolicy != nil) { return s }';
  assert.doesNotThrow(() => vm.runInNewContext(checks, { assert, ensure: safe }));
  for (const unsafe of [
    'if modelMatches && apiKeyOptOutMatches && runtimeMatches { return s }\nif other && s.startedWithoutMemory == (memoryPolicy != nil) { return s }',
    'if modelMatches && apiKeyOptOutMatches && runtimeMatches || unchecked && s.startedWithoutMemory == (memoryPolicy != nil) { return s }',
  ]) assert.throws(() => vm.runInNewContext(checks, { assert, ensure: unsafe }), error => error.name === 'AssertionError');
});
