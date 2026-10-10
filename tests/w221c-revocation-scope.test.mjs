import test from 'node:test';
import assert from 'node:assert/strict';
import { runIsolated } from './helpers/w187-runtime.mjs';
for (const scenario of ['scope', 'scope-roster', 'legacy', 'repeat', 'shared', 'backup-failure']) {
  test(`W221h revoke ${scenario}`, { timeout: 240_000 }, () => {
    const { output } = runIsolated('w187fleet', { TATWO2_W221C: 'h-' + scenario });
    assert.match(output, /W221H SUMMARY failures=0/);
  });
}
