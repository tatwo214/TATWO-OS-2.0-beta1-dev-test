import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';

const app = 'App/Sources/Tatwo2/';
const source = file => readFileSync(app + file, 'utf8');

test('W187 readonly graph, permissions, list, refusal, toolbar and staff render eight PNGs', { timeout: 180_000 }, () => {
  assert.ok(process.env.TATWO2_TEST_BINARY, 'current room binary required');
  const root = testScratch('w187-ui-');
  for (const name of ['home', 'artifacts', 'live', 'os']) mkdirSync(join(root, name));
  const result = spawnSync(process.env.TATWO2_TEST_BINARY, [], {
    env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR,
      HOME: join(root, 'home'), CFFIXED_USER_HOME: join(root, 'home'),
      TATWO2_SELFTEST: 'w187ui', TATWO2_SELFTEST_ARTIFACTS: join(root, 'artifacts'),
      TATWO2_AUTHORIZED_KEYS: join(root, 'authorized_keys'), TATWO2_SSH_KNOWN_HOSTS: join(root, 'known_hosts'),
      TATWO2_SSH_KEY_PATH: join(root, 'absent-key'), TATWO2_SSH_HOST_KEY_PUB: join(root, 'absent-host.pub'), SSH_AUTH_SOCK: join(root, 'absent-agent'),
      TATWO2_LIVE_ROOT: join(root, 'live'), TATWO_OS_ROOT: join(root, 'os'),
      TATWO2_OS_ROOT: join(root, 'os'), TATWO2_OS_SOCKET: join(root, 'os.sock'),
      GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' },
    encoding: 'utf8', timeout: 160_000, maxBuffer: 4 * 1024 * 1024,
  });
  const output = result.stdout + result.stderr;
  writeFileSync(join(root, 'w187ui.log'), output);
  assert.equal(result.status, 0, output);
  assert.match(output, /W187UI SUMMARY checks=\d+ failures=0/);
  const manifest = JSON.parse(readFileSync(join(root, 'artifacts/manifest.json')));
  assert.equal(manifest.failures, 0);
  // Fifth ruling removes all 3 SUB internal arrows (1 mutual, 2 oneway).
  assert.equal(manifest.edges, 6);
  assert.equal(manifest.mutual, 3);
  assert.equal(manifest.oneway, 3);
  assert.equal(manifest.pngs.length, 8);
  assert.deepEqual(manifest.pngs.map(png => png.file.split('/').at(-1)).sort(), [
    'graph-dark.png', 'graph-light.png', 'graph-permissions.png', 'list.png',
    'list-projection-refused.png', 'staff-hidden.png', 'staff-shown.png', 'toolbar.png',
  ].sort());
  for (const png of manifest.pngs) {
    const bytes = readFileSync(png.file);
    assert.equal(bytes.subarray(1, 4).toString(), 'PNG');
    assert.ok(png.width >= 620 && png.height >= 650, png.file);
  }
  for (const label of ['one-route-per-enabled-edge', 'mutual-single-route-two-heads', 'oneway-single-head',
    'staff-full-roster-defense', 'sandbox-full-roster-defense', 'multiple-sub-modules-and-edges', 'permission-panel-direction-capabilities-and-lock', 'arrow-real-click-opens-permissions',
    'toolbar-expanded-readonly-details', 'staff-hidden-render-no-main-name-address-version', 'staff-shown-render-main-name-no-address',
    'R7-CARDS-02-refusing-device-row-renders-update-action']) {
    assert.ok(output.includes('W187UI PASS ' + label), label);
  }
  console.log(output.trim());
});

test('W187 production surfaces read verified graph and preserve backend authority', () => {
  const presentation = source('New/DeviceFleetPresentation.swift');
  assert.match(presentation, /let fleet = DeviceFleetStore\(registry: DeviceRegistry\(\), environment: environment\)\n\s*let payload = try fleet\.readGraph\(\)/);
  assert.match(presentation, /RemoteHostLink\(\)\.queryDeviceStatus\(device: record\)/);
  assert.match(presentation, /DeviceStatusPolicy\.fresh/);
  assert.match(presentation, /slice\.group\?\.showMainPrimary \?\? slice\.faction\.showPrimaryToMembers/);
  assert.match(presentation, /edges = edges\.filter \{ endpoints\.contains\(\$0\.from\) && endpoints\.contains\(\$0\.to\) \}/);
  const page = source('New/DevicesCard.swift').split('enum RemoteDevicePresentation')[0];
  const toolbar = source('Pages/DevicesPage.swift').split('struct PrimaryTransferStatusView')[0];
  const newViews = ['DeviceFleetPresentation', 'DeviceFleetPage', 'DeviceFleetGraphView', 'DeviceFleetListView', 'DeviceFleetStaffView']
    .map(name => source(`New/${name}.swift`)).join('\n');
  for (const text of [page, toolbar, newViews]) {
    assert.doesNotMatch(text, /TextField|Toggle\(|Picker\(|PrimaryTransferPanel\(|DeviceEndpointsRow\(|\.propose\(|\.confirm\(|startPairingWindow|pairWithHost|removeDevice|updateEndpoint|FirstRunDefaults/);
    assert.doesNotMatch(text, /主機|遙控器|Color\.white/);
  }
  assert.match(page, /GlobalDMDeskController\.shared\.openDirect\(\.assistant\)/);
  assert.match(toolbar, /DeviceFleetToolbarContainer\(\)/);
  assert.match(newViews, /要加入設備、調整群組或權限，在私訊框跟 TATWO 助理說。/);
  assert.match(newViews, /打開私訊框/);
  assert.match(newViews, /重新檢查/);
  assert.match(newViews, /accessibilityAction \{ selected = selected == arrow\.id/);
  assert.match(newViews, /反方向（/);
  assert.match(newViews, /要改這條，跟 TATWO 助理說/);
  assert.match(newViews, /DeviceFleetCapabilities.all.map/);
  assert.match(newViews, /DeviceFleetCapabilities.labels\[\$0\]/);
  const methodTable = source('Facade/DeviceFleetGraph.swift');
  for (const description of ['看檔案與專案', '操作畫面', '派工跑指令', '安裝更新', '讀寫這台的記憶']) {
    assert.ok(methodTable.includes(description), description);
  }
});
