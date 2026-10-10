import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync } from 'node:fs';
import { spawnSync, spawn } from 'node:child_process';
import { join, dirname } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';
import net from 'node:net';
import { once } from 'node:events';
import { createInterface } from 'node:readline';
function run(scenario) {
  assert.ok(process.env.TATWO2_TEST_BINARY, 'room binary required');
  const root = testScratch('w187-r8-'); mkdirSync(join(root,'home'));
  for (const folder of ['engines/codex','engines/claude','os','docs','artifacts','unused-entry']) mkdirSync(join(root,folder),{recursive:true});
  writeFileSync(join(root,'owned-fixture'), 'synthetic only\n');
  const result = spawnSync(process.env.TATWO2_TEST_BINARY, scenario === 'memory-launch' ? ['-tatwo2.sidecarPath.codex', join(process.cwd(),'Engines/codex-sidecar/sidecar.mjs')] : [], {
    env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR, TATWO2_RUNTIME_BIN: "/Applications/TATWO OS.app/Contents/Resources/runtime/bin",
      HOME: join(root,'home'), CFFIXED_USER_HOME: join(root,'home'),
      TATWO_STAGING_ROOT:root, TATWO_STAGING_SCRATCH_HOME:join(root,'home'),
      TATWO2_ENGINES_ROOT:join(root,'engines'), CODEX_HOME:join(root,'engines/codex'),
      TATWO2_CODEX_SOURCE_HOME:join(root,'engines/codex'), CLAUDE_CONFIG_DIR:join(root,'engines/claude'),
      CLAUDE_SECURESTORAGE_CONFIG_DIR:join(root,'engines/claude'), TATWO2_OS_SOCKET:join(root,'o.sock'),
      TATWO2_BROWSER_SOCKET:join(root,'b.sock'), TATWO2_SELFTEST_ARTIFACTS:join(root,'artifacts'),
      TATWO2_OS_ROOT:join(root,'os'), TATWO2_DOCS_ROOT:join(root,'docs'),
      TATWO2_OS_UPSTREAM_PATH:join(root,'os/os-upstream.md'), TATWO2_SKILLET_PATH:join(root,'os/skillet.md'),
      TATWO2_SELFTEST:'w187fleet', TATWO2_W187_NODE:process.execPath, ...(scenario === 'transfer-recovery' ? {TATWO2_W187_TRANSFER:'1',TATWO2_W187_R8_TRANSFER:'1'} : {TATWO2_W187_R8:scenario}), TATWO2_W187_TEST_ROOT: root,
      TATWO_OS_ROOT: join(root,'unused-entry'), TATWO2_LIVE_ROOT: join(root,'unused-live'),
      TATWO2_AUTHORIZED_KEYS: join(root,'unused-authorized'), TATWO2_SSH_KNOWN_HOSTS: join(root,'unused-known'),
      TATWO2_SSH_KEY_PATH: join(root,'unused-key'), TATWO2_SSH_HOST_KEY_PUB: join(root,'unused-host.pub'),
      GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' },
    encoding: 'utf8', timeout: 220_000, maxBuffer: 4 * 1024 * 1024 });
  const output = result.stdout + result.stderr;
  writeFileSync(join(root,'runtime.log'),output);
  assert.equal(result.status,0,output);
  assert.match(output,/W187R8 SUMMARY failures=0/);
  return {root, plan: scenario === 'sandbox-plan' ? JSON.parse(readFileSync(join(root,'artifacts/sandbox-plan.json'),'utf8')) : null};
}

