import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';
import {claudeModels} from '../Engines/model-capabilities.mjs';
const source=readFileSync(new URL('../Engines/claude-sidecar/sidecar.mjs',import.meta.url),'utf8');
function fixture(supportsControls=true) {
  const emitted=[],prompts=[],settings=[];
  let line;
  const context={q:supportsControls?{applyFlagSettings:async value=>settings.push(value)}:{},
    rl:{on:(name,handler)=>{if(name==='line')line=handler;}},pending:new Map(),
    emit:value=>emitted.push(value),push:value=>prompts.push({settingsCount:settings.length,value}),
    closed:false};
  vm.runInNewContext(source.slice(source.indexOf("rl.on('line'"),source.indexOf("rl.on('close'")),context);
  return {line,emitted,prompts,settings};
}
test('M10 Claude max and fast are applied before sending the prompt; standard clears fast',async()=>{
  const f=fixture();
  await f.line(JSON.stringify({op:'send',text:'fixture',uuid:'one',effort:'max',serviceTier:'priority'}));
  await f.line(JSON.stringify({op:'send',text:'sample',uuid:'two',effort:'low',serviceTier:'default'}));
  assert.deepEqual(JSON.parse(JSON.stringify(f.settings)),[{effortLevel:'max',fastMode:true},{effortLevel:'low',fastMode:false}]);
  assert.deepEqual(f.prompts.map(p=>p.settingsCount),[1,2]);
  assert.equal(f.prompts[0].value.message.content,'fixture');
  assert.equal(f.emitted.length,0);
});
test('M10 missing SDK control interface rejects the turn with an error',async()=>{
  const f=fixture(false);
  await f.line(JSON.stringify({op:'send',text:'fixture',effort:'max'}));
  assert.equal(f.prompts.length,0);
  assert.equal(f.emitted[0].ev,'error');
  assert.match(f.emitted[0].message,/SDK does not support/);
});
test('M4/M10 SDK aliases resolve to the canonical provider model reported by the running CLI',()=>{
  assert.equal(claudeModels([{value:'sonnet',resolvedModel:'claude-sonnet-5',displayName:'Fixture',supportedEffortLevels:['low','high','max']}])[0].model,'claude-sonnet-5');
  assert.equal(claudeModels([{value:'sample-model',supportedEffortLevels:['low','high','max']}])[0].defaultEffort,'high');
});
