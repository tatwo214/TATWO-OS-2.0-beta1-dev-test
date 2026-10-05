import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const repo = fileURLToPath(new URL('../', import.meta.url));
const read = file => readFileSync(path.join(repo, 'App/Sources/Tatwo2', file), 'utf8');
const model = read('Facade/ChatPageModel.swift');
const selfTest = read('SelfTest.swift');
const checks = ['missing root starts empty', 'completed scan starts fresh cooldown',
  'source scan alone leaves model stale', 'dollar schedules stale scan', 'in-flight scans coalesce',
  'rescan publishes without another keystroke', 'fresh dollar does not rescan', 'changed manifest refreshes'];

test('skill scans publish on the main actor, before waiting for MCP, using one refresh path', () => {
  assert.match(model, /@Published private var pluginEntries:/);
  assert.match(model, /if activeSkillQuery != nil \{ reloadPluginRegistry\(ifOlderThan: 60\) \}/);
  const refresh = model.slice(model.indexOf('func reloadPluginRegistry('), model.indexOf('func isThreadPluginEnabled('));
  assert.match(refresh, /if let pluginRefreshTask \{ return pluginRefreshTask \}/);
  assert.match(refresh, /now\.timeIntervalSince\(lastPluginScanAt\) > age/);
  assert.match(refresh, /Task \{ @MainActor \[weak self\]/);
  assert.match(refresh, /PluginsSource\.scanNow[\s\S]*self\?\.pluginEntries = scanned[\s\S]*PluginsSource\.refreshNow[\s\S]*self\?\.pluginEntries = fresh/);
  // Cooldown begins after both scans finish, not at their potentially stale start time.
  assert.match(refresh, /self\?\.pluginEntries = fresh\s*self\?\.lastPluginScanAt = Date\(\)\s*self\?\.pluginRefreshTask = nil/);
  assert.doesNotMatch(refresh, /lastPluginScanAt = now\b/);
  assert.match(model.slice(model.indexOf('init(environment:'), model.indexOf('func reloadPluginRegistry(')), /reloadPluginRegistry\(\)/);
  assert.ok(read('Facade/PluginsSource.swift').includes('/Library/Application Support/tatwo2/skills'));
});

test('SelfTest covers late root creation, observation, cooldown and changed manifests', () => {
  assert.match(selfTest, /TATWO2_SKILLREFRESHTEST[\s\S]*try await skillRefreshChecks\(\)/);
  const fixture = selfTest.slice(selfTest.indexOf('    @MainActor private static func skillRefreshChecks()'),
    selfTest.indexOf('    /// W81 畫布基本界線'));
  for (const name of checks) assert.ok(fixture.includes(`check("${name}"`));
  assert.match(fixture, /await model\.reloadPluginRegistry\(\)\?\.value[\s\S]*Task\.sleep\(for: \.seconds\(61\)\)[\s\S]*model\.prompt = "\$"/);
  assert.doesNotMatch(fixture, /addingTimeInterval|reloadPluginRegistry\(now:/);
  assert.match(fixture, /pending != nil && model\.reloadPluginRegistry\(\) == pending/);
});

test('built Tatwo2 observes an isolated skills root appearing after the initial scan', {
  skip: process.platform !== 'darwin', timeout: 100_000,
}, () => {
  // Reuse the one acceptance build; never compile or touch real skills/auth here.
  const binary = process.env.TATWO2_TEST_BINARY || path.join(repo, '.build/debug/Tatwo2');
  assert.ok(path.isAbsolute(binary) && existsSync(binary),
    'Build current Tatwo2 or set an absolute TATWO2_TEST_BINARY from this source; never skip acceptance.');
  const root = realpathSync(mkdtempSync(path.join(tmpdir(), 'w15e-skills-')));
  const at = suffix => path.join(root, suffix);
  for (const dir of ['home', 'live', 'engines/codex', 'engines/claude', 'resources', 'tmp']) {
    mkdirSync(at(dir), { recursive: true });
  }
  const env = {
    PATH: '/usr/bin:/bin:/usr/sbin:/sbin', TMPDIR: at('tmp'),
    HOME: at('home'), CFFIXED_USER_HOME: at('home'),
    TATWO_STAGING_ROOT: root, TATWO_STAGING_SCRATCH_HOME: at('home'),
    TATWO2_LIVE_ROOT: at('live'), TATWO2_ENGINES_ROOT: at('engines'),
    CODEX_HOME: at('engines/codex'), TATWO2_CODEX_SOURCE_HOME: at('engines/codex'),
    CLAUDE_CONFIG_DIR: at('engines/claude'), CLAUDE_SECURESTORAGE_CONFIG_DIR: at('engines/claude'),
    TATWO2_OS_SOCKET: at('os.sock'), TATWO2_BROWSER_SOCKET: at('browser.sock'),
    TATWO2_OS_ROOT: at('os'), TATWO2_DOCS_ROOT: at('docs'),
    TATWO2_OS_UPSTREAM_PATH: at('os/os-upstream.md'), TATWO2_SKILLET_PATH: at('os/skillet.md'),
    TATWO2_APP_RESOURCES: at('resources'), TATWO2_SOURCETEST: '1', TATWO2_SKILLREFRESHTEST: '1',
  };
  const result = spawnSync(binary, [], {
    // Includes a real 61-second TTL after scan completion, plus the original probe budget.
    cwd: root, env, encoding: 'utf8', timeout: 95_000, maxBuffer: 4 * 1024 * 1024,
  });
  writeFileSync(at('selftest.log'), `${result.stdout ?? ''}${result.stderr ?? ''}`);
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  for (const name of checks) assert.ok(result.stdout.includes(`SKILLREFRESHTEST PASS ${name}`), name);
  assert.doesNotMatch(result.stdout, /SKILLREFRESHTEST FAIL/);
  assert.match(result.stdout, /SKILLREFRESHTEST RESULT failures=0/);
  console.log(result.stdout);
  console.log('SelfTest evidence:', root);
});
