import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const read = path => readFileSync(new URL('../' + path, import.meta.url), 'utf8');
const native = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
const source = native.match(/kTatwoTypeIntoNode\[\] = R"TATWOJS\(([\s\S]*?)\)TATWOJS";/)[1];
const attributes = Object.fromEntries([...read('Engines/chatgpt-hands/gateway.mjs')
  .match(/<input id="code"[^>]+>/)[0].matchAll(/(\w+)="([^"]*)"/g)].map(m => [m[1], m[2]]));

function fixture(overrides = {}) {
  const document = {}, expectedURL = 'https://fixture.invalid/authorize?synthetic=1';
  const window = {}; window.top = window;
  const location = { href: expectedURL };
  let reads = 0, submitted = 0;
  class Node {
    get isConnected() { return this.connected !== false; }
    get ownerDocument() { return this.foreignDocument ?? document; }
  }
  class Form extends Node {
    constructor() { super(); this.destination = expectedURL; this.verb = 'post'; this.frame = ''; this.encoding = 'application/x-www-form-urlencoded'; }
    get action() { return this.destination; }
    get method() { return this.verb; }
    get target() { return this.frame; }
    get enctype() { return this.encoding; }
    requestSubmit() { submitted++; this.onSubmit?.(); }
  }
  class Input extends Node {
    constructor() {
      super(); Object.assign(this, attributes, { tagName: 'INPUT', type: 'text', maxLength: Number(attributes.maxlength),
        form: new Form(), events: [], _value: '', required: true });
    }
    set value(text) { this._value = text.slice(0, this.maxLength); }
    get value() { reads++; return this._value; }
    getAttribute() { return null; }
    focus() { this.onFocus?.(); }
    dispatchEvent(event) { this.events.push(event.type); this.onEvent?.(event); return true; }
  }
  const fn = vm.runInNewContext('(' + source + ')', { document, window, location, Node,
    HTMLFormElement: Form, HTMLElement: Input, HTMLInputElement: Input, HTMLTextAreaElement: Input,
    EventTarget: Input, Event: class { constructor(type) { this.type = type; } } });
  const field = Object.assign(new Input(), overrides);
  return { field, fn, document, window, location, expectedURL, reads: () => reads, submitted: () => submitted,
    type(pairing = true, text = '23456789', url = expectedURL) { return fn.call(field, text, true, url, pairing); } };
}

test('W330 exact native function fills gateway-shaped field, reads only length and requestSubmits once', () => {
  const f = fixture();
  assert.equal(f.type(), true);
  assert.equal(f.field._value.length, 8);
  assert.deepEqual(f.field.events, ['input', 'change']);
  assert.equal(f.submitted(), 1);
  assert.equal(f.reads(), 2);
  assert.match(source, /const length = \(\) => Object\.getOwnPropertyDescriptor\(proto, 'value'\)\.get\.call\(el\)\.length/);
});

test('W330 generic typeText still refuses identical one-time-code field with no value reads', () => {
  const f = fixture(); assert.equal(f.type(false), false);
  assert.equal(f.field._value.length, 0); assert.equal(f.submitted(), 0); assert.equal(f.reads(), 0);
  assert.equal(f.fn.call(f.field, '23456789', true, f.expectedURL), false, 'omitted pairing argument defaults to false');
});

for (const override of [{ id: 'other' }, { ['name']: 'other' }, { autocomplete: 'off' }, { form: null },
  { maxLength: 8 }, { type: 'password' },
  { type: 'search' }, { tagName: 'TEXTAREA' },
  { disabled: true }, { readOnly: true }, { connected: false }, { foreignDocument: {} }]) {
  test('W330 pairing refuses ' + JSON.stringify(override), () => {
    const f = fixture(override); assert.equal(f.type(), false);
    assert.equal(f.field._value.length, 0); assert.equal(f.submitted(), 0); assert.equal(f.reads(), 0);
  });
}

test('W330 URL mismatch and non-top frame refuse before write', () => {
  for (const change of [f => { f.location.href += '#changed'; }, f => { f.window.top = {}; }]) {
    const f = fixture(); change(f); assert.equal(f.type(), false);
    assert.equal(f.field._value.length, 0); assert.equal(f.submitted(), 0);
  }
});

test('W330 mutation on focus/input/change preserves existing node and form checks', () => {
  for (const stage of ['onFocus', 'input', 'change']) {
    for (const mutate of [f => { f.field.id = 'other'; }, f => { f.field.maxLength = 8; },
      f => { f.field.form = new f.field.form.constructor(); },
      ...['destination', 'verb', 'frame', 'encoding'].map(key => f => { f.field.form[key] = 'changed'; }),
      f => { f.field.form.connected = false; }, f => { f.location.href += '#changed'; }]) {
      const f = fixture();
      if (stage === 'onFocus') f.field.onFocus = () => mutate(f);
      else f.field.onEvent = e => { if (e.type === stage) mutate(f); };
      assert.equal(f.type(), false); assert.equal(f.submitted(), 0);
    }
  }
});

test('W330 wrong value length after input/change refuses submit and reports false', () => {
  for (const event of ['input', 'change']) {
    const f = fixture(); f.field.onEvent = e => { if (e.type === event) f.field._value = ''; };
    assert.equal(f.type(), false); assert.equal(f.submitted(), 0);
  }
  for (const text of ['', '2345678', '234567892']) {
    const f = fixture(); assert.equal(f.type(true, text), false); assert.equal(f.submitted(), 0);
  }
  const f = fixture(); f.field.form.onSubmit = () => { f.field._value = ''; };
  assert.equal(f.type(), false); assert.equal(f.submitted(), 1, 'post-submit readback must still confirm length eight');
});

test('W330 native input stays structured data in isolated world and generic native API defaults false', () => {
  assert.match(native, /submit:submit pairing:NO dispatchGate:dispatchGate/);
  assert.match(native, /pairing \? NodeInputKind::pairingText : NodeInputKind::text/);
  assert.match(native, /pairing->SetBool\("value", type_kind_ == NodeInputKind::pairingText\)/);
  assert.match(native, /params->SetInt\("executionContextId", static_cast<int>\(context_id\)\)/);
  const pod = read('App/Sources/Tatwo2/TAP/ChatGPTConnectorPod.swift');
  const fill = pod.slice(pod.indexOf('    func fillPairingCode('), pod.indexOf('    /// 綁住的那一個畫面'));
  assert.match(fill, /elementID: form.elementID, navigationGeneration: generation, submit: true, pairing: true/);
  assert.match(fill, /\.failed\("type:" \+ typed\)/);
  assert.doesNotMatch(fill, /sendAgentKey|let submit =|sendClick\(at: submit|connectLog[^\n]*code/);
  assert.doesNotMatch(read('App/Sources/Tatwo2/Facade/BrowserAgentBridge.swift'), /pairing: true/);
});
