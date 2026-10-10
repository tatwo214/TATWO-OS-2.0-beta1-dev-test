import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { execFileSync } from 'node:child_process';
import { performance } from 'node:perf_hooks';

const root = new URL('../', import.meta.url);
const file = 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm';
const extract = source => source.match(/const char kBrowserActivityScript\[\] = R"JS\(([\s\S]*?)\)JS";/)[1];
const current = extract(fs.readFileSync(new URL(file, root), 'utf8'));
const baseline = extract(execFileSync('git', ['show', `f737a9d7:${file}`], { cwd: root, encoding: 'utf8' }));

function frame(script = current) {
  const nodes = [], reports = [], events = new Map(), refs = [], streams = new WeakMap();
  let now = 0, tick, scans = 0, derefs = 0;
  class Media {
    constructor(fields = {}) {
      Object.assign(this, { tagName: 'AUDIO', paused: true, ended: false, muted: false, volume: 1,
        isConnected: false, videoWidth: 640, videoHeight: 360, listeners: new Map(), box: { width: 320, height: 180 } }, fields);
    }
    play() { this.paused = false; return this.result; }
    get srcObject() { return streams.get(this); }
    set srcObject(value) { streams.set(this, value); }
    getBoundingClientRect() { return this.box; }
    addEventListener(name, callback) {
      if (!this.listeners.has(name)) this.listeners.set(name, new Set());
      this.listeners.get(name).add(callback);
    }
    emit(name) { for (const callback of this.listeners.get(name) ?? []) callback({ type: name, target: this }); }
  }
  const nativeStreamProperty = Object.getOwnPropertyDescriptor(Media.prototype, 'srcObject');
  for (const key of ['src', 'currentSrc', 'textContent', 'innerHTML', 'title', 'baseURI']) {
    Object.defineProperty(Media.prototype, key, { get() { throw Error(`must not read ${key}`); } });
  }
  const observers = [];
  const knownSets = [];
  class CountingSet extends Set { constructor(...args) { super(...args); knownSets.push(this); } }
  class Ref {
    constructor(element) { this.element = element; refs.push(this); }
    deref() { derefs++; return this.element; }
  }
  const install = vm.runInNewContext(script, {
    HTMLMediaElement: Media, WeakRef: Ref, Set: CountingSet, Date: { now: () => now },
    IntersectionObserver: class {
      constructor(callback) { this.callback = callback; }
      observe(item) { if (!observers.some(([,target]) => target === item)) observers.push([this.callback, item]); }
      unobserve(item) { const i = observers.findIndex(([,target]) => target === item); if (i >= 0) observers.splice(i, 1); }
    },
    location: new Proxy({ host: 'fixture.invalid' }, { get(target, key) { assert.equal(key, 'host'); return target[key]; } }),
    document: {
      getElementsByTagName: tag => ({ get length() { return nodes.filter(item => item.tagName === tag.toUpperCase()).length; },
        [Symbol.iterator]: function* () { yield* nodes.filter(item => item.tagName === tag.toUpperCase()); } }),
      querySelectorAll(selector) { assert.equal(selector, 'audio,video'); scans++; return nodes; },
      createElement(tag) { assert.equal(tag, 'video'); return { canPlayType: () => 'probably' }; },
      addEventListener: (name, callback) => events.set(name, callback),
    },
    setInterval(callback, delay) { assert.equal(delay, 1000); tick = callback; },
  });
  assert.equal(install((...args) => reports.push(args)), true);
  assert.deepEqual(Object.getOwnPropertyDescriptor(Media.prototype, 'srcObject'), nativeStreamProperty,
    'the native srcObject accessor must remain unchanged');
  return {
    Media, nodes, refs, reports, events, known: knownSets[0],
    tick() { tick(); for (const [fn, item] of observers) fn([{target:item,isIntersecting:item.isConnected && item.box.width > 0,boundingClientRect:item.box}]); return reports.filter(args => args.length === 4).at(-1)?.slice(1); },
    remember(item) { events.get('play')({ type: 'play', target: item }); },
    advance(value) { now += value; },
    counters() { return { scans, derefs }; },
  };
}

function liveStream() {
  const listeners = new Map();
  const track = { readyState: 'live', addEventListener: (name, callback) => listeners.set(name, callback),
    get label() { throw Error('must not inspect stream identity'); } };
  return { getTracks: () => [track], end() { track.readyState = 'ended'; listeners.get('ended')?.(); } };
}

