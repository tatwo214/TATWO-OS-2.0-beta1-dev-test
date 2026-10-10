import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { createGateway } from '../Engines/chatgpt-hands/gateway.mjs';
import { createServer } from 'node:http';
import { runIsolated } from './helpers/w187-runtime.mjs';

const agent = resolve('Engines/sandbox-agent/sandbox-agent.py');
const scratch = () => mkdtempSync('/tmp/w335-node-');
function python(script, root = scratch()) {
  const result = spawnSync('python3', ['-c', `import importlib.util,os,sys\nspec=importlib.util.spec_from_file_location('agent',${JSON.stringify(agent)})\na=importlib.util.module_from_spec(spec);spec.loader.exec_module(a)\n${script}`], {
    env: { PATH: process.env.PATH, HOME: root, PYTHONDONTWRITEBYTECODE: '1' }, encoding: 'utf8', timeout: 10000 });
  assert.equal(result.status, 0, result.stdout + result.stderr); return root;
}

test('Python client pairs through production Unix gateway and submits a real host proposal; revoked access stops', () => {
  const { output } = runIsolated('w335sandboxagent');
  assert.match(output, /PASS real-python-result-in-host-proposal-project-unchanged/);
  assert.match(output, /PASS sandbox-register-window-and-callback-boundary/);
  assert.match(output, /PASS chinese-files-and-artifacts-in-host-card/);
  assert.match(output, /PASS runner-commit-and-worktree-in-host-patch/);
  assert.match(output, /SUMMARY failures=0 passed=5/);
});

test('root is refused before network or state creation; installer needs no sudo and preserves executable on reinstall', () => {
  const root = python(`a.os.geteuid=lambda:0\nsys.argv=['agent','run']\ntry:a.main()\nexcept a.Refused as e:assert 'root' in str(e)\nelse:raise AssertionError('root accepted')\nassert not (a.Path.home()/'.tatwo-sandbox').exists()`);
  const install = () => spawnSync('sh', ['Engines/sandbox-agent/install.sh'], { env: { HOME: root, PATH: process.env.PATH }, encoding: 'utf8' });
  assert.equal(install().status, 0);
  const executable = join(root, '.tatwo-sandbox/sandbox-agent.py');
  assert.equal(statSync(executable).mode & 0o777, 0o700);
  assert.equal(readFileSync(executable, 'utf8'), readFileSync(agent, 'utf8'));
  assert.equal(install().status, 0);
  const bin = join(root, 'bin'); mkdirSync(bin);
  writeFileSync(join(bin, 'id'), '#!/bin/sh\necho 0\n', { mode: 0o700 });
  const denied = spawnSync('sh', ['Engines/sandbox-agent/install.sh'], { env: { HOME: root, PATH: bin + ':' + process.env.PATH }, encoding: 'utf8' });
  assert.equal(denied.status, 1); assert.match(denied.stderr, /root/);
});

test('client refuses scope substitution, unsafe snapshots, expired tokens and non-sandbox tools', () => {
  python(`c=a.Client('https://hands.example.com')\nc.request=lambda *args,**kw:(201,{},'${JSON.stringify({ scope: 'tatwo.hands', client_id: 'forged' })}')\ntry:c.pair('fixture')\nexcept a.Refused:pass\nelse:raise AssertionError('full scope accepted')\nfor name in ['../outside','/absolute','.git/config','dir/../../outside','a\\\\b']:\n try:a.path_in(a.Path.home(),name)\n except a.Refused:pass\n else:raise AssertionError(name)\nc.token={'expires_at':0,'access_token':'synthetic'}\nfor name in ['sandbox_heartbeat','read_file','run_command','dispatch','memory_search','user_remember','sandbox_dispatch']:\n try:c.call(name)\n except a.Refused:pass\n else:raise AssertionError(name)`);
});

test('token ownership/mode/symlink checks and zero-call expiry stop before gateway initialization', () => {
  const root = scratch(), state = join(root, '.tatwo-sandbox'); mkdirSync(state);
  const file = join(state, 'token.json');
  writeFileSync(file, JSON.stringify({ gateway: 'https://hands.example.com', access_token: 'synthetic', expires_at: 0 }), { mode: 0o600 });
  const run = () => spawnSync('python3', [agent, 'run', '--runner', 'sh', '--once'], { env: { HOME: root, PATH: process.env.PATH }, encoding: 'utf8', timeout: 5000 });
  assert.match(run().stderr, /expired/);
  chmodSync(file, 0o644); assert.match(run().stderr, /mode 600/);
  python(`os.unlink(a.Path.home()/'.tatwo-sandbox/token.json')\nos.symlink('/dev/null',a.Path.home()/'.tatwo-sandbox/token.json')`, root);
  assert.equal(run().status, 3);
});

