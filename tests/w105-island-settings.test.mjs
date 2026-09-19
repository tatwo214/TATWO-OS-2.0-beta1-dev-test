import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('../', import.meta.url));
const read = file => readFileSync(join(repo, 'App/Sources/Tatwo2', file), 'utf8');

const shell = read('Shell/TatwoIslandShell.swift');
const view = read('New/TatwoIslandSettingsView.swift');
const shield = read('New/ExportPrefsShield.swift');
const settingsPage = read('Shell/ChatPageSettings.swift');

const keys = [
  'tatwo.island.enabled',
  'tatwo.island.notchScale',
  'tatwo.island.glassScale',
  'tatwo.island.style',
];

test('W105 Island 設定的每個鍵都登記在匯出偏好隔離的出廠值裡', () => {
  const registry = shield.slice(
    shield.indexOf('factoryDefaults: [String: Any] = ['),
    shield.indexOf('\n    ]', shield.indexOf('factoryDefaults')));
  for (const key of keys) {
    assert.match(shell, new RegExp(`"${key.replace(/\./g, '\\.')}"`),
      `${key} 必須由 TatwoIslandSettings 定義`);
    assert.match(registry, new RegExp(`"${key.replace(/\./g, '\\.')}"\\s*:`),
      `${key} 未登記在 ExportPrefsShield.factoryDefaults`);
  }
  // 出廠值＝今天的外觀：開關開、兩組尺寸 1.0、經典風格。
  assert.match(registry, /"tatwo\.island\.enabled": true/);
  assert.match(registry, /"tatwo\.island\.notchScale": 1\.0/);
  assert.match(registry, /"tatwo\.island\.glassScale": 1\.0/);
  assert.match(registry, /"tatwo\.island\.style": "classic"/);
});

