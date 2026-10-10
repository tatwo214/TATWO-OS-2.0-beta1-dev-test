import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
const source = n => readFileSync(`App/Sources/Tatwo2/${n}.swift`, 'utf8');
test('R3-GATE-01 unknown SSH uses verified device handshake', () => {
  assert.match(source('Facade/OSAgentBridge'), /authenticateSSHRequest/);
  assert.match(source('Facade/RemoteHostLink'), /deviceHandshake/);
});
test('R3-ROSTER-01 empty controller and independent deliveries', () => {
  assert.doesNotMatch(source('Facade/DeviceFleetRoster'), /valid\(controller.capabilities\), !controller.capabilities.isEmpty/);
  assert.match(source('Facade/DeviceFleetRoster'), /fleet_delivery_skipped/);
});
test('R3-DM-01 managed assistant stays local without primary fallback', () => {
  assert.match(source('Assistant/AssistantPrimaryRouting'), /trust.kind != .owner/);
  assert.doesNotMatch(source('Assistant/AssistantPrimaryRouting'), /marked.count == 1/);
});
test('R3-PAIR-01 preview validates and refuses legacy write', () => {
  assert.match(source('Facade/DevicePairingHost'), /previewNotAllowed/);
});
test('R3-PAIR-02 restoration cleared and physically confirmed', () => {
  assert.match(source('DM/DeviceFlowSession'), /restorationConfirmation/);
  assert.match(source('DM/DeviceFlowSession'), /這台已恢復/);
});
test('R3-ROSTER-02 MAIN transport survives no arrow', () => {
  assert.match(source('Facade/DeviceFleetGraph'), /hasMAINTransport/);
  assert.match(source('Facade/RemoteHostLink'), /usesUnrestrictedKey/);
  assert.match(source('Facade/DeviceFleetGraph'), /Set\(capabilities\) == Set\(DeviceFleetCapabilities.all\)/);
});
test('R3-XFER-01 only unreachable participants skip after commit', () => {
  assert.match(source('Facade/PrimaryTransfer'), /committedAt/);
  assert.match(source('Facade/PrimaryTransfer'), /failedContact/);
});
test('R3-DM-02 colleagues are display only and never polled', () => {
  assert.match(source('Facade/DeviceFleetRoster'), /displayOnly/);
  assert.match(source('Facade/PeerUpdateSource'), /allowsPeerConnection/);
});
test('R3-DM-03 controller threads have creator and no memory bypass', () => {
  assert.match(source('Facade/OSAgentBridge'), /controllerFingerprint/);
  assert.match(source('Facade/OSAgentBridge'), /controllerThread/);
});
test('R2-GATE-02 narrowing warning identifies device', () => {
  assert.match(source('Facade/DeviceFleetRoster'), /possiblyConnectedDevices/);
});
test('R3-DM-05 migrate old staff grants on load', () => {
  assert.match(source('Facade/DeviceFleetRoster'), /migrateStaffInterconnections/);
});
test('R3-PAIR-07 encrypted reply mandatory', () => {
  assert.doesNotMatch(source('Facade/DevicePairingClient'), /openResponse.*\?\? responseLine/);
  assert.match(source('Facade/DevicePairingClient'), /encryptedResponseRequired/);
});
test('R3-PIN-01 CA marker is not literal pin conflict', () => {
  assert.match(source('Facade/DeviceRegistry'), /marker == "@cert-authority"/);
});
test('R3-CUT-01 revocation sweep has own revision budget', () => {
  assert.match(source('Facade/DeviceFleetRoster'), /sweepRevision/);
});
test('R3-PAIR-06 secondary sandbox fails before invitation', () => {
  assert.match(source('Facade/DevicePairingHost'), /kind == .sandbox, identity.role != .primary/);
});

import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';
for (const scenario of ['gate', 'roster', 'assistant', 'narrow', 'pairing', 'gatefailure', 'repair', 'warnings']) test(`R3 runtime ${scenario}: actual production checkpoint`, { timeout: 240_000 }, () => {
  assert.ok(process.env.TATWO2_TEST_BINARY, 'room binary required');
  const root = testScratch('w187-r3-'); mkdirSync(join(root,'home'));
  writeFileSync(join(root,'owned-fixture'), 'synthetic only\n');
  const result = spawnSync(process.env.TATWO2_TEST_BINARY, [], {
    env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR,
      HOME: join(root,'home'), CFFIXED_USER_HOME: join(root,'home'),
      TATWO2_SELFTEST: 'w187fleet', TATWO2_W187_R3: scenario, TATWO2_W187_TEST_ROOT: root,
      TATWO_OS_ROOT: join(root,'unused-entry'), TATWO2_LIVE_ROOT: join(root,'unused-live'),
      TATWO2_AUTHORIZED_KEYS: join(root,'unused-authorized'), TATWO2_SSH_KNOWN_HOSTS: join(root,'unused-known'),
      TATWO2_SSH_KEY_PATH: join(root,'unused-key'), TATWO2_SSH_HOST_KEY_PUB: join(root,'unused-host.pub'),
      GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' },
    encoding: 'utf8', timeout: 220_000, maxBuffer: 4 * 1024 * 1024 });
  const output = result.stdout + result.stderr;
  writeFileSync(join(root,'runtime.log'),output);
  assert.equal(result.status,0,output);
  assert.match(output,/W187R3 SUMMARY failures=0/);
  console.log(output.trim());
});
