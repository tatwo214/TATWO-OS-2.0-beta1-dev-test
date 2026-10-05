import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

test('compiled W225a3 regressions use isolated fake conversations and project folders', {
  skip: !process.env.TATWO2_TEST_BINARY,
  timeout: 180_000,
}, () => {
  const base = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'w225a3-'));
  const home = path.join(base, 'home'), live = path.join(base, 'live');
  const engines = path.join(base, 'engines'), entry = path.join(base, 'os');
  for (const dir of [home, live, entry, path.join(engines, 'codex'), path.join(engines, 'claude')]) fs.mkdirSync(dir, { recursive: true });
  const env = { ...process.env,
    HOME: home, CFFIXED_USER_HOME: home, TATWO_STAGING_ROOT: base, TATWO_STAGING_SCRATCH_HOME: home,
    TATWO2_LIVE_ROOT: live, TATWO2_ENGINES_ROOT: engines,
    CODEX_HOME: path.join(engines, 'codex'), TATWO2_CODEX_SOURCE_HOME: path.join(engines, 'codex'),
    CLAUDE_CONFIG_DIR: path.join(engines, 'claude'), CLAUDE_SECURESTORAGE_CONFIG_DIR: path.join(engines, 'claude'),
    TATWO2_OS_SOCKET: path.join(base, 'os.sock'), TATWO2_BROWSER_SOCKET: path.join(base, 'browser.sock'),
    TATWO2_OS_ROOT: entry, TATWO2_DOCS_ROOT: entry,
    TATWO2_OS_UPSTREAM_PATH: path.join(entry, 'os.md'), TATWO2_SKILLET_PATH: path.join(entry, 'skillet.md'),
    TATWO2_SELFTEST: 'w225mcp', TATWO2_SKIP_ENGINE_LOGIN: '1',
  };
  for (const key of Object.keys(env)) if (/(API_KEY|ACCESS_TOKEN|REFRESH_TOKEN|SECRET|PASSWORD)$/.test(key)) delete env[key];
  const supplied = process.env.TATWO2_TEST_BINARY;
  const binary = fs.existsSync(supplied) ? supplied : path.join(path.dirname(path.dirname(path.dirname(supplied))), 'debug', 'Tatwo2');
  const result = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 160_000, maxBuffer: 4 * 1024 * 1024 });
  fs.writeFileSync(path.join(base, 'selftest.log'), (result.stdout ?? '') + (result.stderr ?? ''));
  console.log(`W225a3 selftest evidence ${path.join(base, 'selftest.log')}`);
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /W225MCP SUMMARY passed=\d+ failures=0/);
  assert.doesNotMatch(result.stdout, /W225MCP FAIL/);
  for (const label of [
    'memory usage and derived system summaries withheld',
    'filtered pagination complete and ordinary system row retained',
    'hour quota blocks eleventh without record or folder batch 0',
    'idempotent retry uses no additional quota batch 0',
    'hourly quota recovers at one hour and failures use no quota',
    'day quota blocks thirty-first after hour recovery',
    'project quotas isolated between grants',
    'day quota recovers at twenty-four hours',
    'raw name controls rejected 0',
    'raw name controls rejected 8',
    'folder controls rejected 0',
    'folder controls rejected 7',
    'controls create no project record',
  ]) assert.ok(result.stdout.includes(`PASS W225a3 ${label}`), label);
});
