import test from 'node:test';
import assert from 'node:assert/strict';
import {runIsolated} from './helpers/w187-runtime.mjs';
test('W232 legacy SSH bootstrap, real gate, metadata-only ledger and final managed check', {timeout: 240_000}, () => {
  const {output} = runIsolated('w232');
  assert.match(output, /W232 FLEET SUMMARY checks=7 failures=0/);
  assert.match(output, /W232 GROUP SUMMARY checks=11 failures=0/);
});
