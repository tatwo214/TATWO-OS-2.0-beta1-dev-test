import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
const read = p => readFileSync(new URL('../' + p, import.meta.url), 'utf8');
test('M10 actual Codex and SDK capabilities preserve new models, native effort and speed', async () => {
  const {codexModels, claudeModels} = await import('../Engines/model-capabilities.mjs');
  assert.deepEqual(codexModels([{model:'sample-model', displayName:'Sample engine name', supportedReasoningEfforts:[{reasoningEffort:'low'},{reasoningEffort:'ultra'}], defaultReasoningEffort:'low', serviceTiers:[{id:'priority'},{id:'default'}],defaultServiceTier:'priority',inputModalities:['image']}]), [{model:'sample-model',displayName:'Sample engine name',efforts:['low','ultra'],defaultEffort:'low',speeds:['fast','standard'],defaultSpeed:'fast',images:true}]);
  assert.deepEqual(claudeModels([{value:'sample-claude',displayName:'SDK sample',supportedEffortLevels:['medium','max'],supportsFastMode:true}]), [{model:'sample-claude',displayName:'SDK sample',efforts:['medium','max'],defaultEffort:'medium',speeds:['fast','standard'],defaultSpeed:'standard',images:true}]);
});
test('M10 catalog is queried from actual runtimes and transported from remote host', () => {
  assert.match(read('Engines/codex-sidecar/sidecar.mjs'), /request\(['"]model\/list/);
  assert.match(read('Engines/claude-sidecar/sidecar.mjs'), /q\.supportedModels\(/);
  for (const f of ['App/Sources/Tatwo2/Facade/OSAgentBridge.swift','App/Sources/Tatwo2/Facade/RemoteLiveEngine.swift']) assert.match(read(f), /engineModelCatalogs/);
  assert.match(read('App/Sources/Tatwo2/Chat/ChatPageModels.swift'), /EngineModelCatalog/);
  assert.match(read('App/Sources/Tatwo2/Facade/ChatPageModel.swift'), /EngineModelCatalogProbe/);
});

import { spawn } from 'node:child_process';
import { once } from 'node:events';
import fs from 'node:fs/promises';
import path from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';
async function catalogEvents(script, binary, root) {
  const home = path.join(root,'home');
  await fs.mkdir(home, {recursive:true});
  const child = spawn(process.execPath,[script,'--cwd',root,'--catalog-only'], {env:{
    PATH:path.dirname(process.execPath)+':/usr/bin:/bin', HOME:home,
    CODEX_HOME:home, TATWO2_CODEX_SOURCE_HOME:home,
    CLAUDE_CONFIG_DIR:home, CLAUDE_SECURESTORAGE_CONFIG_DIR:home,
    TATWO2_CODEX_BIN:binary, TATWO2_CLAUDE_BIN:binary, TATWO2_ENGINE_IDENTITY:'fixture-runtime|0.160.0',
  },stdio:['pipe','pipe','pipe']});
  let output='',error='';
  child.stdout.on('data',data=>output+=data);
  child.stderr.on('data',data=>error+=data);
  let timer;
  try {
    await Promise.race([once(child,'exit'),new Promise((_,reject)=>timer=setTimeout(()=>reject(new Error(`catalog timeout: ${error}\n${output}`)),15000))]);
    const events=output.trim().split('\n').filter(Boolean).map(JSON.parse);
    const catalog=events.find(e=>e.ev==='sdk' && e.msg?.subtype==='model_catalog')?.msg;
    assert.ok(catalog, `catalog absent: ${error}\n${output}`);
    assert.ok(!events.some(e=>e.msg?.subtype==='init'),'catalog probe created a chat thread');
    return catalog;
  } finally { clearTimeout(timer); child.kill('SIGKILL'); }
}
test('M10 Codex model/list pagination reaches the sidecar protocol without starting a thread', {timeout:20000}, async()=>{
  const root=await fs.mkdtemp(path.join(testScratch('w189-model-catalog-'),'fixture-'));
  const binary=path.join(root,'codex');
  const capture=path.join(root,'requests.jsonl');
  await fs.writeFile(binary,`#!${process.execPath}\nconst fs=require('node:fs');
if(process.argv.includes('--version')){console.log('codex-cli 0.160.0');process.exit(0)}
const rl=require('node:readline').createInterface({input:process.stdin});
rl.on('line',line=>{const r=JSON.parse(line);fs.appendFileSync(${JSON.stringify(capture)},line+'\\n');
if(r.method==='initialize') console.log(JSON.stringify({id:r.id,result:{}}));
if(r.method==='model/list') console.log(JSON.stringify({id:r.id,result:{data:[{model:r.params.cursor?'sample-model':'gpt-5.6-sol',displayName:'Fixture display',supportedReasoningEfforts:[{reasoningEffort:'low'},{reasoningEffort:'ultra'}],defaultReasoningEffort:'low',serviceTiers:[{id:'default'}],inputModalities:['image']}],nextCursor:r.params.cursor?null:'fixture-cursor'}}));
});rl.on('close',()=>process.exit(0));`,{mode:0o700});
  const catalog=await catalogEvents(fileURLToPath(new URL('../Engines/codex-sidecar/sidecar.mjs',import.meta.url)),binary,root);
  assert.equal(catalog.engine,'codex');
  assert.deepEqual(catalog.models.map(m=>m.model),['gpt-5.6-sol','sample-model']);
  assert.deepEqual(catalog.models[0].efforts,['low','ultra']);
  const requests=(await fs.readFile(capture,'utf8')).trim().split('\n').map(JSON.parse);
  assert.equal(requests.filter(r=>r.method==='model/list').length,2);
  assert.ok(!requests.some(r=>r.method==='thread/start'||r.method==='turn/start'));
});
test('M10 Claude supportedModels is read from the SDK used by the selected executable', {timeout:20000}, async()=>{
  const root=await fs.mkdtemp(path.join(testScratch('w189-sdk-catalog-'),'fixture-'));
  const dir=path.join(root,'claude-sidecar');
  const sdk=path.join(dir,'node_modules/@anthropic-ai/claude-agent-sdk');
  await fs.mkdir(sdk,{recursive:true});
  await fs.copyFile(new URL('../Engines/claude-sidecar/sidecar.mjs',import.meta.url),path.join(dir,'sidecar.mjs'));
  await fs.copyFile(new URL('../Engines/model-capabilities.mjs',import.meta.url),path.join(root,'model-capabilities.mjs'));
  await fs.writeFile(path.join(sdk,'package.json'),JSON.stringify({type:'module',exports:'./index.mjs'}));
  await fs.writeFile(path.join(sdk,'index.mjs'),`export function query({options}) {
    if(options.pathToClaudeCodeExecutable!=='/fixture/claude') throw new Error('incorrect executable');
    if(Object.keys(options.mcpServers).length || options.settingSources.length) throw new Error('probe mounts settings or MCPs');
    return {supportedModels:async()=>[{value:'sample-claude',displayName:'Fixture SDK display',supportedEffortLevels:['low','max'],supportsFastMode:true}],close(){},async *[Symbol.asyncIterator](){}};
  }`);
  const catalog=await catalogEvents(path.join(dir,'sidecar.mjs'),'/fixture/claude',root);
  assert.equal(catalog.engine,'claude');
  assert.equal(catalog.models[0].displayName,'Fixture SDK display');
  assert.deepEqual(catalog.models[0].efforts,['low','max']);
});
test('M3/M10 officially downloaded native Codex reports gpt-6.1-sol', {timeout:20000,skip:!process.env.W189_NATIVE_CODEX}, async()=>{
  const root=await fs.mkdtemp(path.join(testScratch('w189-native-catalog-'),'fixture-'));
  const catalog=await catalogEvents(fileURLToPath(new URL('../Engines/codex-sidecar/sidecar.mjs',import.meta.url)),process.env.W189_NATIVE_CODEX,root);
  const sol=catalog.models.find(m=>m.model==='gpt-6.1-sol');
  assert.ok(sol);
  assert.deepEqual(sol.efforts,['low','medium','high','xhigh','max','ultra']);
  await fs.writeFile(path.join(root,'native-model-catalog.json'),JSON.stringify(catalog,null,2));
});

test('M10 Claude native controls are bound to the sent turn through SDK flag settings',()=>{
  assert.match(read('Engines/claude-sidecar/sidecar.mjs'), /q\.applyFlagSettings/);
  assert.match(read('Engines/claude-sidecar/sidecar.mjs'), /effortLevel: cmd\.effort/);
  assert.match(read('Engines/claude-sidecar/sidecar.mjs'), /fastMode: cmd\.serviceTier/);
  assert.match(read('App/Sources/Tatwo2/Engine/ClaudeSidecar.swift'), /kind == \.codex \|\| kind == \.claude/);
});
