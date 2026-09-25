// W171：第一次打開不擋路、引導放在 設定 › 開始使用＋各分頁初始設定；Space 全新安裝直接有 Coder／CLI／Bot／Browser。
// 另外鎖住使用者點名「甜蜜點」的 Space 設定頁版面，以及對話裡的小表格樣式（2026-09-22）。
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const read = (p) => fs.readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');

test('W171 first run: safe defaults only, straight into the App', () => {
  const gate = read('Onboarding/OSOnboardingView.swift');
  assert.doesNotMatch(gate, /OSOnboardingView\(/, 'no blocking wizard');
  assert.match(gate, /\.background\(LiquidGlassTokens\.browserGroundFill\)/, 'gate paints its own ground (window is transparent)');
  const defaults = read('Onboarding/FirstRunDefaults.swift');
  assert.match(defaults, /draft\.engines = \[\]\n\s*do \{\n\s*try OSOnboarding\.install/, 'first run never touches engine rule files');
  assert.match(defaults, /guard awaitsDeviceConfirmation else/);
  assert.match(defaults, /guard DeviceStatusReader\.registry\(environment: environment\)\.isEmpty else/, 'switching roles only before any pairing');
  assert.match(defaults, /archive\/first-run-default-/);
  assert.match(defaults, /MANIFEST\.md/);
  assert.doesNotMatch(defaults, /removeItem/, 'archive, never delete');
});

test('W171 settings: 開始使用 first, dots on pending tabs, banners on the four tabs', () => {
  const settings = read('Shell/ChatPageSettings.swift');
  assert.match(settings, /enum Section: String, CaseIterable, Identifiable \{\n[^\n]*\n\s*case start\n\s*case space/);
  assert.match(settings, /case \.start: "開始使用"/);
  assert.match(settings, /else if SetupChecklist\.shared\.remaining > 0 \{ section = \.start \}/);
  assert.match(settings, /checklist\.pendingSections\.contains\(item\)/);
  assert.match(settings, /GitHubBackupSetupBanner\(\)/);
  assert.match(read('New/EngineLoginCard.swift'), /SetupBanner\(done: !loggedIn\.isEmpty/);
  assert.match(read('New/OSSettingsPage.swift'), /for row in pending \{ try EngineLinks\.link\(row\) \}/);
  const devices = read('New/DevicesCard.swift');
  assert.match(devices, /FirstRunDefaults\.switchToExistingPrimary\(\)/);
  assert.match(devices, /\.confirmationDialog\("改成加入你已經有的那台？"/, 'role switch asks first');
  const guide = read('Shell/SetupGuide.swift');
  for (const title of ['登入一個 AI 模型', '讓你的 AI 用同一套規則', '這台 Mac 的名字和身分', '備份到你的 GitHub', 'Computer Use 權限']) {
    assert.ok(guide.includes(`"${title}"`), title);
  }
  assert.doesNotMatch(guide, /borderedProminent|Color\.accentColor|\.blue\b/, 'no blue buttons (settings ruling)');
  assert.match(read('Chat/ChatPage+Sidebar.swift'), /SidebarSetupNudge\(model: model\) \{\n\s*updateSettingsSection = \.start/);
});

test('W171 Space: fresh install gets one default domain; the Space page layout stays as is', () => {
  const controller = read('Space/SpaceWorkspaceController.swift');
  assert.match(controller, /name: SpaceCreation\.defaultDomainName/);
  // 使用者：「space 現在 ui 是甜蜜點 不要破壞」——設定版面的關鍵元件一個都不能少。
  const view = read('Space/SpaceSetupPreviewView.swift');
  for (const piece of ['Text("Work Space").font(.title2.weight(.semibold))', 'Text("只管理「\\(domain.name)」的 work space。")',
                       'Image(systemName: "line.3.horizontal")', '"checkmark.square.fill" : "square"', 'Button("開搭建對話")',
                       'Image(systemName: "chevron.up")', 'Image(systemName: "chevron.down")', 'Button("+add")']) {
    assert.ok(view.includes(piece), 'Space page keeps: ' + piece);
  }
});

test('Transcript tables keep the look the user liked (semibold header, darker header rule, light row rules)', () => {
  const flow = read('Chat/ChatPageLeafViews+TranscriptFlow.swift');
  assert.match(flow, /NSFont\.systemFont\(ofSize: TatwoChatTranscriptVisualMetrics\.tableHeaderPointSize, weight: \.semibold\)/);
  assert.match(flow, /block\.setWidth\(rowIndex == 0 \? 1 : 0\.5, type: \.absoluteValueType, for: \.border, edge: \.maxY\)/);
  assert.match(flow, /block\.setBorderColor\(NSColor\.separatorColor\.withAlphaComponent\(rowIndex == 0 \? 0\.9 : 0\.45\), for: \.maxY\)/);
  assert.match(flow, /block\.setWidth\(column == 0 \? 0 : 8, type: \.absoluteValueType, for: \.padding, edge: \.minX\)/);
});
