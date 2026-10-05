import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture } from './w185-pod-fixture.mjs';

function page({ startLabel = 'Start Voice', endLabel = 'End voice mode', responds = true, disabled = false, hidden = false, absent = false, liveDelay = 0 } = {}) {
  const p = fixture();
  let live = false;
  const start = new p.Element('button', { 'aria-label': startLabel, 'data-testid': 'composer-speech-button' }, p.form);
  const end = new p.Element('button', { 'aria-label': endLabel }, p.form);
  start.disabled = disabled;
  if (hidden) start.style.display = 'none';
  start.isConnected = !absent;
  end.isConnected = false;
  start.onClick = () => {
    if (responds) p.later(liveDelay, () => { live = true; end.isConnected = true; start.isConnected = false; });
  };
  end.onClick = () => { live = false; end.isConnected = false; start.isConnected = true; };
  return { p, start, end, live: () => live };
}
const result = (p, id) => p.reports.find(r => r.type === 'result' && r.id === id);

for (const [name, options] of [
  ['missing control', { absent: true }],
  ['disabled control', { disabled: true }],
  ['hidden control', { hidden: true }],
]) test(`W217 Pod: ${name} fails within five seconds, not a false live session`, async () => {
  const { p, start } = page(options);
  p.command({ cmd: 'voice', id: 'start' });
  await p.advance(5000);
  assert.equal(result(p, 'start')?.ok, false, JSON.stringify(p.reports));
  assert.match(result(p, 'start').message, /語音|voice/i);
  if (!options.responds && !options.absent && !options.disabled && !options.hidden) {
    assert.equal(start.clicks, 1);
  } else {
    assert.equal(start.clicks, 0);
  }
  assert.equal(p.requests.length, 0);
});

test('W217b Pod: page never responds waits eight seconds, then fails by twelve', async () => {
  const { p, start, live } = page({ responds: false });
  p.command({ cmd: 'voice', id: 'start' });
  await p.advance(5000);
  assert.equal(start.clicks, 1);
  assert.equal(result(p, 'start'), undefined, 'do not reject while the page is still allowed to start');
  await p.advance(3000);
  assert.equal(result(p, 'start'), undefined);
  await p.advance(4000);
  assert.equal(result(p, 'start')?.ok, false);
  assert.match(result(p, 'start').message, /語音|voice/i);
  assert.doesNotMatch(result(p, 'start').message, /\n/);
  assert.equal(live(), false);
  assert.equal(p.requests.length, 0);
});

test('W217b Pod: page enters voice five seconds after click', async () => {
  const { p, start, live } = page({ liveDelay: 5000 });
  p.command({ cmd: 'voice', id: 'start' });
  await p.advance(5000);
  assert.equal(start.clicks, 1);
  assert.equal(result(p, 'start'), undefined);
  await p.advance(1000);
  assert.equal(result(p, 'start')?.ok, true);
  assert.equal(result(p, 'start')?.data?.live, true);
  assert.equal(live(), true);
  assert.equal(p.requests.length, 0);
});

test('W217b Pod: voice button appearing after three seconds can still start', async () => {
  const { p, start } = page({ absent: true });
  p.later(3000, () => { start.isConnected = true; });
  p.command({ cmd: 'voice', id: 'start' });
  await p.advance(5000);
  assert.equal(start.clicks, 1);
  assert.equal(result(p, 'start')?.data?.live, true);
});

for (const phase of ['findingButton', 'enteringVoice']) {
  test(`W217b Pod: stop while ${phase} takes effect immediately and invalidates start`, async () => {
    const { p, start, end, live } = page(phase === 'findingButton' ? { absent: true } : { liveDelay: 5000 });
    p.command({ cmd: 'voice', id: 'start' });
    await p.advance(1000);
    p.command({ cmd: 'voice', id: 'stop', stop: true });
    await p.advance(10);
    assert.equal(result(p, 'stop')?.ok, true);
    await p.advance(1000);
    assert.equal(result(p, 'start')?.ok, false);
    if (phase === 'findingButton') start.isConnected = true;
    await p.advance(6000);
    assert.equal(live(), false);
    assert.equal(start.clicks, phase === 'findingButton' ? 0 : 1);
    assert.equal(end.clicks, phase === 'findingButton' ? 0 : 1);
  });
}

for (const endLabel of ['結束語音模式', '结束语音', 'End voice mode']) {
  test(`W217 Pod: ${endLabel} reports live, then really stops`, async () => {
    const { p, end, live } = page({ endLabel });
    p.command({ cmd: 'voice', id: 'start' });
    await p.advance(5000);
    assert.equal(result(p, 'start')?.data?.live, true);
    p.command({ cmd: 'voiceState', id: 'state' });
    await p.advance(10);
    assert.equal(result(p, 'state')?.data?.live, true);
    p.command({ cmd: 'voice', id: 'stop', stop: true });
    await p.advance(10);
    assert.equal(end.clicks, 1);
    assert.equal(live(), false);
  });
}

test('W217 Pod: stop during navigation cancels the pending start before it can click', async () => {
  const { p, start, live } = page();
  p.command({ cmd: 'voice', id: 'start' });
  await p.advance(10); // openConversation is still waiting.
  p.command({ cmd: 'voice', id: 'stop', stop: true });
  await p.advance(5000);
  assert.equal(start.clicks, 0);
  assert.equal(live(), false);
  assert.equal(result(p, 'start')?.ok, false);
  assert.equal(result(p, 'stop')?.ok, true);
});

test('W217 Pod: stop guard also closes a late localized voice session', async () => {
  const { p, end, live } = page({ endLabel: '結束語音模式' });
  p.command({ cmd: 'voice', id: 'stop', stop: true });
  await p.advance(10);
  end.isConnected = true; // fake late permission reply.
  await p.advance(1100);
  assert.equal(end.clicks, 1);
  assert.equal(live(), false);
});
