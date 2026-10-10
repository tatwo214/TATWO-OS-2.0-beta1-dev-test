import test from 'node:test';
import assert from 'node:assert/strict';
import { runIsolated } from './helpers/w187-runtime.mjs';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import {spawnSync} from 'node:child_process';

for (const scenario of ['background-default','admission-once','session-switch','reconcile-cache',
  'ui-complete','ui-primary','ui-app-unavailable','ui-stale','ui-card-coordinator']) {
  test(`R10 negative runtime ${scenario}`, {timeout:240_000}, () => {
    const {output} = runIsolated('w187fleet',{TATWO2_W187_R8:scenario});
    assert.match(output,/W187R8 SUMMARY failures=0/);
  });
}
for (const scenario of ['grow','shrink','unhealthy','stale-proof','memory-transferred']) {
  test(`R10 transfer rejects regression ${scenario}`, {timeout:240_000}, () => {
    const {output} = runIsolated('w187fleet',{TATWO2_W187_TRANSFER:'1',
      TATWO2_W187_R8_TRANSFER:'1',TATWO2_W187_R10_TRANSFER:scenario});
    assert.match(output,/W187R8 SUMMARY failures=0/);
  });
}

test('R11 ruling replaces managed engine CLI with a real confined shell', {timeout:240_000}, () => {
  const {root, output} = runIsolated('w187fleet',{TATWO2_W187_R8:'terminal-plan'});
  assert.match(output,/R11-CARDS-02-engine-CLI-refused-with-reason/);
  const plan = JSON.parse(readFileSync(join(root,'artifacts/terminal-plan.json'),'utf8'));
  const run = command => spawnSync(plan.executable,[...plan.arguments,'-c',command],{env:plan.environment,cwd:plan.cwd,encoding:'utf8',timeout:10_000});
  const allowed = run('printf synthetic > ordinary.txt && /bin/cat ordinary.txt');
  assert.equal(allowed.status,0,allowed.stderr); assert.equal(allowed.stdout.trim(),'synthetic');
  const denied = run(`printf synthetic > '${join(root,'outside.txt')}'`);
  assert.notEqual(denied.status,0,'generic shell still denies outside writes');
});
