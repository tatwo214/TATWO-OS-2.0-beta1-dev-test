// Production App handlers, isolated fixture sidecars; run after swift build.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { testScratch } from './helpers/test-scratch.mjs';
const binary = fs.realpathSync('.build/debug/Tatwo2');
const root = testScratch('w286-app-');
for (const engine of ['claude', 'codex']) {
  for (const flag of ['CHATSTEERING', 'TURNLIFECYCLE']) {
    const dir = path.join(root, engine + '-' + flag);
    const paths = {
      HOME: 'home', CFFIXED_USER_HOME: 'home', TATWO_STAGING_SCRATCH_HOME: 'home',
      TATWO_STAGING_ROOT: '.', TATWO2_ISSUE_TEST_ROOT: '.',
      TATWO2_LIVE_ROOT: 'live', TATWO2_ENGINES_ROOT: 'engines',
      CODEX_HOME: 'engines/codex', TATWO2_CODEX_SOURCE_HOME: 'engines/codex',
      CLAUDE_CONFIG_DIR: 'engines/claude', CLAUDE_SECURESTORAGE_CONFIG_DIR: 'engines/claude',
      TATWO2_OS_ROOT: 'os', TATWO2_DOCS_ROOT: 'docs',
      TATWO2_OS_UPSTREAM_PATH: 'os/os.md', TATWO2_SKILLET_PATH: 'os/skillet.md',
      TATWO2_OS_SOCKET: 'os.sock', TATWO2_BROWSER_SOCKET: 'browser.sock',
    };
    for (const relative of ['home', 'live', 'engines/codex', 'engines/claude', 'os', 'docs']) {
      fs.mkdirSync(path.join(dir, relative), { recursive: true });
    }
    fs.writeFileSync(path.join(dir, 'fixture-only'), '');
    fs.writeFileSync(path.join(dir, 'os/os.md'), 'Fixture rules only.');
    fs.writeFileSync(path.join(dir, 'os/skillet.md'), 'Fixture skills only.');
    const env = { PATH: process.env.PATH, TMPDIR: dir,
      ...Object.fromEntries(Object.entries(paths).map(([key, relative]) => [key, path.join(dir, relative)])),
      ['TATWO2_' + flag + 'TEST']: '1', TATWO2_CHATSTEERING_ENGINE: engine,
    };
    const result = spawnSync(binary, [], { cwd: dir, env, encoding: 'utf8', timeout: 30_000 });
    fs.writeFileSync(path.join(dir, 'run.log'), result.stdout + result.stderr);
    assert.equal(result.status, 0, engine + ' ' + flag + ': ' + result.stdout + result.stderr);
    assert.match(result.stdout, /RESULT passed=\d+ failed=0 skipped=0/);
    console.log(engine, flag, result.stdout.match(/RESULT .*/)[0]);
  }
}
console.log('APP_ACCEPTANCE_EVIDENCE', root);
