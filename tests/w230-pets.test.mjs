import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, readdirSync, mkdirSync, writeFileSync, existsSync, realpathSync} from 'node:fs';
import {spawn, spawnSync, execFileSync} from 'node:child_process';
import readline from 'node:readline';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {testScratch} from './helpers/test-scratch.mjs';

const checkout = fileURLToPath(new URL('..', import.meta.url));
const read = file => readFileSync(path.join(checkout, file), 'utf8');
const sources = 'App/Sources/Tatwo2/';
const files = dir => readdirSync(path.join(checkout, dir), {withFileTypes:true}).flatMap(entry =>
  entry.isDirectory() ? files(`${dir}/${entry.name}`) : [`${dir}/${entry.name}`]);

test('W230 local storage, scope, event privacy and Events line budget', () => {
  const store = read(sources + 'Pets/PetStore.swift');
  assert.doesNotMatch(store, /document\.json|LiveDocumentRecord|store\.save|URLSession|Keychain/);
  for (const name of ['pets.json', 'teams.json', 'hall-of-fame.json', 'avatars', 'corrupt-']) assert.ok(store.includes(name), name);
  assert.match(store, /Darwin.rename/); assert.match(store, /0o600/);
  for (const file of files(sources + 'Pets').filter(f => !f.endsWith('Acceptance.swift'))) {
    assert.doesNotMatch(read(file), /URLSession|SecItem|OSSocketServer|registerTool|os_mcp/);
  }
  const count = files(sources + 'Events').filter(f => !f.endsWith('Acceptance.swift')).reduce((n, f) => n + read(f).trimEnd().split('\n').length, 0);
  assert.ok(count <= 460, `Events production lines ${count}`);
  assert.doesNotMatch(read(sources + 'Facade/OSAgentBridge.swift'), /OSEventLog|PetStore|PetProgress|queryEvents/);
  for (const file of files('Engines').filter(f => /mcp.*\/.*\.mjs$/.test(f))) {
    assert.doesNotMatch(read(file), /OSEventLog|PetStore|queryEvents|pets\.json/, file);
  }
  assert.match(read(sources + 'Pets/PetChat.swift'), /model.sendFromDM/);
  assert.match(read(sources + 'Pets/PetChat.swift'), /origin: "composer", surface: "pets"/);
  assert.match(read(sources + 'Pets/PetChat.swift'), /select: false/);
});

test('W230 production growth stays within 900 net lines', () => {
  const existing = ['Events/OSEventSources.swift','Events/OSEventLog.swift','Facade/ChatLiveEngine.swift','Facade/ChatPageModel.swift','SelfTest.swift'].map(p => sources+p)
    .concat(['Engines/claude-sidecar/sidecar.mjs','Engines/codex-sidecar/sidecar.mjs','Package.swift']);
  // Keep this room's backend budget separate from the later UI rooms.
  const owned = execFileSync('git', ['diff', '--name-only', '6ce1f6d4', 'a22eab36'], {cwd:checkout,encoding:'utf8'})
    .trim().split('\n').filter(file => file.startsWith(sources+'Pets/') || existing.includes(file));
  const rows = execFileSync('git', ['diff', '--numstat', '6ce1f6d4', '--', ...owned], {cwd:checkout,encoding:'utf8'})
    .trim().split('\n').filter(Boolean);
  let net = 0;
  for (const row of rows) {
    const [add, del, file] = row.split('\t');
    if (!file.endsWith('Acceptance.swift')) net += Number(add)-Number(del);
  }
  assert.ok(net<=900, `Production net lines ${net}`);
});

