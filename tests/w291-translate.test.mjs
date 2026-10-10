import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import {spawn, spawnSync} from 'node:child_process';
import {testScratch} from './helpers/test-scratch.mjs';

const root = path.resolve(new URL('..', import.meta.url).pathname);
const source = 'App/Sources/Tatwo2/Browser/BrowserPageTranslation.swift';
const bridge = 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm';
const scratch = testScratch('w291-translate-');
const page = fs.readFileSync(path.join(root, 'tests/fixtures/w291-page.html'));
const env = {...process.env, HOME:path.join(scratch,'home'), CFFIXED_USER_HOME:path.join(scratch,'home'),
  TMPDIR:scratch, CLANG_MODULE_CACHE_PATH:path.join(scratch,'modules')};
fs.mkdirSync(env.HOME);
const run = (cmd,args) => new Promise((resolve,reject)=>{
  const child=spawn(cmd,args,{cwd:root,env}); let output='';
  child.stdout.on('data',b=>output+=b); child.stderr.on('data',b=>output+=b);
  child.on('error',reject); child.on('exit',code=>resolve({code,output}));
});
const read = (p, baseline) => baseline ? spawnSync('git',['show',`2f34610e:${p}`],{cwd:root,encoding:'utf8'}).stdout : fs.readFileSync(path.join(root,p),'utf8');

async function fixture(baseline) {
  const mode=baseline?'baseline':'fixed';
  const server=http.createServer((req,res)=>{res.writeHead(200,{'Content-Type':'text/html'});res.end(page)});
  await new Promise(r=>server.listen(0,'127.0.0.1',r));
  try {
    let swift=read(source,baseline).split('/// 掛在網頁上：')[0];
    if (baseline) swift=swift.replace('func run(_ session: TranslationSession)','func run(_ session: FakeProvider)');
    const launch=baseline?'await translator.run(provider)':`await translator.run(prepare: { try await provider.prepareTranslation() }, translate: { items in
      let requests = items.map { TranslationSession.Request(sourceText: $0[1] as! String, clientIdentifier: String($0[0] as! Int)) }
      return try await provider.translations(from: requests).map { [Int($0.clientIdentifier!)!, $0.targetText] as [Any] }
    })`;
    swift+=`\n@MainActor func launch(_ translator: BrowserPageTranslator, _ provider: FakeProvider) -> Task<Void,Never> {
      Task { try? await wait { if case .translating = translator.phase { return true }; return false }; ${launch} }
    }\n`;
    const input=path.join(scratch,mode+'.swift'), binary=path.join(scratch,mode);
    fs.writeFileSync(input,swift);
    const script=read(bridge,baseline).match(/const char kBrowserTranslateScript\[\] = R"JS\(([\s\S]*?)\)JS";/)[1];
    const js=path.join(scratch,mode+'.js'); fs.writeFileSync(js,script);
    const helper=path.join(scratch,mode+"-fixture.swift");
    fs.copyFileSync(path.join(root,"tests/helpers/w291-translation.swift"),helper);
    const compiled=await run('/usr/bin/swiftc',['-swift-version','5','-parse-as-library',input,
      helper,'-o',binary]);
    assert.equal(compiled.code,0,compiled.output);
    const shots=path.join(scratch,mode+"-shots"); fs.mkdirSync(shots);
    const output=await run(binary,[`http://127.0.0.1:${server.address().port}`,js,
      shots,mode]);
    fs.writeFileSync(path.join(scratch,mode+'.log'),output.output);
    console.log(output.output);
    console.log(`W291 evidence ${scratch}/${mode}.log`);
    assert.equal(output.code,0,output.output);
    assert.match(output.output, baseline ? /BASELINE SUMMARY 4 reproduced 0 unexpected failures/ : /SUMMARY \d+ pass 0 fail/);
  } finally { await new Promise(r=>server.close(r)); }
}

test('W291 baseline: second press, source detection, equal configuration and stale restore reproduced on local long page', {timeout:120000}, ()=>fixture(true));
test('W291 production Swift + renderer: repeats, restore, navigation, cancellation, dynamic content and installed Apple smoke', {timeout:180000}, ()=>fixture(false));
