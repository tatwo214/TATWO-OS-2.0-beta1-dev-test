import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawn, spawnSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';
import { existsSync, realpathSync } from 'node:fs';
import { once } from 'node:events';

// The real binary only executes standalone commands in a fake, credential-free
// home. No model request, real peer, user session or transport configuration is used.
function policyPlan() {
  const root = testScratch('w187-r7-native-'); mkdirSync(join(root,'home'));
  for (const folder of ['engines/codex','engines/claude','os','docs','artifacts','unused-entry']) mkdirSync(join(root,folder),{recursive:true});
  writeFileSync(join(root,'owned-fixture'), 'synthetic only\n');
  const result = spawnSync(process.env.TATWO2_TEST_BINARY, [], {
    env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR,
      HOME: join(root,'home'), CFFIXED_USER_HOME: join(root,'home'),
      TATWO_STAGING_ROOT:root, TATWO_STAGING_SCRATCH_HOME:join(root,'home'),
      TATWO2_ENGINES_ROOT:join(root,'engines'), CODEX_HOME:join(root,'engines/codex'),
      TATWO2_CODEX_SOURCE_HOME:join(root,'engines/codex'), CLAUDE_CONFIG_DIR:join(root,'engines/claude'),
      CLAUDE_SECURESTORAGE_CONFIG_DIR:join(root,'engines/claude'), TATWO2_OS_SOCKET:join(root,'o.sock'),
      TATWO2_BROWSER_SOCKET:join(root,'b.sock'), TATWO2_SELFTEST_ARTIFACTS:join(root,'artifacts'),
      TATWO2_OS_ROOT:join(root,'os'), TATWO2_DOCS_ROOT:join(root,'docs'),
      TATWO2_OS_UPSTREAM_PATH:join(root,'os/os-upstream.md'), TATWO2_SKILLET_PATH:join(root,'os/skillet.md'),
      TATWO2_SELFTEST: 'w187fleet',
      TATWO2_W187_R7:'sandbox-plan', TATWO2_W187_TEST_ROOT: root,
      TATWO_OS_ROOT: join(root,'unused-entry'), TATWO2_LIVE_ROOT: join(root,'unused-live'),
      TATWO2_AUTHORIZED_KEYS: join(root,'unused-authorized'), TATWO2_SSH_KNOWN_HOSTS: join(root,'unused-known'),
      TATWO2_SSH_KEY_PATH: join(root,'unused-key'), TATWO2_SSH_HOST_KEY_PUB: join(root,'unused-host.pub'),
      GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' },
    encoding: 'utf8', timeout: 220_000, maxBuffer: 4 * 1024 * 1024 });
  const output = result.stdout + result.stderr;
  writeFileSync(join(root,'runtime.log'),output);
  assert.equal(result.status, 0, output);
  return { root, plan: JSON.parse(readFileSync(join(root,'artifacts/sandbox-plan.json'),'utf8')) };
}

async function rpcProcess(child) {
  let buffer = '', stderr = '', next = 1;
  const pending = new Map();
  const requests = [];
  child.stderr.on('data', d => { stderr += d; });
  child.stdout.on('data', d => {
    buffer += d;
    while (buffer.includes('\n')) {
      const end = buffer.indexOf('\n'), line = buffer.slice(0,end); buffer = buffer.slice(end+1);
      if (!line.trim()) continue;
      const reply = JSON.parse(line);
      if (reply.method?.includes('requestApproval')) requests.push(reply);
      const waiter = pending.get(reply.id);
      if (waiter) { pending.delete(reply.id); reply.error ? waiter.reject(new Error(JSON.stringify(reply.error))) : waiter.resolve(reply.result); }
    }
  });
  child.on('exit', code => { for (const p of pending.values()) p.reject(new Error(`real Codex exited ${code}: ${stderr}`)); pending.clear(); });
  return { requests, request(method, params) {
    const id = next++;
    return new Promise((resolve,reject) => { pending.set(id,{resolve,reject}); child.stdin.write(JSON.stringify({id,method,params})+'\n'); });
  }};
}

