import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {resolveBinary} from './helpers/app-binary.mjs';
import {testScratch} from './helpers/test-scratch.mjs';
const read = p => readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');

test('W195 wake regression uses the real TAP, Coder delivery, DM and Space with a hidden-sensitive fake Pod', () => {
  const source = read('Facade/W195WakeAcceptance.swift');
  assert.match(read('Facade/ChatGPTTapAcceptance.swift'), /await W195WakeAcceptance.run/);
  for (const label of ['W195-A', 'W195-B', 'W195-C', 'W195-D', 'W195-E', 'W195-F']) assert.ok(source.includes(label));
  assert.match(source, /while hidden/);
  assert.match(source, /elapsed >= \.seconds\(55\)/);
  assert.match(source, /ChatGPTConversationSession\(tap: tap\)/);
  assert.match(source, /ChatGPTSpaceModel\(testTap: tap\)/);
  assert.doesNotMatch(source, /ChatGPTTap\.shared|TapWebPod\(|https?:/);
});

// W199 10-03：使用者要求連線安靜，排隊保留 writing 回覆但不報啟動狀態；仍禁止追加系統列。
test('W195 queued wake remains a writing reply without a startup announcement or system message', {timeout: 480_000}, () => {
  const binary = resolveBinary();
  assert.ok(binary, 'native behavior checks require TATWO2_TEST_BINARY');
  const root = testScratch('w207-tap-'), env = {...process.env, TATWO_STAGING_ROOT: root, TATWO2_SELFTEST: 'w185tap'};
  const locations = {
    HOME: 'home', CFFIXED_USER_HOME: 'home', TATWO_STAGING_SCRATCH_HOME: 'home',
    TATWO2_LIVE_ROOT: 'live', TATWO2_ENGINES_ROOT: 'engines',
    CODEX_HOME: 'engines/codex', TATWO2_CODEX_SOURCE_HOME: 'engines/codex',
    CLAUDE_CONFIG_DIR: 'engines/claude', CLAUDE_SECURESTORAGE_CONFIG_DIR: 'engines/claude',
    TATWO2_OS_ROOT: 'os', TATWO2_DOCS_ROOT: 'docs', TATWO2_SELFTEST_ARTIFACTS: 'artifacts',
  };
  for (const [key, folder] of Object.entries(locations)) { env[key] = path.join(root, folder); fs.mkdirSync(env[key], {recursive: true}); }
  for (const [key, file] of Object.entries({TATWO2_OS_SOCKET: 'o.sock', TATWO2_BROWSER_SOCKET: 'b.sock',
    TATWO2_OS_UPSTREAM_PATH: 'os/os.md', TATWO2_SKILLET_PATH: 'os/skillet.md'})) env[key] = path.join(root, file);
  for (const key of Object.keys(env)) if (/(API_KEY|ACCESS_TOKEN|REFRESH_TOKEN|SECRET|PASSWORD)$/.test(key)) delete env[key];
  const result = spawnSync(binary, [], {env, encoding: 'utf8', timeout: 450_000, maxBuffer: 8 * 1024 * 1024});
  fs.writeFileSync(path.join(root, 'selftest.log'), (result.stdout ?? '') + (result.stderr ?? ''));
  console.log(`native TAP behavior evidence: ${path.join(root, 'selftest.log')}`);
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /W185TAP SUMMARY failures=0 passed=\d+/);
});

test('W195 startup watchdog and send readiness share a 60 second budget', () => {
  const tap = read('TAP/ChatGPTTap.swift');
  assert.match(tap, /startupTimeout: Duration = \.seconds\(60\)/);
  assert.match(tap, /Task\.sleep\(for: (?:self\.)?startupTimeout\)/);
  assert.match(tap, /readinessWaiters > 0/);
});

test('W195 composer always offers Stop for a running TAP turn, including a newly typed command', () => {
  const composer = read('Chat/ChatPage+Composer.swift');
  assert.match(composer, /model\.isRunning && \([^\n]*model\.routeChoice\.runtimeAdapter == \.chatgptTap/);
});

test('W195 Coder keeps a background send lease through model and project preparation', () => {
  assert.match(read('Facade/ChatGPTTapTurnRunner.swift'), /acquireLease\(backgroundWork: true\)/);
  assert.match(read('TAP/ChatGPTTap.swift'), /backgroundWorkLeases\.isEmpty/);
});

test('W195 hides only the legacy TAP startup system row without rewriting stored history', () => {
  const engine = read('Facade/ChatLiveEngine.swift');
  const start = engine.indexOf('    func transcript(for', engine.indexOf('final class ChatLiveEngine'));
  const transcript = engine.slice(start, engine.indexOf('    func isRunning(', start));
  assert.match(transcript, /\.filter\s*\{/);
  assert.match(transcript, /\.role == \.system/);
  assert.match(transcript, /\.status == "info\|ChatGPT"/);
  assert.match(transcript, /\.text == "ChatGPT 啟動中，這句已排隊"/);
  assert.doesNotMatch(transcript, /removeAll|persist\(|store\.save/);
});
