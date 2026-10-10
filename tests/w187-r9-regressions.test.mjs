import test from 'node:test';
import assert from 'node:assert/strict';
import { runIsolated } from './helpers/w187-runtime.mjs';

for (const scenario of ['memory-launch','revocation-resweep','memory-restricted-fetch','brain-mismatch','brain-empty',
  'brain-missing','brain-online','brain-source','ui-initial','ui-observer','ui-complete','memory-errors']) {
  test(`R9 negative runtime ${scenario}`, {timeout:240_000}, () => {
    const flags=scenario.startsWith('brain-')
      ? {TATWO2_W187_TRANSFER:'1',TATWO2_W187_R8_TRANSFER:'1',TATWO2_W187_R9_BRAIN:scenario.slice(6)}
      : {TATWO2_W187_R8:scenario};
    const {output}=runIsolated('w187fleet',flags);
    assert.match(output,/W187R8 SUMMARY failures=0/);
  });
}
