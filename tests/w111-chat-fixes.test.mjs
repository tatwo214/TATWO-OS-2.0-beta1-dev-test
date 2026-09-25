// W111（使用者 2026-09-19）：聊天表格把文字擠爆、Claude 回覆的頭像偶爾變 GPT、錯誤卡片退回灰框、設定有幾頁關不掉。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const read = p => readFileSync(join(root, 'App/Sources/Tatwo2', p), 'utf8');

test('表格：每格在自己的欄裡換行（NSTextTable），不再用 tab 對欄', () => {
  const flow = read('Chat/ChatPageLeafViews+TranscriptFlow.swift');
  assert.doesNotMatch(flow, /configureTableTabs|appendTable\(/);
  assert.match(flow, /NSTextTableBlock\(table: textTable, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1\)/);
  assert.match(flow, /block\.setValue\(shares\[column\], type: \.percentageValueType, for: \.width\)/);
  assert.match(flow, /return tableAttributedString\(/);   // 每格自己的段落樣式，不能被整段 style 蓋掉
  assert.doesNotMatch(flow + read('Chat/ChatPageLeafViews+SelectableText.swift'), /chatTranscriptTableColumnCount|adaptStructuredLayoutIfNeeded/);   // 舊後處理會把第一格樣式套到整張表
  assert.match(flow, /\$1\.value >= 0x2E80 \? 2 : 1/);      // 中日韓字算兩格寬
});

test('頭像：引擎回報的模型要存檔；換引擎不沿用上一家回報的模型；回覆中就標上', () => {
  const store = read('Facade/ChatLiveStore.swift');
  assert.match(store, /var modelID: String\? = nil/);
  assert.match(store, /modelID = m\.modelID/);
  assert.match(store, /message\.modelID = modelID/);
  const engine = read('Facade/ChatLiveEngine.swift');
  assert.match(engine, /if attestedEngine\[threadID\] != engine \{ attestedModel\[threadID\] = nil; attestedEngine\[threadID\] = engine \}/);
  assert.match(engine, /row\.modelID = attestedModel\[threadID\]/);
});

test('錯誤卡片：全 App 同一套液態表面、左緣對齊回覆文字欄', () => {
  const card = read('New/ChatErrorCard.swift');
  assert.doesNotMatch(card, /ChatErrorCardSurface|Color\.primary\.opacity\(0\.075\)/);
  assert.match(card, /\.chatLiquidSection\(cornerRadius: 12\)\s*\.padding\(\.leading, Self\.textColumnInset\)/);
  assert.match(card, /static let textColumnInset: CGFloat = 34/);   // 頭像 24 + 間距 10
});

// W112 起關閉不再用按鈕：點浮層外的空白與 Esc 就關得掉，殼上不留 ✕。
test('設定：每一頁都關得掉（點外面空白＋Esc），殼上沒有 ✕', () => {
  const settings = read('Shell/ChatPageSettings.swift');
  assert.match(settings, /TatwoSettingsShell\(section: \$section\) \{/);
  assert.match(settings, /Button\("關閉設定", action: onClose\)\.keyboardShortcut\(\.cancelAction\)/);   // 浮層拿不到焦點，onExitCommand 收不到 Esc
  assert.doesNotMatch(settings, /onExitCommand/);
  assert.doesNotMatch(settings, /accessibilityIdentifier\("settings-close"\)/);
  // 點浮層外的暗幕關閉是既有行為，不能被拿掉。
  const panels = read('Chat/ChatPage+Panels.swift');
  assert.match(panels, /onTapGesture \{\s*\n\s*withAnimation\(\.easeOut\(duration: 0\.18\)\) \{ showSettingsPage = false \}/);
});