test('running client kills runner descendants after authorization refusal; no retry flood or result is sent', async () => {
  const root = scratch(), socket = join(root, 'g.sock'), config = join(root, 'config.json'), home = join(root, 'home');
  mkdirSync(join(home, '.tatwo-sandbox'), { recursive: true });
  writeFileSync(join(home, '.tatwo-sandbox/token.json'), JSON.stringify({ gateway: 'https://hands.example.com', access_token: 's'.repeat(40), expires_at: Date.now()/1000 + 100 }), { mode: 0o600 });
  writeFileSync(config, JSON.stringify({ socket_path: socket, public_host: 'hands.example.com', allowed_ip_ranges: ['203.0.113.0/24'], ranges_fetched_at: new Date().toISOString() }));
  const pidFile = join(root, 'runner-pid'), calls = [];
  let beats = 0;
  const gateway = createGateway({ configFile: config, osCall: async (method, params) => {
    if (params.op === 'check') return { ok: beats < 2, scope: 'sandbox', grant_id: 'g_' + 'a'.repeat(20), level: 0 };
    if (method === 'hands_call') {
      calls.push(params.name);
      if (params.name === 'sandbox_heartbeat') { beats++; return { content: [{ type: 'text', text: 'ok' }] }; }
      if (params.name === 'sandbox_fetch_job') return { isError: false, content: [{ type: 'text', text: JSON.stringify({ job_id: 'job', lease: 'lease', files: {}, artifacts: [], instruction: `echo $$ > '${pidFile}'\nsleep 60\n` }) }] };
    }
    throw new Error('unexpected call');
  } });
  await new Promise(resolve => gateway.server.listen(socket, resolve));
  try {
    const child = spawn('python3', [agent, 'run', '--runner', 'sh', '--interval', '1', '--socket', socket, '--once'], { env: { HOME: home, PATH: process.env.PATH } });
    let output = ''; child.stderr.on('data', x => output += x);
    const status = await new Promise((resolve, reject) => { const timer = setTimeout(() => { child.kill(); reject(new Error('client did not stop')); }, 10000); child.on('exit', code => { clearTimeout(timer); resolve(code); }); });
    assert.equal(status, 3, output);
    assert.deepEqual(calls, ['sandbox_heartbeat', 'sandbox_fetch_job', 'sandbox_heartbeat']);
    assert.ok(existsSync(pidFile));
    assert.throws(() => process.kill(Number(readFileSync(pidFile, 'utf8').trim()), 0), { code: 'ESRCH' });
    assert.match(output, /refused/);
  } finally { await new Promise(resolve => gateway.server.close(resolve)); }
});

test('tool timeout submits bounded report and retains local workspace; unassigned files never enter patch', () => {
  python(`calls=[]\nclass Fake:\n def call(self,name,args=None):calls.append((name,args))\nroot=a.Path.home(); job={'job_id':'j','lease':'l','files':{'main.txt':'before\\n'},'artifacts':[],'instruction':"printf 'after\\\\n' > main.txt\\nprintf 'unassigned' > extra.txt\\nsleep 5\\n"}\na.run_job(Fake(),job,root,['sh'],1,30)\nresult=calls[-1][1]\nassert calls[-1][0]=='sandbox_post_result'\nassert result['report'].startswith('timeout')\nassert '+after' in result['patch'] and 'extra.txt' not in result['patch']\nassert len(result['patch'].encode())+len(result['report'].encode())<=a.LIMIT\nassert list(root.glob('job-*'))`);
});

test('valid UTF-8 snapshot below W264 limits runs without counting JSON escapes as file bytes', () => {
  python(`calls=[]\nclass Fake:\n def call(self,name,args=None):calls.append((name,args))\njob={'job_id':'j','lease':'l','files':{str(i)+'.txt':'中'*20000 for i in range(3)},'artifacts':[],'instruction':'printf done'}\na.run_job(Fake(),job,a.Path.home(),['sh'],5,30)\nassert calls[-1][0]=='sandbox_post_result'\nassert calls[-1][1]['report']=='exit=0\\ndone'`);
});

