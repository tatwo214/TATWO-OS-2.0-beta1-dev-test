import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

test('W253 sandbox refuses five families, bypasses and stale proofs through the production handler', () => {
  const binary = process.env.TATWO2_TEST_BINARY ?? resolve('.build/debug/Tatwo2');
  assert.ok(existsSync(binary), 'run verify.sh to build Tatwo2');
  const parent = join(homedir(), 'tatwo-build/tmp');
  mkdirSync(parent, { recursive: true });
  const root = mkdtempSync(join(parent, 'w253-node-'));
  for (const dir of ['home', 'live', 'engines/codex', 'engines/claude', 'os', 'docs']) mkdirSync(join(root, dir), { recursive: true });
  const env = {
    ...process.env, HOME: join(root, 'home'), CFFIXED_USER_HOME: join(root, 'home'),
    TATWO_STAGING_SCRATCH_HOME: join(root, 'home'), TATWO_STAGING_ROOT: root,
    TATWO2_LIVE_ROOT: join(root, 'live'), TATWO2_ENGINES_ROOT: join(root, 'engines'),
    CODEX_HOME: join(root, 'engines/codex'), TATWO2_CODEX_SOURCE_HOME: join(root, 'engines/codex'),
    CLAUDE_CONFIG_DIR: join(root, 'engines/claude'), CLAUDE_SECURESTORAGE_CONFIG_DIR: join(root, 'engines/claude'),
    TATWO2_OS_SOCKET: join(root, 'o.sock'), TATWO2_BROWSER_SOCKET: join(root, 'b.sock'),
    TATWO2_OS_ROOT: join(root, 'os'), TATWO2_DOCS_ROOT: join(root, 'docs'),
    TATWO2_OS_UPSTREAM_PATH: join(root, 'os/os-upstream.md'), TATWO2_SKILLET_PATH: join(root, 'os/skillet.md'),
    TATWO2_SELFTEST: 'w253sandbox',
  };
  delete env.SSH_AUTH_SOCK;
  const run = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 120_000, maxBuffer: 4 * 1024 * 1024 });
  const output = run.stdout + run.stderr;
  assert.equal(run.status, 0, output);
  for (const family of ['memory', 'gbrain', 'dispatch', 'background', 'job-queue']) assert.match(output, new RegExp(`PASS ${family}-.*-denied`));
  for (const label of ['normal-owner-device-status', 'method-substitution-denied', 'replay-consumed-owner-proof-denied',
    'expired-valid-owner-envelope-denied', 'expired-sandbox-envelope-denied', 'old-owner-credential-after-sandbox-conversion-denied',
    'restart-reloads-sandbox-denial', 'revoked-old-key-removed', 'revoked-old-proof-denied']) assert.ok(output.includes(`PASS ${label}`), label);
  assert.match(output, /W253SANDBOX SUMMARY failures=0 passed=\d+/);
});
