import test from 'node:test';
import assert from 'node:assert/strict';
import { nativeW298a } from './fixtures/w298a-native.mjs';

test('W309 ChatGPT narrow page reads the desktop model catalog and restores after success or failure', () => {
  const output = nativeW298a();
  assert.ok(output.includes('W298A PASS W309 ChatGPT narrow page reads models and restores viewport'));
  assert.ok(output.includes('W298A PASS W309 ChatGPT failed read restores viewport'));
});

test('W309 Grok native code and route aliases give one composer option', () => {
  assert.ok(nativeW298a().includes('W298A PASS W309 Grok provider and route aliases occur once'));
  assert.ok(nativeW298a().includes('W298A PASS W309 Grok duplicate route from another catalog occurs once'));
});

test('W309 Claude merges aliases, retires old models, falls back only without reports and diagnoses sources', () => {
  const output = nativeW298a();
  for (const label of [
    'Claude aliases merge with readable names and retain reported arguments',
    'Claude retired models and remembered names stay out of menu',
    'Claude reported aliases exclude unreported builtins',
    'Claude absent report uses builtin fallback',
    'menu diagnostic includes only IDs and fixed source codes',
  ]) assert.ok(output.includes(`W298A PASS W309 ${label}`), label);
});
