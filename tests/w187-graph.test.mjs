import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';

test('W187a2 v2 graph: eight exact key/capability sets, signed changes, locked directions, private SUB view and v1 migration',
  { timeout: 240_000 }, () => {
    assert.ok(process.env.TATWO2_TEST_BINARY, 'current room binary required; never skip');
    const root = testScratch('w187-graph-');
    mkdirSync(join(root, 'home'));
    writeFileSync(join(root, 'owned-fixture'), 'fixture only\n');
    const result = spawnSync(process.env.TATWO2_TEST_BINARY, [], {
      env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR,
        HOME: join(root, 'home'), CFFIXED_USER_HOME: join(root, 'home'),
        TATWO2_SELFTEST: 'w187fleet', TATWO2_W187_TEST_ROOT: root, TATWO2_W187_GRAPH: '1',
        TATWO_OS_ROOT: join(root, 'unused-entry'), TATWO2_LIVE_ROOT: join(root, 'unused-live'),
        TATWO2_AUTHORIZED_KEYS: join(root, 'unused-authorized'), TATWO2_SSH_KNOWN_HOSTS: join(root, 'unused-known'),
        TATWO2_SSH_KEY_PATH: join(root, 'unused-key'), TATWO2_SSH_HOST_KEY_PUB: join(root, 'unused-host.pub'),
        GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' },
      encoding: 'utf8', timeout: 220_000, maxBuffer: 4 * 1024 * 1024,
    });
    const output = result.stdout + result.stderr;
    writeFileSync(join(root, 'w187graph.log'), output);
    assert.equal(result.status, 0, output);
    assert.match(output, /W187GRAPH SUMMARY checks=\d+ failures=0/);
    for (let i = 0; i < 8; i++) assert.ok(output.includes(`W187GRAPH PASS default-device-${i}-exact-grants`));
    for (const label of ['memory-off-refused-production-ssh-gate', 'files-on-allowed-production-ssh-gate',
      'memory-on-after-local-confirmed-signature', 'sub-to-main-entire-roster-refused',
      'sub-primary-signed-roster-refused', 'sub-transfer-proposal-refused', 'sandbox-cannot-be-enrolled-in-main',
      'hidden-main-no-name-address-id-role-version', 'show-main-opt-in-projection',
      'transfer-confirm-remains-not-ready', 'v1-read-migrates-groups-edges-no-repair',
      'v1-migration-never-widens-sub-peers', 'v1-write-is-v2-no-faction-format'])
      assert.ok(output.includes('W187GRAPH PASS ' + label), label);
    console.log(output.trim());
  });

test('SSH capability gate captures daemon identity before request bytes and intersects W178', () => {
  const source = readFileSync('App/Sources/Tatwo2/Facade/OSAgentBridge.swift', 'utf8');
  assert.ok(source.indexOf('let sshFingerprint = OSSocketCaller.sshFingerprint') < source.indexOf('let input = Self.readRequest(client)'));
  assert.ok(source.indexOf('!OSSocketCaller.sshMethodAllowed') < source.indexOf('guard Self.allows(caller: caller'));
  assert.match(source, /error": "fleet_capabilityDenied"/);
  const caller = readFileSync('App/Sources/Tatwo2/Facade/OSSocketCaller.swift', 'utf8');
  assert.match(caller, /guard let fingerprint else \{ return false \}/);
  assert.doesNotMatch(caller, /Process\(\)|write.*sshd_config/);
});