for (const scenario of ['cli-history','entry-openai','entry-claude','entry-grok','entry-background','entry-cli','memory-full-fetch','transfer-recovery','projection-enum','projection-schema','projection-storage','row-warnings','memory-push','memory-errors','revocation-pending','stop-tracking']) test(`R8 negative runtime ${scenario}`, {timeout:240_000}, () => run(scenario));
let cached;
const plan = () => cached ??= run('sandbox-plan');
function command(p, executable, args, defaults=false) {
  return spawnSync('/usr/bin/sandbox-exec',(defaults?p.defaultArguments:p.arguments).slice(0,-1).concat([executable,...args]),{cwd:p.cwd,env:p.environment,encoding:'utf8',timeout:30_000});
}
test('R8 CARDS-01 DNS and TLS survive the same inherited profile', {timeout:240_000}, () => {
  const {plan:p}=plan();
  for (const [executable,args] of [
    ['/usr/bin/python3',['-c',"import socket; print(socket.getaddrinfo('api.openai.com',443))"]],
    [process.execPath,['-e',"require('node:dns').lookup('api.openai.com',(err,address)=>{if(err) throw err; console.log(address)})"]],
    ['/usr/bin/python3',['-c',"import socket,ssl; s=socket.create_connection(('api.openai.com',443),timeout=15); t=ssl.create_default_context().wrap_socket(s,server_hostname='api.openai.com'); print(t.version()); t.close()"]]
  ]) {
    const result=command(p,executable,args); assert.equal(result.status,0,result.stdout+result.stderr);
    assert.ok(result.stdout.trim());
  }
});
test('R8 CARDS-01 App socket directories remain denied', {timeout:240_000}, async () => {
  const {plan:p}=plan();
  for (const socket of p.sockets) {
    mkdirSync(join(socket,'..'),{recursive:true});
    const server=net.createServer(s=>s.end('synthetic private socket'));
    server.listen(socket); await once(server,'listening');
    try {
      const result=command(p,process.execPath,['-e',"require('node:net').createConnection(process.argv[1]).on('connect',()=>process.exit(0)).on('error',e=>process.exit(['EPERM','EACCES'].includes(e.code)?17:18))",socket]);
      assert.equal(result.status,17,socket+' '+result.stderr); assert.doesNotMatch(result.stdout,/synthetic private socket/);
    } finally { await new Promise(resolve=>server.close(resolve)); }
  }
});
test('R8 CARDS-02 stderr stdout descriptor PTY and module cache work', {timeout:240_000}, () => {
  const {plan:p}=plan();
  for (const [executable,args] of [
    ['/bin/sh',['-c','set -e; echo synthetic > /dev/stderr; echo synthetic > /dev/stdout; echo synthetic > /dev/fd/2']],
    ['/usr/bin/script',['-q','/dev/null','/usr/bin/true']],
    ['/usr/bin/clang',['-fmodules','-c','module.c','-o','module.o']]
  ]) {
    writeFileSync(join(p.cwd,'module.c'),'#include <stdio.h>\nint fixture(void) { return puts("synthetic"); }\n');
    const result = executable === '/usr/bin/script' ? ttyCommand(p,executable,args) : command(p,executable,args); assert.equal(result.status,0,result.stdout+result.stderr);
  }
  assert.ok(readdirSync(p.environment.CLANG_MODULE_CACHE_PATH,{recursive:true}).some(path=>path.endsWith('.pcm')), 'actual module cache created inside isolation');
  for (const name of ['CLANG_MODULE_CACHE_PATH','SWIFTPM_MODULECACHE_OVERRIDE','SWIFTPM_CACHE_PATH','XDG_CACHE_HOME','TMPDIR']) {
    assert.ok(p.environment[name]?.startsWith(dirname(p.cwd)+'/'),name+' must be isolated');
  }
});
for (const relative of ['.zsh_history','.zsh_sessions/private','.bash_history','.bash_sessions/private','Library/Caches/tatwo2/Cache/private','Library/Application Support/TATWO OS/Browser/private']) test(`R8 CARDS-04 private read denied ${relative}`, {timeout:240_000}, () => {
  const {plan:p}=plan(); const result=command(p,'/bin/cat',[join(p.home,relative)]);
  assert.notEqual(result.status,0,relative); assert.doesNotMatch(result.stdout,/synthetic private history/);
});
for (const entry of ['codex','claude','grok','run_background','cli']) test(`R8 R7-CARDS-04 ${entry} write boundary`, {timeout:240_000}, () => {
  const {plan:p}=plan();
  mkdirSync(join(p.home,'Library/LaunchAgents'),{recursive:true});
  for (const path of [join(p.home,'.zshrc'),join(p.home,'Library/LaunchAgents/x.plist')]) {
    const result=command(p,'/bin/sh',['-c','printf synthetic > "$1"','fixture',path],entry !== 'codex');
    assert.notEqual(result.status,0,entry+' '+path); assert.equal(existsSync(path),false);
  }
  const allowed=command(p,'/bin/sh',['-c',`printf synthetic > ${entry}.txt`],entry !== 'codex');
  assert.equal(allowed.status,0,allowed.stderr);
});

function ttyCommand(p, executable, args) {
  const python = `import os,pty,sys
pid,fd=pty.fork()
if pid==0: os.execve('/usr/bin/sandbox-exec',['/usr/bin/sandbox-exec']+sys.argv[1:],os.environ)
try:
 while True:
  data=os.read(fd,65536)
  if not data: break
  os.write(1,data)
except OSError: pass
_,status=os.waitpid(pid,0)
sys.exit(os.waitstatus_to_exitcode(status))`;
  return spawnSync('/usr/bin/python3',['-c',python,...p.arguments.slice(0,-1),executable,...args],{cwd:p.cwd,env:p.environment,encoding:'utf8',timeout:30_000});
}


test('R8 R7-CARDS-05 MCP advertises stop tracking through confirmed proposal', {timeout:10000}, async () => {
  const root=testScratch('w187-mcp-'), socket=join(root,'fixture.sock');
  const server=net.createServer(connection=>connection.once('data',()=>connection.end(JSON.stringify({ok:true,result:{state:'enrolled'}})+'\n')));
  server.listen(socket); await once(server,'listening');
  const child=spawn(process.execPath,['Engines/os-mcp/server.mjs'],{env:{PATH:process.env.PATH,HOME:root,TATWO2_OS_SOCKET:socket},stdio:['pipe','pipe','pipe']});
  const lines=createInterface({input:child.stdout});
  try {
    const response=once(lines,'line');
    child.stdin.write(JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/list'})+'\n');
    const reply=JSON.parse((await response)[0]);
    const tool=reply.result.tools.find(tool=>tool.name==='fleet_propose');
    assert.ok(tool.inputSchema.properties.changes.items.properties.op.enum.includes('stop_tracking'));
    assert.match(tool.description,/本機預覽.*使用者.*確認/);
    assert.equal(reply.result.tools.some(tool=>tool.name==='fleet_confirm'),false);
  } finally { lines.close(); child.kill(); await once(child,'exit'); await new Promise(resolve=>server.close(resolve)); }
});
