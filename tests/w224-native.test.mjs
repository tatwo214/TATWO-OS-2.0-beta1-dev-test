import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { testScratch } from './helpers/test-scratch.mjs';

test('W224 native fixtures: targeted navigation, cached catalog, shared memory actions and current build card', { timeout: 120_000 }, () => {
  const binary = process.env.TATWO2_TEST_BINARY ?? path.resolve('.build/debug/Tatwo2');
  assert.ok(fs.existsSync(binary), 'build Tatwo2 before native acceptance');
  const root = testScratch('w224-native-');
  for (const dir of ['home', 'live', 'engines/codex', 'engines/claude', 'os', 'docs', 'artifacts']) {
    fs.mkdirSync(path.join(root, dir), { recursive: true });
  }
  const at = name => path.join(root, name);
  const env = {
    ...process.env, HOME: at('home'), CFFIXED_USER_HOME: at('home'),
    TATWO_STAGING_SCRATCH_HOME: at('home'), TATWO_STAGING_ROOT: root,
    TATWO2_LIVE_ROOT: at('live'), TATWO2_ENGINES_ROOT: at('engines'),
    CODEX_HOME: at('engines/codex'), TATWO2_CODEX_SOURCE_HOME: at('engines/codex'),
    CLAUDE_CONFIG_DIR: at('engines/claude'), CLAUDE_SECURESTORAGE_CONFIG_DIR: at('engines/claude'),
    TATWO2_OS_SOCKET: at('o.sock'), TATWO2_BROWSER_SOCKET: at('b.sock'),
    TATWO2_OS_ROOT: at('os'), TATWO2_DOCS_ROOT: at('docs'),
    TATWO2_OS_UPSTREAM_PATH: at('os/os-upstream.md'), TATWO2_SKILLET_PATH: at('os/skillet.md'),
    TATWO2_SELFTEST: 'w224f', TATWO2_SELFTEST_DARK: '0', TATWO2_SELFTEST_ARTIFACTS: at('artifacts'),
  };
  const result = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 110_000, maxBuffer: 4 * 1024 * 1024 });
  const output = (result.stdout ?? '') + (result.stderr ?? '');
  fs.writeFileSync(at('acceptance.log'), output);
  console.log(`W224 evidence ${root}`);
  assert.equal(result.error, undefined, output);
  assert.equal(result.status, 0, output);
  assert.match(output, /W224 SUMMARY failures=0 passed=[1-9]/);
  for (const group of [1, 3, 4, 5]) assert.match(output, new RegExp(`W224 PASS ${group}\\.`));
  for (const name of ['w224-login-update-false.png', 'w224-login-cloudflare-true.png',
    'w224-projects-cached.png', 'w224-memory-true.png']) assert.ok(fs.statSync(at('artifacts/' + name)).size > 0);
});