test('six identical inputs preserve baseline playing / audible / video, including detached media and streams', t => {
  const cases = [
    ['empty', {}, false, [false, false, false]],
    ['audible audio', { paused: false }, true, [true, true, false]],
    ['muted visible video', { tagName: 'VIDEO', paused: false, muted: true }, true, [true, false, true]],
    ['hidden video', { tagName: 'VIDEO', paused: false, box: { width: 0, height: 0 } }, true, [true, true, false]],
    ['detached Spotify audio', { paused: false }, false, [true, true, false]],
    ['detached paused live srcObject', { paused: true, stream: true }, false, [true, false, false]],
  ];
  for (const [name, fields, attached, expected] of cases) {
    const results = [baseline, current].map(script => {
      const f = frame(script);
      if (name !== 'empty') {
        const item = new f.Media({ ...fields, isConnected: attached });
        if (fields.stream) item.srcObject = liveStream();
        if (attached) f.nodes.push(item);
        f.remember(item);
      }
      f.tick(); f.advance(61000);
      return f.tick();
    });
    assert.deepEqual(results[0], expected, `${name}: baseline`);
    assert.deepEqual(results[1], results[0], `${name}: current`);
    t.diagnostic(`${name}: ${results[0].join('/')} = ${results[1].join('/')}`);
  }
});

test('living detached media remain tracked; collected refs leave the set and listeners stay unique', () => {
  for (const script of [baseline, current]) {
    const f = frame(script), item = new f.Media();
    f.remember(item); f.advance(60000); f.tick();
    assert.equal(f.known.size, 1);
    const stream = liveStream();
    item.srcObject = stream;
    assert.deepEqual(f.tick(), [true, false, false]);
    stream.end();
    assert.deepEqual(f.tick(), [false, false, false]);
    f.advance(60000); f.tick();
    item.result = Promise.resolve('native result');
    assert.equal(item.play(), item.result);
    assert.deepEqual(f.tick(), [true, true, false]);
    item.paused = true; item.emit('pause'); f.advance(60000); f.tick();
    item.paused = false; item.emit('playing');
    assert.deepEqual(f.tick(), [true, true, false]);
    for (const callbacks of item.listeners.values()) assert.equal(callbacks.size, 1);
    f.refs[0].element = undefined; f.tick();
    assert.equal(f.known.size, 0);
  }
  for (const script of [baseline, current]) {
    const f = frame(script), item = new f.Media(), tracks = [];
    item.srcObject = { getTracks: () => tracks };
    f.remember(item); f.advance(60000); f.tick();
    tracks.push(...liveStream().getTracks());
    assert.deepEqual(f.tick(), [true, false, false], 'an existing empty stream can acquire live tracks');
    item.srcObject = null; item.paused = false; item.ended = true;
    f.tick(); f.advance(60000); f.tick();
    item.ended = false;
    assert.deepEqual(f.tick(), [true, true, false], 'seeking away from the end can resume an unpaused element');
  }
});

test('empty-document ticks skip DOM queries; inserting and removing media updates all flags and codec errors still publish', () => {
  const f = frame();
  assert.deepEqual(f.tick(), [false, false, false]);
  for (let i = 0; i < 1000; i++) f.tick();
  assert.deepEqual(f.counters(), { scans: 0, derefs: 0 });
  assert.equal(f.reports.length, 1);
  const item = new f.Media({ tagName: 'VIDEO', paused: false, isConnected: true });
  f.nodes.push(item);
  assert.deepEqual(f.tick(), [true, true, true]);
  item.volume = 0;
  assert.deepEqual(f.tick(), [true, false, true]);
  item.videoWidth = 0;
  assert.deepEqual(f.tick(), [true, false, false]);
  item.ended = true;
  assert.deepEqual(f.tick(), [false, false, false]);
  f.nodes.length = 0; f.tick();
  const counters = f.counters(); f.tick();
  assert.equal(f.counters().scans, counters.scans);
  assert.equal(f.counters().derefs, counters.derefs + 1, 'living removed media stays tracked for Spotify');
  f.events.get('error')({ type: 'error', target: new f.Media({ tagName: 'VIDEO', error: { code: 4 } }) });
  assert.deepEqual({ ...f.reports.at(-1)[0] }, { kind: 'tatwo.media.codec_unsupported', host: 'fixture.invalid' });
});

test('2000 recorded media, 1500 detached: median tick < 2 ms with all living records retained', t => {
  const medians = [];
  for (const script of [baseline, current]) {
    const f = frame(script);
    for (let i = 0; i < 2000; i++) {
      const item = new f.Media({ isConnected: i < 500 });
      if (item.isConnected) f.nodes.push(item);
      f.remember(item);
    }
    assert.equal(f.known.size, 2000);
    for (let i = 0; i < 20; i++) f.tick();
    const samples = [];
    for (let i = 0; i < 101; i++) {
      const start = performance.now(); f.tick(); samples.push(performance.now() - start);
    }
    const median = samples.sort((a, b) => a - b)[50];
    medians.push(median);
    assert.deepEqual(f.tick(), [false, false, false]);
    f.advance(60000); f.tick();
    assert.equal(f.known.size, 2000);
    if (script === current) {
      assert.ok(median < 2, `median ${median.toFixed(3)} ms`);
      const before = f.counters().derefs; f.tick();
      assert.equal(f.counters().derefs - before, 2000, 'all living media remain in the periodic work');
    }
  }
  t.diagnostic(`2000 records (1500 detached), median of 101 ticks: baseline ${medians[0].toFixed(3)} ms; current ${medians[1].toFixed(3)} ms`);
});
