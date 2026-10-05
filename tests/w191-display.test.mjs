import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const source = path => readFileSync(new URL(`../App/Sources/Tatwo2/${path}.swift`, import.meta.url), 'utf8');

test('M9 display discovery is demanded by use and follows system events without polling', () => {
  const service = source('Display/DisplayControlService');
  const ui = source('New/DisplaySettingsView').split('#if DEBUG')[0];
  assert.doesNotMatch(service, /Timer|scheduledTimer|withTimeInterval: 2/);
  assert.match(service, /if discoveryNeeded \{ refresh\(\) \}/);
  assert.match(service, /settingsVisible \|\| (settings\.keyboardDefaultPending \|\| )?settings\.keyboardEnabled \|\| settings\.shades\.values\.contains/);
  assert.match(service, /didChangeScreenParametersNotification/);
  assert.match(service, /didWakeNotification/);
  assert.match(service, /didBecomeActiveNotification/);
  assert.match(ui, /\.onAppear \{ service\.settingsDidOpen\(\) \}/);
  assert.match(ui, /\.onDisappear \{ service\.settingsDidClose\(\) \}/);
});

test('M10 unavailable display, write failures and key tap failures have reasons and recovery on cards', () => {
  const ui = source('New/DisplaySettingsView').split('#if DEBUG')[0];
  const service = source('Display/DisplayControlService');
  assert.match(ui, /case \.unavailable: "無法調整"/);
  assert.match(ui, /if let reason = service\.failureReason\(for: display\)/);
  assert.match(ui, /Text\(reason\)/);
  assert.match(ui, /OSChipButton\(title: "重試", action: \{ service\.refresh\(\) \}\)/);
  assert.match(ui, /if let reason = service\.keyboardError/);
  assert.match(ui, /OSChipButton\(title: "重試", action: \{ service\.updateKeyboardTap\(\) \}\)/);
  assert.match(ui, /OSChipButton\(title: "打開系統設定", action: openSettings\)/);
  for (const reason of [
    '這台螢幕沒有回應亮度調整，已改用軟體調光。',
    '這台螢幕沒有回應音量調整，暫時無法調音量。',
    '目前無法在這台螢幕加上遮光，請重試。',
    '鍵盤控制沒有啟動，請重試或重新確認系統權限。',
  ]) assert.ok(service.includes(reason), reason);
});

test('M11 display acceptance fixtures and read-only probe are fully inside DEBUG', () => {
  const acceptance = source('Display/DisplayAcceptance').trim();
  assert.ok(acceptance.startsWith('#if DEBUG\n'), 'DEBUG must precede every import and fixture');
  assert.ok(acceptance.endsWith('\n#endif'), 'DEBUG must cover the probe and final declaration');
});

test('M17 display permission copy consistently includes the old permission name', () => {
  const ui = source('New/DisplaySettingsView').split('#if DEBUG')[0];
  const permissionLines = ui.split('\n').filter(line => line.includes('裝置控制和資料取用'));
  assert.equal(permissionLines.length, 2, 'both granted and missing permission descriptions');
  for (const line of permissionLines) assert.ok(line.includes('裝置控制和資料取用（舊稱輔助使用）'), line);
});
