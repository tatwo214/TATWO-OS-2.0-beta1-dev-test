// Run after building Tatwo2. All application state and engine homes are isolated.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { testScratch } from './helpers/test-scratch.mjs';
const binary = fs.realpathSync('.build/debug/Tatwo2');
const root = testScratch('pr-app-');
const paths = {
  HOME: 'home', CFFIXED_USER_HOME: 'home', TATWO_STAGING_SCRATCH_HOME: 'home',
  TATWO2_LIVE_ROOT: 'live', TATWO2_ENGINES_ROOT: 'engines',
  CODEX_HOME: 'engines/codex', TATWO2_CODEX_SOURCE_HOME: 'engines/codex',
  CLAUDE_CONFIG_DIR: 'engines/claude', CLAUDE_SECURESTORAGE_CONFIG_DIR: 'engines/claude',
  TATWO2_OS_ROOT: 'os', TATWO2_DOCS_ROOT: 'docs', TATWO2_OS_UPSTREAM_PATH: 'os/os.md',
  TATWO2_SKILLET_PATH: 'os/skillet.md', TATWO2_OS_SOCKET: 'os.sock', TATWO2_BROWSER_SOCKET: 'browser.sock',
};
for (const dir of ['home', 'live', 'engines/codex', 'engines/claude', 'os', 'docs']) {
  fs.mkdirSync(path.join(root, dir), { recursive: true });
}
fs.writeFileSync(path.join(root, 'os/os.md'), 'Fixture rules only.');
fs.writeFileSync(path.join(root, 'os/skillet.md'), 'Fixture skills only.');
const env = {
  PATH: process.env.PATH, TMPDIR: root, TATWO_STAGING_ROOT: root,
  TATWO2_PLANCANVASTEST: '1', TATWO2_PLAN_TEST_ROOT: path.join(root, 'live'),
  ...Object.fromEntries(Object.entries(paths).map(([key, value]) => [key, path.join(root, value)])),
};
const result = spawnSync(binary, [], { cwd: root, env, encoding: 'utf8', timeout: 60_000 });
fs.writeFileSync(path.join(root, 'result.log'), result.stdout + result.stderr);
assert.equal(result.status, 0, result.stdout + result.stderr);
assert.match(result.stdout, /PLANCANVASTEST RESULT failed=0/);
for (const check of ['pr dispatched plan releases context', 'pr exit survives reload',
  'pr reloaded exit releases context', 'pr interruption does not restore mode', 'pr legacy ready releases context']) {
  assert.ok(result.stdout.includes('PLANCANVASTEST PASS ' + check), check);
}
console.log(result.stdout.trim());
console.log('APP_ACCEPTANCE_EVIDENCE', root);
