import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { resolveBinary } from './helpers/app-binary.mjs';
import { testScratch } from './helpers/test-scratch.mjs';

// One execution per suite: assert real receipts, never source-code labels.
const suites = [
  ['w185tap', 'W185TAP', ['W196 C4 display and navigation leave stored map bytes unchanged', 'W205-1 w205-aurora-dark input-mode-disabled stays legible']],
  ['w199quiet', 'W199QUIET', ['W199 expand synchronously enters loading', 'W203-1 offline for five minutes keeps Space and DM entry silent']],
  ['w202perf', 'W202PERF', ['20 Browser switches do not rebuild ChatPage or composer', 'retained hidden ChatPage and shell stay quiet', 'W204 main favorites redraw', 'W204 DM favorites redraw through their own store']],
  ['w182assistoffline', 'W182ASSISTOFFLINE', ['W201 ten disconnect/reconnect cycles: zero hints and zero Island notices', 'W203 actual Remove removes obsolete refusal', 'actual retry requeues and handling prompt disappears']],
  ['w182offline', 'W182OFFLINE', ['(12) reconnect stays quiet; nothing is merged automatically', '(9) DM: read-only with the cached content']],
  ['w180dm', 'W180DM', ['D2 sessions on another paired device are listed too', 'D2 offline device: the target stays, one line explains, no send']],
  ['w198dispatch', 'W198', ['W203-3 dispatch rejects full contact/path/short-password ticket with category', 'outside/symlink/hardlink/FIFO ticket rejected without send']],
  ['w179remote', 'W179REMOTE', ['(3) a send the primary refuses keeps the draft', '(8) engine-disable settings untouched']],
];
for (const [suite, prefix, labels] of suites) {
  test(`${suite} native cleanup behavior`, { timeout: 300_000 }, () => {
    const binary = resolveBinary();
    assert.ok(binary && fs.existsSync(binary), 'Set TATWO2_TEST_BINARY to the current debug build');
    const root = testScratch(suite + '-');
    for (const dir of ['home', 'live', 'engines/codex', 'engines/claude', 'os', 'docs', 'artifacts']) fs.mkdirSync(path.join(root, dir), { recursive: true });
    const env = { ...process.env, HOME: root + '/home', CFFIXED_USER_HOME: root + '/home',
      TATWO_STAGING_ROOT: root, TATWO_STAGING_SCRATCH_HOME: root + '/home', TATWO2_LIVE_ROOT: root + '/live',
      TATWO2_ENGINES_ROOT: root + '/engines', CODEX_HOME: root + '/engines/codex', TATWO2_CODEX_SOURCE_HOME: root + '/engines/codex',
      CLAUDE_CONFIG_DIR: root + '/engines/claude', CLAUDE_SECURESTORAGE_CONFIG_DIR: root + '/engines/claude',
      TATWO2_OS_ROOT: root + '/os', TATWO2_DOCS_ROOT: root + '/docs', TATWO2_OS_UPSTREAM_PATH: root + '/os/os.md',
      TATWO2_SKILLET_PATH: root + '/os/skillet.md', TATWO2_OS_SOCKET: root + '/o.sock', TATWO2_BROWSER_SOCKET: root + '/b.sock',
      TATWO2_SELFTEST: suite, TATWO2_SELFTEST_ARTIFACTS: root + '/artifacts', TATWO2_SKIP_ENGINE_LOGIN: '1' };
    for (const key of Object.keys(env)) if (/(API_KEY|ACCESS_TOKEN|REFRESH_TOKEN|SECRET|PASSWORD)$/.test(key)) delete env[key];
    const result = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 280_000, maxBuffer: 8 * 1024 * 1024 });
    const output = (result.stdout ?? '') + (result.stderr ?? '');
    fs.writeFileSync(path.join(root, 'selftest.log'), output);
    console.log(`${suite} receipts ${root}/selftest.log`);
    assert.equal(result.status, 0, `${result.error ?? ''}\n${output}`);
    assert.match(output, new RegExp(`^${prefix} SUMMARY .*failures=0\\b`, 'm'));
    assert.doesNotMatch(output, /\bFAIL\b/);
    for (const label of labels) assert.ok(output.split('\n').some(line => line.includes(' PASS ') && line.includes(label)), `missing PASS: ${label}`);
  });
}
