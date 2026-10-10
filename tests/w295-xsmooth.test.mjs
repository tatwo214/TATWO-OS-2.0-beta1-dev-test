import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {testScratch} from './helpers/test-scratch.mjs';
import {resolveBinary} from './helpers/app-binary.mjs';

for (const [suite, prefix] of [['w295', 'W295'], ['w292', 'W292'], ['w288', 'W288'],
  ['w258download', 'W258'], ['w248webspace', 'W248']]) {
  test(`${suite} native isolated acceptance`, {timeout: 1220000}, () => {
    const binary = resolveBinary();
    assert.ok(binary && fs.existsSync(binary));
    const root = testScratch(`w295-${suite}-`), at = name => path.join(root, name);
    for (const dir of ['home', 'live', 'engines/codex', 'engines/claude', 'os', 'docs', 'artifacts']) {
      fs.mkdirSync(at(dir), {recursive: true});
    }
    const env = {...process.env, HOME: at('home'), CFFIXED_USER_HOME: at('home'),
      TATWO_STAGING_SCRATCH_HOME: at('home'), TATWO_STAGING_ROOT: root,
      TATWO2_LIVE_ROOT: at('live'), TATWO2_ENGINES_ROOT: at('engines'),
      CODEX_HOME: at('engines/codex'), TATWO2_CODEX_SOURCE_HOME: at('engines/codex'),
      CLAUDE_CONFIG_DIR: at('engines/claude'), CLAUDE_SECURESTORAGE_CONFIG_DIR: at('engines/claude'),
      TATWO2_OS_SOCKET: at('o.sock'), TATWO2_BROWSER_SOCKET: at('b.sock'), TATWO2_OS_ROOT: at('os'),
      TATWO2_DOCS_ROOT: at('docs'), TATWO2_OS_UPSTREAM_PATH: at('os/os-upstream.md'),
      TATWO2_SKILLET_PATH: at('os/skillet.md'), TATWO2_SELFTEST: suite,
      TATWO2_SELFTEST_ARTIFACTS: at('artifacts'), TATWO2_SELFTEST_NODE: process.execPath};
    delete env.TATWO2_W258_REAL_SITE; // this room only permits local fixture pages
    for (const key of Object.keys(env)) if (/(API_KEY|ACCESS_TOKEN|REFRESH_TOKEN|SECRET|PASSWORD)$/.test(key)) delete env[key];
    const child = spawnSync(binary, ['--use-mock-keychain'], {env, encoding: 'utf8', timeout: 1200000, maxBuffer: 16 * 1024 * 1024});
    const output = (child.stdout ?? '') + (child.stderr ?? '');
    fs.writeFileSync(at('selftest.log'), output);
    fs.writeFileSync(path.resolve(process.env.TATWO2_W295_EVIDENCE_ROOT ?? 'tests/fixtures', `w295-${suite}.log`), output.replace(/\/Users\/[^/\s]+/g, '/Users/fixture'));
    console.log(`${suite} evidence: ${root}`);
    assert.equal(child.status, 0, `${child.error ?? ''}\n${output}`);
    assert.match(output, new RegExp(`^${prefix} SUMMARY .*failures=0\\b`, 'm'));
    assert.doesNotMatch(output, /\bFAIL\b/);
    if (suite === 'w295') {
      assert.match(output, /W295 COUNTS updates=\d+ trustReads=[01] policyReads=[01] mainLoads=0 loads=\d+ mainJSON=0 JSON=200 coder=0/);
      assert.match(output, /W295 COUNTS .*activityLines=[01] hydratedBodies=\d+/);
      assert.match(output, /W295 AUTHORITY revisions=1 hydratedBodies=1/);
      assert.match(output, /W295 DEVICE COUNTS reads=200 unchanged=0 changed=1/);
    }
  });
}

test('document comparison and JSON run outside the main snapshot closure', () => {
  const bridge = fs.readFileSync('App/Sources/Tatwo2/Facade/OSAgentBridge.swift', 'utf8');
  const get = bridge.slice(bridge.indexOf('case "get_document":'), bridge.indexOf('case "transcript":'));
  const main = get.slice(0, get.indexOf('guard let snapshot else'));
  assert.doesNotMatch(main, /store\.load\(|store\.save\(|documentsEqual|jsonObject/);
  assert.match(get, /documentQueue\.async/);
  assert.match(get, /saveIfChanged\(snapshot\.0, expectedStamp: snapshot\.4\)/);
});