test('W349: invalid result text and refused submissions become report-only failures; homes are removed and only 20 jobs remain', () => {
  python(`calls=[]
class Fake:
 def call(self,name,args=None):
  calls.append((name,args))
  if name=='sandbox_post_result' and args.get('patch') and reject_patch:raise a.JobError('synthetic tool refusal')
root=a.Path.home()
for instruction,reason,reject_patch in [("head -c 1 /dev/zero > output.txt",'bounded text',False), (r"printf '\\377' > output.txt",'utf-8',False), ("head -c 204801 /dev/zero > output.txt",'bounded text',False), ("printf after > main.txt",'synthetic tool refusal',True), (r"head -c 204700 /dev/zero | tr '\\000' x > output.txt",'exceeds 200 KB',False)]:
 job={'job_id':'j','lease':'l','files':{'main.txt':'before\\n'},'artifacts':['output.txt'],'instruction':instruction}
 a.run_job(Fake(),job,root,['sh'],5,30)
 assert calls[-1][0]=='sandbox_post_result' and 'patch' not in calls[-1][1] and calls[-1][1]['report'].startswith('工作失敗：')
 assert reason in calls[-1][1]['report'],calls[-1]
 assert not list(root.glob('runner-home-*'))
class Reject:
 def call(self,name,args=None):
  if name=='sandbox_post_result':raise a.JobError('cannot post report')
a.run_job(Reject(),job,root,['sh'],5,30)
assert any((p/'failure-report.txt').exists() for p in root.glob('job-*'))
for i in range(21):
 job['instruction']='printf done'
 a.run_job(Fake(),job,root,['sh'],5,30)
assert len(list(root.glob('job-*')))==20 and not list(root.glob('runner-home-*'))`);
});

test('W349: live client reports a binary result, fetches the next job and still exits 3 on revoked access', async () => {
  const root = scratch(), home = join(root, 'home'), state = join(home, '.tatwo-sandbox'), socket = join(root, 'g.sock'), config = join(root, 'config.json');
  mkdirSync(state, { recursive: true });
  writeFileSync(join(state, 'token.json'), JSON.stringify({ gateway: 'https://hands.example.com', access_token: 's'.repeat(40), expires_at: Date.now()/1000 + 3600 }), { mode: 0o600 });
  writeFileSync(config, JSON.stringify({ socket_path: socket, public_host: 'hands.example.com', allowed_ip_ranges: ['203.0.113.0/24'], ranges_fetched_at: new Date().toISOString() }));
  const results = []; let fetched = 0;
  const gateway = createGateway({ configFile: config, osCall: async (method, params) => {
    if (params.op === 'check') return { ok: results.length < 2, scope: 'sandbox', grant_id: 'g_' + 'a'.repeat(20), level: 0 };
    if (method !== 'hands_call') throw new Error('unexpected call');
    if (params.name === 'sandbox_fetch_job') {
      fetched++;
      return { content: [{ type: 'text', text: JSON.stringify({ job_id: 'j' + fetched, lease: 'l', files: {}, artifacts: ['output.txt'], instruction: fetched === 1 ? "printf '\\000' > output.txt" : "printf done > output.txt" }) }] };
    }
    if (params.name === 'sandbox_post_result') results.push(params.arguments);
    return { content: [{ type: 'text', text: 'ok' }] };
  } });
  await new Promise(resolve => gateway.server.listen(socket, resolve));
  try {
    const child = spawn('python3', [agent, 'run', '--runner', 'sh', '--interval', '1', '--socket', socket], { env: { HOME: home, PATH: process.env.PATH } });
    let output = ''; child.stderr.on('data', x => output += x); child.stdout.resume();
    const code = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => { child.kill(); reject(new Error('client stalled')); }, 15000);
      child.on('error', reject); child.on('exit', code => { clearTimeout(timer); resolve(code); });
    });
    assert.equal(code, 3, output); assert.equal(fetched, 2); assert.equal(results.length, 2);
    assert.equal(results[0].job_id, 'j1'); assert.match(results[0].report, /^工作失敗：/); assert.equal(results[0].patch, undefined);
    assert.equal(results[1].job_id, 'j2'); assert.match(results[1].patch, /\+done/);
    assert.match(output, /HTTP 401/);
  } finally { await new Promise(resolve => gateway.server.close(resolve)); }
});

