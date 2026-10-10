import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, copyFileSync, chmodSync, mkdirSync, mkdtempSync } from 'node:fs';
import { execFileSync, spawn } from 'node:child_process';
import { join, dirname } from 'node:path';
import { once } from 'node:events';
import net from 'node:net';
import { testScratch } from './helpers/test-scratch.mjs';
const source = n => readFileSync(`App/Sources/Tatwo2/Facade/${n}.swift`, 'utf8');
const command = 'env SSH_ORIGINAL_COMMAND=tatwo-fleet-rpc "$HOME/Library/Application Support/tatwo2/bin/fleet-gate" --device synthetic --policy "$HOME/Library/Application Support/tatwo2/live/fleet-gate-policy.json"';
test('ROSTER-02 signed system messages use a channel compatible with both actual key rows', () => {
  const send = source('DeviceDispatch').split('private func send(')[1].split('var transportEnvironment')[0];
  assert.match(send, /DeviceFleetCapabilities.isFleetTransport\(method\)/);
  assert.match(source('DeviceFleetGate'), /ownerCompatibleCommand/);
});
for (const mode of ['restricted-row', 'unrestricted-row', 'anonymous-controller-row']) test(`ROSTER-02 native stdio transition: ${mode}`, { timeout: 30_000 }, async () => {
  const home = mkdtempSync('/tmp/w187h-channel-');
  assert.ok(join(home, 'Library/Application Support/tatwo2/live/os.sock').length < 104);
  const base = join(home, 'Library/Application Support/tatwo2');
  const root = join(base, 'live'); mkdirSync(root, { recursive: true }); mkdirSync(join(base, 'bin'));
  const helper = join(base, 'bin/fleet-gate');
  copyFileSync(join(dirname(process.env.TATWO2_TEST_BINARY), 'TatwoFleetGate'), helper); chmodSync(helper, 0o700);
  execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', '--timestamp=none', helper]);
  const policy = join(root, 'fleet-gate-policy.json');
  const controller = mode === 'anonymous-controller-row' ? 'controller_aaaaaaaa' : 'synthetic';
  writeFileSync(policy, JSON.stringify({ controllers: { [controller]: { capabilities: [] } }, methods: { dispatch_fetch: 'fleetTransport' } }), { mode: 0o600 });
  let forwarded = 0;
  const server = net.createServer(socket => socket.once('data', bytes => {
    const request = JSON.parse(bytes); forwarded++;
    assert.equal(request.method, 'dispatch_fetch');
    socket.end(JSON.stringify({ ok: true, result: { received: true } }) + '\n');
  }));
  server.listen(join(root, 'os.sock')); await once(server, 'listening');
  try {
    const env = { HOME: home, PATH: '/usr/bin:/bin', SSH_ORIGINAL_COMMAND: command };
    const child = mode !== 'unrestricted-row'
      ? spawn(helper, ['--device', controller, '--policy', policy], { env })
      : spawn('/bin/sh', ['-c', command], { env });
    let output = ''; child.stdout.on('data', bytes => { output += bytes; });
    child.stdin.on('error', () => {}); child.stdin.end(JSON.stringify({ method: 'dispatch_fetch', params: { signedFixture: true } }) + '\n');
    const [status] = await once(child, 'exit');
    assert.equal(status, 0, output); assert.equal(forwarded, 1);
    assert.equal(JSON.parse(output).ok, true);
  } finally { await new Promise(resolve => server.close(resolve)); }
});
