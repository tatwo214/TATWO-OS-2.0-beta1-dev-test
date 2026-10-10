import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';
const read = p => readFileSync(`App/Sources/Tatwo2/${p}`, 'utf8');

test('W187g ruling 1: no automatic SUB primary; assistant exposes designation and cancellation', () => {
  assert.ok(read('Facade/DeviceFleetRoster.swift').includes('firstManagedDeviceIsPrimary = false'));
  assert.ok(read('Facade/DeviceFleetGraph.swift').includes('case setSubPrimary'));
  assert.ok(read('Assistant/AssistantFleetTools.swift').includes('set_sub_primary'));
  assert.ok(readFileSync('Engines/os-mcp/server.mjs', 'utf8').includes('set_sub_primary'));
});
test('W187g ruling 2: staff peers unavailable; MAIN publication migrates existing arrows', () => {
  assert.ok(read('Facade/DeviceFleetRoster.swift').includes('staffPeerCapabilities: [String] = []'));
  assert.ok(read('Facade/DeviceFleetRoster.swift').includes('職員電腦之間的互聯暫不開放'));
  assert.ok(read('Facade/DeviceFleetRoster.swift').split('func publish(')[1].includes('removeStaffInterconnections'));
});
test('W187g ruling 3: consent, preview and device views explain designation without colleague control', () => {
  for (const p of ['DM/DeviceFlowSession.swift', 'New/DeviceFlowCards.swift', 'New/DeviceFleetGraphView.swift', 'New/DeviceFleetListView.swift', 'New/DeviceFleetStaffView.swift']) {
    const source = read(p);
    assert.ok(source.includes('staffRoleExplanation'), p);
    assert.ok(!source.includes('新群組第一台目前預設成為'), p);
  }
});
test('W187g role preview does not describe designation as a device rename', () => {
  assert.ok(read('DM/DeviceFlowSession.swift').includes('if old.name != device.name'));
});
test('W187g runtime: designation security, migration and exact controller sets', { timeout: 240_000 }, () => {
  assert.ok(process.env.TATWO2_TEST_BINARY, 'current room binary required; never skip');
  const root = testScratch('w187-g-ruling-');
  mkdirSync(join(root, 'home'));
  writeFileSync(join(root, 'owned-fixture'), 'fixture only\n');
  const result = spawnSync(process.env.TATWO2_TEST_BINARY, [], {
    env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR,
      HOME: join(root, 'home'), CFFIXED_USER_HOME: join(root, 'home'),
      TATWO2_SELFTEST: 'w187fleet', TATWO2_W187_TEST_ROOT: root, TATWO2_W187_GRAPH: '1',
      TATWO_OS_ROOT: join(root, 'unused-entry'), TATWO2_LIVE_ROOT: join(root, 'unused-live'),
      TATWO2_AUTHORIZED_KEYS: join(root, 'unused-authorized'), TATWO2_SSH_KNOWN_HOSTS: join(root, 'unused-known'),
      TATWO2_SSH_KEY_PATH: join(root, 'unused-key'), TATWO2_SSH_HOST_KEY_PUB: join(root, 'unused-host.pub'),
      GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' },
    encoding: 'utf8', timeout: 220_000, maxBuffer: 4 * 1024 * 1024,
  });
  const output = result.stdout + result.stderr;
  writeFileSync(join(root, 'w187-g-ruling.log'), output);
  assert.equal(result.status, 0, output);
  for (const label of ['g-first-managed-not-primary', 'g-staff-peer-capabilities-empty',
    'g-sub-without-primary-valid', 'g-designate-replace-cancel-primary',
    'g-secondary-cannot-designate', 'g-sub-cannot-designate', 'g-sandbox-cannot-designate',
    'g-peer-proposals-all-refused', 'g-next-signature-removes-legacy-peer-arrows',
    'g-migration-removes-peer-keys-and-live-gate', 'g-designation-preview-only-before-confirmation'])
    assert.ok(output.includes('W187GRAPH PASS ' + label), label);
  assert.match(output, /W187GRAPH SUMMARY checks=\d+ failures=0/);
});
