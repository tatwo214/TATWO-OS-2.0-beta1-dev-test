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
  'tatwo.island.glassOpacity',
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
  // 使用者 2026-09-19：黑瀏海只調左右寬度；高度＝這台螢幕的實體瀏海（各型號自己量），寬度下限不小於實體瀏海，圓角不跟著縮放。
  const collapsed = scaleOf('collapsedSize');
  assert.ok(collapsed.notch && !collapsed.glass, 'collapsedSize 只能吃黑瀏海倍率');
  assert.match(metrics, /width: max\(baseCollapsedSize\.width \* notchScale, minimumCollapsedWidth\),\s*height: hardwareNotch\?\.height \?\? baseCollapsedSize\.height/);
  assert.match(metrics, /hardwareNotch\.map \{ \$0\.width \+ hardwareNotchMargin \* 2 \}/);
  assert.match(metrics, /screen\.frame\.width - left\.width - right\.width/);
  assert.doesNotMatch(metrics, /baseCollapsedSize\.height \* notchScale|CornerRadius \* notchScale/);
  assert.match(shell, /TatwoIslandShellMetrics\.hardwareNotch = TatwoIslandShellMetrics\.hardwareNotch\(of: screen\)/);
  for (const name of ['expandedSize', 'expandedTopReverseCornerRadius', 'expandedBottomCornerRadius']) {
    const used = scaleOf(name);
    assert.ok(used.glass && !used.notch, `${name} 只能吃玻璃倍率`);
  }
  // 承載視窗要同時容得下兩邊，放大的一邊才不會被裁掉。
  assert.match(metrics, /static var expandedOverlaySize: NSSize \{[\s\S]*?max\(glassWidth, notchWidth\)/);

  // 設定頁真的有兩支各自綁定的滑桿。
  assert.match(view, /Slider\(value: value, in: widthOnly \? notchRange : TatwoIslandSettings\.scaleRange\)/);
  // 玻璃透明度：自己的鍵、自己的滑軌，拖的時候真的 Island 保持展開；只作用在玻璃那一層。
  assert.match(view, /Slider\(value: \$settings\.glassOpacity, in: TatwoIslandSettings\.glassOpacityRange\) \{ editing in\s*settings\.previewExpanded = editing/);
  assert.match(shell, /glassIsInteractive: glassIsInteractive\s*\)\s*\.opacity\(TatwoIslandSettings\.glassOpacityValue\)/);
  assert.match(view, /"黑瀏海寬度"[\s\S]{0,300}value: \$settings\.notchScale/);
  assert.match(view, /"玻璃尺寸"[\s\S]{0,200}value: \$settings\.glassScale/);
});

test('使用者 2026-09-19：Island 的畫法就是原版（mini 上那個），只多加自定義滑軌——不准有別的補丁', () => {
  // 「mini現在的os玻璃就是原版正確的 我們只是要加自定義滑軌 你要去看 避免打一堆補丁」
  assert.doesNotMatch(shell, /enum Style|styleValue|glassEnabled|notchFeather|HardwareNotchBlend/);
  assert.doesNotMatch(view, /TatwoIslandSettings\.Style|IslandStyleSwatch|notchFeather|瀏海暈開/);
  // 原版的畫法原文還在：黑瀏海在玻璃底下、收合時同一塊黑補回去、玻璃一層。
  assert.match(shell, /TatwoIslandNotchBlackPaint\(\s*progress: progress,\s*shellSize: geometry\.shellSize\s*\)\s*\.clipShape\(shellShape\)\s*\.allowsHitTesting\(false\)/);
  assert.match(shell, /if collapsedRecoveryOpacity > 0 \{/);
  assert.match(shell, /\.glassEffect\(\.regular\.interactive\(glassIsInteractive\), in: shellShape\)/);
  assert.match(shell, /let coreWidth = max\(0, shellSize\.width/);
  // 設定頁預覽照原設計：黑瀏海先畫、玻璃蓋在上面；玻璃上面沒有黑塊。
  assert.match(view, /notch\.fill\(\.black\)[^\n]*\.blur\(radius: 7\)[^\n]*\n\s*glass\(shape\)/);
});

test('Island 設定頁掛在設定的 Tatwo Island 分頁，不再是預留空頁', () => {
  assert.match(settingsPage, /case \.tatwoIsland:\s*\n\s*tatwoIslandContent/);
  assert.match(settingsPage, /private var tatwoIslandContent: some View \{[\s\S]{0,200}TatwoIslandSettingsView\(onClose: onClose\)/);
  assert.ok(!settingsPage.includes('目前沒有設定項目'), '預留空頁文案必須移除');
  assert.match(view, /Toggle\("", isOn: \$settings\.enabled\)/);
});

test('使用者 2026-09-19：拖尺寸滑桿時真的 Island 要即時變化', () => {
  // 尺寸倍率必須是畫面元件的輸入，否則 SwiftUI 不重畫；拖玻璃尺寸時暫時保持展開。
  assert.match(shell, /sizeScales: \[settings\.notchScale, settings\.glassScale, settings\.glassOpacity\]/);
  assert.match(shell, /@Published var previewExpanded = false/);
  assert.match(shell, /if wantsPreview \|\| IslandNotice\.shared\.current == nil \{ state\.holdOpen\(wantsPreview\) \}/);
  assert.match(view, /if holdsIslandOpen \{ settings\.previewExpanded = editing \}/);
});

