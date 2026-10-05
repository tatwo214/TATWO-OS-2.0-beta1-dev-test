import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { execFile, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';

test('omnibox waits for a live holder to release without taking its lock (no compiler)', { timeout: 30_000 }, async t => {
  const repo = fileURLToPath(new URL('../', import.meta.url));
  const helper = readFileSync(path.join(repo, 'tests/helpers/omnibox-native-checks.mjs'), 'utf8');
  const waitSeconds = helper.match(/const acquired = run\('bash', \[lock, 'acquire', '--pid', String\(process.pid\), '--timeout', '(\d+)'\]\)/)?.[1];
  assert.equal(waitSeconds, '120');
  assert.match(helper, /timeout: 150_000/);

  const lock = path.join(repo, 'scripts/tatwo-build-lock.sh');
  const lockDir = path.join(testScratch('omnibox-lock-wait-'), 'lock');
  // Only this test's private lock; never inherit a shared token-file destination.
  const env = { ...process.env, TATWO_BUILD_LOCK_DIR: lockDir,
    TATWO_BUILD_LOCK_TOKEN_FILE: '', TATWO_BUILD_LOCK_TOKEN: '' };
  const tokenOf = stdout => stdout.match(/^token=([0-9a-f]+)$/m)?.[1];
  const run = args => {
    const result = spawnSync('/bin/bash', [lock, ...args], { env, encoding: 'utf8', timeout: 5000 });
    assert.equal(result.status, 0, result.stderr || String(result.error));
    return result.stdout;
  };
  const acquire = seconds => new Promise(resolve => {
    execFile('/bin/bash', [lock, 'acquire', '--pid', String(process.pid), '--timeout', seconds],
      { env, timeout: 20_000 }, (error, stdout, stderr) => resolve({ code: error?.code ?? 0, stdout, stderr }));
  });
  let holder = tokenOf(run(['acquire', '--pid', String(process.pid), '--timeout', '1']));
  assert.ok(holder);
  let waiter;
  t.after(async () => {
    try {
      if (holder) run(['release', '--token', holder]);
    } finally {
      const token = waiter && tokenOf((await waiter).stdout);
      if (token) run(['release', '--token', token]);
    }
    assert.equal(existsSync(lockDir), false);
  });
  const ownerHash = readFileSync(path.join(lockDir, 'owner.token.sha256'), 'utf8');
  let settled = false;
  waiter = acquire(waitSeconds).then(result => { settled = true; return result; });
  // The former one-second cap must fail against the same live holder.
  const oldCap = await acquire('1');
  assert.equal(oldCap.code, 1, oldCap.stderr);
  assert.match(oldCap.stderr, /acquire timeout after 1s; holder pid=\d+ alive=yes/);
  assert.equal(settled, false, 'new waiter must remain queued, not steal or time out');
  assert.equal(readFileSync(path.join(lockDir, 'owner.token.sha256'), 'utf8'), ownerHash);
  run(['release', '--token', holder]); // The live owner voluntarily releases.
  const oldToken = holder;
  holder = undefined;
  const acquired = await waiter;
  assert.equal(acquired.code, 0, acquired.stderr);
  assert.ok(tokenOf(acquired.stdout));
  assert.notEqual(tokenOf(acquired.stdout), oldToken);
  assert.notEqual(readFileSync(path.join(lockDir, 'owner.token.sha256'), 'utf8'), ownerHash);
});
