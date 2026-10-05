import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { once, EventEmitter } from 'node:events';
import vm from 'node:vm';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

const serverPath = fileURLToPath(new URL('../Engines/os-mcp/server.mjs', import.meta.url));
const caller = '00000000-0000-0000-0000-000000000198';
async function fixture(t, bound = caller, handler = request => request.params) {
  const root = fs.realpathSync(fs.mkdtempSync('/tmp/w198-mcp-'));
  const calls = [];
  const socketPath = path.join(root, 'o.sock');
  const server = net.createServer({ allowHalfOpen: true }, socket => {
    socket.setEncoding('utf8');
    let data = '';
    socket.on('data', chunk => { data += chunk; });
    socket.on('end', async () => {
      const request = JSON.parse(data);
      calls.push(request);
      const result = await handler(request);
      if (!socket.destroyed) socket.end(JSON.stringify({ id: request.id, ok: true, result }) + '\n');
    });
  });
  await new Promise(resolve => server.listen(socketPath, resolve));
  const env = { ...process.env, TATWO2_OS_SOCKET: socketPath };
  delete env.TATWO2_THREAD_ID;
  if (bound !== null) env.TATWO2_THREAD_ID = bound;
  const child = spawn(process.execPath, [serverPath], { env, stdio: ['pipe', 'pipe', 'pipe'] });
  const pending = new Map();
  let serial = 0;
  readline.createInterface({ input: child.stdout }).on('line', line => {
    const reply = JSON.parse(line);
    pending.get(reply.id)?.(reply);
    pending.delete(reply.id);
  });
  function rpc(method, params = {}) {
    const id = ++serial;
    return new Promise(resolve => {
      pending.set(id, resolve);
      child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    });
  }
  t.after(async () => {
    child.kill();
    await once(child, 'exit');
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(root, { recursive: true, force: true });
  });
  return { calls, rpc, call: (name, args = {}) => rpc('tools/call', { name, arguments: args }) };
}

test('W198 MCP declares native model, calling-room ticket, bounded wait and stop schema', async t => {
  const { rpc, call, calls } = await fixture(t);
  const { result } = await rpc('tools/list');
  const dispatch = result.tools.find(tool => tool.name === 'chatgpt_dispatch');
  const stop = result.tools.find(tool => tool.name === 'chatgpt_dispatch_stop');
  assert.ok(dispatch && stop);
  assert.deepEqual(dispatch.inputSchema.required, ['model', 'title']);
  assert.equal(dispatch.inputSchema.additionalProperties, false);
  assert.deepEqual(dispatch.inputSchema.properties.timeoutSeconds, { type: 'integer', minimum: 1, maximum: 1800, default: 600 });
  assert.deepEqual(stop.inputSchema.properties, {});
  assert.match(dispatch.description, /chatgpt-dispatch\/<dispatchID>\.md/);
  for (const args of [
    { text: 'Review fixture', model: 'native-fixture', title: 'Review' },
    { ticketPath: 'tickets/review.md', model: 'native-fixture', title: 'Review', projectID: caller, timeoutSeconds: 1800 },
  ]) {
    const reply = await call('chatgpt_dispatch', args);
    assert.ok(!reply.result.isError, JSON.stringify(reply));
    assert.deepEqual(calls.at(-1).params, { ...args, callerThreadID: caller });
  }
  assert.ok(!(await call('chatgpt_dispatch_stop')).result.isError);
  assert.deepEqual(calls.at(-1).params, { callerThreadID: caller });
});

test('W198 MCP rejects supplied identity and unknown keys before App socket', async t => {
  const { call, calls } = await fixture(t);
  const valid = { text: 'Review fixture', model: 'native-fixture', title: 'Review' };
  for (const key of ['callerThreadID', '_threadID', 'outputPath']) {
    assert.equal((await call('chatgpt_dispatch', { ...valid, [key]: caller })).result.isError, true);
    assert.equal((await call('chatgpt_dispatch_stop', { [key]: caller })).result.isError, true);
  }
  for (const args of [[], 1, 'ticket']) {
    for (const name of ['chatgpt_dispatch', 'chatgpt_dispatch_stop']) assert.equal((await call(name, args)).result.isError, true);
  }
  assert.equal(calls.length, 0);
});

