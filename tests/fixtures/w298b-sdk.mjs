// Synthetic SDK transport; only isolated fake CLI binaries are admitted.
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
const bin = process.env.TATWO2_CLAUDE_BIN;
const fakeSDK = {
  async supportedModels() {
    if (!bin?.startsWith(process.env.TATWO_STAGING_ROOT + '/')) throw Error('outside isolated root');
    if (!readFileSync(bin, 'utf8').includes('sdk=yes')) throw Error('unsupported CLI combination');
    execFileSync(bin, ['--version'], {env: process.env, timeout: 1000});
    return [{model:'claude-fixture-2',displayName:'Claude Fixture 2',efforts:[],defaultEffort:'',speeds:[],defaultSpeed:'',images:false}];
  }
};
try {
  const models = await fakeSDK.supportedModels();
  console.log(JSON.stringify({ev:'sdk',msg:{type:'system',subtype:'model_catalog',engine:'claude',identity:process.env.TATWO2_ENGINE_IDENTITY,source:'fixture supportedModels()',models}}));
} catch (error) { console.log(JSON.stringify({ev:'error',message:error.message})); }
console.log(JSON.stringify({ev:'closed'}));
process.exit(0);
