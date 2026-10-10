import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdirSync, writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {testScratch} from './helpers/test-scratch.mjs';

for (const name of ['DISPATCHTEST', 'RECLAIMTEST', 'REMOTETEST']) {
  test(`R14 CARDS-03 ${name} waits for its isolated asynchronous work`, {timeout:150_000}, () => {
    assert.ok(process.env.TATWO2_TEST_BINARY, 'room binary required');
    const root = testScratch('w187-r14-selftest-');
    for (const dir of ['home','tmp','live','engines/codex','engines/claude','os','docs','artifacts','tmp/w72']) mkdirSync(join(root, dir), {recursive:true});
    writeFileSync(join(root, 'tmp/w72/owned-fixture'), 'synthetic only\n');
    const sidecar = join(root, 'empty-sidecar.mjs');
    writeFileSync(sidecar, 'process.stdin.resume();\n');
    const flags = name === 'DISPATCHTEST' ? {TATWO2_DISPATCH_HYGIENE_CASES:'1'} :
      name === 'REMOTETEST' ? {TATWO2_W72_TEST_ROOT:join(root, 'tmp/w72')} : {};
    const result = spawnSync(process.env.TATWO2_TEST_BINARY, ['-tatwo2.sidecarPath.codex', sidecar], {
      env: {PATH:process.env.PATH, HOME:join(root,'home'), CFFIXED_USER_HOME:join(root,'home'), TMPDIR:join(root,'tmp'),
        TATWO_STAGING_ROOT:root, TATWO_STAGING_SCRATCH_HOME:join(root,'home'),
        TATWO2_RUNTIME_BIN:'/Applications/TATWO OS.app/Contents/Resources/runtime/bin',
        TATWO2_LIVE_ROOT:join(root,'live'), TATWO2_ENGINES_ROOT:join(root,'engines'), CODEX_HOME:join(root,'engines/codex'),
        TATWO2_CODEX_SOURCE_HOME:join(root,'engines/codex'), CLAUDE_CONFIG_DIR:join(root,'engines/claude'),
        CLAUDE_SECURESTORAGE_CONFIG_DIR:join(root,'engines/claude'),
        TATWO_OS_ROOT:join(root,'os'), TATWO2_OS_ROOT:join(root,'os'), TATWO2_DOCS_ROOT:join(root,'docs'),
        TATWO2_OS_UPSTREAM_PATH:join(root,'os/os-upstream.md'), TATWO2_SKILLET_PATH:join(root,'os/skillet.md'),
        TATWO2_OS_SOCKET:join(root,'o.sock'), TATWO2_BROWSER_SOCKET:join(root,'b.sock'),
        TATWO2_AUTHORIZED_KEYS:join(root,'authorized_keys'), TATWO2_SSH_KNOWN_HOSTS:join(root,'known_hosts'),
        TATWO2_SSH_KEY_PATH:join(root,'fixture-key'), TATWO2_SSH_HOST_KEY_PUB:join(root,'fixture-host.pub'),
        SSH_AUTH_SOCK:join(root,'absent-agent'), GIT_CONFIG_GLOBAL:'/dev/null', GIT_CONFIG_NOSYSTEM:'1',
        TATWO2_SELFTEST_ARTIFACTS:join(root,'artifacts'), [`TATWO2_${name}`]:'1', ...flags},
      encoding:'utf8', timeout:120_000, maxBuffer:8*1024*1024,
    });
    const output = result.stdout + result.stderr;
    writeFileSync(join(root, 'runtime.log'), output);
    assert.equal(result.status, 0, `${output}\nsignal=${result.signal} error=${result.error?.message ?? ''}`);
    assert.doesNotMatch(output, /\bFAIL(?:ED)?\b/);
    assert.match(output, name === 'DISPATCHTEST' ? /DISPATCHTEST HYGIENE PASS requested-model-persisted/ :
      name === 'RECLAIMTEST' ? /RECLAIMTEST ALL PASS/ : /W72TEST SUMMARY failures=0/);
    console.log(`${name} PASS ${root}`);
  });
}