test('W349: empty queues are idle, tool errors are per job and explicit revoked grants stay fatal', () => {
  python(`c=a.Client('https://hands.example.com')
c.rpc=lambda *args,**kw:{'isError':True,'content':[{'text':'沒有可領取的工作，或工作不屬於此權杖。'}]}
assert c.call('sandbox_fetch_job') is None
c.rpc=lambda *args,**kw:{'isError':True,'content':[{'text':'synthetic result rejected'}]}
try:c.call('sandbox_post_result',{'job_id':'j'})
except a.JobError:pass
else:raise AssertionError('tool error stopped client')
for text in ['unauthorized','invalid_grant','revoked','沙盒授權已撤銷']:
 c.rpc=lambda *args,**kw:{'isError':True,'content':[{'text':text}]}
 try:c.call('sandbox_post_result',{'job_id':'j'})
 except a.JobError:raise AssertionError('revocation treated as job failure')
 except a.Refused as e:assert e.status==403
 else:raise AssertionError('revocation ignored')
class Offline:
 def call(self,name,args=None):
  if name=='sandbox_post_result':raise a.Refused('host unavailable',503)
job={'job_id':'j','lease':'l','files':{},'artifacts':['binary'],'instruction':'head -c 1 /dev/zero > binary'}
a.run_job(Offline(),job,a.Path.home(),['sh'],5,30)
assert list(a.Path.home().glob('job-*/failure-report.txt')) and not list(a.Path.home().glob('runner-home-*'))`);
});

test('W339: expired access token refreshes once with rotation and saves; revoked refresh stops; stale MCP session re-initializes once', () => {
  python(`import json
saved=[];calls=[]
c=a.Client('https://hands.example.com');c.save=lambda t:saved.append(dict(t));c.session='s-old'
c.token={'expires_at':0,'access_token':'old','refresh_token':'r1','client_id':'cid'}
stale=[True]
def req(path,body=None,form=False,headers=None):
    calls.append((path,body,dict(headers or {})))
    if path=='/sandbox/token': return 200,{},json.dumps({'access_token':'new','refresh_token':'r2','expires_in':3600,'scope':'sandbox'})
    if body['method']!='initialize' and stale[0]:
        stale[0]=False; raise a.Refused('gateway refused /mcp (HTTP 404); stopped',404)
    return 200,{'mcp-session-id':'s-new'} if body['method']=='initialize' else {},json.dumps({'result':{'ok':True}})
c.request=req
assert c.rpc('tools/list',{})=={'ok':True}
assert calls[0][0]=='/sandbox/token' and calls[0][1]=={'grant_type':'refresh_token','refresh_token':'r1','client_id':'cid'}
assert [x[1]['method'] for x in calls[1:]]==['tools/list','initialize','tools/list']
assert calls[1][2]['Authorization']=='Bearer new' and calls[3][2]['Mcp-Session-Id']=='s-new'
assert saved[-1]['refresh_token']=='r2' and saved[-1]['access_token']=='new' and c.token['expires_at']>0
c.token['expires_at']=0
def refused(path,body=None,form=False,headers=None):
    calls.append((path,body,headers))
    raise a.Refused('gateway refused /sandbox/token (HTTP 400); stopped',400)
c.request=refused;calls.clear()
try:c.rpc('tools/list',{})
except a.Refused as e:assert e.status==400
else:raise AssertionError('revoked refresh accepted')
assert [x[0] for x in calls]==['/sandbox/token']
c.token={'expires_at':0,'access_token':'old'}
try:c.rpc('tools/list',{})
except a.Refused as e:assert 'expired' in str(e)
else:raise AssertionError('no refresh token accepted')`);
});

test('W340: denied refresh exits 3; HTTP failures and a missing socket exit 1 without retrying in process', async () => {
  const root = scratch(), state = join(root, '.tatwo-sandbox'), socket = join(root, 'g.sock');
  mkdirSync(state);
  writeFileSync(join(state, 'token.json'), JSON.stringify({ gateway: 'https://hands.example.com', access_token: 'synthetic',
    client_id: 'synthetic-client', refresh_token: 'synthetic-refresh', expires_at: 0 }), { mode: 0o600 });
  const run = () => new Promise((resolve, reject) => {
    const child = spawn('python3', [agent, 'run', '--runner', 'sh', '--once', '--socket', socket], { env: { HOME: root, PATH: process.env.PATH } });
    let output = ''; child.stderr.on('data', x => output += x); child.on('error', reject);
    const timer = setTimeout(() => { child.kill(); reject(new Error('client did not stop')); }, 5000);
    child.on('exit', code => { clearTimeout(timer); resolve({ code, output }); });
  });
  for (const [status, expected] of [[400, 3], [401, 3], [403, 3], [408, 1], [429, 1], [500, 1], [503, 1]]) {
    const calls = [];
    const server = createServer((req, res) => { calls.push(req.url); req.resume(); res.writeHead(status, { 'Content-Type': 'application/json' }); res.end('{"error":"synthetic"}'); });
    await new Promise(resolve => server.listen(socket, resolve));
    try { const result = await run(); assert.equal(result.code, expected, result.output); assert.deepEqual(calls, ['/sandbox/token']); }
    finally { await new Promise(resolve => server.close(resolve)); }
  }
  assert.equal((await run()).code, 1);
  const denied = spawnSync('python3', ['-c', "import os,runpy,sys\npath=sys.argv[1]\ndef denied(*args,**kw):raise PermissionError('synthetic permission denied')\nos.open=denied\nsys.argv=[path,'run','--runner','sh','--once']\nrunpy.run_path(path,run_name='__main__')", agent], {
    env: { HOME: root, PATH: process.env.PATH }, encoding: 'utf8', timeout: 5000 });
  assert.equal(denied.status, 3, denied.stderr);
  assert.match(denied.stderr, /PermissionError/);
  python(`c=a.Client('https://hands.example.com');c.token={'expires_at':a.time.time()+3600,'access_token':'synthetic'}
c.request=lambda *args,**kw:(200,{},a.json.dumps({'error':{'code':-32000,'message':'TATWO OS is temporarily unavailable'}}))
try:c.rpc('tools/list',{})
except a.Refused as e:assert e.status==503
else:raise AssertionError('MCP transport failure accepted')
c.rpc=lambda *args,**kw:{'isError':True,'content':[{'type':'text','text':'TATWO OS is temporarily unavailable.'}]}
try:c.call('sandbox_heartbeat')
except a.Refused as e:assert e.status==503
else:raise AssertionError('host unavailable accepted')`);
});

