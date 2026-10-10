import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync, readdirSync, statSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { testScratch } from './helpers/test-scratch.mjs';

const app = () => readFileSync('App/Sources/Tatwo2/Tatwo2App.swift', 'utf8');
const roster = () => readFileSync('App/Sources/Tatwo2/Facade/DeviceFleetRoster.swift', 'utf8');
test('upgrade check executes before every launch hook and its transitive source contains no write operation', () => {
  assert.match(app(), /TATWO2_FLEET_UPGRADE_CHECK/);
  assert.ok(app().indexOf('DeviceFleetStore.upgradeCheck') < app().indexOf('StagingBrowserLoopbackPolicy.runtimeEnvironment'));
  const body = roster().split('static func upgradeCheck')[1]?.split('\n    func ')[0];
  assert.ok(body, 'read-only check implementation required');
  assert.doesNotMatch(body, /\.write\(|\.save\(|\.audit\(|\.accept\(|\.verified\(|createDirectory|\.run\(|chmod|bootstrapPrimary|synchronize/);
  const noWrites = /\.write\(|\.save\(|\.audit\(|createDirectory|removeItem|chmod|O_WRONLY|O_RDWR|O_CREAT|\.run\(/;
  function method(file, signature) {
    const source = readFileSync('App/Sources/Tatwo2/Facade/' + file + '.swift', 'utf8');
    const text = file === 'DeviceRegistry' ? source.slice(source.indexOf('final class DeviceRegistry:')) : source;
    const start = text.indexOf(signature); assert.ok(start >= 0, signature);
    const opening = text.indexOf('{', start); let depth = 1, end = opening + 1;
    while (depth && end < text.length) { const c = text[end++]; if (c === '{') depth++; if (c === '}') depth--; }
    assert.equal(depth, 0, signature);
    assert.doesNotMatch(text.slice(opening, end), noWrites, file + '.' + signature);
  }
  // All filesystem-facing callees used by the entry: constructors, local identity,
  // registry classification, fingerprint calculation and the bounded O_RDONLY reader.
  for (const [file, signatures] of [
    ['TatwoEntry', ['    init(']],
    ['DeviceIdentity', ['static func readLocal(', 'private static func checkFile(', 'static func decode(', 'func validated()']],
    ['DeviceRegistry', ['    init(', 'func list()', 'private func readUnlocked()', 'private func classifiedLegacyFingerprints(',
      'private static func authorizedFingerprintsByDevice(', 'private static func knownHostFingerprints(',
      'private static func readLines(', 'static func fingerprint(publicKey:', 'private static func normalizedPublicKey(',
      'private static func fingerprint(forNormalizedPublicKey', 'func fleetHasAuthorizedFingerprint(', 'func fleetHostPublicKey(']],
    ['DeviceFleetRoster', ['init(registry:', 'func read() throws -> State', 'static func read(_ url: URL, limit: Int)']],
  ]) for (const signature of signatures) method(file, signature);

});

function snapshot(root) {
  const result = {};
  function walk(dir) {
    for (const name of readdirSync(dir)) {
      const path = join(dir, name), stat = statSync(path);
      result[path.slice(root.length)] = stat.isDirectory() ? 'directory' : [stat.mtimeMs, readFileSync(path).toString('base64')];
      if (stat.isDirectory()) walk(path);
    }
  }
  walk(root); return result;
}
for (const shape of ['mini', 'book', 'Studio-pinned', 'Studio-client-only', 'Studio-unpinned', 'clock', 'unknown', 'missing-live']) {
  test(`upgrade check ${shape}: exact private output and no fixture writes`, { timeout: 20_000 }, () => {
    // Keep an old binary from falling through into normal App startup during the red test.
    assert.match(app(), /TATWO2_FLEET_UPGRADE_CHECK/);
    assert.ok(process.env.TATWO2_TEST_BINARY);
    const root = testScratch('w221c-check-'), os = join(root, 'os'), live = join(root, 'live');
    mkdirSync(os); if (shape !== 'missing-live') mkdirSync(live); mkdirSync(join(root, 'home'));
    const privateName = ['PRIVATE', 'NAME'].join('_'), privateHost = ['PRIVATE', 'HOST'].join('_'), privateUser = ['PRIVATE', 'USER'].join('_');
    const mini = '11111111-1111-4111-8111-111111111111', local = shape === 'mini' ? mini : '22222222-2222-4222-8222-222222222222';
    const fingerprint = blob => 'SHA256:' + createHash('sha256').update(Buffer.from(blob, 'base64')).digest('base64').replace(/=/g, '');
    const now = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'), date = shape === 'clock' ? new Date(Date.now() + 600_000).toISOString().replace(/\.\d{3}Z$/, 'Z') : now;
    if (shape !== 'unknown') writeFileSync(join(os, 'device.json'), JSON.stringify({ schema: 'tatwo.device-identity.v1',
      deviceID: local, name: privateName, hardwareModel: 'fixture', role: shape === 'mini' ? 'primary' : 'secondary',
      epoch: 1, primaryDeviceID: mini, updatedAt: date, preferences: { allowsRemoteWork: false, energy: '平衡', updateChannel: 'stable' },
      resources: {}, boundaries: [], managedEngines: [] }));
    const pinned = shape === 'Studio-pinned' || shape === 'Studio-client-only' || shape === 'clock';
    if (shape !== 'missing-live') writeFileSync(join(live, 'devices.json'), JSON.stringify(shape === 'mini' ? [] : [{ id: mini, name: privateHost, host: '192.0.2.1',
      user: privateUser, sshPort: 22, publicKeyFingerprint: fingerprint('AQID'), addedAt: now, lastSeenAt: now, workdirMap: {},
      endpoints: [{ kind: 'lan', host: '192.0.2.1', port: 22 }], ...(shape === 'Studio-client-only' ? {} : { hostKeyFingerprint: fingerprint('AQID') }),
      ...(pinned ? { clientKeyFingerprint: fingerprint('BAUG') } : {}) }]));
    writeFileSync(join(root, 'known'), shape === 'book' ? '192.0.2.1 ssh-ed25519 AQID\n' : '');
    writeFileSync(join(root, 'authorized'), pinned ? 'ssh-ed25519 BAUG tatwo2-device:' + mini + '\nssh-ed25519 BAUG manual\r\n# ssh-ed25519 BAUG comment\ncommand="echo ssh-ed25519 BAUG" ssh-ed25519 AQID other\n' : '');
    writeFileSync(join(root, 'key.pub'), 'ssh-ed25519 BwgJ fixture\n');
    writeFileSync(join(root, 'host.pub'), 'ssh-ed25519 CgsM fixture\n');
    const before = snapshot(root);
    const run = spawnSync(process.env.TATWO2_TEST_BINARY, [], { env: { PATH: process.env.PATH, HOME: join(root, 'home'), CFFIXED_USER_HOME: join(root, 'home'),
      TATWO2_FLEET_UPGRADE_CHECK: '1', TATWO_OS_ROOT: os, TATWO2_LIVE_ROOT: live,
      TATWO2_AUTHORIZED_KEYS: join(root, 'authorized'), TATWO2_SSH_KNOWN_HOSTS: join(root, 'known'),
      TATWO2_SSH_KEY_PATH: join(root, 'key'), TATWO2_SSH_HOST_KEY_PUB: join(root, 'host.pub') }, encoding: 'utf8', timeout: 15_000 });
    assert.equal(run.status, 0, run.stdout + run.stderr);
    const output = JSON.parse(run.stdout);
    assert.deepEqual(Object.keys(output).sort(), ['automatic', 'clock', 'reason', 'role', 'unmarked_device_key_lines']);
    assert.equal(output.unmarked_device_key_lines, pinned ? 2 : 0);
    assert.equal(run.stderr, '');
    assert.equal(output.role, shape === 'mini' ? 'primary' : shape === 'unknown' ? 'unknown' : 'secondary');
    assert.equal(output.automatic, !['Studio-unpinned', 'unknown', 'missing-live'].includes(shape));
    assert.equal(output.reason, ['Studio-unpinned', 'missing-live'].includes(shape) ? 'fleet_legacy_repair_required' : shape === 'unknown' ? 'identity_unavailable' : 'none');
    assert.equal(output.clock, shape === 'clock' ? 'adjust' : 'check_automatic_time');
    assert.doesNotMatch(run.stdout + run.stderr, /PRIVATE|192\.0\.2|SHA256|ssh-ed25519|BAUG|AQID/);
    assert.deepEqual(snapshot(root), before);
    console.log(shape + ' ' + run.stdout.trim());
  });
}