test('W198 MCP forwards known fields unchanged for authoritative native validation', async t => {
  const { call, calls } = await fixture(t);
  for (const args of [{ text: '漢'.repeat(22000), model: 1, title: 'title\nspoof' },
    ...['not-a-number', -1, 1e100, { valueOf: 1, toString: 2 }].map(timeoutSeconds => ({ timeoutSeconds })),
    { text: 'Review', ticketPath: 'ticket.md', timeoutSeconds: true, title: '派'.repeat(200) }]) {
    const reply = await call('chatgpt_dispatch', args);
    assert.ok(!reply.result.isError, JSON.stringify(reply));
    assert.deepEqual(calls.at(-1).params, { ...args, callerThreadID: caller });
  }
});

test('W198 MCP requires startup-bound local thread for dispatch and stop', async t => {
  for (const identity of [null, 'invalid']) {
    const { call, calls } = await fixture(t, identity);
    for (const name of ['chatgpt_dispatch', 'chatgpt_dispatch_stop']) {
      const reply = await call(name, { text: 'Review', model: 'fixture', title: 'Review' });
      assert.equal(reply.result.isError, true);
      assert.match(reply.result.content[0].text, /caller_required/);
    }
    assert.equal(calls.length, 0);
  }
});

test('W198 stop is processed over the same MCP connection while dispatch waits', { timeout: 5000 }, async t => {
  let finish, started;
  const didStart = new Promise(resolve => { started = resolve; });
  const { call, calls } = await fixture(t, caller, request => {
    if (request.method === 'chatgpt_dispatch') {
      started();
      return new Promise(resolve => { finish = resolve; });
    }
    if (request.method === 'chatgpt_dispatch_stop') {
      finish({ status: 'failed', stopped: true, conversationID: 'fixture', replyPath: null });
      return { stopped: true };
    }
  });
  const waiting = call('chatgpt_dispatch', { text: 'Review', model: 'fixture', title: 'Review', timeoutSeconds: 60 });
  await didStart;
  const stopping = await call('chatgpt_dispatch_stop');
  const result = await waiting;
  assert.equal(JSON.parse(stopping.result.content[0].text).stopped, true);
  assert.equal(JSON.parse(result.result.content[0].text).stopped, true);
  assert.deepEqual(calls.map(row => row.method), ['chatgpt_dispatch', 'chatgpt_dispatch_stop']);
});

test('W198 dispatch waits beyond 45 seconds, returns its receipt, and times out at its own deadline', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const source = fs.readFileSync(serverPath, 'utf8');
  const appCall = source.slice(source.indexOf('function appCall('), source.indexOf('function textResult('));
  class Socket extends EventEmitter {
    destroyed = false;
    setEncoding() {}
    end() {}
    destroy() { this.destroyed = true; }
  }
  const sockets = [];
  const call = vm.runInNewContext(appCall + '\nappCall', {
    net: { createConnection() { const socket = new Socket(); sockets.push(socket); return socket; } },
    socketPath: '/fixture.sock', nextSocketID: 1, process: { env: { TATWO2_THREAD_ID: caller } },
    setTimeout, clearTimeout,
  });
  const pending = call('chatgpt_dispatch', { timeoutSeconds: 60 });
  const socket = sockets.at(-1);
  t.mock.timers.tick(46_000);
  assert.equal(socket.destroyed, false);
  socket.emit('data', JSON.stringify({ ok: true, result: { conversationID: 'fixture-long' } }) + '\n');
  socket.emit('close');
  assert.equal((await pending).conversationID, 'fixture-long');
  t.mock.timers.tick(29_000);
  assert.equal(socket.destroyed, false, 'receipt cancels its deadline');
  for (const [method, params, deadline] of [['status', {}, 45_000], ['chatgpt_dispatch', { timeoutSeconds: 60 }, 75_000], ['chatgpt_dispatch', {}, 615_000]]) {
    const failure = call(method, params);
    const expired = sockets.at(-1);
    t.mock.timers.tick(deadline - 1);
    assert.equal(expired.destroyed, false);
    t.mock.timers.tick(1);
    await assert.rejects(failure, /os_bridge_timeout/);
    assert.equal(expired.destroyed, true);
  }
});