test('W340: generated service definitions restart failures after 60 seconds and stop denied access', () => {
  const installer = readFileSync('Engines/sandbox-agent/vm/install.sh', 'utf8');
  assert.match(installer, /Restart=on-failure\nRestartSec=60\nRestartPreventExitStatus=3/);
  const mac = readFileSync('Engines/sandbox-agent/vm/macos.sh', 'utf8');
  const plist = mac.split("tee /Library/LaunchDaemons/com.tatwo.sandbox.plist >/dev/null <<'PL'\n")[1].split('\nPL')[0];
  const parsed = spawnSync('python3', ['-c', 'import plistlib,json,sys;print(json.dumps(plistlib.loads(sys.stdin.buffer.read())))'], { input: plist, encoding: 'utf8' });
  assert.equal(parsed.status, 0, parsed.stderr);
  const definition = JSON.parse(parsed.stdout);
  assert.deepEqual(definition.KeepAlive, { SuccessfulExit: false }); assert.equal(definition.ThrottleInterval, 60);
  assert.equal(definition.UserName, 'work'); assert.equal(definition.RunAtLoad, true);
  const root = scratch(), bin = join(root, 'bin'), state = join(root, '.tatwo-sandbox'), delay = join(root, 'delay');
  mkdirSync(bin); mkdirSync(state); writeFileSync(join(state, 'token.json'), '{}');
  writeFileSync(join(bin, 'python3'), '#!/bin/sh\nexit "$SYNTHETIC_EXIT"\n', { mode: 0o700 });
  writeFileSync(join(bin, 'sleep'), '#!/bin/sh\nprintf "%s\\n" "$1" >> "$SYNTHETIC_DELAY"\n', { mode: 0o700 });
  const command = definition.ProgramArguments[2].replaceAll(definition.EnvironmentVariables.HOME + '/.tatwo-sandbox', state).replace('/usr/bin/python3', join(bin, 'python3'));
  for (const [status, expected] of [[0, 0], [3, 0], [1, 1]]) {
    writeFileSync(delay, '');
    const run = spawnSync('/bin/sh', ['-c', command], { env: { HOME: root, PATH: bin + ':/usr/bin:/bin', SYNTHETIC_EXIT: String(status), SYNTHETIC_DELAY: delay }, encoding: 'utf8', timeout: 5000 });
    assert.equal(run.status, expected, run.stderr); assert.equal(readFileSync(delay, 'utf8'), status === 1 ? '60\n' : '');
  }
});

test('W344: a refresh whose new token cannot be saved stops for re-pairing instead of restarting', () => {
  python(`import json
c=a.Client('https://hands.example.com')
def boom(t): raise OSError('disk full')
c.save=boom
c.token={'expires_at':0,'access_token':'old','refresh_token':'r1','client_id':'cid'}
c.request=lambda path,body=None,form=False,headers=None:(200,{},json.dumps({'access_token':'new','refresh_token':'r2','expires_in':3600,'scope':'sandbox'}))
try:c.refresh()
except a.Refused as e:assert e.status is None and 'pair again' in str(e)
else:raise AssertionError('unsaved rotation accepted')`);
});
