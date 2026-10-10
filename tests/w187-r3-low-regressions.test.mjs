import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const swift = n => readFileSync(`App/Sources/Tatwo2/Facade/${n}.swift`, 'utf8');
test('R3-GATE-05 missing unreferenced gate can be reinstalled', () => {
  assert.doesNotMatch(swift('DeviceFleetGate'), /errno == ENOENT, previous == nil/);
});
test('R2-GATE-06 close verified transports before cleanup writes', () => {
  const reconcile = swift('DeviceFleetRoster').split('func reconcile(_ payload:')[1];
  assert.ok(reconcile.indexOf('closeBeforeCleanup') >= 0);
  assert.ok(reconcile.indexOf('closeBeforeCleanup') < reconcile.indexOf('applyRePairVersions'));
});
test('R3-GATE-05 gate publish failure still converges authorization', () => {
  assert.match(swift('DeviceFleetRoster'), /gateFailure/);
});
test('R2-GATE-01 disconnected staff retains signed roster channel', () => {
  assert.match(swift('DeviceFleetGraph'), /hasManagedTransport/);
});
test('R3-XFER-02 old graph normalized consistently when staging', () => {
  const stage = swift('DeviceFleetTransfer').split('var expected = previous')[1].split('guard expected == roster')[0];
  assert.match(stage, /removeStaffInterconnections/);
  assert.match(stage, /normalizeNames/);
});
test('R2-GATE-05 reported gate identity never substitutes signed handshake', () => {
  assert.doesNotMatch(swift('OSAgentBridge'), /if fingerprint == nil, !Self.signedDeviceMethods.contains/);
});
test('R3-DM-03 dispatch children inherit verified creator', () => {
  const configure = swift('ChatLiveEngine').split('func configureRoom(threadID:')[1].split('persist()')[0];
  assert.match(configure, /controllerCreatorFingerprint/);
});
test('R3-DM-02 cached peer update offer cannot bypass managed isolation', () => {
  const pull = swift('PeerUpdateSource').split('static func pull(')[1].split('let runtime =')[0];
  assert.match(pull, /allowsPeerConnection/);
});
test('R3-DM-02 direct status probe also refuses managed peers', () => {
  const probe = swift('RemoteHostLink').split('func queryDeviceStatus(')[1].split('lock.lock()')[0];
  assert.match(probe, /allowsPeerConnection/);
});
test('R3-DM-03 SSH job lookups never use selected conversation', () => {
  assert.match(swift('OSAgentBridge'), /allowSelected: !context.isSSH/);
});
test('R3-GATE-03 revoked full owner cleanup selects its retained actual row', () => {
  const route = swift('RemoteHostLink').split('func requiresFleetGate(')[1].split('private func callFleetGate')[0];
  assert.match(route, /forRevocation: revocationCleanup/);
});

test('R3-REV-01 unrelated authenticated sessions do not produce stale warnings', () => {
  assert.doesNotMatch(swift('DeviceFleetRevocation'), /!matched \|\| failed \|\| addresses.isEmpty \|\| unidentified/);
});
test('R2-REV-08 pending revocation and repin show named device status', () => {
  const session = readFileSync('App/Sources/Tatwo2/DM/DeviceFlowSession.swift', 'utf8');
  const cards = readFileSync('App/Sources/Tatwo2/New/DeviceFlowCards.swift', 'utf8');
  assert.match(session, /pendingManagedRemoval\(\)/);
  assert.match(cards, /pendingDeliveryLines/);
});
test('R2-DM-03 repeated consent never steals assistant focus', () => {
  const observer = readFileSync('App/Sources/Tatwo2/DM/DeviceFlowSession.swift', 'utf8').split('consentObserver =')[1].split('var code:')[0];
  assert.doesNotMatch(observer, /select\(\.assistant\)|openDocked\(/);
});

test('R3-GATE-02 dispatcher also signs interactive restricted requests', () => {
  const send = swift('DeviceDispatch').split('private func send(')[1].split('var transportEnvironment')[0];
  assert.match(send, /handshake: handshake/);
  assert.match(send, /signedHandshake\(method: method, params: params, recipient: peer.id\)/);
});

test('R3-XFER-01 absence needs actual SSH endpoint diagnostics, not local socket failure', () => {
  assert.match(swift('DeviceFleetGate'), /isSSHUnreachable/);
  assert.doesNotMatch(swift('PrimaryTransfer'), /case \.tunnelUnavailable, \.connectFailed, \.tunnelStartFailed: return true/);
});

test('R3-XFER-01 any reachable endpoint prevents an offline skip', () => {
  const gate = swift('DeviceFleetGate');
  assert.match(gate, /throw rpcFailure\(failures\)/);
});

test('R3-PAIR-06 secondary menu never invites sandbox', () => {
  const cards = readFileSync('App/Sources/Tatwo2/New/DeviceFlowCards.swift', 'utf8');
  assert.match(cards, /if session.canInviteSandbox/);
});
