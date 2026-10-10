import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';

test('W221c unmanaged keys survive production transfer, handback and revocation on five fixtures', { timeout: 240_000 }, () => {
  assert.ok(process.env.TATWO2_TEST_BINARY);
  const root = testScratch('w221c-transfer-');
  mkdirSync(join(root, 'home'));
  writeFileSync(join(root, 'owned-fixture'), 'synthetic only\n');
  const result = spawnSync(process.env.TATWO2_TEST_BINARY, [], {
    env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR,
      HOME: join(root, 'home'), CFFIXED_USER_HOME: join(root, 'home'),
      TATWO2_SELFTEST: 'w187fleet', TATWO2_W187_TRANSFER: '1', TATWO2_W221C_TRANSFER: '1', TATWO2_W187_TEST_ROOT: root,
      TATWO_OS_ROOT: join(root, 'unused-entry'), TATWO2_LIVE_ROOT: join(root, 'unused-live'),
      TATWO2_AUTHORIZED_KEYS: join(root, 'unused-authorized'), TATWO2_SSH_KNOWN_HOSTS: join(root, 'unused-known'),
      TATWO2_SSH_KEY_PATH: join(root, 'unused-key'), TATWO2_SSH_HOST_KEY_PUB: join(root, 'unused-host.pub'),
      GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' },
    encoding: 'utf8', timeout: 220_000, maxBuffer: 4 * 1024 * 1024,
  });
  const output = result.stdout + result.stderr;
  writeFileSync(join(root, 'test.log'), output);
  assert.equal(result.status, 0, output);
  assert.match(output, /W187TRANSFER SUMMARY checks=\d+ failures=0/);
  for (let index = 0; index < 5; index++) assert.ok(output.includes('W187TRANSFER PASS W221c-transfer-preserves-user-lines-' + index));
  console.log(output.trim());
});
