import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const app = path => read(`App/Sources/Tatwo2/${path}`);
const metrics = app('Visual/WorkspaceSidebarMetrics.swift');
const tokens = app('Visual/LiquidGlassTokens.swift');
const row = app('Browser/BrowserTabRow.swift');
const design = app('Browser/BrowserWorkSpaceDesignView.swift');
const toolbar = app('Browser/EmbeddedBrowserToolbar.swift').split('struct EmbeddedBrowserToolbar: View')[1];
const flow = app('Browser/Import/BrowserImportFlowView.swift');
const notice = app('New/ComputerUseConsentPrompt.swift');
const settings = app('Shell/ChatPageSettings.swift');
const components = app('Browser/BrowserSettingsComponents.swift');
const section = (source, start, end) => {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `${start} / ${end}`);
  return source.slice(from, to);
};
function constant(source, name, value) {
  const literal = String(value).replace('.', '\\.');
  assert.match(source, new RegExp(`static let ${name}(?:: \\w+)? = ${literal}(?:\\s|$)`), name);
}
function uses(source, names, owner = 'BrowserSidebarMetrics') {
  for (const name of names) assert.ok(source.includes(`${owner}.${name}`), `${owner}.${name}`);
}

test('W54 v10 exact browser geometry has one named-token authority', () => {
  for (const [name, value] of Object.entries({
    omniboxHeight: 34, omniboxCornerRadius: 9, omniboxFontSize: 12.5,
    omniboxHintFontSize: 11, sleepingOpacity: 0.55, sleepingFontSize: 10.5,
    selectedHostFontSize: 11, downloadsWidth: 226, downloadsCornerRadius: 12,
    downloadTitleFontSize: 12.5, downloadProgressHeight: 4, downloadProgressRadius: 2,
    importSheetWidth: 860, importSheetCornerRadius: 14, importSourceColumns: 4,
    importDataColumns: 2, importStepFillOpacity: 0.14, importStepBorderWidth: 1,
    importKeySize: 44, importProgressSize: 40, importCompletionSize: 22,
    settingsNavWidth: 200, settingsCardRadius: 12, settingsCardVerticalPadding: 12,
    settingsCardHorizontalPadding: 14, settingsNumberSize: 18, settingsKeyWidth: 150,
    settingsControlFontSize: 11.5, settingsDisabledOpacity: 0.5,
  })) constant(metrics, name, value);
  for (const [name, value] of Object.entries({
    islandNoticeWidth: 346, islandNoticeRadius: 22, islandNoticeTitleSize: 13.5,
    islandNoticeDetailSize: 11.5, islandNoticeCountdownSize: 10.5,
    islandNoticeButtonSize: 30, islandNoticeInfoSize: 26,
  })) constant(tokens, name, value);
});

