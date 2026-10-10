import test from 'node:test';
import assert from 'node:assert/strict';
import {runIsolated} from './helpers/w187-runtime.mjs';

for (const scenario of ['source-unhealthy','target-ahead','missing-pages','signing-repair']) {
  test(`R11 transfer ${scenario}`, {timeout:240_000}, () => {
    const {output} = runIsolated('w187fleet', {TATWO2_W187_TRANSFER:'1', TATWO2_W187_R8_TRANSFER:'1', TATWO2_W187_R11_TRANSFER:scenario});
    assert.match(output,/W187R11 SUMMARY failures=0/);
  });
}
for (const scenario of ['ui-signing','ui-progress','ui-retired','ui-recovery-invalid','r11-dialog','r11-return','r11-invalid-target','r11-empty-card','r11-cwd','r11-cli','r11-ssh-copy','r11-memory-race','r11-admission','r11-external']) {
  test(`R11 production entry ${scenario}`, {timeout:240_000}, () => {
    const {output} = runIsolated('w187fleet', {TATWO2_W187_R8:scenario, TATWO_ULTRAWORK_EXPORT_CHAT_SCENE:'cli-多session'});
    assert.match(output,/W187R(?:8|11) SUMMARY failures=0/);
  });
}
