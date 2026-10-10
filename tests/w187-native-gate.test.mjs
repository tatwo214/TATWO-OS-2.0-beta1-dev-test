import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, existsSync, statSync, unlinkSync, symlinkSync, mkdirSync, copyFileSync, chmodSync } from 'node:fs';
import { spawn, execFileSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { once } from 'node:events';
import net from 'node:net';
import { testScratch } from './helpers/test-scratch.mjs';
import { scanDurableWriterSites, computeDurableWriterFingerprint } from '../scripts/validate-tatwo-sync-catalog.mjs';

const helper = () => join(dirname(process.env.TATWO2_TEST_BINARY), 'TatwoFleetGate');
const source = path => readFileSync(path, 'utf8');

test('native fleet product and authorized command never depend on a script interpreter', () => {
  for (const path of ['App/Sources/Tatwo2/Facade/DeviceFleetGate.swift',
    'App/Sources/Tatwo2/Facade/DeviceRegistry.swift', 'App/Sources/Tatwo2/Facade/OSSocketCaller.swift',
    'App/Sources/TatwoFleetGate/main.swift']) {
    assert.doesNotMatch(source(path), /python3|fleet-gate\.py|\/usr\/bin\/(?:perl|ruby|osascript)/, path);
  }
  const native = source('App/Sources/TatwoFleetGate/main.swift');
  assert.deepEqual([...native.matchAll(/^import (\w+)$/gm)].map(m => m[1]), ['Darwin', 'Foundation']);
  assert.doesNotMatch(native, /Process\(|executableURL|policy\["socket"\]/);
  const manifest = source('Package.swift');
  assert.match(manifest, /let fleetGateTarget = "TatwoFleetGate"/);
  assert.match(manifest, /\.executableTarget\(name: fleetGateTarget, path: "App\/Sources\/TatwoFleetGate"\)/);
  assert.match(source('scripts/build-app.sh'), /--product TatwoFleetGate/);
  assert.match(source('scripts/build-app.sh'), /codesign[^\n]+\$CONTENTS\/Helpers\/TatwoFleetGate/);
  assert.match(source('scripts/package-release.sh'), /codesign --verify --strict[^\n]+Helpers\/TatwoFleetGate/);
  execFileSync('/bin/bash', ['-n', 'scripts/build-app.sh']);
  execFileSync('/bin/bash', ['-n', 'scripts/package-release.sh']);
  const reconcile = source('App/Sources/Tatwo2/Facade/DeviceRegistry.swift').split('func fleetReconcileKeys(')[1].split('\nextension DeviceRegistry')[0];
  assert.equal((reconcile.match(/Self\.writeAuthorizedLines\(/g) ?? []).length, 1, 'migration publishes the complete restricted file in one atomic write');
  const writer = source('App/Sources/Tatwo2/Facade/DeviceRegistry.swift').split('private static func writeAuthorizedLines(')[1].split('\n    }')[0];
  assert.equal((writer.match(/DeviceDispatchSafeFile\.write\(/g) ?? []).length, 1, 'shared lossless writer uses one atomic replacement');
  assert.match(writer, /Data\(lines\.joined\(\)\.utf8\)/);
});

test('native helper is Mach-O and links only macOS runtime libraries', () => {
  const magic = readFileSync(helper()).readUInt32LE(0);
  assert.equal(magic, 0xfeedfacf);
  const linkage = execFileSync('/usr/bin/otool', ['-L', helper()], { encoding: 'utf8' }).trim().split('\n').slice(1).join('\n');
  for (const line of linkage.split('\n')) {
    const library = line.trim().split(' ')[0];
    assert.ok(library.startsWith('/usr/lib/') || library.startsWith('/System/Library/'), library);
  }
  assert.doesNotMatch(linkage, /python|perl|ruby|osascript|CEF|AppKit|\.build|CommandLineTools|Xcode/i);
  console.log(linkage.trim());
});

test('native packaging reports exact writer snapshot delta for upstream review', () => {
  const discovery = JSON.parse(source('config/tatwo-durable-writer-discovery-v1.json'));
  const sites = scanDurableWriterSites(process.cwd(), discovery);
  const baseline = testScratch('w187-writer-baseline-');
  mkdirSync(join(baseline, 'scripts'));
  const paths = ['scripts/build-app.sh', 'scripts/package-release.sh'];
  // Compare W187's packaging changes against the exact mainline merged for W221.
  for (const path of paths) writeFileSync(join(baseline, path), execFileSync('/usr/bin/git', ['show', `bc42047e51a8a3b84b466725f87b5d1e82371a4e:${path}`]));
  const old = scanDurableWriterSites(baseline, { scanRoots: ['scripts'] });
  const key = ({ path, primitive, signature, occurrence }) => JSON.stringify({ path, primitive, signature, occurrence });
  const oldKeys = new Set(old.map(key));
  const added = sites.filter(site => paths.includes(site.path) && !oldKeys.has(key(site)));
  const currentKeys = new Set(sites.map(key));
  const removed = old.filter(site => !currentKeys.has(key(site)));
  assert.equal(removed.length, 0, 'no existing writer sites are obscured');
  assert.equal(added.length, 2);
  console.log('writer review additions: ' + JSON.stringify(added));
  console.log(`writer review candidate: count=${sites.length} fingerprint=${computeDurableWriterFingerprint(sites)}`);
});

test('native gate: fixed socket, live policy, bounded frames, registration and startup under 0.2s', { timeout: 30_000 }, async () => {
  const root = testScratch('w187-native-');
  const signedHelper = join(root, 'fleet-gate');
  copyFileSync(helper(), signedHelper); chmodSync(signedHelper, 0o700);
  execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', '--timestamp=none', signedHelper]);
  execFileSync('/usr/bin/codesign', ['--verify', '--strict', signedHelper]);
  const policyPath = join(root, 'fleet-gate-policy.json'), socketPath = join(root, 'os.sock');
  const policy = { socket: join(root, 'forbidden.sock'), controllers: { synthetic: { capabilities: ['files'] } }, methods: { allowed: 'files' } };
  const publish = value => writeFileSync(policyPath, JSON.stringify(value), { mode: 0o600 });
  publish(policy);
  const calls = [], starts = [], latency = [];
  const server = net.createServer(socket => {
    socket.once('data', bytes => {
      const request = JSON.parse(bytes);
      calls.push(request);
      if (request.benchmark) latency.push(Number(process.hrtime.bigint() - starts.shift()) / 1e6);
      socket.end(JSON.stringify({ id: request.id, ok: true, result: {} }) + '\n');
    });
  });
  server.listen(socketPath); await once(server, 'listening');
  function launch(command = 'tatwo-fleet-rpc', args = ['--device', 'synthetic', '--policy', policyPath]) {
    return spawn(signedHelper, args, { env: { PATH: '/nonexistent', HOME: root, SSH_ORIGINAL_COMMAND: command,
      TATWO2_OS_SOCKET: join(root, 'forbidden.sock'), PYTHONHOME: '/nonexistent' } });
  }
  async function run(frame, command, args) {
    const child = launch(command, args);
    let output = ''; child.stdout.on('data', data => { output += data; });
    child.stdin.on('error', () => {}); child.stdin.end(frame);
    const [status] = await once(child, 'exit');
    return { status, output };
  }
  let live;
  try {
    for (const command of ['sh', 'ssh -L 99:localhost:22', 'tatwo-fleet-rpc extra', '']) {
      assert.equal((await run('', command)).status, 126);
    }
    assert.equal((await run('', undefined, ['--device', 'unknown', '--policy', policyPath])).status, 126);
    assert.equal((await run('', undefined, ['--device', 'synthetic', '--policy', policyPath, '--socket', socketPath])).status, 126);
    assert.equal((await run('{broken}\n')).status, 126);
    assert.equal((await run('x'.repeat(1024 * 1024 + 1))).status, 126);
    assert.equal((await run('{"method":"allowed"}')).status, 126, 'unterminated frame is refused');
    const spoofed = await run(JSON.stringify({ id: 1, method: 'unlisted', device: 'owner', capabilities: ['files'] }) + '\n');
    assert.equal(JSON.parse(spoofed.output).error, 'fleet_gate_denied');
    assert.equal(calls.length, 0);
    for (let i = 0; i < 20; i++) {
      starts.push(process.hrtime.bigint());
      assert.equal((await run(JSON.stringify({ id: i, method: 'allowed', benchmark: true, socket: '/tmp/other.sock' }) + '\n')).status, 0);
    }
    assert.equal(latency.length, 20);
    const sorted = [...latency].sort((a, b) => a - b);
    console.log(`native gate spawn→first forwarded request: n=20 min=${sorted[0].toFixed(3)}ms median=${sorted[10].toFixed(3)}ms p95=${sorted[18].toFixed(3)}ms max=${sorted[19].toFixed(3)}ms`);
    assert.ok(sorted[19] < 200, 'every measured launch starts relaying within 0.2 seconds');
    live = launch();
    live.stdin.on('error', () => {});
    live.stdout.setEncoding('utf8');
    let pending = '';
    const lines = [];
    live.stdout.on('data', chunk => {
      pending += chunk;
      while (pending.includes('\n')) { const end = pending.indexOf('\n'); lines.push(JSON.parse(pending.slice(0, end))); pending = pending.slice(end + 1); }
    });
    async function request(value) {
      const before = lines.length;
      live.stdin.write(JSON.stringify(value) + '\n');
      const deadline = Date.now() + 3000;
      while (lines.length === before && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 5));
      assert.equal(lines.length, before + 1);
      return lines.at(-1);
    }
    assert.equal((await request({ id: 21, method: 'allowed' })).ok, true);
    const record = join(root, 'gate-sessions', `${live.pid}.json`);
    assert.deepEqual(JSON.parse(readFileSync(record)), { device: 'synthetic', pid: live.pid });
    assert.equal(statSync(record).mode & 0o777, 0o600);
    publish({ ...policy, controllers: {} });
    assert.equal((await request({ id: 22, method: 'allowed', device: 'owner' })).error, 'fleet_gate_denied');
    assert.equal(calls.length, 21, 'revocation reread stops an already running gate from forwarding');
    live.stdin.end(); assert.equal((await once(live, 'exit'))[0], 0);
    assert.equal(existsSync(record), false);
    publish(policy); unlinkSync(policyPath);
    assert.equal((await run('')).status, 126, 'missing policy fails closed');
    const other = join(root, 'other.json'); writeFileSync(other, JSON.stringify(policy), { mode: 0o600 });
    symlinkSync(other, policyPath);
    assert.equal((await run('')).status, 126, 'policy symlinks fail closed');
  } finally {
    if (live && live.exitCode === null) live.kill('SIGKILL');
    await new Promise(resolve => server.close(resolve));
  }
});
