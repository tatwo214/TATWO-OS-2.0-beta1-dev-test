import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read = p => readFileSync(`App/Sources/Tatwo2/${p}`, 'utf8');

test('DM-02 direct native events, fresh one-shot card and proposal authorization, AX refusal', () => {
  const cards = read('New/DeviceFlowCards.swift'), session = read('DM/DeviceFlowSession.swift');
  assert.doesNotMatch(cards, /NSApp\.currentEvent/);
  for (const pattern of [/override func mouseDown/, /override func mouseUp/, /override func accessibilityPerformPress/, /systemUptime/, /event\.window === window/, /bounds\.contains/, /0\.5/]) assert.match(cards, pattern);
  assert.match(session.split('func confirmFromCard')[1].split('func cancelProposal')[0], /authority\.consume/);
});
test('DM-04 local consent ceiling clips every controller until a physical approval', () => {
  const roster = read('Facade/DeviceFleetRoster.swift');
  assert.match(roster, /consentCeiling/);
  assert.match(roster, /func pendingConsent/);
  assert.match(roster, /func approveConsent/);
  assert.match(read('New/DeviceFlowCards.swift'), /管理者想多開這些權限/);
  assert.match(roster, /firstManagedDeviceIsPrimary/);
  // Fifth ruling: the constant is empty; graph defaults build no staff peer edges.
  assert.match(roster, /staffPeerCapabilities: \[String\] = \[\]/);
});
test('DM-06 inherited effective gains and identity warnings; no move promotion', () => {
  const preview = read('DM/DeviceFlowSession.swift').split('enum DeviceFlowPreview')[1];
  assert.match(preview, /capabilities\(from:/);
  assert.match(preview, /身分變更/);
  assert.match(read('Facade/DeviceFleetGraph.swift'), /kind\(of: id\) == \.owner/);
});
test('ROSTER-08 shared visible-name policy, duplicate suffixes, card role and short fingerprint', () => {
  assert.match(read('Facade/DeviceFleetRoster.swift'), /enum DeviceFleetName/);
  assert.match(read('Facade/DevicePairingHost.swift'), /DeviceFleetName/);
  const authenticated = read('Facade/DevicePairingHost.swift').split('DevicePairingAuth.requestFields(')[1].split('else {')[0];
  assert.match(authenticated, /name: request\.name/);
  assert.doesNotMatch(authenticated, /DeviceFleetName\.clean/);
  assert.match(read('Assistant/AssistantFleetTools.swift'), /DeviceFleetName/);
  assert.match(read('DM/DeviceFlowSession.swift'), /DeviceFleetName\.label/);
});
test('DM-07 engine list and status use one allowlisted projection; protocol keeps records', () => {
  const bridge = read('Facade/OSAgentBridge.swift');
  assert.match(bridge.split('case "list_devices":')[1].split('case "computer_list_apps"')[0], /engineDeviceProjection/);
  assert.match(bridge.split('let deviceRows:')[1].split('var result:')[0], /engineDeviceProjection/);
  assert.match(read('Facade/DeviceFleetRoster.swift'), /func engineDeviceProjection/);
});
test('DM-08 visible primary is a display-only wire type and staff view has no address', () => {
  assert.match(read('Facade/DeviceFleetRoster.swift'), /var primary: DeviceFleetPrimaryDisplay\?/);
  assert.doesNotMatch(read('New/DeviceFleetStaffView.swift'), /endpoints|\.user|PublicKey|Fingerprint/);
  assert.match(read('New/DeviceFlowCards.swift'), /只顯示名稱與角色/);
});
test('DM-09 snapshot holds secret suppression and refuses protected visible windows', () => {
  const probe = read('Facade/UIProbe.swift').split('func snapshot()')[1];
  assert.match(probe, /DMSecretCodeView\.holdForCapture/);
  assert.match(probe, /WindowCaptureShield\.shared\.isShielding/);
  assert.match(probe, /sensitive_window_open/);
});
test('TR-02 and REG-05 cards surface uncertain connections and pin conflict', () => {
  assert.match(read('New/DeviceFlowCards.swift'), /中斷主設備及受影響的「我的設備」上所有遠端連線（其他設備會自動重連）/);
  assert.match(read('DM/DeviceFlowSession.swift'), /possiblyConnected/);
  assert.match(read('New/DeviceFleetPresentation.swift'), /這台的身分跟你電腦記得的不一樣，暫不自動信任/);
});
test('REG-05 general remote calls use gate for restricted peers and compose both pins', () => {
  const remote = read('Facade/RemoteHostLink.swift');
  assert.match(remote, /DeviceFleetGate\.call/);
  assert.match(remote, /DeviceFleetSSHPins\.lines/);
  const pins = read('Facade/DeviceRegistry.swift');
  assert.match(pins, /registry\.knownHostsURL, registry\.fleetKnownHostsURL/);
  assert.match(pins, /pinConflicts/);
});
test('TR-04 every uncommitted handoff can cancel through direct physical input', () => {
  const panel = read('New/DeviceFlowTransferPanel.swift');
  assert.doesNotMatch(panel, /previousTransferID == nil/);
  assert.match(panel, /DeviceFlowPhysicalButton/);
});