test('總開關預設開啟，且沒有動過滑桿時尺寸與過去完全相同', () => {
  assert.match(shell,
    /nonisolated static var isEnabled: Bool \{\s*UserDefaults\.standard\.object\(forKey: Key\.enabled\) as\? Bool \?\? true/);
  assert.match(shell, /static let defaultScale: Double = 1\b/);
  assert.match(shell, /static let scaleRange: ClosedRange<Double> = 0\.6\.\.\.1\.6/);
  assert.match(shell, /guard let value, value\.isFinite else \{ return defaultScale \}/);
  // 出廠基準數值不能被改動（倍率 1.0 時幾何與 W105 之前一致）。
  assert.match(shell, /static let baseCollapsedSize = NSSize\(width: 240, height: 33\)/);
  assert.match(shell, /static let baseExpandedSize = NSSize\(width: 648, height: 172\)/);
  assert.match(shell, /static let baseCollapsedTopReverseCornerRadius: CGFloat = 10/);
  assert.match(shell, /static let baseExpandedTopReverseCornerRadius: CGFloat = 22/);
  assert.match(shell, /static let baseCollapsedBottomCornerRadius: CGFloat = 17/);
  assert.match(shell, /static let baseExpandedBottomCornerRadius: CGFloat = 28/);
});

test('總開關關閉時 Island 視窗不顯示、輪詢計時器與 notice host 都停掉', () => {
  const show = shell.slice(shell.indexOf('    func show() {'), shell.indexOf('    func hide() {'));
  assert.match(show, /guard TatwoIslandSettings\.isEnabled else \{ hide\(\); return \}/,
    'show() 必須先看總開關');
  assert.ok(show.indexOf('panel.orderFrontRegardless()') > show.indexOf('TatwoIslandSettings.isEnabled'),
    '開關判斷要在 orderFront 之前');
  assert.ok(show.indexOf('Timer(timeInterval') > show.indexOf('TatwoIslandSettings.isEnabled'),
    '關閉時不得啟動指標輪詢計時器');

  const hide = shell.slice(shell.indexOf('    func hide() {'));
  const hideBody = hide.slice(0, hide.indexOf('\n    }'));
  assert.match(hideBody, /pointerTimer\?\.invalidate\(\)/);
  assert.match(hideBody, /pointerTimer = nil/);
  assert.match(hideBody, /IslandNotice\.shared\.hostAvailable = false/);
  assert.match(hideBody, /panel\.orderOut\(nil\)/);

  // 打開／關閉都不必重開 App：設定變動會廣播，controller 當場套用。
  assert.match(shell, /static let tatwoIslandSettingsChanged = Notification\.Name\("tatwo\.island\.settingsChanged"\)/);
  assert.match(shell, /forName: \.tatwoIslandSettingsChanged/);
  assert.match(shell, /private func applySettings\(\) \{\s*\n\s*guard TatwoIslandSettings\.isEnabled else \{ hide\(\); return \}\s*\n\s*show\(\)/);
  // 舊路徑會在 init 就宣告 host；那會讓關閉狀態仍然吃下 notice。
  const init = shell.slice(shell.indexOf('final class TatwoIslandShellController'), shell.indexOf('    func show() {'));
  assert.ok(!/IslandNotice\.shared\.hostAvailable = true/.test(init),
    'hostAvailable 只能由 show() 打開');
});

test('黑瀏海與玻璃是兩個獨立的尺寸鍵，各自只驅動自己那一半的幾何', () => {
  assert.match(shell, /static var notchScale: CGFloat \{ TatwoIslandSettings\.notchScaleValue \}/);
  assert.match(shell, /static var glassScale: CGFloat \{ TatwoIslandSettings\.glassScaleValue \}/);
  assert.notEqual('tatwo.island.notchScale', 'tatwo.island.glassScale');

  const metrics = shell.slice(shell.indexOf('enum TatwoIslandShellMetrics {'),
    shell.indexOf('@MainActor\nfinal class TatwoIslandShellState'));
  const scaleOf = name => {
    const at = metrics.indexOf(`static var ${name}`);
    assert.ok(at > 0, `${name} 必須是跟著設定走的計算屬性`);
    const body = metrics.slice(at, metrics.indexOf('static var', at + 10) === -1
      ? metrics.length : metrics.indexOf('static var', at + 10));
    return { notch: body.includes('notchScale'), glass: body.includes('glassScale') };
  };
  for (const name of ['collapsedSize', 'collapsedTopReverseCornerRadius', 'collapsedBottomCornerRadius']) {
    const used = scaleOf(name);
    assert.ok(used.notch && !used.glass, `${name} 只能吃黑瀏海倍率`);
  }
  for (const name of ['expandedSize', 'expandedTopReverseCornerRadius', 'expandedBottomCornerRadius']) {
    const used = scaleOf(name);
    assert.ok(used.glass && !used.notch, `${name} 只能吃玻璃倍率`);
  }
  // 承載視窗要同時容得下兩邊，放大的一邊才不會被裁掉。
  assert.match(metrics, /static var expandedOverlaySize: NSSize \{[\s\S]*?max\(glassWidth, notchWidth\)/);

  // 設定頁真的有兩支各自綁定的滑桿。
  assert.match(view, /Slider\(value: value, in: TatwoIslandSettings\.scaleRange\)/);
  assert.match(view, /"黑瀏海尺寸"[\s\S]{0,200}value: \$settings\.notchScale/);
  assert.match(view, /"玻璃尺寸"[\s\S]{0,200}value: \$settings\.glassScale/);
});

test('風格用與 Computer Use 相同的磚塊呈現方式，並真的改變 Island 的畫法', () => {
  assert.match(shell, /enum Style: String, CaseIterable, Identifiable, Sendable/);
  for (const style of ['classic', 'glass', 'solid']) {
    assert.match(shell, new RegExp(`case ${style}\\b`), `缺少風格 ${style}`);
  }
  // 與 ComputerUseSettingsView 同一種選擇器：allCases 逐一成為可點磚塊，選中描邊。
  const cu = read('New/ComputerUseSettingsView.swift');
  for (const source of [cu, view]) {
    assert.match(source, /ForEach\((ComputerUseSettings\.ArrowStyle|TatwoIslandSettings\.Style)\.allCases\) \{ style in/);
    assert.match(source, /let selected = settings\.\w+ == style/);
    assert.match(source, /\.buttonStyle\(\.plain\)/);
    assert.match(source, /RoundedRectangle\(cornerRadius: 10, style: \.continuous\)\s*\n\s*\.strokeBorder\(/);
    assert.match(source, /\.accessibilityAddTraits\(selected \? \[\.isSelected\] : \[\]\)/);
  }

  // 風格接到島本體：純玻璃不畫黑瀏海、實心黑不開玻璃。
  assert.match(shell, /style: settings\.style/);
  assert.match(shell, /let style: TatwoIslandSettings\.Style/);
  assert.match(shell, /if style != \.glass \{/);
  assert.match(shell, /glassEnabled: style != \.solid/);
  assert.match(shell, /if #available\(macOS 26\.0, \*\), glassEnabled \{/);
});

test('Island 設定頁掛在設定的 Tatwo Island 分頁，不再是預留空頁', () => {
  assert.match(settingsPage, /case \.tatwoIsland:\s*\n\s*tatwoIslandContent/);
  assert.match(settingsPage, /private var tatwoIslandContent: some View \{[\s\S]{0,200}TatwoIslandSettingsView\(onClose: onClose\)/);
  assert.ok(!settingsPage.includes('目前沒有設定項目'), '預留空頁文案必須移除');
  assert.match(view, /Toggle\("", isOn: \$settings\.enabled\)/);
});
