import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdirSync, existsSync, rmSync, mkdtempSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {join} from 'node:path';
import net from 'node:net';
import {once} from 'node:events';
import {runIsolated} from './helpers/w187-runtime.mjs';

for (const mode of ['entrance', 'save-failure', 'legacy']) test(`R12 ROSTER-02 ${mode}`, {timeout:240_000}, () => {
  const {output}=runIsolated('w187fleet',{TATWO2_W187_TRANSFER:'1', TATWO2_W187_R12_TRANSFER:mode});
  assert.match(output,/W187R12 SUMMARY failures=0/);
});
for (const scenario of ['r12-dialog-app','r12-dialog-offline','r12-dialog-rejected','r12-ui-status','r12-ui-field','r12-ui-card','r12-ui-retired','r12-git','r12-cwd','r12-admission','r12-cli-error','r12-errors']) test(`R12 production ${scenario}`,{timeout:240_000},()=> {
  const {output}=runIsolated('w187fleet',{TATWO2_W187_R8:scenario,TATWO_ULTRAWORK_EXPORT_CHAT_SCENE:'cli-多session'});
  assert.match(output,/W187R12 SUMMARY failures=0/);
});
let cached;
function plan() {
  if (!cached) {
    // sockaddr_un has a fixed path limit even when the caller's TMPDIR is long.
    const {root}=runIsolated('w187fleet',{TATWO2_W187_R8:'r12-sandbox'},{shortSocketPaths:true});
    cached=JSON.parse(readFileSync(join(root,'artifacts/r12-plan.json'),'utf8'));
  }
  return cached;
}
function command(p, executable, args) {
  return spawnSync('/usr/bin/sandbox-exec',[...p.arguments.slice(0,-1),executable,...args],{cwd:p.cwd,env:p.environment,encoding:'utf8',timeout:30_000});
}
test('R12 CARDS-N2 removes inherited SSH_AUTH_SOCK',()=>assert.equal(plan().environment.SSH_AUTH_SOCK,undefined));
for (const path of ['.git/config','.git/hooks/pre-commit','.git/nested/config']) test(`R12 CARDS-N1 denies write ${path}`,()=> {
  const p=plan(), file=join(p.cwd,path);
  mkdirSync(join(file,'..'),{recursive:true}); writeFileSync(file,'original');
  const result=command(p,'/bin/sh',['-c','printf changed > "$1"','fixture',file]);
  assert.notEqual(result.status,0,result.stderr); assert.equal(readFileSync(file,'utf8'),'original');
});
test('R12 CARDS-N1 denies git directory creation and rename',()=> {
  const p=plan(), git=join(p.cwd,'.git');
  rmSync(git,{recursive:true,force:true});
  assert.notEqual(command(p,'/bin/mkdir',[git]).status,0); assert.equal(existsSync(git),false);
  mkdirSync(git); writeFileSync(join(git,'config'),'original');
  assert.notEqual(command(p,'/bin/mv',[git,join(p.cwd,'renamed-git')]).status,0);
  assert.equal(existsSync(git),true); assert.equal(existsSync(join(p.cwd,'renamed-git')),false);
  mkdirSync(join(p.cwd,'replacement'));
  assert.notEqual(command(p,'/bin/mv',[join(p.cwd,'replacement'),join(p.cwd,'nested','.git')]).status,0);
});
for (const entry of ['background','engine','terminal']) test(`R12 CARDS-N2 ${entry} cannot connect fake SSH agent`,{timeout:240_000},async()=> {
  const p=plan();
  const defaults=mkdtempSync('/private/tmp/com.apple.launchd.w187-fixture-');
  try {
    for (const socket of [p.socket,join(defaults,'Listeners')]) {
      mkdirSync(join(socket,'..'),{recursive:true});
      const server=net.createServer(s=>s.end('synthetic-agent')); server.listen(socket); await once(server,'listening');
      try {
        const {output}=runIsolated('w187fleet',{TATWO2_W187_R8:'r12-entry-'+entry,TATWO2_W187_AGENT_SOCKET:socket,TATWO2_W187_POLICY_AGENT:p.socket});
        assert.match(output,/W187R12 SUMMARY failures=0/);
      } finally { await new Promise(resolve=>server.close(resolve)); }
    }
  } finally { rmSync(defaults,{recursive:true,force:true}); }
});
