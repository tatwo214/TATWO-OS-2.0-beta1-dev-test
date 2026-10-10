import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { spawnSync } from 'node:child_process';

const cache = new Map();
export function nativeW298b(step = 1) {
  if (cache.has(step)) return cache.get(step);
  const binary = process.env.TATWO2_TEST_BINARY ?? resolve('.build/debug/Tatwo2');
  assert.ok(existsSync(binary), 'build Tatwo2 with verify.sh before native UI tests');
  const parent = join(homedir(), 'tatwo-build/tmp');
  mkdirSync(parent, { recursive: true });
  const root = mkdtempSync(join(parent, 'w298b-node-'));
  for (const dir of ['home', 'live', 'engines/codex', 'engines/claude', 'os', 'docs', 'artifacts']) mkdirSync(join(root, dir), { recursive: true });
  const isolated = {
    ...process.env, HOME: join(root, 'home'), CFFIXED_USER_HOME: join(root, 'home'),
    TATWO_STAGING_SCRATCH_HOME: join(root, 'home'), TATWO_STAGING_ROOT: root,
    TATWO2_LIVE_ROOT: join(root, 'live'), TATWO2_ENGINES_ROOT: join(root, 'engines'),
    CODEX_HOME: join(root, 'engines/codex'), TATWO2_CODEX_SOURCE_HOME: join(root, 'engines/codex'),
    CLAUDE_CONFIG_DIR: join(root, 'engines/claude'), CLAUDE_SECURESTORAGE_CONFIG_DIR: join(root, 'engines/claude'),
    TATWO2_OS_SOCKET: join(root, 'o.sock'), TATWO2_BROWSER_SOCKET: join(root, 'b.sock'),
    TATWO2_OS_ROOT: join(root, 'os'), TATWO2_DOCS_ROOT: join(root, 'docs'),
    TATWO2_OS_UPSTREAM_PATH: join(root, 'os/os-upstream.md'), TATWO2_SKILLET_PATH: join(root, 'os/skillet.md'),
    TATWO2_SELFTEST: 'w298b', TATWO2_SELFTEST_ARTIFACTS: join(root, 'artifacts'),
  };
  const run = spawnSync(binary, [], { env: isolated, encoding: 'utf8', timeout: 120_000, maxBuffer: 4 * 1024 * 1024 });
  const output = run.stdout + run.stderr;
  assert.equal(run.status, 0, output);
  assert.match(output, /W298B SUMMARY failures=0 passed=[1-9]/);
  cache.set(step, output);
  return output;
}
