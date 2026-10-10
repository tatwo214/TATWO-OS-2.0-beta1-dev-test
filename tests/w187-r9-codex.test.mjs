import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { server } from './helpers/w187-codex.mjs';
import { runIsolated } from './helpers/w187-runtime.mjs';


test('N1 N2 actual managed launch: real Codex command and saved session resume after restart', {timeout:240_000}, async ()=>{
  const {root}=runIsolated('w187fleet',{TATWO2_W187_R8:'memory-launch'});
  const plan=JSON.parse(readFileSync(join(root,'artifacts/memory-launch.json'),'utf8'));
  assert.notEqual(plan.executable,'/usr/bin/sandbox-exec');
  assert.equal(plan.environment.TATWO2_MANAGED_NO_MEMORY,undefined);
  const binary='/Applications/TATWO OS.app/Contents/Resources/runtime/bin/codex';
  assert.ok(existsSync(binary),'real bundled Codex required');
  let rpc=server(binary,plan), id;
  try {
    await rpc.request('initialize',{clientInfo:{name:'fixture',version:'1'},capabilities:{experimentalApi:true}});rpc.initialized();
    const result=await rpc.request('command/exec',{command:['/bin/sh','-c','printf synthetic > ordinary.txt && /bin/cat ordinary.txt'],cwd:plan.cwd,
      sandboxPolicy:{type:'workspaceWrite',writableRoots:[plan.cwd],networkAccess:false},timeoutMs:5000});
    assert.equal(result.exitCode,0,JSON.stringify(result));assert.equal(result.stdout,'synthetic');
    // Seed a credential-free saved session through the real Codex history API; no model turn is sent.
    const seeded=await rpc.request('thread/resume',{threadId:'',history:[{type:'message',role:'user',content:[{type:'input_text',text:'synthetic prior turn'}]}],
      cwd:plan.cwd,sandbox:'workspace-write',approvalPolicy:'untrusted'});
    id=seeded.thread.id;assert.ok(id);
  } finally {await rpc.close();}
  rpc=server(binary,plan);
  try {
    await rpc.request('initialize',{clientInfo:{name:'fixture',version:'1'},capabilities:{experimentalApi:true}});rpc.initialized();
    const resumed=await rpc.request('thread/resume',{threadId:id,cwd:plan.cwd,sandbox:'workspace-write',approvalPolicy:'untrusted'});
    assert.equal(resumed.thread.id,id);
  } finally {await rpc.close();}
});
