import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {spawnSync} from 'node:child_process';
import {testScratch} from './helpers/test-scratch.mjs';
const bridge = fs.readFileSync(new URL('../Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm', import.meta.url), 'utf8');
const script = bridge.match(/const char kBrowserActivityScript\[\] = R"JS\(([\s\S]*?)\)JS";/)[1];
function fixture(enabled) {
  let now = 0, io, mutation, po, report;
  const emitted=[], events=new Map();
  const images=[];
  const root={nodeType:1,querySelectorAll:()=>images};
  for (const key of ['src','currentSrc','textContent','innerHTML','title','baseURI','username']) {
    Object.defineProperty(root,key,{get(){throw Error('privacy read '+key);}});
  }
  class Image {
    constructor() { Object.assign(this,{nodeType:1,tagName:'IMG',isConnected:true,naturalWidth:100,complete:false}); }
    decode(){return {then: done=>{this.done=done;}};}
    querySelectorAll(){return [];}
    closest(){return this.article;}
  }
  for (const key of ['src','currentSrc','textContent','innerHTML','title','baseURI','username'])
    Object.defineProperty(Image.prototype,key,{get(){throw Error('privacy read '+key);}});
  class PO { static supportedEntryTypes=['long-animation-frame']; constructor(fn){po=fn;} observe(opts){assert.equal(opts.type,'long-animation-frame');} }
  class IO { constructor(fn){io=fn;this.targets=new Set();this.observed=[];fixture.io=this;} observe(n){this.targets.add(n);this.observed.push(n);} unobserve(n){this.targets.delete(n);} }
  class MO { constructor(fn){mutation=fn;} observe(){ } }
  const factory=vm.runInNewContext(script,{
    WeakRef,performance:{now:()=>now},PerformanceObserver:PO,IntersectionObserver:IO,MutationObserver:MO,
    location:new Proxy({host:'fixture.invalid'},{get:(v,k)=>{assert.equal(k,'host');return v[k];}}),
    document:{documentElement:root,getElementsByTagName:()=>[],querySelectorAll:()=>[],
      addEventListener:(n,f)=>events.set(n,f),
      evaluate(expression, article, resolver, type){
        assert.equal(type,9); assert.match(expression,/text\(\)="Ad"/);
        return {singleNodeValue:['Ad','推廣','Promoted'].includes(article.badge) ? {} : null};
      }},
    setInterval:(fn,ms)=>{assert.equal(ms,1000);},
  });
  report=(...args)=>emitted.push(args);
  assert.equal(factory(report,enabled),true);
  return {Image,emitted,events,add(img,time){images.push(img);mutation([{addedNodes:[img],removedNodes:[]}]);io([{target:img,isIntersecting:true,time}]);},
    attribute(target){mutation([{type:'attributes',target,addedNodes:[],removedNodes:[]}]);},
    remove(img){img.isConnected=false;mutation([{addedNodes:[],removedNodes:[img]}]);},
    at:t=>now=t,po:list=>po({getEntries:()=>list}),poll:()=>report.diag?.(),hasObserver:()=>!!mutation};
}
test('W289 opt-in observers measure numeric 5-second deltas and drain without reading private content',()=>{
  const f=fixture(true), a=new f.Image(),b=new f.Image();
  f.add(a,10);f.at(40);a.done();f.add(b,50);f.at(100);b.done();
  f.po([{duration:70},{duration:80}]);
  f.events.get('waiting')({target:{tagName:'VIDEO'}});f.events.get('stalled')({target:{tagName:'VIDEO'}});
  f.poll();const metrics=f.emitted.at(-1)[0];
  assert.deepEqual({...metrics},{kind:'tatwo.xdiag',loafCount:2,loafMs:150,imageCount:2,imageMedianMs:40,imageMaxMs:50,adImageCount:0,adImageMedianMs:null,adImageMaxMs:null,postImageCount:2,postImageMedianMs:40,postImageMaxMs:50,videoWaiting:1,videoStalled:1,sampleID:0});
  assert.doesNotMatch(JSON.stringify(metrics),/https?:|PRIVATE|username|textContent|currentSrc/);
  f.poll();assert.equal(f.emitted.at(-1)[0].imageMedianMs,null);assert.equal(f.emitted.at(-1)[0].loafCount,0);
  const c=new f.Image();f.add(c,110);f.remove(c);f.at(160);c.done();f.poll();assert.equal(f.emitted.at(-1)[0].imageCount,0);
  assert.equal(fixture.io.targets.has(c),false,'removed images are unobserved');
  const video={nodeType:1,tagName:'VIDEO'};f.attribute(video);assert.equal(fixture.io.targets.has(video),false,'video source changes cannot enter image decoding');
});
test('W289 disabled activity has no diagnostic observers; native sampler allocation and all CDP calls are opt-in',()=>{
  const f=fixture(false);assert.equal(f.hasObserver(),false);assert.equal(f.poll(),undefined);
  assert.match(bridge,/if \(XDiagEnabled\(\) && source_process == PID_RENDERER/);
  assert.match(bridge,/if \(!\(XDiagNoInject\(\) && XDiagHost\(frame\)\) && context->Eval/);
  const native=bridge.slice(bridge.indexOf('class W289Diag'),bridge.indexOf('bool TatwoClient::OnProcessMessageReceived'));
  assert.match(native,/if \(!Eligible\(view\)\)/);assert.match(native,/navigation_generation == generation/);
  assert.match(native,/proc_pid_rusage/);assert.match(native,/proc_listchildpids/);
  assert.match(native,/"Performance.enable"/);assert.match(native,/"Performance.getMetrics"/);assert.match(native,/"Memory.getDOMCounters"/);
  assert.doesNotMatch(native,/Runtime\.evaluate|Network\.|DOMSnapshot|currentSrc|textContent/);
});
test('W289 per-minute summary keeps document baselines distinct, sums counters and preserves nulls',()=>{
  const scratch=testScratch('w289-summary-'),file=scratch+'/sample.log';
  fs.writeFileSync(file,['phase=unrelated url=fixture-secret',
    'phase=x_diag monoMs=1000 browserID=1 generation=1 JSHeapUsedSize=100 LayoutCount=null loafCount=1 imageMedianMs=20 imageMaxMs=30 adImageCount=2 adImageMedianMs=5 adImageMaxMs=10 postImageCount=3 postImageMedianMs=100 postImageMaxMs=200',
    'phase=x_diag monoMs=6000 browserID=1 generation=1 JSHeapUsedSize=200 LayoutCount=3 loafCount=2 imageMedianMs=40 imageMaxMs=50 adImageCount=1 adImageMedianMs=15 adImageMaxMs=20 postImageCount=2 postImageMedianMs=300 postImageMaxMs=400',
    'phase=x_diag monoMs=62000 browserID=1 generation=1 JSHeapUsedSize=300 LayoutCount=4',
    'phase=x_diag monoMs=63000 browserID=1 generation=2 LayoutCount=null'].join('\n'));
  const result=spawnSync('python3',['scripts/x-diag-summary.py',file],{encoding:'utf8'});
  assert.equal(result.status,0,result.stderr);assert.doesNotMatch(result.stdout,/secret|url=|sample.log/);
  const lines=result.stdout.trim().split('\n'),headers=lines[0].split('|').map(s=>s.trim());
  assert.equal(lines.length,5);const values=lines[2].split('|').map(s=>s.trim());
  assert.equal(values[headers.indexOf('JSHeapUsedSize')],'150.000');assert.equal(values[headers.indexOf('LayoutCount')],'3.000');
  assert.equal(values[headers.indexOf('loafCount')],'3.000');assert.equal(values[headers.indexOf('imageMedianMs')],'30.000');
  assert.equal(values[headers.indexOf('imageMaxMs')],'50.000');assert.equal(values[headers.indexOf('gpuCPUSeconds')],'-');
  for (const [field,value] of [['adImageCount','3.000'],['adImageMedianMs','10.000'],['adImageMaxMs','20.000'],['postImageCount','5.000'],['postImageMedianMs','200.000'],['postImageMaxMs','400.000']])
    assert.equal(values[headers.indexOf(field)],value,field);
});

test('W308 ad badges and ordinary posts keep separate medians, maxima and resets',()=>{
  const f=fixture(true);
  for (const [badge,delay] of [['Ad',0],['推廣',20],['Promoted',10],['ordinary',100],['ordinary',400]]) {
    const img=new f.Image(); img.article={badge}; f.add(img,1000); f.at(1000+delay); img.done();
  }
  f.poll(); const m=f.emitted.at(-1)[0];
  assert.deepEqual([m.adImageCount,m.adImageMedianMs,m.adImageMaxMs],[3,10,20]);
  assert.deepEqual([m.postImageCount,m.postImageMedianMs,m.postImageMaxMs],[2,250,400]);
  f.poll(); const empty=f.emitted.at(-1)[0];
  assert.deepEqual([empty.adImageCount,empty.adImageMedianMs,empty.postImageMaxMs],[0,null,null]);
  assert.match(bridge,/args->GetSize\(\) != 15/);
  assert.match(bridge,/args->GetDouble\(14\)/);
});

test('W308 exact badge XPath rejects matching tweet text and user names',()=>{
  const expression=script.match(/document.evaluate\('([^']+)'/)[1];
  for (const [xml,count] of [
    ['<article><div><span>Ad</span></div></article>',1],
    ['<article><span>推廣</span></article>',1],
    ['<article><span>Promoted</span></article>',1],
    ['<article><span>Added</span></article>',0],
    ['<article><div data-testid="tweetText"><span>Ad</span></div></article>',0],
    ['<article><div data-testid="User-Name"><span>Promoted</span></div></article>',0],
  ]) {
    const result=spawnSync('/usr/bin/xmllint',['--xpath',`count(${expression})`,'-'],{input:xml,encoding:'utf8'});
    assert.equal(result.status,0,result.stderr); assert.equal(Number(result.stdout),count,xml);
  }
});
