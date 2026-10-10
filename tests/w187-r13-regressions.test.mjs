import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {runIsolated} from './helpers/w187-runtime.mjs';

test('R13 ROSTER-01 source deletion and last-second todo survive source switch', {timeout:240_000}, () => {
  const {output}=runIsolated('w187fleet',{TATWO2_W187_TRANSFER:'1', TATWO2_W187_R12_TRANSFER:'entrance', TATWO2_W187_R13_TRANSFER:'work'});
  assert.match(output,/W187R13 SUMMARY failures=0/);
});

test('R13 ROSTER-02 recovery names the probed old primary and ordinary sync has no new primary', {timeout:240_000}, () => {
  const {output}=runIsolated('w187fleet',{TATWO2_W187_TRANSFER:'1', TATWO2_W187_R12_TRANSFER:'entrance', TATWO2_W187_R13_TRANSFER:'reason'});
  assert.match(output,/W187R13 SUMMARY failures=0/);
});

test('R13 CARDS-05 reclaim over one MB returns within timeout while the main thread responds', {timeout:240_000}, () => {
  const {output}=runIsolated('w187fleet',{TATWO2_W187_R8:'r13-reclaim'});
  assert.match(output,/W187R13 SUMMARY failures=0/);
});

for (const scenario of ['r13-audit','r13-managed-git','r13-summary','r13-refusal']) test(`R13 production ${scenario}`, {timeout:240_000}, () => {
  const {output}=runIsolated('w187fleet',{TATWO2_W187_R8:scenario, ...(scenario === 'r13-refusal' ? {TATWO_ULTRAWORK_EXPORT_CHAT_SCENE:'cli-多session'} : {})});
  assert.match(output,/W187R13 SUMMARY failures=0/);
});

for (const [state, check] of [
  ['pending', 'R13-ROSTER-03-epoch-readback-pending-hides-start-fields'],
  ['readback', 'R13-ROSTER-03-epoch-readback-done-shows-start-before-brain-release'],
]) test(`R12 ROSTER-03 promoted primary UI state ${state}`, {timeout:240_000}, () => {
  const {output}=runIsolated('w187fleet',{TATWO2_W187_TRANSFER:'1', TATWO2_W187_R12_TRANSFER:'entrance', TATWO2_W187_R13_TRANSFER:'ui', TATWO2_W187_R13_UI_STATE:state});
  assert.ok(output.includes(`W187TRANSFER PASS ${check}`), output);
  assert.match(output,/W187R13 SUMMARY failures=0/);
});

test('R13 CARDS-01 real tmux removes inherited agent variables', {timeout:240_000}, () => {
  const {output}=runIsolated('w187fleet',{TATWO2_W187_R8:'r13-shell', SSH_AUTH_SOCK:'/private/tmp/w187-synthetic-unused-agent.sock', TMUX:'/private/tmp/w187-synthetic-unused-tmux.sock,1,0'});
  assert.match(output,/W187R13 SUMMARY failures=0/);
});

test('R12 ROSTER-03 blank names are refused by begin and direct confirmation before RPC', {timeout:240_000}, () => {
  const {output}=runIsolated('w187fleet',{TATWO2_W187_R8:'r13-blank-name'});
  assert.match(output,/W187R13 SUMMARY failures=0/);
});

test('R13 SEQ-04 the second button names the frozen originals', {timeout:240_000}, () => {
  const {output}=runIsolated('w187fleet',{TATWO2_W187_R8:'r13-button'});
  assert.match(output,/W187R13 SUMMARY failures=0/);
});

test('R7 CARDS-04 copied renamed resigned osascript cannot send to the owned synthetic receiver', {timeout:240_000}, () => {
  const {root}=runIsolated('w187fleet',{TATWO2_W187_R8:'r12-sandbox'});
  const result=spawnSync('/usr/bin/python3',['tests/r7-copy-probe.py',root+'/artifacts/r12-plan.json'],{encoding:'utf8',timeout:30_000,env:{PATH:process.env.PATH,HOME:root+'/home',TMPDIR:root+'/tmp'}});
  assert.equal(result.status,0,result.stdout+result.stderr);
  assert.match(result.stdout,/R7-CARDS-04 PASS/);
});
