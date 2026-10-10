import { fixture } from '../w185-pod-fixture.mjs';
import { rendererPage } from './w318-newrenderer.mjs';

// Synthetic connector and account labels; no browser, real account, or network.
export function expiredCard(p, parent, { name = 'TATWO（Mac mini）4', language = 'en', role = 'group', heading = true, expired = true, reconnect = true, dismiss = true, turn = false, wrapped = false } = {}) {
  const card = new p.Element('div', turn ? { class: '@container/approval-card' } : { role }, parent);
  const alert = turn ? new p.Element('div', { role: 'alert' }, card) : card;
  const text = (value, host = alert) => { const n = new p.Element('div', {}, host); n.textContent = value; return n; };
  text(name);
  const titleHost = wrapped ? new p.Element('div', {}, alert) : alert;
  if (heading) text((language === 'en' ? 'Reconnect ' : language === 'zh' ? '重新連線 ' : '重新连线 ') + name, titleHost);
  const descriptionHost = wrapped ? new p.Element('div', {}, alert) : alert;
  if (expired) text(language === 'en'
    ? `Your ${name} connection has expired. Reconnect it before ChatGPT can use it for this request.`
    : language === 'zh' ? `你的 ${name} 連線已過期。請重新連線，ChatGPT 才能處理這個要求。`
      : `你的 ${name} 连线已过期。请重新连线，ChatGPT 才能处理这个请求。`, descriptionHost);
  text('Primary', card);
  const account = text('Fixture Account', card);
  const buttonHost = turn ? new p.Element('div', {}, card) : card;
  const buttons = new p.Element('div', { class: 'flex shrink-0 items-center gap-2 px-4 pt-2 pb-4 @max-md/approval-card:flex-col' }, buttonHost);
  const button = label => { const n = new p.Element('button', {}, buttons); n.textContent = label; return n; };
  const notNow = dismiss && button(language === 'en' ? 'Not now' : language === 'zh' ? '暫時不要' : '暂时不要');
  const connect = reconnect && button(language === 'en' ? 'Reconnect' : language === 'zh' ? '重新連線' : '重新连线');
  return { card, notNow, connect, account, alert };
}

export function userTurn(p, parent, { userRole = 'section' } = {}) {
  const container = new p.Element('section', { class: 'relative shrink-0', ...(userRole === 'section' ? { 'data-message-author-role': 'user' } : {}) }, parent);
  new p.Element('h4', { class: 'sr-only' }, container).textContent = 'You said:';
  const bubble = new p.Element('div', { class: 'bg-user-message bubble-vBnidZ', ...(userRole === 'bubble' ? { 'data-message-author-role': 'user' } : {}) }, container);
  bubble.textContent = '請用這個 app 的 tatwo_status';
  for (const label of ['Copy message', 'Share prompt', 'Edit message']) new p.Element('button', { 'aria-label': label }, container);
  return { container, bubble };
}

// Browser matches() accepts selector lists; the shared minimal fixture handles one selector.
export function listMatches(p) {
  const matches = p.Element.prototype.matches;
  p.Element.prototype.matches = function(selector) { return selector.split(',').some(s => s.trim() === '*' || matches.call(this, s.trim())); };
  const children = Object.getOwnPropertyDescriptor(p.Element.prototype, 'childNodes').get;
  Object.defineProperty(p.Element.prototype, 'childNodes', { get() {
    return this.textOverride == null ? children.call(this) : [{ nodeType: 3, textContent: this.textOverride }, ...children.call(this)];
  } });
  return p;
}

export function expiredPage({ layout = 'renderer', placement = 'answer', userRole = 'section', ...options } = {}) {
  if (layout === 'renderer' || layout === 'turn') {
    const rig = rendererPage({ api: 'hanging', thinking: true });
    listMatches(rig.p);
    rig.showCard = () => {
      rig.body.textContent = '';
      if (layout === 'renderer') return expiredCard(rig.p, placement === 'answer' ? rig.body : null, { role: placement === 'dialog' ? 'dialog' : 'group', ...options });
      // 046 實機：卡片在使用者這一輪的容器裡，這一輪沒有 ChatGPT 回答節點。
      rig.heading.textContent = '';
      const bubble = rig.p.nodes.find(n => n.parentElement === rig.container && /bg-user-message/.test(n.attrs.class || ''));
      (userRole === 'bubble' ? bubble : rig.container).attrs['data-message-author-role'] = 'user';
      return expiredCard(rig.p, rig.container, { turn: true, ...options });
    };
    return rig;
  }
  const p = listMatches(fixture()), main = new p.Element('main');
  const rig = { p };
  p.button.onClick = () => {
    rig.stop = new p.Element('button', { 'data-testid': 'stop-button' }, p.form);
    rig.body = new p.Element('div', { 'data-message-author-role': 'assistant' }, main);
    rig.body.textContent = 'Listing Available Projects';
  };
  rig.showCard = () => {
    rig.body.textContent = '';
    return expiredCard(p, placement === 'answer' ? rig.body : null, { role: placement === 'dialog' ? 'dialog' : 'group', ...options });
  };
  return rig;
}
