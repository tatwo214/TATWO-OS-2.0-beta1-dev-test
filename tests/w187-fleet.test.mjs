import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';

test('W187 signed fleet: production pairing, offline enrollment, filtered one-way management, attacks and revocation',
  { timeout: 240_000 }, () => {
    assert.ok(process.env.TATWO2_TEST_BINARY, 'current room binary required; never skip');
    const root = testScratch('w187-fleet-');
    mkdirSync(join(root, 'home'));
    writeFileSync(join(root, 'owned-fixture'), 'synthetic only\n');
    const result = spawnSync(process.env.TATWO2_TEST_BINARY, [], {
      env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR,
        HOME: join(root, 'home'), CFFIXED_USER_HOME: join(root, 'home'),
        TATWO2_SELFTEST: 'w187fleet', TATWO2_W187_TEST_ROOT: root,
        TATWO_OS_ROOT: join(root, 'unused-entry'), TATWO2_LIVE_ROOT: join(root, 'unused-live'),
        TATWO2_AUTHORIZED_KEYS: join(root, 'unused-authorized'), TATWO2_SSH_KNOWN_HOSTS: join(root, 'unused-known'),
        TATWO2_SSH_KEY_PATH: join(root, 'unused-key'), TATWO2_SSH_HOST_KEY_PUB: join(root, 'unused-host.pub'),
        GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' },
      encoding: 'utf8', timeout: 220_000, maxBuffer: 4 * 1024 * 1024,
    });
    const output = result.stdout + result.stderr;
    writeFileSync(join(root, 'w187fleet.log'), output);
    assert.equal(result.status, 0, output);
    assert.match(output, /W187FLEET SUMMARY checks=\d+ failures=0/);
    for (const label of ['two-device-once-bidirectional-keys', 'offline-pending-primary',
      'managed-transfer-refused', 'sandbox-transfer-refused', 'owner-cannot-join-managed-host-key',
      'managed-self-signed-roster-refused', 'owner-in-other-fleet-refused', 'old-roster-replay-refused',
      'wrong-epoch-refused', 'revoke-B-removes-A-and-C-keys', 'revoke-M-clears-owner-keys',
      'fleet-transfer-stops-before-partial-epoch', 'fleet-resumed-transfer-cannot-commit-epoch',
      'legacy-mini-book-no-repairing']) {
      assert.ok(output.includes('W187FLEET PASS ' + label), label);
    }
    console.log(output.trim());
  });

test('W187 no UI rewrite; fleet extensions bind to existing HMAC and W78 transport', () => {
  const facade = name => readFileSync(join('App/Sources/Tatwo2/Facade', name + '.swift'), 'utf8');
  assert.match(facade('DevicePairingAuth'), /fleet\.map \{ \["fleet-v1", \$0\] \}/);
  assert.match(facade('DevicePairingHost'), /ttlSeconds: 300/);
  assert.match(facade('DevicePairingHost'), /TatwoDevicePairingCodeEngineV1\.consume/);
  assert.match(facade('DeviceDispatch'), /trust\.kind != \.owner \{ return \}/);
  assert.match(facade('DeviceFleetRoster'), /tatwo2-device-fleet/);
  assert.match(facade('HandsBuildEnvelope'), /DeviceSignature\.sign\(data, namespace: namespace/);
  assert.match(facade('OSSocketCaller'), /KERN_PROCARGS2/);
});
