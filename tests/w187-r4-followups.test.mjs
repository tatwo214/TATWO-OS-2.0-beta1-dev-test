import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';
for (const scenario of ['delivery-warning', 'sweep', 'broad-scope', 'transfer-managed-gate', 'transfer-target-none']) test(`R4 runtime ${scenario}: actual production checkpoint`, { timeout: 240_000 }, () => {
  assert.ok(process.env.TATWO2_TEST_BINARY, 'room binary required');
  const root = testScratch('w187-r4-'); mkdirSync(join(root,'home'));
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
      TATWO2_SELFTEST: ['cards','engine'].includes(scenario) ? 'w187dm' : 'w187fleet', ...(['cards','engine'].includes(scenario) ? {TATWO2_W187_R4_DM:scenario==='cards'?'1':'engine'} : {}),
      ...(scenario.startsWith('transfer-') ? {TATWO2_W187_TRANSFER:'1', TATWO2_W187_R4_TRANSFER:scenario.slice(9)} : {TATWO2_W187_R4:scenario}), TATWO2_W187_TEST_ROOT: root,
      TATWO_OS_ROOT: join(root,'unused-entry'), TATWO2_LIVE_ROOT: join(root,'unused-live'),
      TATWO2_AUTHORIZED_KEYS: join(root,'unused-authorized'), TATWO2_SSH_KNOWN_HOSTS: join(root,'unused-known'),
      TATWO2_SSH_KEY_PATH: join(root,'unused-key'), TATWO2_SSH_HOST_KEY_PUB: join(root,'unused-host.pub'),
      GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' },
    encoding: 'utf8', timeout: 220_000, maxBuffer: 4 * 1024 * 1024 });
  const output = result.stdout + result.stderr;
  writeFileSync(join(root,'runtime.log'),output);
  assert.equal(result.status,0,output);
  if (scenario === 'engine') assert.match(output,/W187DM SUMMARY checks=\d+ failures=0/); else if (scenario === 'cards') assert.match(output,/R4-PAIR-N1-invite-survives/); else assert.match(output,/W187R4 SUMMARY failures=0/);
  console.log(output.trim());
});

test('broad physical disconnect clearly names the affected device scope', () => {
  const view = readFileSync('App/Sources/Tatwo2/New/DeviceFlowCards.swift','utf8');
  assert.match(view, /主設備及受影響的「我的設備」/);
});

test('rejected projection is visible by device name with an update hint', () => {
  assert.match(readFileSync('App/Sources/Tatwo2/New/DeviceFleetPresentation.swift','utf8'), /deliveryProblems/);
  assert.match(readFileSync('App/Sources/Tatwo2/New/DeviceFleetPage.swift','utf8'), /pendingDeliveryLines/);
  assert.match(readFileSync('App/Sources/Tatwo2/Facade/DeviceFleetRoster.swift','utf8'), /更新.*尚未收到新版權限|尚未收到新版權限.*更新/);
});
