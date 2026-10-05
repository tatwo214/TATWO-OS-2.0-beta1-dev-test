import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const source = path => readFileSync(new URL(`../App/Sources/Tatwo2/${path}.swift`, import.meta.url), 'utf8');
const ui = source('New/DisplaySettingsView');
const production = ui.split('#if DEBUG')[0];

test('display section follows devices and preserves existing settings order and raw values', () => {
  const settings = source('Shell/ChatPageSettings');
  const section = settings.slice(settings.indexOf('enum Section:'), settings.indexOf('@State private var section:'));
  assert.deepEqual([...section.matchAll(/^        case (\w+)$/gm)].map(x => x[1]), [
    'start', 'space', 'issueList', 'browserManagement', 'agentAccounts', 'modelAccess',
    'tatwoIsland', 'computerUse', 'devices', 'display', 'plugin', 'github', 'os',
  ]);
  assert.match(section, /case \.display: "顯示器"/);
  assert.match(section, /case \.display: "display"/);
  assert.match(settings, /case \.display:\s*DisplaySettingsView\(\)/);
});

test('approved text, external-only cards, conditional volume and brand controls', () => {
  for (const text of [
    '顯示器', '外接螢幕的亮度與音量。', '硬體調光', '軟體調光', '亮度', '音量', '目前沒有接外接螢幕',
    '用鍵盤亮度鍵、音量鍵調外接螢幕', '調滑鼠所在的那台；按的時候 Tatwo Island 顯示百分比。',
    '權限已開（系統設定 › 隱私權與安全性 › 裝置控制和資料取用（舊稱輔助使用））', '打開系統設定',
    'MonitorControl 也在執行，兩邊同時調會互搶。確認這裡好用後，可以把它關掉。',
  ]) assert.ok(production.includes(text), `approved copy: ${text}`);
  assert.match(production, /listDisplays\(\)\.filter \{ !\$0\.isBuiltIn \}/);
  assert.match(production, /ForEach\(externalDisplays\)/);
  assert.match(production, /if display\.volume != nil/);
  assert.match(production, /Circle\(\)\.fill\(Color\.green\)/);
  assert.match(production, /if monitorControl\.isRunning/);
  assert.match(production, /setBrightness\(value, for: display\.id\)/);
  assert.match(production, /setVolume\(value, for: display\.id\)/);
  assert.match(production, /Slider\(value: value, in: 0\.\.\.100\)/);
  assert.match(production, /Toggle\([\s\S]*isOn: keyboardBinding\)/);
  assert.match(production, /set: \{ settings\.keyboardEnabled = \$0 \}/);
  assert.equal([...production.matchAll(/\.tint\(LiquidGlassTokens\.brandAccent\)/g)].length, 2);
  assert.doesNotMatch(production, /iPad|example|sample|fixture/i);
});

test('settings action is a glass chip and permission checks are gated by the keyboard toggle', () => {
  assert.match(production, /OSChipButton\(title: "打開系統設定", action: openSettings\)/);
  assert.match(production, /x-apple\.systempreferences:com\.apple\.preference\.security\?Privacy_Accessibility/);
  assert.doesNotMatch(production, /\.blue|systemBlue|borderedProminent|buttonStyle\(\.bordered/);
  const service = source('Display/DisplayControlService');
  const update = service.slice(service.indexOf('    func updateKeyboardTap()'));
  assert.match(update, /guard settings\.keyboardEnabled else \{[\s\S]*return\s*\}\s*hasDeviceControlPermission = permissionCheck\(\)/);
  assert.doesNotMatch(service + production, /AXIsProcessTrustedWithOptions|AXTrustedCheckOptionPrompt|CGRequest/);
});

test('Island uses existing notice slot, keeps one meter, and expires from the last feedback event', () => {
  const notice = source('New/IslandNotice');
  const renderer = source('New/ComputerUseConsentPrompt');
  assert.match(production, /publisher\(for: DisplayFeedback\.notification\)/);
  const meter = notice.slice(notice.indexOf('    func showDisplayMeter('), notice.indexOf('    /// Use the same callback'));
  assert.match(meter, /guard hostAvailable else \{ return \}/);
  assert.match(meter, /existing\?\.request\.id \?\? UUID\(\)/);
  assert.match(meter, /timeout: 1/);
  assert.match(meter, /existing\.request = request\s*scheduleTimeout\(existing\)/);
  assert.match(notice, /entry\.timer\?\.invalidate\(\)/);
  assert.match(notice, /entry\.request\.kind == \.info && entry\.request\.meter == nil/);
  assert.match(renderer, /if let meter = prompt\.displayMeter\?\.meter \{\s*IslandDisplayFeedbackContent/);
  const content = renderer.slice(renderer.indexOf('struct IslandDisplayFeedbackContent:'), renderer.indexOf('/// Preserve the former'));
  assert.match(content, /sun\.max\.fill/);
  assert.match(production, /speaker\.wave\.2\.fill/);
  assert.match(content, /Text\(meter\.displayName\)/);
  assert.match(content, /\.frame\(height: 3\)/);
  assert.doesNotMatch(content, /TatwoIslandShellShape|\.glassEffect|RoundedRectangle|\.shadow/);
});

test('normal launch starts the shared display service after the early selftest hook', () => {
  const app = source('Tatwo2App');
  assert.equal([...app.matchAll(/_ = DisplayControlService\.shared/g)].length, 1);
  assert.ok(app.indexOf('SelfTest.runIfRequested()') < app.indexOf('_ = DisplayControlService.shared'));
  assert.match(source('SelfTest'), /"w188ui"[\s\S]*DisplayUIAcceptance\.run\(\)/);
});

test('UI selftest renders all seven artifacts with fixture service, sliders, toggle and notices', () => {
  const acceptance = ui.split('#if DEBUG')[1];
  for (const artifact of [
    'a-hardware-volume.png', 'b-software.png', 'c-no-displays.png', 'd-keyboard-permitted.png',
    'e-keyboard-needs-permission.png', 'f-monitorcontrol.png', 'g-island-brightness-volume.png',
  ]) assert.ok(acceptance.includes(artifact));
  assert.match(acceptance, /TATWO2_SELFTEST_ARTIFACTS/);
  assert.match(acceptance, /DisplayControlService\(settings: settings, dimmer: dimmer, observe: false/);
  assert.match(acceptance, /DDCArm64\(transport: transport/);
  assert.match(acceptance, /brightnessBinding\(for: hardware\)\.wrappedValue = 72/);
  assert.match(acceptance, /volumeBinding\(for: hardware\)\.wrappedValue = 43/);
  assert.match(acceptance, /keyboardBinding\.wrappedValue = true/);
  assert.match(acceptance, /keyboardBinding\.wrappedValue = false/);
  assert.match(acceptance, /SUMMARY failures=/);
  assert.doesNotMatch(acceptance, /DisplayDiscovery\.discover|IOAVTransport\(|SoftwareDimmer\(|NSWorkspace\.shared\.open|DisplayControlService\.shared/);
});