async function sidecarSettings(root, plan) {
  const env = plan.environment;
  const bin = join(root,'bin'); mkdirSync(bin);
  const capture = join(plan.cwd,'settings.json');
  writeFileSync(join(bin,'codex'), `#!${process.execPath}
const fs=require('node:fs');
if(process.argv.includes('--version')) { console.log('synthetic Codex'); process.exit(0); }
const send=x=>process.stdout.write(JSON.stringify(x)+'\\n');
require('node:readline').createInterface({input:process.stdin}).on('line', line=>{
 const q=JSON.parse(line);
 if(q.method==='initialize') send({id:q.id,result:{}});
 if(q.method==='thread/start') {
  fs.writeFileSync(process.env.R7_CAPTURE,JSON.stringify({params:q.params,args:process.argv}));
  send({id:q.id,result:{thread:{id:'synthetic-thread'}}});
 }
});
`,{mode:0o700});
  const child=spawn('/usr/bin/sandbox-exec',plan.arguments.slice(0,-1).concat([process.execPath,join(process.cwd(),'Engines/codex-sidecar/sidecar.mjs'),'--cwd',plan.cwd]),{
    env:{...env,PATH:bin+':'+dirname(process.execPath)+':/usr/bin:/bin',R7_CAPTURE:capture},stdio:['pipe','pipe','pipe']});
  let output=''; child.stdout.on('data',d=>{output+=d;}); child.stderr.on('data',d=>{output+=d;});
  child.stdin.write(JSON.stringify({op:'send',text:'synthetic',uuid:'synthetic-turn'})+'\n');
  try {
    for(let i=0;i<100 && !existsSync(capture);i++) await new Promise(resolve=>setTimeout(resolve,50));
    assert.ok(existsSync(capture),output);
    return JSON.parse(readFileSync(capture,'utf8'));
  } finally { child.stdin.end(); if(child.exitCode===null) child.kill('SIGTERM'); }
}