test('W230 Codex real sidecar accumulates native output once, handles repeated and stale notifications', {timeout:20000}, async t => {
  const root = realpathSync(testScratch('w230-usage-'));
  for (const dir of ['home', 'codex', 'source']) mkdirSync(path.join(root, dir));
  const binary = path.join(root, 'app-server-fixture.cjs');
  writeFileSync(binary, `#!${process.execPath}\n` + String.raw`
if(process.argv.includes('--version')) { console.log('fixture codex'); process.exit(0); }
const readline = require('node:readline');
const emit = value => console.log(JSON.stringify(value));
let turn = 0;
const notify = (method,params) => emit({method,params});
const usage = (id,total,last) => notify('thread/tokenUsage/updated',{threadId:'fixture-thread',turnId:id,
  tokenUsage:{total:{outputTokens:total,reasoningOutputTokens:total-5},last:{outputTokens:last,reasoningOutputTokens:last-5}}});
readline.createInterface({input:process.stdin}).on('line', line => {
  const c=JSON.parse(line);
  if(c.method==='initialize') return emit({id:c.id,result:{}});
  if(c.method==='thread/start') return emit({id:c.id,result:{thread:{id:'fixture-thread'}}});
  if(c.method==='thread/goal/get') return emit({id:c.id,result:{goal:null}});
  if(c.method==='model/list') return emit({id:c.id,result:{data:[]}});
  if(c.method!=='turn/start') { if(c.id) emit({id:c.id,result:{}}); return; }
  const id='turn-'+(++turn);
  emit({id:c.id,result:{turn:{id}}});
  notify('turn/started',{threadId:'fixture-thread',turn:{id}});
  if(turn===1) { usage(id,150,150); usage(id,150,150); usage(id,230,80); }
  if(turn===2) { usage('turn-1',9000,8770); usage(id,300,70); }
  if(turn===4) { usage(id,450,50); }
  if(turn===5) { notify('thread/tokenUsage/updated',{threadId:'other-thread',turnId:id,tokenUsage:{last:{outputTokens:800},total:{outputTokens:1250}}}); }
  if(turn===6) { usage(id,-1,50); }
  notify('turn/completed',{threadId:'fixture-thread',turn:{id,status:'completed'}});
});
`, {mode:0o700});
  const child = spawn(process.execPath, [path.join(checkout, 'Engines/codex-sidecar/sidecar.mjs'), '--cwd', root], {
    env:{PATH:`${path.dirname(process.execPath)}:/usr/bin:/bin`, HOME:`${root}/home`, CODEX_HOME:`${root}/codex`,
      TATWO2_CODEX_SOURCE_HOME:`${root}/source`, TATWO2_CODEX_BIN:binary}, stdio:['pipe','pipe','pipe']});
  const events = []; let stderr = '';
  readline.createInterface({input:child.stdout}).on('line', line => events.push(JSON.parse(line)));
  child.stderr.on('data', data => { stderr += data; });
  t.after(() => { child.stdin.end(); if (child.exitCode === null) child.kill();
    writeFileSync(`${root}/events.json`, JSON.stringify(events, null, 2)); writeFileSync(`${root}/stderr.log`, stderr); });
  const until = async fn => { const end=Date.now()+6000;
    while(Date.now()<end) { if(fn()) return; if(child.exitCode!==null) assert.fail(stderr+JSON.stringify(events)); await new Promise(r=>setTimeout(r,10)); }
    assert.fail(stderr+JSON.stringify(events)); };
  await until(() => events.some(e=>e.msg?.subtype==='init'));
  for (let i=1;i<=6;i++) {
    child.stdin.write(JSON.stringify({op:'send',text:`turn ${i}`,uuid:`client-${i}`})+'\n');
    await until(() => events.filter(e=>e.msg?.type==='result').length === i);
  }
  const results=events.filter(e=>e.msg?.type==='result').map(e=>e.msg);
  assert.deepEqual(results.map(r=>r.usage?.output_tokens), [230,70,undefined,50,undefined,undefined]);
  assert.deepEqual(results.map(r=>r.client_turn_id),[1,2,3,4,5,6].map(n=>`client-${n}`));
  console.log(`W230 Codex notification evidence: ${root}`);
});

test('W230 w230pets native acceptance, all backend requirements in isolated environment', {timeout:120000}, () => {
  const binary = process.env.TATWO2_TEST_BINARY;
  assert.ok(binary && existsSync(binary), 'TATWO2_TEST_BINARY must point to the built native binary');
  const root = realpathSync(testScratch('w230-native-'));
  for(const dir of ['home','live','engines/codex','engines/claude','os','docs','artifacts']) mkdirSync(`${root}/${dir}`,{recursive:true});
  const env = {...process.env, HOME:`${root}/home`, CFFIXED_USER_HOME:`${root}/home`,
    TATWO_STAGING_SCRATCH_HOME:`${root}/home`, TATWO_STAGING_ROOT:root,
    TATWO2_LIVE_ROOT:`${root}/live`,TATWO2_ENGINES_ROOT:`${root}/engines`, CODEX_HOME:`${root}/engines/codex`,
    TATWO2_CODEX_SOURCE_HOME:`${root}/engines/codex`, CLAUDE_CONFIG_DIR:`${root}/engines/claude`, CLAUDE_SECURESTORAGE_CONFIG_DIR:`${root}/engines/claude`,
    TATWO2_OS_SOCKET:`${root}/o.sock`,TATWO2_BROWSER_SOCKET:`${root}/b.sock`,TATWO2_OS_ROOT:`${root}/os`,TATWO2_DOCS_ROOT:`${root}/docs`,
    TATWO2_OS_UPSTREAM_PATH:`${root}/os/os-upstream.md`,TATWO2_SKILLET_PATH:`${root}/os/skillet.md`,
    TATWO2_SELFTEST:'w230pets',TATWO2_SELFTEST_ARTIFACTS:`${root}/artifacts`,TATWO2_SELFTEST_NODE:process.execPath};
  const run=spawnSync(binary,[],{env,encoding:'utf8',timeout:110000,maxBuffer:8*1024*1024});
  const output=(run.stdout??'')+(run.stderr??''); writeFileSync(`${root}/result.log`,output);
  console.log(`W230 native evidence: ${root}`);
  assert.equal(run.status,0,output||String(run.error));
  assert.match(output,/W230PETS SUMMARY failures=0 passed=[1-9]\d*/);
  for(let n=1;n<=9;n++) assert.match(output,new RegExp(`^W230PETS PASS ${n}(?:/| )`, 'm'));
});
