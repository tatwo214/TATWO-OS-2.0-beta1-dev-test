import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';

test('W187a3: dual-signature primary rotation, interrupted four checkpoints and immediate revocation',
  { timeout: 240_000 }, () => {
    assert.ok(process.env.TATWO2_TEST_BINARY, 'current room binary required; never skip');
    const root = testScratch('w187-transfer-');
    mkdirSync(join(root, 'home'));
    writeFileSync(join(root, 'owned-fixture'), 'fixture only\n');
    const result = spawnSync(process.env.TATWO2_TEST_BINARY, [], {
      env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR,
        HOME: join(root, 'home'), CFFIXED_USER_HOME: join(root, 'home'),
        TATWO2_SELFTEST: 'w187fleet', TATWO2_W187_TEST_ROOT: root, TATWO2_W187_TRANSFER: '1',
        TATWO_OS_ROOT: join(root, 'unused-entry'), TATWO2_LIVE_ROOT: join(root, 'unused-live'),
        TATWO2_AUTHORIZED_KEYS: join(root, 'unused-authorized'), TATWO2_SSH_KNOWN_HOSTS: join(root, 'unused-known'),
        TATWO2_SSH_KEY_PATH: join(root, 'unused-key'), TATWO2_SSH_HOST_KEY_PUB: join(root, 'unused-host.pub'),
        GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' },
      encoding: 'utf8', timeout: 220_000, maxBuffer: 4 * 1024 * 1024,
    });
    const output = result.stdout + result.stderr;
    writeFileSync(join(root, 'w187transfer.log'), output);
    assert.equal(result.status, 0, output);
    assert.match(output, /W187TRANSFER SUMMARY checks=\d+ failures=0/);
    for (const label of ['SUB-target-refused', 'sandbox-target-refused', 'secondary-cannot-initiate',
      'no-local-UI-confirmation-refused', 'remote-Boolean-confirmation-refused', 'missing-handoff-signature-refused',
      'forged-handoff-signature-refused', 'new-primary-unsigned-roster-refused', 'wrong-new-primary-signature-refused', 'observer-requires-both-signatures',
      'unverified-owner-target-refused', 'offline-projection-rotates-before-later-roster',
      'completed-fleet-can-hand-back-with-fresh-dual-signatures',
      'old-epoch-handoff-replay-refused', 'four-checkpoints-complete', 'persistent-link-immediately-closed',
      'only-key-or-related-endpoint-sessions-terminated', 'revoked-link-cannot-reconnect',
      'new-link-to-revoked-peer-refused', 'already-queued-reconnect-never-launches',
      'missing-new-primary-projection-refused', 'ssh-call-immediately-refused-without-App-restart'])
      assert.ok(output.includes('W187TRANSFER PASS ' + label), label + '\n' + output);
    console.log(output.trim());
  });

 test('local confirmation action is not an RPC Boolean; revocation does not configure sshd', () => {
  const facade = name => readFileSync(join('App/Sources/Tatwo2/Facade', name + '.swift'), 'utf8');
  // The real transfer fixture above rejects missing physical confirmation through the production entry.
  assert.match(facade('DeviceDispatch'), /forLocalUI/);
  assert.match(facade('DeviceFleetRoster'), /Boolean from an assistant\/RPC is never local UI authority/);
  assert.doesNotMatch(facade('DeviceFleetRevocation'), /sshd_config|launchctl|systemsetup/);
  assert.match(facade('RemoteHostLink'), /cutOffImmediately/);
  assert.match(facade('RemoteHostLink'), /shutdown\(fd, SHUT_RDWR\)/);
});
