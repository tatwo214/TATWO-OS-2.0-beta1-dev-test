import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';

let nativeOutput;
export function runNative() {
  if (nativeOutput !== undefined) return nativeOutput;
  assert.ok(process.env.TATWO2_TEST_BINARY, 'current room binary required; never skip');
  const root = testScratch('w221d-ack-'), home = join(root, 'home');
  mkdirSync(home);
  writeFileSync(join(root, 'owned-fixture'), 'synthetic only\n');
  const result = spawnSync(process.env.TATWO2_TEST_BINARY, [], {
    env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR, HOME: home, CFFIXED_USER_HOME: home,
      TATWO2_SELFTEST: 'w187fleet', TATWO2_W221C: 'ack', TATWO2_W187_TEST_ROOT: root,
      TATWO_OS_ROOT: join(root, 'unused-entry'), TATWO2_LIVE_ROOT: join(root, 'unused-live'),
      TATWO2_AUTHORIZED_KEYS: join(root, 'unused-authorized'), TATWO2_SSH_KNOWN_HOSTS: join(root, 'unused-known'),
      TATWO2_SSH_KEY_PATH: join(root, 'unused-key'), TATWO2_SSH_HOST_KEY_PUB: join(root, 'unused-host.pub'),
      SSH_AUTH_SOCK: join(root, 'absent-agent'), GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' },
    encoding: 'utf8', timeout: 120_000, maxBuffer: 4 * 1024 * 1024,
  });
  const output = result.stdout + result.stderr;
  writeFileSync(join(root, 'test.log'), output);
  assert.equal(result.status, 0, output);
  assert.match(output, /W221D ACK SUMMARY checks=12 failures=0/);
  nativeOutput = output;
  console.log(output.trim());
  return output;
}

test('W221d non-fleet legacy ACK preserves old unsplit pin and handoff guards', { timeout: 150_000 }, () => {
  const output = runNative();
  for (const label of ['legacy-no-fleet-no-explicit-client-pin', 'non-fleet-old-handoff-authenticates',
    'old-ack-ledger-still-required', 'non-fleet-replay', 'non-fleet-signature', 'non-fleet-unpinned-sender',
    'non-fleet-epoch', 'non-fleet-revoked-key', 'rejections-never-adopt-fleet']) {
    assert.ok(output.includes(`W221D ACK PASS ${label}`), output);
  }
});

test('W221d claimed phase differing from the verified decoded receipt is refused in both directions', () => {
  const output = runNative();
  for (const label of ['phase-mismatch-fleet', 'phase-mismatch-converged', 'missing-claimed-phase']) {
    assert.ok(output.includes(`W221D ACK PASS ${label}`), output);
  }
  const source = readFileSync('App/Sources/Tatwo2/Facade/DeviceDispatch.swift', 'utf8');
  const start = source.indexOf('    func authenticate(method:');
  const body = source.slice(start, source.indexOf('    private func authenticateController', start));
  const signatureCheck = body.indexOf('guard result.0 == 0');
  assert.ok(signatureCheck > body.indexOf('let legacyPhase: String?'));
  assert.ok(body.indexOf('try !fleet.methodAllowed') > signatureCheck);
  assert.ok(body.indexOf('throw Failure(reason: "stale_epoch_or_replayed_sequence")') > signatureCheck);
  assert.ok(body.indexOf('try consumeRPC') > signatureCheck);
  assert.match(body, /let receipt = try Self\.decode\(Receipt\.self, authenticated\)/);
  assert.doesNotMatch(source, /requireACKPhase/);
});
