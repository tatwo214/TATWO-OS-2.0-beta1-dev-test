import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { resolveBinary } from './helpers/app-binary.mjs';
import { testScratch } from './helpers/test-scratch.mjs';

test('W210 native regressions and twenty measured reconnect rows retain isolated UI evidence', () => {
  const binary = resolveBinary();
  assert.ok(binary, 'build the App first or set TATWO2_TEST_BINARY');
  const root = testScratch('w210-native-');
  const at = (name) => path.join(root, name);
  for (const name of ['home', 'live', 'engines/codex', 'engines/claude', 'os', 'docs', 'artifacts']) {
    fs.mkdirSync(at(name), { recursive: true });
  }
  const node = at('node');
  fs.copyFileSync(process.execPath, node);
  fs.chmodSync(node, 0o700);
  const env = {
    ...process.env, HOME: at('home'), CFFIXED_USER_HOME: at('home'),
    TATWO_STAGING_SCRATCH_HOME: at('home'), TATWO_STAGING_ROOT: root,
    TATWO2_LIVE_ROOT: at('live'), TATWO2_ENGINES_ROOT: at('engines'),
    CODEX_HOME: at('engines/codex'), TATWO2_CODEX_SOURCE_HOME: at('engines/codex'),
    CLAUDE_CONFIG_DIR: at('engines/claude'), CLAUDE_SECURESTORAGE_CONFIG_DIR: at('engines/claude'),
    TATWO2_OS_SOCKET: at('o.sock'), TATWO2_BROWSER_SOCKET: at('b.sock'),
    TATWO2_OS_ROOT: at('os'), TATWO2_DOCS_ROOT: at('docs'),
    TATWO2_OS_UPSTREAM_PATH: at('os/os-upstream.md'), TATWO2_SKILLET_PATH: at('os/skillet.md'),
    TATWO2_SELFTEST: 'w208tap', TATWO2_SELFTEST_DARK: '0',
    TATWO2_SELFTEST_NODE: node, TATWO2_SELFTEST_ARTIFACTS: at('artifacts'),
  };
  const result = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 120000, maxBuffer: 16 * 1024 * 1024 });
  fs.writeFileSync(at('native.log'), (result.stdout ?? '') + (result.stderr ?? ''), { mode: 0o600 });
  console.log('W210 isolated artifacts:', at('artifacts'));
  assert.equal(result.status, 0, result.error?.message ?? result.stdout + result.stderr);
  const rows = fs.readFileSync(at('artifacts/w208-reconnect-metrics.tsv'), 'utf8').trim().split('\n');
  assert.equal(rows[0].split('\t').at(-1), 'connectors');
  assert.equal(rows.length, 21);
  assert.deepEqual(rows.slice(1).map((row) => Number(row.split('\t').at(-1))), Array(20).fill(1));
  for (const name of ['w210-cleanup-false.png', 'w210-cleanup-true.png']) {
    assert.ok(fs.statSync(at('artifacts/' + name)).size > 0);
  }
});
