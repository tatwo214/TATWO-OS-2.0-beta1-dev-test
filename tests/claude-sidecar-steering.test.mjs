import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { testScratch } from './helpers/test-scratch.mjs';

// Real sidecar, inert SDK. A file carries synthetic vendor events; no account,
// credentials, network, settings, or model calls are involved.
async function fixture(t, resume, pauseInputs = false) {
  const root = testScratch('claude-steering-');
  const sdk = path.join(root, 'node_modules/@anthropic-ai/claude-agent-sdk');
  await fs.mkdir(sdk, { recursive: true });
  await fs.writeFile(path.join(sdk, 'package.json'), JSON.stringify({ type: 'module', exports: './index.mjs' }));
  await fs.writeFile(path.join(sdk, 'index.mjs'), `
import fs from 'node:fs';
export function query({prompt, options}) {
  fs.writeFileSync(options.cwd+'/options', JSON.stringify({resume: options.resume, extraArgs: options.extraArgs}));
  let stopped = false, offset = 0;
  (async () => { for await (const m of prompt) {
    fs.appendFileSync(options.cwd+'/inputs', JSON.stringify(m)+'\\n');
    if (${pauseInputs}) await new Promise(() => {});
  } })();
  const q = (async function* () {
    while (!stopped) {
      const lines = fs.readFileSync(options.cwd+'/events','utf8').split('\\n').filter(Boolean);
      while (offset < lines.length) yield JSON.parse(lines[offset++]);
      await new Promise(r => setTimeout(r, 5));
    }
  })();
  q.interrupt = async () => { fs.writeFileSync(options.cwd+'/interrupted','yes'); await new Promise(r => setTimeout(r, 40)); };
  q.close = () => { stopped = true; fs.writeFileSync(options.cwd+'/closed','yes'); };
  return q;
}
`);
  await fs.writeFile(path.join(root, 'events'), '');
  const sidecar = path.join(root, 'claude-sidecar/sidecar.mjs');
  await fs.mkdir(path.dirname(sidecar));
  await fs.copyFile(new URL('../Engines/model-capabilities.mjs', import.meta.url), path.join(root, 'model-capabilities.mjs'));
  await fs.copyFile(new URL('../Engines/claude-sidecar/sidecar.mjs', import.meta.url), sidecar);
  const child = spawn(process.execPath, [sidecar, '--cwd', root, ...(resume ? ['--resume', resume] : [])], {
    env: { HOME: root, PATH: '/usr/bin:/bin' }, stdio: ['pipe', 'pipe', 'pipe'],
  });
  const events = []; let buffer = '', stderr = '';
  child.stdout.on('data', chunk => {
    buffer += chunk;
    while (buffer.includes('\n')) {
      const i = buffer.indexOf('\n');
      events.push(JSON.parse(buffer.slice(0, i))); buffer = buffer.slice(i + 1);
    }
  });
  child.stderr.on('data', chunk => { stderr += chunk; });
  t.after(() => { if (child.exitCode === null) child.kill(); });
  const until = async predicate => {
    for (let i = 0; i < 500; i++) {
      if (await predicate()) return;
      await new Promise(r => setTimeout(r, 10));
    }
    assert.fail(JSON.stringify(events) + stderr);
  };
  const inputs = async () => (await fs.readFile(path.join(root, 'inputs'), 'utf8').catch(() => ''))
    .trim().split('\n').filter(Boolean).map(JSON.parse);
  return { root, child, events, until, inputs,
    send: cmd => child.stdin.write(JSON.stringify(cmd) + '\n'),
    vendor: msg => fs.appendFile(path.join(root, 'events'), JSON.stringify(msg) + '\n'),
    messages: () => events.filter(e => e.ev === 'sdk').map(e => e.msg),
  };
}
const result = ids => ({ type: 'result', subtype: 'success', is_error: false, user_message_uuids: ids });
const replay = uuid => ({ type: 'user', isReplay: true, uuid, parent_tool_use_id: null, message: { content: 'fixture' } });