test('R7 CARDS-03 real Codex command runs without nested sandbox or approval and denies every private path', {timeout:240_000}, async () => {
  assert.ok(process.env.TATWO2_TEST_BINARY,'room binary required');
  const {root,plan}=policyPlan();
  const settings=await sidecarSettings(root,plan);
  const bundled=join(process.env.TATWO2_RUNTIME_BIN || '/Applications/TATWO OS.app/Contents/Resources/runtime/bin','codex');
  const candidate=[bundled,...(process.env.PATH||'').split(':').map(dir=>join(dir,'codex'))].find(existsSync);
  assert.ok(candidate,'real Codex binary required');
  const binary=realpathSync(candidate);
  const version=spawnSync(binary,['--version'],{env:plan.environment,encoding:'utf8'});
  assert.equal(version.status,0,version.stderr);
  console.log('R7 real Codex '+version.stdout.trim()+'; synthetic home, no model request');
  const args=plan.arguments.slice(0,-1).concat([binary,'-c','features.plugins=false','-c','features.plugin_sharing=false','app-server']);
  const child=spawn('/usr/bin/sandbox-exec',args,{cwd:plan.cwd,env:plan.environment,stdio:['pipe','pipe','pipe']});
  const rpc=await rpcProcess(child);
  const timeout=setTimeout(()=>child.kill('SIGTERM'),30_000);
  try {
    await rpc.request('initialize',{clientInfo:{name:'fixture',version:'1'},capabilities:{experimentalApi:true}});
    child.stdin.write(JSON.stringify({method:'initialized'})+'\n');
    const sandboxPolicy={type:settings.params.sandbox==='danger-full-access'?'dangerFullAccess':'workspaceWrite'};
    const ordinary=await rpc.request('command/exec',{command:['/bin/sh','-c','printf synthetic > ordinary.txt && /bin/cat ordinary.txt'],cwd:plan.cwd,sandboxPolicy,timeoutMs:5000});
    assert.equal(ordinary.exitCode,0,JSON.stringify(ordinary));
    assert.equal(ordinary.stdout,'synthetic');
    assert.equal(rpc.requests.length,0,'ordinary read/write must not request approval');
    for(const path of plan.privatePaths) {
      const denied=await rpc.request('command/exec',{command:['/bin/cat',path],cwd:plan.cwd,sandboxPolicy,timeoutMs:5000});
      assert.notEqual(denied.exitCode,0,`private read succeeded: ${path}`);
      assert.doesNotMatch(denied.stdout,/synthetic private marker/);
    }
    const outside=join(root,'outside-workspace.txt');
    const deniedWrite=await rpc.request('command/exec',{command:['/bin/sh','-c',`printf synthetic > '${outside}'`],cwd:plan.cwd,sandboxPolicy,timeoutMs:5000});
    assert.notEqual(deniedWrite.exitCode,0,'Codex cannot write outside its workspace and isolated home');
    assert.equal(existsSync(outside),false);
    const appData = dirname(dirname(dirname(plan.cwd)));
    const attribute = spawnSync('/usr/bin/xattr',['-w','com.tatwo.synthetic','synthetic-private-attribute',appData]);
    assert.equal(attribute.status,0);
    const attributeRead = await rpc.request('command/exec', {command:['/usr/bin/python3','-c',
      "import ctypes,os,sys; lib=ctypes.CDLL(None); b=ctypes.create_string_buffer(256); n=lib.getxattr(os.fsencode(sys.argv[1]),b'com.tatwo.synthetic',b,256,0,0); sys.exit(0 if n>=0 else 17)", appData],cwd:plan.cwd,sandboxPolicy,timeoutMs:5000});
    assert.notEqual(attributeRead.exitCode,0,'directory traversal may not expose private extended attributes');
    assert.equal(settings.params.sandbox,'danger-full-access');
    assert.equal(settings.params.approvalPolicy,'untrusted','existing native command approval policy stays enforced');
    assert.ok(settings.args.includes('mcp_servers.tatwo2_os.enabled=false'));
    assert.ok(settings.args.includes('mcp_servers.tatwo2_browser.enabled=false'));
  } finally {
    clearTimeout(timeout);
    child.stdin.end();
    if(child.exitCode===null) child.kill('SIGTERM');
  }
});

test('R7 CARDS-04 approved child cannot borrow an unsandboxed Unix server or LaunchServices', {timeout:240_000}, async () => {
  const {root,plan}=policyPlan();
  const socket=join(root,'s.sock');
  const server=spawn(process.execPath,['-e',`const net=require('node:net'),fs=require('node:fs');const server=net.createServer(s=>s.end(fs.readFileSync(process.env.R7_PRIVATE)));server.listen(process.env.R7_SOCKET,()=>console.log('ready'));`],{
    env:{PATH:'/usr/bin:/bin',R7_PRIVATE:plan.privatePaths[0],R7_SOCKET:socket},stdio:['ignore','pipe','pipe']});
  try {
    await once(server.stdout,'data');
    const clientCode=`require('node:net').createConnection(process.argv[1]).on('data',d=>process.stdout.write(d)).on('error',()=>process.exit(17));`;
    const borrowed=spawnSync('/usr/bin/sandbox-exec',plan.arguments.slice(0,-1).concat([process.execPath,'-e',clientCode,socket]),{
      cwd:plan.cwd,env:plan.environment,encoding:'utf8',timeout:5000});
    assert.notEqual(borrowed.status,0,'unsandboxed server accepted the restricted client');
    assert.doesNotMatch(borrowed.stdout,/synthetic private marker/);
    const opened=spawnSync('/usr/bin/sandbox-exec',plan.arguments.slice(0,-1).concat(['/usr/bin/open','-a','synthetic-r7-app-that-does-not-exist']),{
      cwd:plan.cwd,env:plan.environment,encoding:'utf8',timeout:5000});
    assert.notEqual(opened.status,0);
    assert.match(opened.stderr,/Operation not permitted/,'open must be blocked before LaunchServices');
    assert.equal(plan.environment.TMUX,undefined);
  } finally { server.kill('SIGTERM'); }
});
