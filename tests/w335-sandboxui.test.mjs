import assert from 'node:assert/strict';
import test from 'node:test';
import { runIsolated } from './helpers/w187-runtime.mjs';

test('sandbox settings renders empty/platform/source rows, registers and pairs, remembers choices, and rejects non-primary', () => {
  const { output } = runIsolated('w335sandboxui');
  for (const name of ['empty-state', 'add-name-platform-source-form', 'add-registers-sandbox-and-opens-existing-pairing',
    'existing-pairing-code-inline', 'source-metadata-roundtrip', 'graph-has-no-duplicate-pairing-entry', 'non-primary-cannot-add',
    'disabled-add-does-not-open-form', 'backend-rechecks-primary-authority']) assert.ok(output.includes('PASS ' + name), name);
  assert.match(output, /SUMMARY failures=0 passed=\d+/);
});