test('Claude confirms native receipt, preserves intermediate replies, and coalesces insertions', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  f.send({ op: 'send', uuid: 'turn', text: 'work' });
  f.send({ op: 'steer', uuid: 'insert-1', targetTurnUUID: 'turn', text: 'change' });
  await f.until(async () => (await f.inputs()).length === 2);
  assert.equal(f.messages().filter(m => m.subtype === 'steer_result').length, 0, 'writing stdin is not receipt');
  await f.vendor(replay('insert-1'));
  await f.until(() => f.messages().some(m => m.request_id === 'insert-1' && m.accepted));
  f.send({ op: 'steer', uuid: 'insert-2', targetTurnUUID: 'turn', text: 'also this' });
  f.send({ op: 'steer', uuid: 'insert-2', targetTurnUUID: 'turn', text: 'duplicate' });
  await f.until(async () => (await f.inputs()).length === 3);
  await f.vendor(result(['turn']));
  await f.until(() => f.messages().some(m => m.subtype === 'turn_continued'));
  assert.equal(f.messages().filter(m => m.type === 'result').length, 0);
  await f.vendor({ type: 'stream_event', user_message_uuids: ['insert-1', 'insert-2'],
    event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'follow-up reply' } } });
  await f.vendor(result(['insert-1', 'insert-2']));
  await f.until(() => f.messages().some(m => m.type === 'result'));
  assert.equal(f.messages().filter(m => m.type === 'result').length, 1);
  assert.equal(f.messages().find(m => m.type === 'stream_event').client_turn_id, 'turn');
  assert.equal(f.messages().filter(m => m.subtype === 'steer_result' && m.accepted).length, 2);
  assert.equal((await f.inputs()).filter(m => m.uuid === 'insert-2').length, 1);
  f.send({ op: 'steer', uuid: 'late', targetTurnUUID: 'turn', text: 'stale' });
  await f.until(() => f.messages().some(m => m.request_id === 'late' && m.accepted === false));
  f.send({ op: 'send', uuid: 'next', text: 'ordinary next turn' });
  await f.until(async () => (await f.inputs()).length === 4);
  await f.vendor(result(['turn'])); // A duplicate terminal frame cannot end the successor.
  await f.vendor(result(['next']));
  await f.until(() => f.messages().some(m => m.type === 'result' && m.client_turn_id === 'next'));
  assert.equal(f.messages().filter(m => m.type === 'result').length, 2);
});

test('Claude failure terminates waiting insertions and retains the vendor error', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  f.send({ op: 'send', uuid: 'turn', text: 'work' });
  f.send({ op: 'steer', uuid: 'insert', targetTurnUUID: 'turn', text: 'change' });
  await f.until(async () => (await f.inputs()).length === 2);
  const exited = once(f.child, 'exit');
  await f.vendor({ ...result(['turn']), is_error: true, result: 'fixture failure' });
  await exited;
  assert.equal(f.messages().find(m => m.type === 'result').result, 'fixture failure');
  assert.equal(f.messages().find(m => m.request_id === 'insert').unknown, true);
});

test('Claude one result may answer the original and every insertion together', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  f.send({ op: 'send', uuid: 'turn', text: 'work' });
  f.send({ op: 'steer', uuid: 'insert', targetTurnUUID: 'turn', text: 'change' });
  await f.until(async () => (await f.inputs()).length === 2);
  await f.vendor(result(['turn', 'insert']));
  await f.until(() => f.messages().some(m => m.type === 'result'));
  assert.equal(f.messages().find(m => m.request_id === 'insert').accepted, true);
  assert.equal(f.messages().filter(m => m.subtype === 'turn_continued').length, 0);
});

