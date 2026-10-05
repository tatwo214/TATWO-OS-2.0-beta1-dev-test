import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { testScratch } from './test-scratch.mjs';

export function runNativeW215(t, stage = 5) {
  if (process.platform !== 'darwin') return t.skip('native macOS UI required');
  const checkout = fileURLToPath(new URL('../..', import.meta.url));
  const binary = process.env.TATWO2_TEST_BINARY ?? path.resolve(checkout, '.build/debug/Tatwo2');
  assert.ok(fs.existsSync(binary), `Build native Tatwo2 first: ${binary}`);
  const root = fs.realpathSync(testScratch('w215-coder-'));
  for (const dir of ['home', 'live', 'engines/codex', 'engines/claude', 'os', 'docs', 'artifacts']) {
    fs.mkdirSync(path.join(root, dir), { recursive: true });
  }
  const env = {
    ...process.env, HOME: `${root}/home`, CFFIXED_USER_HOME: `${root}/home`,
    TATWO_STAGING_SCRATCH_HOME: `${root}/home`, TATWO_STAGING_ROOT: root,
    TATWO2_LIVE_ROOT: `${root}/live`, TATWO2_ENGINES_ROOT: `${root}/engines`,
    CODEX_HOME: `${root}/engines/codex`, TATWO2_CODEX_SOURCE_HOME: `${root}/engines/codex`,
    CLAUDE_CONFIG_DIR: `${root}/engines/claude`, CLAUDE_SECURESTORAGE_CONFIG_DIR: `${root}/engines/claude`,
    TATWO2_OS_SOCKET: `${root}/o.sock`, TATWO2_BROWSER_SOCKET: `${root}/b.sock`,
    TATWO2_OS_ROOT: `${root}/os`, TATWO2_DOCS_ROOT: `${root}/docs`,
    TATWO2_OS_UPSTREAM_PATH: `${root}/os/os-upstream.md`, TATWO2_SKILLET_PATH: `${root}/os/skillet.md`,
    W215_CHECK: String(stage), TATWO2_SELFTEST: 'w215', TATWO2_SELFTEST_DARK: '0',
    TATWO2_SELFTEST_ARTIFACTS: `${root}/artifacts`, TATWO2_SELFTEST_NODE: process.execPath,
  };
  const run = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 110_000, maxBuffer: 8 * 1024 * 1024 });
  const output = `${run.stdout ?? ''}${run.stderr ?? ''}`;
  fs.writeFileSync(`${root}/result.log`, output);
  console.log(`W215 native evidence: ${root}`);
  console.log(output.split('\n').filter(line => /W215 (FAIL|SUMMARY)/.test(line)).join('\n'));
  assert.equal(run.status, 0, output || String(run.error));
  assert.match(output, /W215 SUMMARY failures=0 passed=[1-9]\d*/);
  for (const name of [`w215-n${stage}-light.png`, `w215-n${stage}-dark.png`]) {
    const png = fs.readFileSync(`${root}/artifacts/${name}`);
    assert.deepEqual(png.subarray(0, 8), Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
    assert.ok(png.length > 10_000, `${name} must contain a rendered page`);
  }
  return output;
}
