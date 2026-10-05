import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { resolveBinary } from './helpers/app-binary.mjs';
import { testScratch } from './helpers/test-scratch.mjs';

test('W211 real bindings, fake DDC timing, keyboard default and isolated synchronization failures', () => {
  const binary = resolveBinary();
  assert.ok(binary && fs.existsSync(binary), 'W211 requires a built application; never skip acceptance');
  const root = testScratch('w211-behavior-');
  for (const folder of ['home', 'live', 'engines/codex', 'engines/claude', 'os', 'docs', 'artifacts']) {
    fs.mkdirSync(path.join(root, folder), { recursive: true });
  }
  const env = {
    ...process.env,
    HOME: path.join(root, 'home'), CFFIXED_USER_HOME: path.join(root, 'home'),
    TATWO_STAGING_SCRATCH_HOME: path.join(root, 'home'), TATWO_STAGING_ROOT: root,
    TATWO2_LIVE_ROOT: path.join(root, 'live'), TATWO2_ENGINES_ROOT: path.join(root, 'engines'),
    CODEX_HOME: path.join(root, 'engines/codex'), TATWO2_CODEX_SOURCE_HOME: path.join(root, 'engines/codex'),
    CLAUDE_CONFIG_DIR: path.join(root, 'engines/claude'),
    CLAUDE_SECURESTORAGE_CONFIG_DIR: path.join(root, 'engines/claude'),
    TATWO2_OS_SOCKET: path.join(root, 'o.sock'), TATWO2_BROWSER_SOCKET: path.join(root, 'b.sock'),
    TATWO2_OS_ROOT: path.join(root, 'os'), TATWO2_DOCS_ROOT: path.join(root, 'docs'),
    TATWO2_OS_UPSTREAM_PATH: path.join(root, 'os/os-upstream.md'),
    TATWO2_SKILLET_PATH: path.join(root, 'os/skillet.md'),
    TATWO2_SELFTEST: 'w211', TATWO2_SELFTEST_ARTIFACTS: path.join(root, 'artifacts'),
  };
  const result = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 60_000, maxBuffer: 4 * 1024 * 1024 });
  const output = (result.stdout ?? '') + (result.stderr ?? '');
  fs.writeFileSync(path.join(root, 'acceptance.log'), output);
  assert.equal(result.error, undefined, output);
  assert.equal(result.status, 0, output);
  for (const behavior of [
    'brightness binding immediate readback 35', 'volume binding immediate readback 70',
    'drag coalesces 20 updates into at most 6 writes', 'drag release always writes final value',
    'drag never writes stale value after final value', 'keyboard adjustment retains smooth steps',
    'unconfigured external adjustable display defaults keyboard on',
    'automatic keyboard default never writes user preference',
    'missing keyboard permission is only announced once across restart',
    'user disabled keyboard remains disabled after restart',
    'missing primary shows Chinese consistency status', 'missing paired key shows Chinese consistency status',
    'missing epoch shows Chinese consistency status',
    'unknown English system error is not displayed verbatim',
  ]) assert.ok(output.includes(`PASS ${behavior}`), `missing executed behavior: ${behavior}\n${output}`);
  assert.ok(output.includes('W211 SUMMARY failures=0'), output);
  assert.ok(output.includes('W211SYNC SUMMARY failures=0'), output);
});