test('Claude attachment insertion and stop close queued work without claiming delivery', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  const image = path.join(f.root, 'fixture.png');
  await fs.writeFile(image, 'synthetic image');
  f.send({ op: 'send', uuid: 'turn', text: 'work' });
  f.send({ op: 'steer', uuid: 'image', targetTurnUUID: 'turn', text: '', attachments: [image] });
  await f.until(async () => (await f.inputs()).length === 2);
  assert.equal((await f.inputs())[1].message.content[0].type, 'image');
  const exited = once(f.child, 'exit');
  f.send({ op: 'interrupt' });
  const [code] = await exited;
  assert.equal(code, 0);
  assert.equal(await fs.readFile(path.join(f.root, 'closed'), 'utf8'), 'yes');
  const ack = f.messages().find(m => m.request_id === 'image');
  assert.equal(ack.accepted, false); assert.equal(ack.unknown, true);
  assert.equal(f.messages().filter(m => m.subtype === 'cancelled').length, 1);
  const resumed = await fixture(t, 'fixture-session');
  resumed.send({ op: 'send', uuid: 'retry', text: 'explicit resend' });
  await resumed.until(async () => (await resumed.inputs()).length === 1);
  assert.equal(JSON.parse(await fs.readFile(path.join(resumed.root, 'options'), 'utf8')).resume, 'fixture-session');
  await resumed.vendor(result(['retry']));
  await resumed.until(() => resumed.messages().some(m => m.type === 'result'));
  assert.deepEqual((await resumed.inputs()).map(m => m.uuid), ['retry'], 'restart must not replay the cancelled insertion');
});

test('Claude missing batch identifiers fails visibly instead of losing or replaying insertions', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  f.send({ op: 'send', uuid: 'turn', text: 'work' });
  f.send({ op: 'steer', uuid: 'insert', targetTurnUUID: 'turn', text: 'change' });
  await f.until(async () => (await f.inputs()).length === 2);
  const exited = once(f.child, 'exit');
  await f.vendor({ type: 'result', subtype: 'success', is_error: false });
  await exited;
  assert.equal(f.messages().find(m => m.type === 'result').is_error, true);
  assert.equal(f.messages().find(m => m.request_id === 'insert').unknown, true);
  assert.equal((await f.inputs()).length, 2);
});

test('Stop discards inputs still in the sidecar inbox and ignores sends during interrupt', { timeout: 10_000 }, async t => {
  const f = await fixture(t, undefined, true);
  f.send({ op: 'send', uuid: 'turn', text: 'work' });
  await f.until(async () => (await f.inputs()).length === 1);
  assert.deepEqual(JSON.parse(await fs.readFile(path.join(f.root, 'options'), 'utf8')).extraArgs,
    { 'replay-user-messages': null });
  f.send({ op: 'steer', uuid: 'queued', targetTurnUUID: 'turn', text: 'must not execute' });
  const exited = once(f.child, 'exit');
  f.send({ op: 'interrupt' });
  await f.until(async () => fs.access(path.join(f.root, 'interrupted')).then(() => true, () => false));
  f.send({ op: 'send', uuid: 'during-stop', text: 'must not execute' });
  f.send({ op: 'steer', uuid: 'late', targetTurnUUID: 'turn', text: 'must not execute' });
  await f.vendor(replay('queued'));
  await f.vendor(result(['turn', 'queued']));
  const [code] = await exited;
  assert.equal(code, 0);
  assert.deepEqual((await f.inputs()).map(m => m.uuid), ['turn']);
  assert.equal(f.messages().find(m => m.request_id === 'queued').unknown, true);
  assert.equal(f.messages().some(m => m.request_id === 'queued' && m.accepted), false);
  assert.equal(f.messages().filter(m => m.type === 'result').length, 1);
  assert.equal(f.messages().find(m => m.type === 'result').subtype, 'cancelled');
});

test('Singular UUID fallback confirms receipt and pending results keep the turn active', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  f.send({ op: 'send', uuid: 'turn', text: 'work' });
  f.send({ op: 'steer', uuid: 'insert', targetTurnUUID: 'turn', text: 'change' });
  await f.until(async () => (await f.inputs()).length === 2);
  await f.vendor({ type: 'result', is_error: false, user_message_uuid: 'turn', queued_turn_count: 1 });
  await f.until(() => f.messages().some(m => m.subtype === 'turn_continued'));
  await f.vendor({ type: 'result', is_error: false, user_message_uuid: 'insert', queued_turn_count: 0 });
  await f.until(() => f.messages().some(m => m.type === 'result'));
  assert.equal(f.messages().find(m => m.request_id === 'insert').accepted, true);
  assert.equal(f.messages().find(m => m.type === 'result').client_turn_id, 'turn');
});
