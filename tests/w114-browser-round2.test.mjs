// W114（使用者 2026-09-20 04:00 回饋）：點連結要切到新分頁、翻譯鈕進工具列、空間選單排版、標題對齊紅綠燈、側欄拖拽、額度列。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const read = p => readFileSync(join(root, p), 'utf8');
const app = p => read('App/Sources/Tatwo2/' + p);

test('點連結開的新分頁會切過去；⌘點擊才留在背景', () => {
  const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
  assert.match(bridge, /if \(target_disposition == CEF_WOD_NEW_BACKGROUND_TAB \|\| !opener\.onForegroundTabRequested\) opener\.onPopupRequested\(url\);\s*else opener\.onForegroundTabRequested\(url\);/);
  const surface = app('Browser/BrowserWorkSpaceCEFSurface.swift');
  assert.match(surface, /host\.onTabForegroundRequested = \{[\s\S]*?self\.registry\.openTab\(owner: source\.owner, url: url, folderID: source\.folderID\)[\s\S]*?self\.foregroundTabRequest = \(tab\.id,/);
  const design = app('Browser/BrowserWorkSpaceDesignView.swift');
  assert.match(design, /\.onChange\(of: runtime\.foregroundTabRequest\.serial\) \{ _, _ in if let id = runtime\.foregroundTabRequest\.tabID \{ store\.select\(registryID: id\) \} \}/);
  assert.ok(design.split('\n').length <= 1300);
});

test('翻譯鈕在工具列、可手動按；網頁上不再有浮動圓鈕', () => {
  const swift = app('Browser/BrowserPageTranslation.swift');
  assert.match(swift, /struct BrowserTranslateButton: View/);
  assert.match(swift, /func startManually\(\)/);
  assert.match(swift, /Button\(action: translator\.toggleAuto\)/);   // W119：翻譯鈕改成自動翻譯的開關
  assert.doesNotMatch(swift, /overlay\(alignment: \.topTrailing\)/);
  assert.match(app('Browser/BrowserWorkSpaceEmbeddedChrome.swift'), /BrowserTranslateButton\(translator: translator, host:/);
});

test('空間選單：寬度含內距（橘色不被裁）；標題中心釘在紅綠燈中心線', () => {
  assert.match(app('Browser/BrowserSpaceMenu.swift'), /\.padding\(14\)\s*\.frame\(width: 8 \* 26 \+ 7 \* 6 \+ 28, alignment: \.leading\)/);
  const sidebar = app('Chat/ChatPage+Sidebar.swift');
  assert.match(sidebar, /TrafficLightAlignedTitle\(height: WorkspaceSidebarMetrics\.spaceSwitcherHeight\) \{\s*browserSpaceSwitcher/);
  const aligned = app('Shell/TrafficLightAlignedTitle.swift');
  assert.match(aligned, /window\.standardWindowButton\(\.closeButton\)/);                          // 直接量，不用常數
  assert.match(aligned, /- proxy\.frame\(in: \.global\)\.minY\)/);                              // 不管容器在哪
});

test('側欄拖拽：釘選／取消釘選／移出書籤／移出珍藏／存進資料夾', () => {
  const drops = app('Browser/BrowserSidebarDrops.swift');
  for (const pair of ['("tatwo-browser-tab", .pinned)', '("tatwo-browser-tab", .tabs)', '("tatwo-browser-bookmark", .tabs)', '("tatwo-browser-favorite", .tabs)'])
    assert.ok(drops.includes(`case ${pair}:`), pair);
  assert.doesNotMatch(drops, /URL\(string: value\)|openTab\(/);   // 不把拖進來的文字當網址
  const design = app('Browser/BrowserWorkSpaceDesignView.swift');
  assert.match(design, /\.modifier\(BrowserSidebarDrop\(store: store, target: \.tabs\)\)/);
  assert.match(design, /\.modifier\(BrowserSidebarDrop\(store: store, target: \.pinned\)\)/);
  assert.match(app('Browser/BrowserBookmarkRows.swift'), /\.dropDestination\(for: String\.self\) \{ payloads, _ in store\.saveDraggedTabs\(payloads, into: folderID\) \}/);
});

test('額度：不認得、用量 0、沒有重置時間的時窗不畫成「剩 100%」', () => {
  assert.match(app('Facade/EngineQuotaDetail.swift'), /if used == 0, \(w\["resets_at"\] as\? String\) == nil \{ continue \}/);
});
