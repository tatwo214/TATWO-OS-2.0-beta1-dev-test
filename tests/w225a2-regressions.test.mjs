import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

test('project collision resolution has one owner shared by the returned name and default folder', () => {
  const read = name => fs.readFileSync(new URL('../App/Sources/Tatwo2/Facade/' + name, import.meta.url), 'utf8');
  const service = read('HandsService.swift'), engine = read('ChatLiveEngine.swift');
  const bodies = [service.slice(service.indexOf('func createProject('), service.indexOf('func readSession(')),
    engine.slice(engine.indexOf('func handsCreateProject('), engine.indexOf('func importTransferredThread('))];
  assert.equal(bodies.filter(body => /while[\s\S]*caseInsensitiveCompare/.test(body)).length, 1,
    'HandsService and ChatLiveEngine must not resolve the same name independently');
});

test('compiled W225a2 regressions use isolated fake conversations and project folders', {
  skip: !process.env.TATWO2_TEST_BINARY,
  timeout: 180_000,
}, () => {
  const base = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'w225a2-'));
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
  console.log(`W225a2 selftest evidence ${path.join(base, 'selftest.log')}`);
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /W225MCP SUMMARY passed=\d+ failures=0/);
  assert.doesNotMatch(result.stdout, /W225MCP FAIL/);
  for (const kind of ['bearer', 'base64', 'pem']) {
    for (const boundary of ['rows', 'pages']) assert.ok(result.stdout.includes(`PASS ${kind} trailing newline state across ${boundary}`));
  }
  for (const mode of ['existing', 'empty', 'populated', 'replacement']) {
    assert.ok(result.stdout.includes(`PASS ${mode} moved ancestor rejected with same error and no project`));
    assert.ok(result.stdout.includes(`PASS ${mode} cleanup removes only own empty directories and leaves no escaped child`));
  }
  assert.ok(result.stdout.includes('PASS case-insensitive suffix uses same published name and default folder'));
});
