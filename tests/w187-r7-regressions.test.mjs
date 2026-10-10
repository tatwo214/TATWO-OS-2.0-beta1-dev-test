import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';
for (const scenario of ['transfer-skip-online', 'transfer-fork', 'transfer-return-denied', 'transfer-return-signature', 'transfer-return-exhausted', 'transfer-return-next', 'transfer-retired', 'transfer-stale-evidence', 'dm-actions', 'native-paths', 'projection-errors', 'memory-errors', 'memory-fetch', 'secondary-leave', 'memory-endpoints']) test(`R7 negative runtime ${scenario}: actual production checkpoint`, { timeout: 240_000 }, () => {
  assert.ok(process.env.TATWO2_TEST_BINARY, 'room binary required');
  const root = testScratch('w187-r7-'); mkdirSync(join(root,'home'));
  for (const folder of ['engines/codex','engines/claude','os','docs','artifacts','unused-entry']) mkdirSync(join(root,folder),{recursive:true});
  writeFileSync(join(root,'owned-fixture'), 'synthetic only\n');
  const result = spawnSync(process.env.TATWO2_TEST_BINARY, [], {
    env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR,
      HOME: join(root,'home'), CFFIXED_USER_HOME: join(root,'home'),
      TATWO_STAGING_ROOT:root, TATWO_STAGING_SCRATCH_HOME:join(root,'home'),
      TATWO2_ENGINES_ROOT:join(root,'engines'), CODEX_HOME:join(root,'engines/codex'),
      TATWO2_CODEX_SOURCE_HOME:join(root,'engines/codex'), CLAUDE_CONFIG_DIR:join(root,'engines/claude'),
      CLAUDE_SECURESTORAGE_CONFIG_DIR:join(root,'engines/claude'), TATWO2_OS_SOCKET:join(root,'o.sock'),
      TATWO2_BROWSER_SOCKET:join(root,'b.sock'), TATWO2_SELFTEST_ARTIFACTS:join(root,'artifacts'),
      TATWO2_OS_ROOT:join(root,'os'), TATWO2_DOCS_ROOT:join(root,'docs'),
      TATWO2_OS_UPSTREAM_PATH:join(root,'os/os-upstream.md'), TATWO2_SKILLET_PATH:join(root,'os/skillet.md'),
      TATWO2_SELFTEST: scenario === 'dm-actions' ? 'w187dm' : 'w187fleet', ...(scenario === 'dm-actions' ? {TATWO2_W187_R4_DM:'1', TATWO2_W187_R7_DM:'1'} : {}),
      ...(scenario.startsWith('transfer-') ? {TATWO2_W187_TRANSFER:'1', TATWO2_W187_R7_TRANSFER:scenario.slice(9), TATWO2_W187_R4_TRANSFER:scenario.startsWith('transfer-return-')?'skipped-return':''} : {TATWO2_W187_R7:scenario}), TATWO2_W187_TEST_ROOT: root,
      TATWO_OS_ROOT: join(root,'unused-entry'), TATWO2_LIVE_ROOT: join(root,'unused-live'),
      TATWO2_AUTHORIZED_KEYS: join(root,'unused-authorized'), TATWO2_SSH_KNOWN_HOSTS: join(root,'unused-known'),
      TATWO2_SSH_KEY_PATH: join(root,'unused-key'), TATWO2_SSH_HOST_KEY_PUB: join(root,'unused-host.pub'),
      GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' },
    encoding: 'utf8', timeout: 220_000, maxBuffer: 4 * 1024 * 1024 });
  const output = result.stdout + result.stderr;
  writeFileSync(join(root,'runtime.log'),output);
  assert.equal(result.status,0,output);
  assert.match(output, scenario === 'dm-actions' ? /W187DM SUMMARY checks=\d+ failures=0/ : /W187R7 SUMMARY failures=0/);
  if (scenario === 'dm-actions') assert.match(output,/R7-CARDS-05-revocation-retries-do-not-flash-in-DM/);
  console.log(output.trim());
});


test('R7 prior CARDS-01 invitation does not promise unavailable conversation or terminal results', () => {
  const card = readFileSync('App/Sources/Tatwo2/New/DeviceFlowCards.swift','utf8');
  assert.doesNotMatch(card, /看它跑、拿回成果/);
  assert.match(card, /對話全文與終端機紀錄/);
});
