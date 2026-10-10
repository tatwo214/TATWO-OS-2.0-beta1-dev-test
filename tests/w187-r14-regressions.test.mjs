import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {testScratch} from './helpers/test-scratch.mjs';
import {runIsolated} from './helpers/w187-runtime.mjs';

test('R14 SEQ-01 new primary start follows epoch readback, with a visible pending reason', {timeout:240_000}, () => {
  const {output} = runIsolated('w187fleet', {TATWO2_W187_R8:'r14-begin'});
  assert.match(output, /W187R14 SUMMARY failures=0/);
});

for (const scenario of ['r14-dispatch-readonly', 'r14-dispatch-applied']) test(`R14 ROSTER-01 / SEQ-03 ${scenario}`, {timeout:240_000}, () => {
  const {output} = runIsolated('w187fleet', {TATWO2_W187_R8:scenario});
  assert.match(output, /W187R14 SUMMARY failures=0/);
});

test('R14 ROSTER-01 w78 named selftest uses an explicit owned fixture', {timeout:240_000}, () => {
  const temp = testScratch('w187-r14-w78-'), root = join(temp, 'fixture');
  mkdirSync(root); writeFileSync(join(root, 'owned-fixture'), 'synthetic only\n');
  const result = spawnSync(process.env.TATWO2_TEST_BINARY, [], {
    env:{PATH:process.env.PATH, HOME:join(temp,'home'), CFFIXED_USER_HOME:join(temp,'home'), TMPDIR:temp,
      TATWO2_SELFTEST:'w78', TATWO2_W78_TEST_ROOT:root, TATWO_OS_ROOT:join(root,'secondary/entry'),
      TATWO2_LIVE_ROOT:join(root,'secondary/live'), TATWO2_ENGINES_ROOT:join(root,'engines'),
      TATWO2_AUTHORIZED_KEYS:join(root,'unused-authorized'), TATWO2_SSH_KNOWN_HOSTS:join(root,'unused-known'),
      SSH_AUTH_SOCK:join(root,'absent-agent'), GIT_CONFIG_NOSYSTEM:'1', GIT_CONFIG_GLOBAL:'/dev/null'},
    encoding:'utf8', timeout:150_000, maxBuffer:8*1024*1024,
  });
  const output = result.stdout + result.stderr;
  writeFileSync(join(temp,'runtime.log'), output);
  assert.equal(result.status, 0, output);
  assert.match(output, /W78TEST SUMMARY failures=0/);
});

test('R14 ROSTER-03 wake fixture replaces only transport and keeps production alignment', () => {
  const source = readFileSync('App/Sources/Tatwo2/Facade/DeviceFleetFourteenthRoundAcceptance.swift', 'utf8');
  const wake = source.split('if scenario == "r14-wake" {')[1].split('if scenario.hasPrefix("r14-second")')[0];
  assert.doesNotMatch(wake, /fixtureAlign/);
  assert.match(wake, /DeviceFleetGate\.fixtureExchange/);
});

test('R14 ROSTER-03 ordinary primary wake cannot fan out notifications', {timeout:240_000}, () => {
  const {output} = runIsolated('w187fleet', {TATWO2_W187_R8:'r14-wake'});
  for (const check of [
    'transport-observes-real-primary-align-notification',
    'ordinary-primary-wake-does-not-align-or-notify',
    'secondary-wake-fetches-and-ACKs-through-real-align',
    'pending-new-primary-wake-fetches-former-primary-only',
    'switched-primary-wake-does-not-align',
  ]) assert.ok(output.includes(`W187R14 PASS ROSTER-03-${check}`), output);
  assert.match(output, /W187R14 SUMMARY failures=0/);
});

for (const scenario of ['r14-second-update','r14-second-ui']) test(`R14 SEQ-02 ${scenario} completed second step is inert`, {timeout:240_000}, () => {
  const {output} = runIsolated('w187fleet', {TATWO2_W187_R8:scenario});
  assert.match(output, /W187R14 SUMMARY failures=0/);
});