test('W54 four requested views contain no naked font, padding, frame or corner size', () => {
  for (const file of ['Browser/BrowserTabRow.swift', 'Browser/BrowserWorkSpaceCEFSurface.swift',
    'Browser/Import/BrowserImportFlowView.swift', 'Browser/BrowserPasswordsSettingsView.swift']) {
    const source = app(file);
    assert.doesNotMatch(source, /\.font\(\.system\(size:\s*\d/, file);
    assert.doesNotMatch(source, /\.padding\((?:\.\w+,\s*)?\d/, file);
    assert.doesNotMatch(source, /\.(?:frame|cornerRadius)\((?:width:|height:|maxWidth:|minHeight:)?\s*\d/, file);
  }
  const chrome = app('Browser/BrowserWorkSpaceEmbeddedChrome.swift');
  for (const source of [toolbar, notice, components, chrome,
    design.slice(design.indexOf('struct BrowserWorkSpaceDesignView:'))]) {
    assert.doesNotMatch(source, /\.font\(\.system\(size:\s*\d|\.padding\((?:\.\w+,\s*)?\d/);
    assert.doesNotMatch(source, /Color\(red:\s*\d/);
  }
  uses(design, ['browserFieldFill', 'browserFolderFill', 'browserShadowColor'], 'LiquidGlassTokens');
});

test('W67 supersedes W54 idle geometry while retaining its editing and dynamic-hint contract', () => {
  uses(toolbar, ['collapsedHeight', 'editorFontSize', 'hintFontSize'], 'BrowserOmniboxMetrics');
  assert.match(toolbar, /Text\(labelOverride \?\? BrowserOmniboxPresentation.domain\(for: state.urlString\)\)/);
  // Hints follow the user's current map, including standard defaults.
  assert.doesNotMatch(toolbar, /Text\("⌘L/, 'omnibox hint must not hardcode a shortcut');
  assert.match(toolbar, /addressShortcutHint\.map \{[^}]*編輯 · Esc 還原[^}]*\} \?\? "Esc 還原"/);
  assert.match(toolbar, /Text\(editHint\)/);
  assert.match(toolbar, /onReceive\(NotificationCenter.default.publisher\(for: BrowserShortcutMap.changed\)\)/);
  assert.match(toolbar, /func focusAddressHint\(/);
  assert.match(toolbar, /map\.combos\(for: \.focusAddressBar\)\.first\?\.display/);
  assert.match(toolbar, /\.onExitCommand \{\s*addressText = state.urlString \?\? ""\s*dismissEditor\(\.escape\)/);
  assert.match(toolbar, /private func dismissEditor[\s\S]*?addressFieldFocused.wrappedValue = false/);
  assert.match(toolbar, /accessibilityIdentifier\("browser.omnibox"\)/);
});

test('W54 space dots and folder rows expose accessibility identifiers, not just labels', () => {
  const design = read('App/Sources/Tatwo2/Browser/BrowserWorkSpaceDesignView.swift');
  assert.match(design, /accessibilityIdentifier\("browser\.space\./);
  const folderSources = design + app('Browser/BrowserBookmarkRows.swift');
  const folders = folderSources.match(/accessibilityIdentifier\("browser\.folder\.\\\(/g) ?? [];
  assert.equal(folders.length, 2, 'both workspace and session folder rows need identifiers');
});

test('W54 every shared row owner carries title, identity and sleep state', () => {
  uses(row, ['sleepingOpacity', 'sleepingFontSize', 'selectedHostFontSize']);
  assert.match(row, /if sleeping \{\s*Text\("睡眠中"\)/);
  assert.match(row, /variant == \.workspace, selected, let host/);
  assert.match(row, /\.accessibilityLabel\(title\)/);
  assert.match(row, /accessibilityIdentifier\("browser.tab.\\\(tabID\)"\)/);
  assert.match(row, /let tabID: String/);
  const session = section(design, 'private func sessionTabRow', 'private var spaceControls:');
  assert.match(session, /tabID: tab.id.uuidString/);
  assert.match(session, /sleeping: tab.isSleeping/);
  assert.match(design, /registryID: \$0.id/);
  assert.match(design, /tabID: tab.registryID\?\.uuidString/);
  assert.match(app('Browser/EmbeddedBrowserView.swift'), /tabID: tab.id.uuidString/);
});

test('W54 downloads retain real actions and render a compact, progress-aware panel', () => {
  const downloads = section(design, 'private var downloadsPopover:', '// MARK: - Sidebar sections:');
  uses(downloads, ['downloadsWidth', 'downloadsCornerRadius', 'downloadTitleFontSize',
    'downloadProgressHeight', 'downloadProgressRadius']);
  assert.match(design, /if !downloadStore.downloads.isEmpty/);
  uses(design, ['downloadBadgeSize', 'downloadBadgeOffsetX', 'downloadBadgeOffsetY']);
  assert.match(downloads, /if !download.state.isTerminal/);
  assert.match(downloads, /download.received[\s\S]*download.total/);
  for (const action of ['preview', 'reveal', 'hide']) assert.ok(downloads.includes(`downloadStore.${action}(download)`));
  assert.match(downloads, /Button\("清除紀錄", action: downloadStore.clearDownloads\)/);
});

test('W54 one Island card style serves ask, confirm and info without changing resolution', () => {
  uses(notice, ['islandNoticeWidth', 'islandNoticeRadius', 'islandNoticeTitleSize',
    'islandNoticeDetailSize', 'islandNoticeCountdownSize', 'islandNoticeButtonSize',
    'islandNoticeInfoSize'], 'LiquidGlassTokens');
  assert.match(tokens, /islandNoticeFill = Color\(red: 21 \/ 255, green: 20 \/ 255, blue: 18 \/ 255\)/);
  assert.match(tokens, /islandNoticeDetailColor = Color\(red: 184 \/ 255, green: 176 \/ 255, blue: 164 \/ 255\)/);
  assert.match(tokens, /islandNoticeCountdownColor = Color\(red: 142 \/ 255, green: 134 \/ 255, blue: 122 \/ 255\)/);
  assert.match(tokens, /islandNoticeAllowFill = Color\(red: 58 \/ 255, green: 90 \/ 255, blue: 63 \/ 255\)/);
  assert.match(notice, /Text\(detail\)[\s\S]*?\.lineLimit\(1\)\.truncationMode\(\.tail\)/);
  assert.match(notice, /info: request.kind == \.info/);
  assert.match(notice, /if request.kind != \.info/);
  assert.match(notice, /IslandNotice.shared.resolve\(\.allow, id: request.id\)/);
  assert.match(notice, /IslandNotice.shared.resolve\(\.cancel, id: request.id\)/);
  assert.match(notice, /request.deadline.timeIntervalSince\(context.date\)/);
});

test('W54 import keeps all four states, true progress and right-aligned existing actions', () => {
  uses(flow, ['importSheetWidth', 'importSheetCornerRadius', 'importSourceColumns', 'importDataColumns',
    'importStepFillOpacity', 'importStepBorderWidth', 'importKeySize', 'importProgressSize', 'importCompletionSize']);
  assert.match(flow, /\["1 來源", "2 資料", "3 Keychain", "4 進度 → 完成"\]/);
  assert.match(flow, /HStack\(alignment: \.top, spacing: BrowserSidebarMetrics.laneRowSpacing\) \{\s*Text\("🔑"\)/);
  assert.equal((flow.match(/Circle\(\).inset\(by: BrowserSidebarMetrics.importProgressInset\)/g) ?? []).length, 2);
  assert.match(flow, /trim\(from: 0, to: progress.fraction\)/);
  assert.match(flow, /Text\(count.label\).monospacedDigit\(\)/);
  assert.match(flow, /private var footer:[\s\S]*?HStack[^{]+\{\s*Spacer\(\)/);
  assert.match(flow, /interactiveDismissDisabled\(coordinator.isRunning\)/);
  assert.match(flow, /onDisappear \{ coordinator.cancel\(\) \}/);
});

test('W54 settings use numbered warm cards, three-column rows and immutable AI values', () => {
  uses(settings, ['settingsNavWidth', 'settingsCardRadius', 'settingsCardVerticalPadding', 'settingsCardHorizontalPadding']);
  uses(components, ['settingsNumberSize', 'settingsKeyWidth', 'settingsControlFontSize', 'settingsDisabledOpacity']);
  assert.match(settings, /browserHumanSecurityColumn\s*Divider\(\)\s*browserAISecurityColumn/);
  const ai = section(settings, 'private var browserAISecurityColumn:', 'private var browserDiagnosticsSettings:');
  assert.doesNotMatch(ai, /Toggle|Picker|Button|Binding|Slider|Stepper/);
  assert.match(ai, /\.disabled\(true\).allowsHitTesting\(false\)/);
  assert.match(components, /struct BrowserSettingsPolicyValue[\s\S]*allowsHitTesting\(false\)/);
  assert.match(settings, /browserSettingsCard\("快捷鍵"\) \{ BrowserShortcutsSettingsView\(\) \}/);
  assert.match(settings, /BrowserPasswordsSettingsView\(\)/);
});

test('W54 accessibility measurement uses actual raw-value identifiers and no group indices', () => {
  const picker = app('Shell/WorkspaceSidebarModePicker.swift');
  assert.match(picker, /\.accessibilityLabel\(mode.displayName\)/);
  assert.match(picker, /accessibilityIdentifier\("workspace.mode.\\\(mode.rawValue\)"\)/);
  assert.match(design, /accessibilityIdentifier\("browser.newTab"\)/);
  assert.match(app('Browser/BrowserSpaceMenu.swift'), /accessibilityLabel\(space.name\)/);   // W112：空間圓點搬到獨立檔
  assert.ok(((design + app('Browser/BrowserBookmarkRows.swift')).match(/accessibilityLabel\(folder.name\)/g) ?? []).length >= 2);
  const perf = read('scripts/browser-perf.sh');
  for (const identifier of ['workspace.mode.Browser', 'workspace.mode.Chat', 'browser.omnibox', 'browser.newTab', 'browser.tab.']) {
    assert.ok(perf.includes(identifier), identifier);
  }
  assert.match(perf, /attribute "AXIdentifier"/);
  assert.doesNotMatch(perf, /text field 1 of group|splitter group 1/);
});

test('W54 deprecated settings aliases point to canonical tokens rather than duplicate literals', () => {
  const aliases = app('Browser/BrowserSettingsMetrics.swift');
  assert.equal((aliases.match(/@available\(\*, deprecated, renamed:/g) ?? []).length, 6);
  assert.equal((aliases.match(/= BrowserSidebarMetrics\./g) ?? []).length, 6);
  assert.match(metrics, /@available\(\*, deprecated, renamed: "importKeySize"\)/);
});
