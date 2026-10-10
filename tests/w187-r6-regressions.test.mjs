import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';
for (const scenario of ['transfer-return-online', 'transfer-return-app-closed', 'memory-endpoints', 'transfer-ack-churn', 'native-memory', 'revocation-retry', 'clock-gate', 'legacy-ack', 'memory-errors', 'secondary-forward', 'transfer-new-primary-skip', 'transfer-coordinator-recovered', 'legacy-names', 'legacy-prepared', 'restore-old-key', 'restore-host-key', 'disconnect-targets']) test(`R6 negative runtime ${scenario}: actual production checkpoint`, { timeout: 240_000 }, () => {
  assert.ok(process.env.TATWO2_TEST_BINARY, 'room binary required');
  const root = testScratch('w187-r6-'); mkdirSync(join(root,'home'));
  for (const folder of ['engines/codex','engines/claude','os','docs','artifacts','unused-entry']) mkdirSync(join(root,folder),{recursive:true});
  writeFileSync(join(root,'owned-fixture'), 'synthetic only\n');
  const result = spawnSync(process.env.TATWO2_TEST_BINARY, [], {
    env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR,
      TATWO2_RUNTIME_BIN: '/Applications/TATWO OS.app/Contents/Resources/runtime/bin',
      HOME: join(root,'home'), CFFIXED_USER_HOME: join(root,'home'),
      TATWO_STAGING_ROOT:root, TATWO_STAGING_SCRATCH_HOME:join(root,'home'),
      TATWO2_ENGINES_ROOT:join(root,'engines'), CODEX_HOME:join(root,'engines/codex'),
      TATWO2_CODEX_SOURCE_HOME:join(root,'engines/codex'), CLAUDE_CONFIG_DIR:join(root,'engines/claude'),
      CLAUDE_SECURESTORAGE_CONFIG_DIR:join(root,'engines/claude'), TATWO2_OS_SOCKET:join(root,'o.sock'),
      TATWO2_BROWSER_SOCKET:join(root,'b.sock'), TATWO2_SELFTEST_ARTIFACTS:join(root,'artifacts'),
      TATWO2_OS_ROOT:join(root,'os'), TATWO2_DOCS_ROOT:join(root,'docs'),
      TATWO2_OS_UPSTREAM_PATH:join(root,'os/os-upstream.md'), TATWO2_SKILLET_PATH:join(root,'os/skillet.md'),
      TATWO2_SELFTEST: scenario === 'native-memory' ? 'w187dm' : 'w187fleet', ...(scenario === 'native-memory' ? {TATWO2_W187_R4_DM:'engine', TATWO2_W187_R6_DM:'1'} : {}),
      ...(scenario.startsWith('transfer-') ? {TATWO2_W187_TRANSFER:'1', TATWO2_W187_R6_TRANSFER:scenario.slice(9), TATWO2_W187_R4_TRANSFER:scenario.startsWith('transfer-return-')?'skipped-return':''} : {TATWO2_W187_R6:scenario}), TATWO2_W187_TEST_ROOT: root,
      TATWO_OS_ROOT: join(root,'unused-entry'), TATWO2_LIVE_ROOT: join(root,'unused-live'),
      TATWO2_AUTHORIZED_KEYS: join(root,'unused-authorized'), TATWO2_SSH_KNOWN_HOSTS: join(root,'unused-known'),
      TATWO2_SSH_KEY_PATH: join(root,'unused-key'), TATWO2_SSH_HOST_KEY_PUB: join(root,'unused-host.pub'),
      GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' },
    encoding: 'utf8', timeout: 220_000, maxBuffer: 4 * 1024 * 1024 });
  const output = result.stdout + result.stderr;
  writeFileSync(join(root,'runtime.log'),output);
  assert.equal(result.status,0,output);
  if (scenario === 'native-memory') assert.match(output,/W187DM SUMMARY checks=\d+ failures=0/); else if (scenario === 'cards') assert.match(output,/R4-PAIR-N1-invite-survives/); else assert.match(output,/W187R6 SUMMARY failures=0/);
  console.log(output.trim());
});

test('R5 ROSTER-N4 offline disconnect expiry is visible on consent card', () => {
  const card = readFileSync(new URL('../App/Sources/Tatwo2/New/DeviceFlowCards.swift', import.meta.url), 'utf8');
  assert.match(card, /目前離線的設備，要在下一次名單變更前連上才會中斷/);
});
