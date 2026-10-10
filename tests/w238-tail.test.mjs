import test from 'node:test';
import assert from 'node:assert/strict';
import {runIsolated} from './helpers/w187-runtime.mjs';

test('W238 actual TAP queue and tail behavior regressions', {timeout:240000}, () => {
  const {output} = runIsolated('w238tail');
  assert.match(output, /W238 SUMMARY passed=[1-9]\d* failures=0/);
  for (const label of ['G1 managed marker cancels queued send without dispatch',
    'G1 UI has one managed cancellation reason', 'G1 dequeue rechecks policy and reports not submitted',
    'G2 restored event bodies and Coder relay use transcript row offsets',
    'G2 old archived group retains event skeleton without bodies or handoff',
    'G2 newly archived legacy group contains only event skeleton',
    'G2 managed after models wait refuses destination lookup and project creation',
    'F1 identical content leaves persisted document and revision unchanged',
    'F1 changed body with unchanged timestamps triggers update']) {
    assert.ok(output.includes(`W238 PASS ${label}`), label);
  }
});
