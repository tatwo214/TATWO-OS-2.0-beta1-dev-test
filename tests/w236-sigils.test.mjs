import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { testScratch } from './helpers/test-scratch.mjs';

test('W236 sigils and three-party Coder UI isolated acceptance', { timeout: 300_000 }, () => {
  const binary = process.env.TATWO2_TEST_BINARY ?? path.resolve('.build/debug/Tatwo2');
  assert.ok(fs.existsSync(binary), 'build Tatwo2 before native acceptance');
  const root = testScratch('w236-sigils-');
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
    TATWO2_SELFTEST: 'w236sigils', TATWO2_SELFTEST_ARTIFACTS: at('artifacts'),
  };
  const result = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 290_000, maxBuffer: 4 * 1024 * 1024 });
  const output = (result.stdout ?? '') + (result.stderr ?? '');
  fs.writeFileSync(at('acceptance.log'), output);
  assert.equal(result.error, undefined, output);
  assert.equal(result.status, 0, output);
  assert.match(output, /SUMMARY[^\n]*failures=0/);
  assert.doesNotMatch(output, /\bFAIL\b/);
});
