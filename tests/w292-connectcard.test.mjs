import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { resolveBinary } from './helpers/app-binary.mjs';
import { testScratch } from './helpers/test-scratch.mjs';

// Real native controls, W208 fake Pods, private homes; no live account or network.
for (const [suite, prefix] of [['w292', 'W292'], ['w208tap', 'W208'], ['w185tap', 'W185TAP'], ['w183connect', 'W183CONNECT'], ['w199quiet', 'W199QUIET']]) {
  test(`${suite} isolated native acceptance`, { timeout: 300000 }, () => {
    const binary = resolveBinary();
    assert.ok(binary && fs.existsSync(binary), 'TATWO2_TEST_BINARY must be a current debug build');
    const root = testScratch(`w292-${suite}-`);
    const at = name => path.join(root, name);
    for (const dir of ['home', 'live', 'engines/codex', 'engines/claude', 'os', 'docs', 'artifacts']) fs.mkdirSync(at(dir), { recursive: true });
    const env = { ...process.env, HOME: at('home'), CFFIXED_USER_HOME: at('home'), TATWO_STAGING_SCRATCH_HOME: at('home'),
      TATWO_STAGING_ROOT: root, TATWO2_LIVE_ROOT: at('live'), TATWO2_ENGINES_ROOT: at('engines'),
      CODEX_HOME: at('engines/codex'), TATWO2_CODEX_SOURCE_HOME: at('engines/codex'),
      CLAUDE_CONFIG_DIR: at('engines/claude'), CLAUDE_SECURESTORAGE_CONFIG_DIR: at('engines/claude'),
      TATWO2_OS_SOCKET: at('o.sock'), TATWO2_BROWSER_SOCKET: at('b.sock'), TATWO2_OS_ROOT: at('os'), TATWO2_DOCS_ROOT: at('docs'),
      TATWO2_OS_UPSTREAM_PATH: at('os/os-upstream.md'), TATWO2_SKILLET_PATH: at('os/skillet.md'),
      TATWO2_SELFTEST: suite, TATWO2_SELFTEST_ARTIFACTS: at('artifacts'), TATWO2_SELFTEST_NODE: process.execPath };
    for (const key of Object.keys(env)) if (/(API_KEY|ACCESS_TOKEN|REFRESH_TOKEN|SECRET|PASSWORD)$/.test(key)) delete env[key];
    const result = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 280000, maxBuffer: 16 * 1024 * 1024 });
    const output = (result.stdout ?? '') + (result.stderr ?? '');
    fs.writeFileSync(at('selftest.log'), output);
    console.log(`${suite} evidence: ${root}`);
    const receipts = path.resolve(process.env.TATWO2_SELFTEST_RECEIPTS ?? 'tests/fixtures/w292-shots');
    fs.mkdirSync(receipts, { recursive: true });
    fs.writeFileSync(path.join(receipts, `${suite}.log`), output);
    if (suite === 'w292') for (const file of fs.readdirSync(at('artifacts'))) {
      if (file.endsWith('.png')) fs.copyFileSync(at('artifacts/' + file), path.join(receipts, file));
    }
    assert.equal(result.status, 0, `${result.error ?? ''}\n${output}`);
    assert.match(output, new RegExp(`^${prefix} SUMMARY .*failures=0\\b`, 'm'));
    assert.doesNotMatch(output, /\bFAIL\b/);
  });
}
