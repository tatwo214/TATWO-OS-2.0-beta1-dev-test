import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

export const source = readFileSync(new URL('../App/Sources/Tatwo2/TAP/ChatGPTTap.swift', import.meta.url), 'utf8');
export const start = source.indexOf('static let podScript = #"""');
const privacySource = readFileSync(new URL('../App/Sources/Tatwo2/TAP/ChatGPTTurnPresentation.swift', import.meta.url), 'utf8');
const privacyJSON = privacySource.match(/static let privacyRulesJSON = #"""([\s\S]*?)"""#/)[1];
export const script = source.slice(source.indexOf('\n', start) + 1, source.indexOf('"""#', start))
  .replace('\\#(ChatGPTLocalText.privacyRulesJSON)', privacyJSON)
  .replace('\\#(noProgressMessage)', source.match(/static let noProgressMessage = "([^"]+)"/)[1]);
export const key = 'a'.repeat(64);
export const podScript = key => script.replace('__TATWO_POD_KEY__', key);

export function fixture({ allowNetwork = false, respond, navigationEvents = true, webSocket = false } = {}) {
  let now = 0, serial = 0;
  const timers = new Map(), reports = [], nodes = [], insertions = [], requests = [], navigations = [];
  const observers = [];
  const listeners = Symbol('fixture listeners');
  const windowListeners = new Map(); // VM global proxy and the host sandbox are the same synthetic window.
  class EventTarget {
    addEventListener(type, listener) {
      const events = this.window ? windowListeners : (this[listeners] ??= new Map());
      if (!events.has(type)) events.set(type, []);
      events.get(type).push(listener);
    }
    dispatchEvent(event) {
      const events = this.window ? windowListeners : this[listeners];
      for (const listener of events?.get(event.type) ?? []) listener.call(this, event);
      return true;
    }
  }
  class MutationObserver {
    constructor(callback) { this.callback = callback; this.records = []; }
    observe() { observers.push(this); }
    takeRecords() { return this.records.splice(0); }
    disconnect() { const i = observers.indexOf(this); if (i >= 0) observers.splice(i, 1); }
  }
  const schedule = (fn, ms, repeat = false) => {
    const id = ++serial;
    timers.set(id, { fn, at: now + ms, repeat: repeat ? ms : 0 });
    return id;
  };
  class Element {
    constructor(tag, attrs = {}, parent = null) {
      this.tagName = tag.toUpperCase();
      this.attrs = { ...attrs };
      this.parentElement = parent;
      this.isConnected = true;
      this.disabled = false;
      this.readOnly = false;
      this.hidden = false;
      this.inert = false;
      this.style = { display: 'block', visibility: 'visible', opacity: '1' };
      this.value = '';
      this.clicks = 0;
      this.events = [];
      nodes.push(this);
    }
    get isContentEditable() { return this.attrs.contenteditable === 'true'; }
    get nodeType() { return 1; }
    get childNodes() { return this.childrenOverride ?? nodes.filter((n) => n.parentElement === this); }
    get textContent() { return this.textOverride ?? this.childNodes.map((n) => n.textContent).join(''); }
    set textContent(text) { this.textOverride = text; }
    get innerText() { return this.innerOverride ?? this.textContent; }
    set innerText(text) { this.innerOverride = text; }
    get nextElementSibling() { const siblings = nodes.filter(n => n.isConnected && n.parentElement === this.parentElement); return siblings[siblings.indexOf(this) + 1] || null; }
    get form() { return this.owner === undefined ? this.closest('form') : this.owner; }
    getAttribute(name) { return this.attrs[name] ?? null; }
    setAttribute() { assert.fail('send must not change DOM attributes'); }
    removeAttribute() { assert.fail('send must not remove DOM attributes'); }
    getClientRects() { return this.style.display === 'none' ? [] : [{ width: 300, height: 40 }]; }
    contains(other) {
      for (let n = other; n; n = n.parentElement) if (n === this) return true;
      return false;
    }
    matches(selector) {
      if (selector === ':disabled') return this.disabled || !!this.closest('fieldset[disabled]');
      if (selector === 'form') return this.tagName === 'FORM';
      if (selector === '[inert]') return this.inert;
      if (selector === 'fieldset[disabled]') return this.tagName === 'FIELDSET' && this.disabled;
      if (/^\.[A-Za-z0-9_-]+$/.test(selector)) return String(this.attrs.class || '').split(/\s+/).includes(selector.slice(1));
      if (selector.startsWith('#')) return this.attrs.id === selector.slice(1);
      if (selector === 'form .ProseMirror[contenteditable="true"]') {
        return this.attrs.class === 'ProseMirror' && this.isContentEditable && !!this.closest('form');
      }
      const contains = selector.match(/^\[([\w-]+)\*='([^']*)'\]$/) || selector.match(/^\[([\w-]+)\*="([^"]*)"\]$/);
      if (contains) return String(this.attrs[contains[1]] || '').includes(contains[2]);
      const match = selector.match(/^([a-z][a-z0-9-]*)?(?:\[([\w-]+)(?:="([^"]*)")?\])?$/);
      return !!match && (!match[1] || this.tagName === match[1].toUpperCase())
        && (!match[2] || (match[3] === undefined ? match[2] in this.attrs : this.attrs[match[2]] === match[3]));
    }
    closest(selector) {
      for (let n = this; n; n = n.parentElement) if (selector.split(',').some((s) => n.matches(s.trim()))) return n;
      return null;
    }
    querySelectorAll(selector) { return doc.querySelectorAll(selector).filter((n) => n !== this && this.contains(n)); }
    focus() { doc.activeElement = this; this.onFocus?.(); }
    select() { doc.selected = this; }
    click() { this.clicks++; this.onClick?.(); }
    dispatchEvent(event) { this.events.push(event.type); return true; }
  }
  const doc = {
    readyState: 'loading', activeElement: null, selected: null,
    addEventListener() {},
    querySelectorAll(selector) {
      return nodes.filter((n) => n.isConnected && selector.split(',').some((s) => n.matches(s.trim())));
    },
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; },
    createRange() { return { selectNodeContents: (el) => { this.selected = el; } }; },
    execCommand(cmd, _ui, text) {
      insertions.push({ cmd, target: this.activeElement });
      if (this.onInsert) return this.onInsert(cmd, text);
      assert.equal(this.activeElement, this.selected, 'insertion must stay inside selected composer');
      this.activeElement.value = cmd === 'delete' ? '' : text;
      return true;
    },
  };
  class NavigationCurrentEntryChangeEvent {
    #navigationType;
    constructor(type, { navigationType = null, from = null } = {}) {
      Object.assign(this, { type, from });
      this.#navigationType = navigationType;
    }
    get navigationType() { return this.#navigationType; }
  }
  const changePath = (path, navigationType) => {
    const from = { url: sandbox.location.origin + sandbox.location.pathname };
    sandbox.location.pathname = new URL(path, sandbox.location.origin).pathname;
    navigations.push(sandbox.location.pathname);
    // The browser dispatches currententrychange inside push/replaceState, before the wrapper returns.
    if (navigationEvents) sandbox.navigation.dispatchEvent(new NavigationCurrentEntryChangeEvent(
      'currententrychange', { navigationType, from }));
    sandbox.onNavigate?.();
  };
  class History {
    pushState(_s, _t, path) { changePath(path, 'push'); }
    replaceState(_s, _t, path) { changePath(path, 'replace'); }
  }
  const sandbox = {
    Headers, Request, Response, ReadableStream, TextEncoder, TextDecoder, URL, URLSearchParams,
    Date: class extends Date { static now() { return now; } },
    setTimeout: (fn, ms) => schedule(fn, ms), clearTimeout: (id) => timers.delete(id),
    setInterval: (fn, ms) => schedule(fn, ms, true), clearInterval: (id) => timers.delete(id),
    document: doc, location: { host: 'chatgpt.com', origin: 'https://chatgpt.com', pathname: '/' },
    History, history: new History(), MutationObserver, EventTarget, navigation: new EventTarget(), NavigationCurrentEntryChangeEvent,
    WebSocket: webSocket ? class extends EventTarget { constructor(url) { super(); this.url = url; } } : undefined,
    getComputedStyle: (n) => n.style,
    getSelection: () => ({ removeAllRanges() {}, addRange() {} }),
    addEventListener: EventTarget.prototype.addEventListener, dispatchEvent: EventTarget.prototype.dispatchEvent,
    PopStateEvent: class { constructor(type) { this.type = type; } },
    Event: class { constructor(type) { this.type = type; } },
    DataTransfer: class {
      constructor() { this.files = []; this.items = { add: (f) => this.files.push(f) }; }
    },
    File: class { constructor(bytes, name, options) { Object.assign(this, { bytes, name, ...options }); } },
    atob: (s) => Buffer.from(s, 'base64').toString('binary'),
    fetch: async (url, init) => {
      if (!allowNetwork) throw new Error('unexpected network request in synthetic-only test');
      requests.push({ url, init });
      if (respond) return respond(url, init);
      return new Response('data: [DONE]\n\n', { headers: { 'content-type': 'text/event-stream' } });
    },
  };
  sandbox.window = sandbox;
  vm.runInNewContext(script.replace('__TATWO_POD_KEY__', key), sandbox)((json) => reports.push(JSON.parse(json)));
  const form = new Element('form');
  const box = new Element('textarea', { id: 'prompt-textarea' }, form);
  const button = new Element('button', { 'data-testid': 'send-button', type: 'submit' }, form);
  const flush = async () => { for (let i = 0; i < 40; i++) await Promise.resolve(); };
  const advance = async (ms) => {
    const until = now + ms;
    await flush();
    while (true) {
      const entry = [...timers].filter(([, t]) => t.at <= until).sort((a, b) => a[1].at - b[1].at)[0];
      if (!entry) break;
      const [id, t] = entry;
      now = t.at;
      if (t.repeat) t.at += t.repeat;
      else timers.delete(id);
      t.fn();
      await flush();
    }
    now = until;
    await flush();
  };
  const command = (c) => sandbox.__tatwoPod.command({ ...c, key });
  return {
    doc, form, box, button, nodes, reports, insertions, requests, navigations, sandbox, Element, command, advance,
    later: (ms, fn) => schedule(fn, ms),
    queueMutation: (record) => observers.forEach((o) => o.records.push(record)),
    mutate: (records = []) => observers.forEach((o) => o.callback([...o.takeRecords(), ...records])),
    send: (extra = {}) => command({ cmd: 'send', id: 'S', text: 'synthetic question', ...extra }),
    failure: () => reports.find((r) => r.id === 'S' && r.kind === 'failed'),
  };
}

// Shared browser-faithful surface for connector and stress tests.
// W183 R9 審查（GPT-6 #3）：App 每次建立 Pod 換一把鑰匙（keyedPodScript 換掉唯一的佔位字）；每個指令都帶它。測試用一把假的。
export const POD_KEY = 'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';
assert.equal(script.split('__TATWO_POD_KEY__').length - 1, 1, 'exactly one key placeholder in the Pod script');

export const MCP = 'https://os-for-chatgpt.example.com/mcp';

/// 很小的 DOM：夠跑連接器指令（tag、[attr]、[attr="v"]、#id、逗號清單）。
/// W183 R9 審查（GPT-6 #11、Claude #1、#2）：click() 有真的預設行為——灰的鈕（disabled）按了只記 clicks、不觸發；
/// input 勾選框翻轉 checked；<label> 轉點到它的欄位；自己的字是文字節點（childNodes），跟真的 DOM 一樣。
/// W183 R9 審查（GPT-6 N1–N4）：再貼近瀏覽器一點——
/// - 點擊一律經過 window 的捕獲階段（Pod 的 noteTrusted 在那裡）：使用者按的是 isTrusted、網頁的程式 click() 不是；
///   原生勾選框在派送之前就先翻轉（pre-activation）；label 轉給欄位的那一下照 Chromium 當成真人（連 label.click() 也是）。
/// - 增刪節點、改屬性會通知 MutationObserver（微任務送出，跟瀏覽器一樣）。
/// W183 R9c（GPT-6 C1）：跟瀏覽器一樣，取值器與方法都在原型上（Node、Element、HTMLInputElement…、Document、NodeList、DOMRectList、
/// DOMRectReadOnly、CSSStyleDeclaration、MutationRecord、History、EventTarget）：Pod 在文件建立時抓得到，網頁之後改得到。
/// 假 DOM 自己內部只用底線開頭的內部欄位（網頁改寫公開的方法不會弄壞假 DOM 本身）。
export class FakeList {
  constructor(items) {
    Object.defineProperty(this, '_items', { value: items });
    items.forEach((x, i) => Object.defineProperty(this, i, { value: x, enumerable: true, configurable: true }));
  }
  get length() { return this._items.length; }
  item(i) { return this._items[i] ?? null; }
  forEach(fn, thisArg) { this._items.forEach(fn, thisArg); }
  [Symbol.iterator]() { return this._items[Symbol.iterator](); }
}
export class FakeRect {
  constructor(left, top, width, height) { Object.defineProperty(this, '_r', { value: { left, top, width, height } }); }
  get left() { return this._r.left; }
  get top() { return this._r.top; }
  get width() { return this._r.width; }
  get height() { return this._r.height; }
  get right() { return this._r.left + this._r.width; }
  get bottom() { return this._r.top + this._r.height; }
}
export class FakeStyle {
  constructor(map) { Object.defineProperty(this, '_map', { value: map }); }
  getPropertyValue(name) { return this._map[name] ?? ''; }
  get display() { return this._map.display ?? ''; }
  get visibility() { return this._map.visibility ?? ''; }
}
export class FakeRecord {
  constructor(r) { Object.defineProperty(this, '_r', { value: r }); }
  get type() { return this._r.type; }
  get target() { return this._r.target; }
  get removedNodes() { return new FakeList(this._r.removedNodes || []); }
  get addedNodes() { return new FakeList(this._r.addedNodes || []); }
  get attributeName() { return this._r.attributeName ?? null; }
  get oldValue() { return this._r.oldValue ?? null; }
}
/// 節點（也當 EventTarget：window、document、navigation 都用它的 addEventListener／dispatchEvent）。
export class FakeNode {
  get parentElement() { const p = this._parent; return p && p._nodeType === 1 ? p : null; }
  set parentElement(v) { this._parent = v; }   // 舊的反例直接設（不經 DOM 方法）
  get parentNode() { return this._parent || null; }
  get nodeType() { return this._nodeType; }
  get nodeValue() { return this._nodeType === 3 ? this._text : null; }
  get textContent() { return textOf(this); }
  get childNodes() { return new FakeList(childNodesOf(this)); }
  contains(other) { for (let p = other; p; p = p._parent) if (p === this) return true; return false; }
  appendChild(child) {
    if (child._parent) child.remove();   // 搬家＝先從原處拿下來（MutationObserver 看得到）
    child._parent = this;
    this._kids.push(child);
    notifyMutation(this, { type: 'childList', target: this, addedNodes: [child], removedNodes: [] });
    return child;
  }
  addEventListener(type, fn) { const L = listenersOf(this); (L[type] ||= []).push(fn); }
  removeEventListener() {}
  dispatchEvent(event) {
    const env = envOf(this);
    if (env) env.retarget(event, this);
    (listenersOf(this)[event.type] || []).forEach((fn) => fn.call(this, event));
    return true;
  }
}
const listenersOf = (target) => {
  if (!Object.prototype.hasOwnProperty.call(target, '__listeners')) Object.defineProperty(target, '__listeners', { value: {}, configurable: true });
  return target.__listeners;
};
export class FakeText extends FakeNode {
  constructor(text, parent) { super(); this._nodeType = 3; this._text = text; this._parent = parent; }
}
const textOf = (node) => (node._nodeType === 3 ? node._text : [node.text, ...(node._kids || []).map(textOf)].filter(Boolean).join(' '));
const childNodesOf = (node) => (node._nodeType === 9 ? [node._root] : node._nodeType === 1 ? [...(node.text ? [new FakeText(node.text, node)] : []), ...node._kids] : []);
/// 這個元素看不看得到（自己或上層 hidden、style.display none＝看不到；跟瀏覽器一樣算進 getClientRects）。
const renderedOf = (el) => { for (let p = el; p && p._nodeType === 1; p = p._parent) if (p._hidden || (p.style && p.style.display === 'none')) return false; return true; };
export class El extends FakeNode {
  constructor(tag, attrs = {}, children = [], text = '') {
    super();
    this._nodeType = 1;
    this._tag = tag.toUpperCase();
    this._attrs = {};
    // value 也是屬性（getAttribute('value') 讀得到，跟瀏覽器一樣）；value 這個性質另外放（輸入之後跟屬性分開）。
    for (const [k, v] of Object.entries(attrs)) if (!['checked', 'disabled', 'onclick', 'hidden'].includes(k)) this._attrs[k] = String(v);
    this._value = attrs.value ?? '';
    this._checked = !!attrs.checked;
    this._disabled = !!attrs.disabled;
    this._hidden = !!attrs.hidden;
    this._readOnly = false;
    this._selected = false;
    this.onclick = attrs.onclick ?? null;
    this._kids = [];
    this._parent = null;
    this.text = text;
    this.style = {};
    this.clicks = 0;
    children.forEach((c) => this.appendChild(c));
  }
  _attr(name) { return Object.prototype.hasOwnProperty.call(this._attrs, name) ? this._attrs[name] : null; }
  get tagName() { return this._tag; }
  get children() { return this._kids; }
  get value() { return this._value; }
  set value(v) { this._value = String(v); }
  get checked() { return this._checked; }
  set checked(v) { this._checked = !!v; }
  get disabled() { return this._disabled; }
  set disabled(v) { this._disabled = !!v; }
  get hidden() { return this._hidden; }
  set hidden(v) { this._hidden = !!v; }
  get readOnly() { return this._readOnly; }
  set readOnly(v) { this._readOnly = !!v; }
  get selected() { return this._selected; }
  set selected(v) { this._selected = !!v; }
  get options() { return this._tag === 'SELECT' ? this._kids.filter((c) => c._tag === 'OPTION') : undefined; }
  /// 表單歸屬（瀏覽器的規則：有 form 屬性＝那個 id 的 <form>；沒有＝最近的上層 <form>）。
  get form() {
    if (!['INPUT', 'TEXTAREA', 'SELECT', 'BUTTON'].includes(this._tag)) return undefined;
    const id = this._attr('form');
    if (id !== null) {
      let root = this;
      while (root._parent) root = root._parent;
      const hit = queryAll(root._nodeType === 9 ? root._root : root, `#${id}`)[0];
      return hit && hit._tag === 'FORM' ? hit : null;
    }
    for (let p = this._parent; p && p._nodeType === 1; p = p._parent) if (p._tag === 'FORM') return p;
    return null;
  }
  prepend(child) {
    if (child._parent) child.remove();
    child._parent = this;
    this._kids.unshift(child);
    notifyMutation(this, { type: 'childList', target: this, addedNodes: [child], removedNodes: [] });
    return child;
  }
  remove() {
    const parent = this._parent;
    if (!parent || parent._nodeType !== 1) return;
    parent._kids = parent._kids.filter((c) => c !== this);
    this._parent = null;
    notifyMutation(parent, { type: 'childList', target: parent, addedNodes: [], removedNodes: [this] });
  }
  getAttribute(name) { return this._attr(name) ?? ((name === 'type' && this._attrs.type) || null); }
  setAttribute(name, value) {
    const old = this._attr(name);
    this._attrs[name] = String(value);
    notifyMutation(this, { type: 'attributes', target: this, attributeName: name, oldValue: old });
  }
  removeAttribute(name) {
    const old = this._attr(name);
    delete this._attrs[name];
    notifyMutation(this, { type: 'attributes', target: this, attributeName: name, oldValue: old });
  }
  /// 網頁的程式（或 TATWO 的 press）叫的 click()：不是 isTrusted。
  click() { dispatchClick(this, false); }
  focus() {}
  /// W183 R10：版面（_rect＝這一格在畫面上的位置；沒給＝舊的固定框）。代勾要量那一格的位置、看那一點最上面是誰。
  getBoundingClientRect() { return this._rect || new FakeRect(10, 10, 30, 20); }
  getClientRects() { return new FakeList(renderedOf(this) ? [this._rect || new FakeRect(10, 10, 30, 20)] : []); }
  /// 捲到畫面裡：記下選項（代勾要立刻捲到中間，不照網頁的 scroll-behavior 慢慢捲）。
  scrollIntoView(options) { (this._scrolls ||= []).push(options); }
  querySelectorAll(selector) { return new FakeList(queryAll(this, selector)); }
  querySelector(selector) { return queryAll(this, selector)[0] || null; }
}
export class FakeDocument extends FakeNode {
  constructor(root, body) { super(); this._nodeType = 9; this._root = root; this._body = body; this.readyState = 'complete'; root._parent = this; }
  get body() { return this._body; }
  get documentElement() { return this._root; }
  get textContent() { return null; }
  querySelectorAll(selector) { return new FakeList(queryAll(this._root, selector)); }
  querySelector(selector) { return queryAll(this._root, selector)[0] || null; }
  getElementById(id) { return queryAll(this._root, `#${id}`)[0] || null; }
  createElement(tag) { return new El(tag); }
  execCommand() { return true; }
  /// W183 R10：那一點最上面的元素（只有給了 _rect 的元素在版面上；文件順序後面的蓋前面的、子蓋父）。不叫任何元素的方法（直接看 _rect）。
  elementFromPoint(x, y) {
    let top = null;
    const walk = (el) => {
      for (const c of el._kids) {
        const r = c._rect && c._rect._r;
        if (r && renderedOf(c) && x >= r.left && x < r.left + r.width && y >= r.top && y < r.top + r.height) top = c;
        walk(c);
      }
    };
    walk(this._root);
    return top;
  }
}
/// 這個節點掛在哪一頁（掛在頁面上的 document 有 env；拿下來的沒有）。
function envOf(node) {
  if (node && node.env) return node.env;
  let root = node;
  while (root && root._parent) root = root._parent;
  return (root && root.env) || null;
}
function notifyMutation(node, record) {
  const env = envOf(node);
  if (env) env.mutated(record);
}
/// 瀏覽器派送一次點擊：灰的鈕不派送；原生勾選框先翻轉；window 捕獲 → 元素自己的處理 → 預設行為（label 轉點）。
function dispatchClick(el, trusted) {
  el.clicks += 1;
  if (el._disabled) return;
  const env = envOf(el);
  const type = el._attr('type');
  if (el._tag === 'INPUT' && type === 'checkbox') el._checked = !el._checked;
  if (el._tag === 'INPUT' && type === 'radio') {
    // 同名的單選：選這一個＝其他的變沒選。
    const name = el._attr('name');
    let root = el;
    while (root._parent && root._parent._nodeType === 1) root = root._parent;
    if (name) for (const r of queryAll(root, 'input[type="radio"]')) if (r !== el && r._attr('name') === name) r._checked = false;
    el._checked = true;
  }
  const event = env ? env.clickEvent(el, trusted) : { type: 'click', target: el, isTrusted: trusted };
  if (env) env.capture('click', event);
  if (el.onclick) el.onclick.call(el, event);
  (listenersOf(el).click || []).forEach((fn) => fn.call(el, event));
  if (el._tag === 'LABEL') {
    const id = el._attr('for');
    let root = el;
    while (root._parent && root._parent._nodeType === 1) root = root._parent;
    const target = id ? queryAll(root, `#${id}`)[0] : queryAll(el, 'input')[0];
    // Chromium：label 轉給欄位的那一下是 isTrusted（就算 label 那一下是網頁的程式按的）。
    if (target && target !== el) dispatchClick(target, true);
  }
}
export const h = (tag, attrs, ...children) => {
  const kids = children.flat().filter((c) => c !== null && c !== undefined && c !== false);
  const text = kids.filter((c) => typeof c === 'string').join(' ');
  return new El(tag, attrs || {}, kids.filter((c) => typeof c !== 'string'), text);
};
function matcher(simple) {
  if (simple.trim() === '*') return () => true;
  const m = /^([a-zA-Z][a-zA-Z0-9-]*)?((?:\[[^\]]+\]|#[\w-]+)*)$/.exec(simple.trim());
  if (!m) throw new Error('selector ' + simple);
  const tag = m[1] ? m[1].toUpperCase() : null;
  const parts = [...(m[2] || '').matchAll(/\[([\w-]+)(?:="([^"]*)")?\]|#([\w-]+)/g)]
    .map((p) => (p[3] ? { attr: 'id', value: p[3] } : { attr: p[1], value: p[2] }));
  const attrOf = (el, name) => el._attr(name) ?? ((name === 'type' && el._attrs.type) || null);
  return (el) => (!tag || el._tag === tag) && parts.every((p) => (p.value === undefined ? attrOf(el, p.attr) !== null : attrOf(el, p.attr) === p.value));
}
export function queryAll(root, selector) {
  const tests = selector.split(',').map(matcher);
  const out = [];
  const walk = (el) => { for (const c of el._kids) { if (tests.some((t) => t(c))) out.push(c); walk(c); } };
  walk(root);
  return out;
}

/// 這一頁的事件類別（在這一頁的 vm 裡建：原型、取值器屬於這一頁，網頁改得到；isTrusted 是每個事件自己的、改不動的屬性；
/// 只有瀏覽器——這裡是測試的 trusted()——做得出 isTrusted 的事件；派送時才定 target）。KeyboardEvent 的 key／code 也在原型上。
const EVENT_KIT = `(() => {
  const TRUST = {};
  let setTarget = null;
  class Event {
    #type; #target = null;
    static { setTarget = (ev, t) => { ev.#target = t; }; }
    constructor(type, opts, token) {
      this.#type = String(type);
      Object.defineProperty(this, 'isTrusted', { value: token === TRUST, enumerable: true, configurable: false, writable: false });
      if (opts && typeof opts === 'object') for (const k of Object.keys(opts)) if (!(k in this) && k !== 'isTrusted') this[k] = opts[k];
      this.defaultPrevented = false;
    }
    get type() { return this.#type; }
    get target() { return this.#target; }
    preventDefault() { this.defaultPrevented = true; }
    stopPropagation() {}
    stopImmediatePropagation() {}
  }
  class MouseEvent extends Event {}
  class PointerEvent extends MouseEvent {}
  class KeyboardEvent extends Event {
    #key = ''; #code = '';
    constructor(type, opts, token) { super(type, opts, token); this.#key = String((opts && opts.key) || ''); this.#code = String((opts && opts.code) || ''); }
    get key() { return this.#key; }
    get code() { return this.#code; }
  }
  class PopStateEvent extends Event {}
  const retarget = (ev, t) => { try { setTarget(ev, t); } catch (e) {} return ev; };
  const trusted = (C, type, t, opts) => retarget(new C(type, opts, TRUST), t);
  return { Event, MouseEvent, PointerEvent, KeyboardEvent, PopStateEvent, retarget, trusted };
})()`;

/// 頁面的 Pod 腳本檔名（變異測試、原型污染測試用堆疊認出「是 Pod 腳本自己叫的」）。
export const POD_FILE = 'tatwo-pod.js';

export function makePage({ build, installed = { status: 200, json: { items: [] } }, routes = {}, script = podScript(POD_KEY), mutationObserver = true, drop = [], viewport = null }) {
  const reports = [];
  const pageState = { pathname: '/' };
  const body = new El('body');
  const documentRoot = new El('html', {}, [body]);
  // window 的捕獲階段（Pod 腳本最早裝，記使用者真的按過的）；document 的 keydown（選單按 Escape 會關）。
  const windowListeners = {};
  // MutationObserver：看得到的增刪、屬性改變，在微任務送出。
  const observers = new Set();
  class MutationObserver {
    constructor(callback) { this.callback = callback; this.targets = []; this.queue = []; this.pending = false; }
    // mutationObserver: 'deaf'＝有這個類別、但從來不送紀錄（驗讀回時那幾道自己也擋得住）。
    observe(target, options) { if (mutationObserver === 'deaf') return; this.targets.push({ target, options: options || {} }); observers.add(this); }
    disconnect() { this.targets = []; this.queue = []; observers.delete(this); }
    takeRecords() { const q = this.queue; this.queue = []; return q; }
  }
  const inScope = (target, options, node) => {
    if (target === document) return envOf(node) === env;
    if (target === node) return true;
    return !!options.subtree && target instanceof FakeNode && target.contains(node);
  };
  // 導頁：History（每一頁自己一個類別：Pod 包的是這一頁的原型）與 Navigation API（任何同文件換網址都會發 currententrychange）。
  class History {
    pushState(_s, _t, path) { env.navigate(path); }
    replaceState(_s, _t, path) { env.navigate(path); }
  }
  class Navigation extends FakeNode {}
  const navigation = new Navigation();
  const env = {
    mutated(record) {
      for (const observer of observers) {
        const hit = observer.targets.some(({ target, options }) => inScope(target, options, record.target) && (record.type === 'childList'
          ? !!options.childList
          : !!options.attributes && (!options.attributeFilter || options.attributeFilter.includes(record.attributeName))));
        if (!hit) continue;
        const wantsOld = observer.targets.some(({ options }) => options.attributeOldValue);
        observer.queue.push(new FakeRecord({ ...record, oldValue: record.type === 'attributes' && wantsOld ? record.oldValue : null }));
        if (!observer.pending) {
          observer.pending = true;
          queueMicrotask(() => { observer.pending = false; const q = observer.takeRecords(); if (q.length && observers.has(observer)) observer.callback(q, observer); });
        }
      }
    },
    capture(type, event) { (windowListeners[type] || []).forEach((fn) => fn(event)); },
    clickEvent(target, trusted) { return trusted ? kit.trusted(kit.MouseEvent, 'click', target, { bubbles: true }) : kit.retarget(new kit.MouseEvent('click', { bubbles: true }), target); },
    retarget(event, target) { if (event instanceof kit.Event) kit.retarget(event, target); },
    navigate(path) {
      const changed = pageState.pathname !== path;
      pageState.pathname = path;
      if (changed) navigation.dispatchEvent(new kit.Event('currententrychange'));
      pageState.onNavigate?.(path);
    },
  };
  const document = new FakeDocument(documentRoot, body);
  document.env = env;
  const sandbox = {
    Headers, Request, Response, ReadableStream, TextEncoder, TextDecoder, URL, URLSearchParams,
    // 長的計時器（高亮 2 分鐘後自己拿掉、登入等 20 秒）不讓測試行程多等。
    setTimeout: (fn, ms) => { const t = setTimeout(fn, ms); if (ms >= 5000) t.unref(); return t; }, clearTimeout,
    setInterval: (fn, ms) => { const t = setInterval(fn, ms); if (ms >= 1000) t.unref(); return t; }, clearInterval,
    queueMicrotask,
    location: { host: 'chatgpt.com', origin: 'https://chatgpt.com', get href() { return 'https://chatgpt.com' + pageState.pathname; }, get pathname() { return pageState.pathname; } },
    // 原型上有取值器的 DOM 類別（Pod 在文件建立時抓）。
    EventTarget: FakeNode, Node: FakeNode, Element: El, HTMLElement: El, HTMLInputElement: El, HTMLTextAreaElement: El, HTMLSelectElement: El,
    HTMLOptionElement: El, HTMLButtonElement: El, Document: FakeDocument, NodeList: FakeList, HTMLCollection: FakeList, DOMRectList: FakeList,
    DOMRectReadOnly: FakeRect, CSSStyleDeclaration: FakeStyle, MutationRecord: FakeRecord, History, Navigation,
    getComputedStyle: (el) => new FakeStyle({ display: el._hidden || (el.style && el.style.display === 'none') ? 'none' : (el.style.display || 'block'),
      visibility: el.style.visibility || 'visible' }),
    MutationObserver,
    removeEventListener: () => {},
  };
  sandbox.history = new History();
  sandbox.navigation = navigation;
  sandbox.document = document;
  sandbox.window = sandbox;
  sandbox.env = env;
  Object.defineProperty(sandbox, '__listeners', { value: windowListeners });
  sandbox.addEventListener = (type, fn) => { (windowListeners[type] ||= []).push(fn); };
  sandbox.dispatchEvent = (event) => FakeNode.prototype.dispatchEvent.call(sandbox, event);
  // W183 R10：畫面大小（代勾量那一格的位置用；跟瀏覽器一樣是 window 自己身上的取值器）。沒給＝這一頁沒有 innerWidth／innerHeight
  //（Pod 不代勾，照舊交給使用者）。visual＝有 visualViewport（scale、offset 的取值器在原型上）；雙指縮放或視覺視窗有位移＝不代勾。
  if (viewport) {
    Object.defineProperty(sandbox, 'innerWidth', { get() { return viewport.width; }, configurable: true, enumerable: true });
    Object.defineProperty(sandbox, 'innerHeight', { get() { return viewport.height; }, configurable: true, enumerable: true });
    if (viewport.visual) {
      class VisualViewport {
        get scale() { return viewport.scale ?? 1; }
        get offsetLeft() { return viewport.offsetLeft ?? 0; }
        get offsetTop() { return viewport.offsetTop ?? 0; }
      }
      const visual = new VisualViewport();
      sandbox.VisualViewport = VisualViewport;
      Object.defineProperty(sandbox, 'visualViewport', { get() { return visual; }, configurable: true, enumerable: true });
    }
  }
  // drop：這一頁少了某個瀏覽器能力（驗「少了就拒絕，不退回網頁的方法」）。
  for (const name of drop) delete sandbox[name];
  const context = vm.createContext(sandbox);
  const kit = vm.runInContext(EVENT_KIT, context);
  Object.assign(sandbox, { Event: kit.Event, MouseEvent: kit.MouseEvent, PointerEvent: kit.PointerEvent, KeyboardEvent: kit.KeyboardEvent, PopStateEvent: kit.PopStateEvent });
  for (const name of drop) delete sandbox[name];
  // 使用者真的按（isTrusted）：瀏覽器派送（原生勾選框先翻轉、window 捕獲、元素的處理、label 轉點）。網頁自己的程式按的＝el.click()（不是 isTrusted）。
  const userClick = (el) => dispatchClick(el, true);
  const pageClick = (el) => el.click();
  // 使用者按鍵（焦點在 el 上）：keydown、keyup 都是 isTrusted。瀏覽器的預設：按鈕上的 Enter 在按下時送一次真人點擊；
  // 按鈕、原生勾選框／單選上的空白鍵在放開時送一次真人點擊（網頁 preventDefault＝不送）。其他（role=checkbox 的 div）由網頁自己處理。
  const userKey = (el, key) => {
    const code = key === ' ' ? 'Space' : key;
    const fire = (type) => {
      const event = kit.trusted(kit.KeyboardEvent, type, el, { key, code, bubbles: true });
      env.capture(type, event);
      (listenersOf(el)[type] || []).forEach((fn) => fn.call(el, event));
      return event;
    };
    const button = el._tag === 'BUTTON';
    const native = el._tag === 'INPUT' && ['checkbox', 'radio'].includes(el._attr('type'));
    const down = fire('keydown');
    if (key === 'Enter' && button && !down.defaultPrevented) dispatchClick(el, true);
    const up = fire('keyup');
    if (key === ' ' && (button || native) && !down.defaultPrevented && !up.defaultPrevented) dispatchClick(el, true);
  };
  sandbox.fetch = async (input) => {
    const url = typeof input === 'string' ? input : input.url;
    const path = new URL(url, 'https://chatgpt.com').pathname;
    if (path === '/backend-api/ps/plugins/installed') {
      return new Response(JSON.stringify(installed.json), { status: installed.status, headers: { 'content-type': 'application/json' } });
    }
    if (Object.prototype.hasOwnProperty.call(routes, path)) {
      return new Response(JSON.stringify(routes[path]), { status: 200, headers: { 'content-type': 'application/json' } });
    }
    return new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  const factory = vm.runInContext(script, context, { filename: POD_FILE });
  factory((json) => reports.push(JSON.parse(json)));
  body.document = document;   // 頁面自己的元件要聽 document 的鍵（例如選單按 Escape 會關）
  const page = build ? build(body) : {};
  if (page && typeof page === 'object') Object.assign(page, { userClick, userKey, pageClick });
  let n = 0;
  // App 的指令是另一個工作（task）：前面的點擊、按鍵整段處理完（含 Pod 事後讀回的那一步）才輪到。
  const nextTask = () => new Promise((r) => setTimeout(r, 5));
  return {
    reports, sandbox, body, page, pageState, userClick, userKey, pageClick,
    /// 在這一頁的 vm 裡跑一段「網頁自己的程式」（例如改寫內建函式）。
    run: (source) => vm.runInContext(source, context),
    /// 不經 History.prototype 的同文件換網址（例如網頁用別的 realm 的 pushState）：瀏覽器照樣會發 Navigation API 的事件。
    navigateNatively: (path) => env.navigate(path),
    signIn: () => sandbox.window.fetch('https://chatgpt.com/backend-api/me', { headers: { authorization: 'Bearer SECRET-TOKEN' } }),
    // App 送的指令一律帶 Pod 的鑰匙（raw＝照原樣送，給「網頁自己的程式叫」的反例用）。
    /// W183 R10 第二輪：Create／重新連線分兩步——網頁腳本核對完回 armed（不按），App 記下錨點再送 connectorPress。
    /// press（預設 true）＝照 App 的樣子接著送 connectorPress，回的是按下去那一步的結果；false＝停在 armed（驗兩步之間的反例）。
    async command(payload, ms = 12000, { raw = false, press = true } = {}) {
      const hit = await this.send(payload, ms, { raw });
      if (press && !raw && (payload.cmd === 'connectorCreate' || payload.cmd === 'connectorReconnect') && hit.data && hit.data.status === 'armed') {
        this.armed.push(hit.data.form);
        return this.send({ cmd: 'connectorPress', form: hit.data.form }, ms);
      }
      return hit;
    },
    /// 送出的 armed 記號（依序）：驗「按了一次、記號就用掉」。
    armed: [],
    async send(payload, ms = 12000, { raw = false } = {}) {
      await nextTask();
      const id = 'R' + (n += 1);
      sandbox.__tatwoPod.command(raw ? { ...payload, id } : { ...payload, id, key: POD_KEY });
      const end = Date.now() + ms;
      while (Date.now() < end) {
        const hit = reports.find((r) => r.type === 'result' && r.id === id);
        if (hit) return hit;
        await new Promise((r) => setTimeout(r, 10));
      }
      assert.fail('timed out ' + payload.cmd);
    },
    /// 送了之後等一下：回報裡有沒有這一個的任何結果（鑰匙不對＝安靜丟掉，一個都沒有）。
    async silent(payload, ms = 300) {
      await nextTask();
      const id = 'S' + (n += 1);
      sandbox.__tatwoPod.command({ ...payload, id });
      await new Promise((r) => setTimeout(r, ms));
      return !reports.some((r) => r.id === id);
    },
  };
}
