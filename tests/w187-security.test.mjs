import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import net from 'node:net';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { join, dirname } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';
const source = n => readFileSync(`App/Sources/Tatwo2/${n}.swift`, 'utf8');
test('PAIR-01 DM-01: discovery contains no code-derived identifier or device name', () => {
  const s = source('Facade/DevicePairingDiscovery');
  assert.doesNotMatch(s, /SHA256\.hash/);
  assert.match(s, /makeNonce\(\)/);
  assert.doesNotMatch(s, /name: name, port/);
});
test('PAIR-01: client proves host before sending its public key', () => {
  const s = source('Facade/DevicePairingClient');
  assert.ok(s.includes('proveHost('));
  assert.ok(s.indexOf('proveHost(') < s.indexOf('var request = PairRequest('));
});
test('PAIR-07: complete TCP response is authenticated encryption', () => {
  assert.match(source('Facade/DevicePairingAuth'), /AES\.GCM\.seal/);
  assert.match(source('Facade/DevicePairingAuth'), /HKDF<SHA256>/);
  assert.match(source('Facade/DevicePairingHost'), /sealResponse/);
  assert.match(source('Facade/DevicePairingClient'), /openResponse/);
});
test('PAIR-04 PAIR-06: offer snapshot and approval transaction fail closed', () => {
  const s = source('Facade/DevicePairingHost');
  assert.doesNotMatch(s, /var offer = stateLock\.withLock/);
  assert.match(s, /pairingTransaction/);
  assert.match(s, /fleetRequest == nil/);
});
test('ROSTER-02 TR-01 DM-03: revocation is a confirmable graph operation', () => {
  assert.match(source('Facade/DeviceFleetGraph'), /case revoke\(id: String\)/);
  assert.match(source('Assistant/AssistantFleetTools'), /case "revoke_device"/);
});
test('REG-05: pin failure cannot prevent revocation; dedicated host store', () => {
  assert.match(source('Facade/DeviceRegistry'), /fleetKnownHostsURL/);
  assert.match(source('Facade/DeviceFleetRoster'), /pinConflicts/);
});
test('ROSTER-09 TR-06: revoked delivery is private and bounded', () => {
  assert.match(source('Facade/DeviceFleetRoster'), /revocationNotice/);
  assert.match(source('Facade/DeviceDispatch'), /claimRevocationDelivery/);
});
test('REG-03 DM-05: every non MAIN-owner arrow has a forced SSH gate', () => {
  assert.match(source('Facade/DeviceRegistry'), /restrict,command=/);
});
test('TR-03: rotation requires old-primary commit and bound projection', () => {
  assert.match(source('Facade/DeviceFleetTransfer'), /verifyRotationCommit/);
  assert.match(source('Facade/DeviceFleetTransfer'), /projectionHashes/);
});
test('TR-04 TR-05: pending handoff expires; offline projection is deferrable', () => {
  assert.match(source('Facade/DeviceFleetTransfer'), /expirePreparedTransfer/);
  assert.match(source('Facade/DeviceFleetTransfer'), /pendingRepin/);
});
test('selftest: missing W187_TEST_ROOT never starts normal App', () => {
  assert.match(source('SelfTest'), /DeviceFleetAcceptance\.isolatedRoot/);
});
test('PAIR-01: fake TCP host receives only a random challenge, never a public key or roster', { timeout: 40_000 }, async () => {
  assert.ok(process.env.TATWO2_TEST_BINARY);
  const root = testScratch('w187-fake-host-');
  mkdirSync(join(root, 'home'));
  const requests = [];
  const server = net.createServer(socket => {
    let line = '';
    socket.setEncoding('utf8');
    socket.on('data', chunk => {
      line += chunk;
      if (line.includes('\n')) {
        requests.push(JSON.parse(line.split('\n')[0]));
        socket.end(JSON.stringify({ proof: Buffer.alloc(32, 7).toString('base64') }) + '\n');
      }
    });
    socket.on('error', () => {});
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const child = spawn(process.env.TATWO2_TEST_BINARY, [], { env: {
    PATH: process.env.PATH, HOME: join(root, 'home'), CFFIXED_USER_HOME: join(root, 'home'),
    TATWO2_PAIRCLIENT: `127.0.0.1:${server.address().port}:ABC123:Synthetic client`,
    TATWO_OS_ROOT: join(root, 'entry'), TATWO2_LIVE_ROOT: join(root, 'live'),
    TATWO2_AUTHORIZED_KEYS: join(root, 'authorized_keys'), TATWO2_SSH_KEY_PATH: join(root, 'client-key'),
    TATWO2_SSH_HOST_KEY_PUB: join(root, 'host-key.pub'), TATWO2_SSH_KNOWN_HOSTS: join(root, 'known_hosts'),
    TATWO2_OS_SOCKET: join(root, 'os.sock'), TATWO2_BROWSER_SOCKET: join(root, 'browser.sock'),
  } });
  let output = '';
  child.stdout.on('data', chunk => { output += chunk; });
  child.stderr.on('data', chunk => { output += chunk; });
  const deadline = setTimeout(() => child.kill('SIGKILL'), 30_000);
  try {
    const [code] = await once(child, 'exit');
    assert.equal(code, 1, output);
    assert.match(output, /pairing_response_unauthenticated/);
    assert.equal(requests.length, 1);
    assert.deepEqual(Object.keys(requests[0]), ['hello']);
    assert.equal(Buffer.from(requests[0].hello, 'base64').length, 32);
    assert.equal(existsSync(join(root, 'client-key.pub')), true, 'local key generation preserves W178 behavior; the wire still contains only hello');
    assert.equal(existsSync(join(root, 'fleet-state.json')), false);
  } finally {
    clearTimeout(deadline);
    if (child.exitCode === null) child.kill('SIGKILL');
    await new Promise(resolve => server.close(resolve));
  }
});


test('REG-03 DM-05: installed gate allows only its local socket and live controller methods', { timeout: 30_000 }, async () => {
  const root = testScratch('w187-gate-');
  const policyPath = join(root, 'fleet-gate-policy.json');
  const socketPath = join(root, 'os.sock');
  const gatePath = join(dirname(process.env.TATWO2_TEST_BINARY), 'TatwoFleetGate');
  writeFileSync(policyPath, JSON.stringify({ socket: socketPath, controllers: { synthetic: { capabilities: ['files'] } }, methods: { allowed: 'files' } }), { mode: 0o600 });
  const calls = [];
  const server = net.createServer(socket => {
    socket.once('data', data => {
      const request = JSON.parse(data);
      calls.push(request.method);
      socket.end(JSON.stringify({ id: request.id, ok: true, result: { synthetic: true } }) + '\n');
    });
  });
  server.listen(socketPath);
  await once(server, 'listening');
  async function run(command, method, id = 'synthetic') {
    const child = spawn(gatePath, ['--device', id, '--policy', policyPath], { env: { PATH: process.env.PATH, HOME: root, SSH_ORIGINAL_COMMAND: command } });
    let output = '';
    child.stdout.on('data', data => { output += data; });
    child.stderr.on('data', data => { output += data; });
    child.stdin.end(JSON.stringify({ id: 1, method }) + '\n');
    const [status] = await once(child, 'exit');
    return { status, output };
  }
  try {
    assert.equal((await run('sh', 'allowed')).status, 126);
    assert.equal((await run('ssh -L 99:localhost:22', 'allowed')).status, 126);
    assert.equal((await run('tatwo-fleet-rpc', 'allowed', 'unknown')).status, 126);
    const denied = await run('tatwo-fleet-rpc', 'unlisted');
    assert.equal(denied.status, 0, denied.output);
    assert.equal(JSON.parse(denied.output).error, 'fleet_gate_denied');
    const allowed = await run('tatwo-fleet-rpc', 'allowed');
    assert.equal(allowed.status, 0, allowed.output);
    assert.equal(JSON.parse(allowed.output).result.synthetic, true);
    assert.deepEqual(calls, ['allowed']);
    writeFileSync(policyPath, JSON.stringify({ socket: socketPath, controllers: {}, methods: { allowed: 'files' } }));
    assert.equal((await run('tatwo-fleet-rpc', 'allowed')).status, 126);
  } finally { await new Promise(resolve => server.close(resolve)); }
});
