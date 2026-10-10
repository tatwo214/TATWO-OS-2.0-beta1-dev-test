import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {execFileSync} from 'node:child_process';
const file='Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm';
const extract=s=>s.match(/const char kBrowserActivityScript\[\] = R"JS\(([\s\S]*?)\)JS";/)[1];
const before=extract(execFileSync('git',['show',`bbd34e2d:${file}`],{encoding:'utf8'}));
const after=extract(fs.readFileSync(file,'utf8'));
function page(source) {
  const nodes=[],events=new Map(),reports=[],observers=[];
  const counters={rect:0,media:0,scans:0,stateReads:0}; let tick;
  class Media {
    constructor(attached=true) { Object.assign(this,{tagName:'VIDEO',isConnected:attached,muted:true,volume:0,
      ended:false,videoWidth:640,videoHeight:360,listeners:new Map(),box:{width:320,height:180}}); this.stopped=true; }
    get paused(){ counters.stateReads++; return this.stopped; }
    set paused(v){this.stopped=v;}
    play(){this.paused=false;this.emit('play');this.emit('playing');return 'native-result';}
    pause(){this.paused=true;this.emit('pause');}
    getBoundingClientRect(){counters.rect++;return this.box;}
    addEventListener(n,fn){if(!this.listeners.has(n))this.listeners.set(n,new Set());this.listeners.get(n).add(fn);}
    emit(type,capture=this.isConnected){const e={type,target:this};if(capture)events.get(type)?.(e);for(const fn of this.listeners.get(type)??[])fn(e);}
  }
  for(const key of ['src','currentSrc','textContent','innerHTML'])
    Object.defineProperty(Media.prototype,key,{get(){throw Error(`private read ${key}`);}});
  class IO {
    constructor(fn){this.fn=fn;this.targets=new Set();observers.push(this);}
    observe(n){this.targets.add(n);} unobserve(n){this.targets.delete(n);}
    deliver(){this.fn([...this.targets].map(target=>({target,isIntersecting:target.isConnected,boundingClientRect:target.box})));}
  }
  const install=vm.runInNewContext(source.replace('const media = event => {','const media = event => { probe();'),{
    probe:()=>counters.media++,HTMLMediaElement:Media,IntersectionObserver:IO,
    location:{host:'fixture.invalid'},document:{
      getElementsByTagName:tag=>({get length(){return nodes.filter(n=>n.tagName.toLowerCase()===tag).length;},[Symbol.iterator]:function*(){yield* nodes.filter(n=>n.tagName.toLowerCase()===tag);}}),
      querySelectorAll:()=>{counters.scans++;return nodes;},createElement:()=>({canPlayType:()=> 'probably'}),
      addEventListener:(n,fn)=>events.set(n,fn)},setInterval:fn=>{tick=fn;},
  });
  install((...args)=>reports.push(args));
  return {Media,nodes,counters,reports,events,tick:()=>tick(),intersect:()=>observers.forEach(o=>o.deliver()),
    reset(){for(const k of Object.keys(counters))counters[k]=0;}};
}
test('W308 30 autoplay videos plus 30000 scroll events eliminate synchronous geometry and reduce media work by over 40 percent',t=>{
  const measured=[];
  for(const source of [before,after]) {
    const f=page(source);
    for(let i=0;i<30;i++){const n=new f.Media();f.nodes.push(n);n.play();}
    f.tick();f.intersect();f.reset();
    for(let round=0;round<100;round++) {
      for(let i=0;i<300;i++)f.events.get('scroll')?.({type:'scroll',target:{}});
      for(const n of f.nodes){n.pause();n.play();n.emit('loadstart');n.emit('loadedmetadata');}
      f.tick();
    }
    measured.push({...f.counters});
    assert.deepEqual(f.reports.at(-1),[false,true,false,true]);
  }
  const [old,next]=measured;
  assert.equal(next.rect,0);assert.ok(old.rect>10000);
  assert.ok(next.media<=old.media*0.6,JSON.stringify(measured));
  assert.equal(next.scans,0,'live collections avoid document queries even on periodic ticks');
  assert.ok(next.stateReads<old.stateReads*0.6);
  t.diagnostic(`bbd34e2d -> W308: ${JSON.stringify(measured)}`);
});
test('W308 visibility, simultaneous playback, detached native play and media errors update only the target',()=>{
  const f=page(after),a=new f.Media(),b=new f.Media();f.nodes.push(a,b);
  a.play();b.play();f.intersect();f.reset();a.pause();
  assert.equal(f.counters.media,1);assert.equal(f.counters.scans,0);
  assert.deepEqual(f.reports.at(-1),[false,true,false,true]);
  b.isConnected=false;f.tick();assert.equal(f.reports.at(-1)[3],false,'removed video keeps playback but loses its picture');
  b.isConnected=true;f.tick();f.intersect();assert.equal(f.reports.at(-1)[3],true);
  b.box={width:0,height:0};f.intersect();assert.equal(f.reports.at(-1)[3],false);
  b.pause();assert.equal(f.reports.at(-1)[1],false);
  const offline=new f.Media(false);offline.tagName='AUDIO';offline.muted=false;offline.volume=1;
  assert.equal(offline.play(),'native-result');assert.deepEqual(f.reports.at(-1),[false,true,true,false]);
  offline.pause();assert.deepEqual(f.reports.at(-1),[false,false,false,false]);
  offline.tagName='VIDEO';offline.error={code:4};offline.emit('error');
  assert.deepEqual({...f.reports.at(-1)[0]},{kind:'tatwo.media.codec_unsupported',host:'fixture.invalid'});
});

test('W308 connected shadow media without document capture still updates once',()=>{
  const f=page(after),item=new f.Media();item.tagName='AUDIO';item.muted=false;item.volume=1;
  item.play();f.reset();item.paused=true;item.emit('pause',false);
  assert.deepEqual(f.reports.at(-1),[false,false,false,false]);
  assert.equal(f.counters.media,1);assert.equal(f.counters.scans,0);
  item.paused=false;item.emit('playing',false);
  assert.deepEqual(f.reports.at(-1),[false,true,true,false]);
});
