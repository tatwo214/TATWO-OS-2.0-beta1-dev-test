// W112（使用者 2026-09-20）：「設定頁本來就預設點空白可退出 不要做按鈕 以及目前設定頁每頁比例都不一樣
// 應該固定 字體大小、排版、筐尺寸 以space頁為標準」。
// 這支測試釘的是排版契約：外框一個尺寸、每頁同一組標題列與內距、沒有關閉／完成鈕、Esc 還在。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const read = p => readFileSync(join(root, 'App/Sources/Tatwo2', p), 'utf8');

const shell = read('Shell/ChatPageSettings.swift');

// 十二頁各自的實作檔（Space 本來就是標準，排版不動，所以不在下面的標題列名單裡）。
const pageFiles = {
  'Issue List': 'Shell/ChatPageSettings.swift',
  '瀏覽器': 'Shell/ChatPageSettings.swift',
  'GitHub': 'Shell/ChatPageSettings.swift',
  '代理帳戶＆錢包': 'Custody/AgentAccountsSettingsView.swift',
  '模型登入': 'New/EngineLoginCard.swift',
  'Tatwo Island': 'New/TatwoIslandSettingsView.swift',
  'Computer Use': 'New/ComputerUseSettingsView.swift',
  '設備': 'New/DevicesCard.swift',
  'Plugin': 'New/PluginSettingsView.swift',
  // W160：「文件」併進 OS（OS › 文件）；OS 頁本體是 OSSettingsPage。
  'OS': 'New/OSSettingsPage.swift',
};

// 標題列以外、也要一起清乾淨的設定頁檔案。
const extraFiles = ['New/GitHubAccountsCard.swift'];
const allFiles = [...new Set([...Object.values(pageFiles), ...extraFiles])];

test('外框只有一個尺寸：780×560，沒有哪一頁自己撐大', () => {
  assert.match(shell, /static let shellWidth: CGFloat = 780/);
  assert.match(shell, /static let shellHeight: CGFloat = 560/);
  assert.match(shell,
    /\.frame\(width: TatwoSettingsPageMetrics\.shellWidth,\s*\n\s*height: TatwoSettingsPageMetrics\.shellHeight\)/);
  // 舊的 agentAccounts 1080×700 例外必須消失。
  assert.doesNotMatch(shell, /1080/);
  assert.doesNotMatch(shell, /section == \.agentAccounts \? /);
});

test('共用元件存在：內距 14、區塊間距 12、標題 .headline、副標 .caption＋secondary', () => {
  assert.match(shell, /enum TatwoSettingsPageMetrics \{/);
  assert.match(shell, /static let inset: CGFloat = 14/);
  assert.match(shell, /static let sectionSpacing: CGFloat = 12/);
  assert.match(shell, /struct TatwoSettingsPageHeader<Trailing: View>: View \{/);
  const header = shell.slice(shell.indexOf('struct TatwoSettingsPageHeader<Trailing: View>'),
    shell.indexOf('struct TatwoSettingsShell<Content: View>'));
  assert.match(header, /Text\(title\)\.font\(\.headline\)/);
  assert.match(header, /Text\(subtitle\)\s*\n\s*\.font\(\.caption\)\s*\n\s*\.foregroundStyle\(\.secondary\)/);
  // 標題列自己不帶關閉鈕。
  assert.doesNotMatch(header, /關閉|xmark|完成/);
  // 不給 trailing 的頁面也能用。
  assert.match(shell, /extension TatwoSettingsPageHeader where Trailing == EmptyView/);
});

test('十一頁都改用同一組標題列與內距（Space 本來就是標準）', () => {
  for (const [title, file] of Object.entries(pageFiles)) {
    const source = read(file);
    assert.match(source, /TatwoSettingsPageHeader\(/, `${file} 沒有用共用標題列`);
    assert.ok(source.includes(`title: "${title}"`), `${file} 少了「${title}」的標題`);
    assert.match(source, /TatwoSettingsPageMetrics\.inset/, `${file} 的內距沒有統一`);
  }
});

test('設定相關檔案不再有各頁自訂大標與 22 內距', () => {
  for (const file of allFiles) {
    const source = read(file);
    assert.doesNotMatch(source, /\.title3|\.title2|settingsPageTitleFontSize/, `${file} 還有自訂大標字級`);
    assert.doesNotMatch(source, /\.padding\(22\)|padding\(\.horizontal, 22\)|settingsPagePadding/, `${file} 還有 22 內距`);
  }
});

test('沒有「完成」按鈕，殼上也沒有 ✕', () => {
  for (const file of allFiles) {
    assert.doesNotMatch(read(file), /Button\("完成"\)/, `${file} 還有「完成」鈕`);
  }
  assert.doesNotMatch(shell, /accessibilityIdentifier\("settings-close"\)/);
  assert.doesNotMatch(shell, /Image\(systemName: "xmark"\)/);
  assert.match(shell, /init\(section: Binding<Section>, @ViewBuilder content: \(\) -> Content\)/);
  assert.match(shell, /TatwoSettingsShell\(section: \$section\) \{/);
});

test('Esc 那顆看不見的按鈕還在（浮層拿不到焦點，只有鍵盤捷徑收得到）', () => {
  assert.match(shell, /Button\("關閉設定", action: onClose\)\.keyboardShortcut\(\.cancelAction\)/);
  assert.doesNotMatch(shell, /onExitCommand/);
});

test('框變窄之後，內容過長／過寬的頁面在框內捲動', () => {
  // 代理帳戶的七欄帳號表：框內橫向捲動，不把浮層撐寬。
  const accounts = read('Custody/AgentAccountsSettingsView.swift');
  assert.match(accounts, /ScrollView\(\.horizontal\) \{\s*\n\s*BrowserAIVaultSettingsView/);
  assert.match(accounts, /\.fixedSize\(horizontal: false, vertical: true\)/);
  // 設備、模型登入原本沒有捲動，內容超過 560 高會被裁掉。
  for (const file of ['New/DevicesCard.swift', 'New/EngineLoginCard.swift']) {
    assert.match(read(file), /var body: some View \{\s*\n\s*ScrollView \{/, `${file} 少了外層 ScrollView`);
  }
});

test('Computer Use 的授權說明變成那一頁的副標，不再是設定頁外層自己補的一行', () => {
  assert.doesNotMatch(shell, /授權層級跟隨對話的權限設定/);
  const view = read('New/ComputerUseSettingsView.swift');
  assert.match(view, /授權層級跟隨對話的權限設定（要求核准／代我核准／完整存取權）/);
  assert.match(shell, /case \.computerUse:\s*\n\s*ComputerUseSettingsView\(onClose: onClose\)/);
});
