// W112 第一批（使用者 2026-09-20）：Claude 額度標籤、空間改名改色、Chat 固定鈕位置、獨立 Browser 頂列隱形。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const read = p => readFileSync(join(root, 'App/Sources/Tatwo2', p), 'utf8');

test('額度：不替不認得的時窗取名字；原始回傳只有代號與數字', () => {
  const quota = read('Facade/EngineQuotaDetail.swift');
  assert.doesNotMatch(quota, /nimbus_quill|Fable 週上限|Opus／Fable/);
  assert.match(quota, /label: "其他額度（\\\(key\)）"/);
  assert.match(quota, /detail\.rawLines = payload\.keys\.sorted\(\)\.filter \{ \$0 != "limits" \}\.map/);   // W117：limits 陣列另外列
  assert.doesNotMatch(quota.slice(quota.indexOf('detail.rawLines ='), quota.indexOf('detail.rawLines =') + 420), /token|accessToken|Bearer/i);
  // W120（使用者 09-21：「查看原始回傳不用」）：卡片不再有原始回傳；重置券改成「券符號 ×N」，0 張變暗不能點。
  const card = read('New/EngineLoginCard.swift');
  assert.doesNotMatch(card, /DisclosureGroup\(/);   // 註解裡會引用使用者原話，所以釘元件，不釘字樣
  assert.match(card, /Image\(systemName: "ticket"\)/);
  assert.match(card, /\.disabled\(tickets <= 0\)/);
  assert.match(card, /\.opacity\(tickets > 0 \? 1 : 0\.35\)/);
  assert.match(quota, /\["availableCount"\] as\? NSNumber\)\?\.intValue/);
  // W121（使用者 09-21：「顏色變很霧」「這個說明也不要」）：關鍵數字用主色、軌道看得見；底部的拖拽說明移除。
  assert.match(card, /Text\("剩 \\\(Int\(remaining\.rounded\(\)\)\)%"\)[\s\S]{0,120}foregroundStyle\(\.primary\)/);
  assert.match(card, /Capsule\(\)\.fill\(Color\.primary\.opacity\(0\.12\)\)/);
  assert.doesNotMatch(card, /foregroundStyle\(\.tertiary\)[\s\S]{0,40}\n\s*\}/);
  assert.doesNotMatch(card, /往左拖一列/);
});

test('空間：顏色欄位舊檔相容、刪除先封存、右鍵開 Dia 式選單', () => {
  const registry = read('Browser/BrowserTabRegistry.swift');
  assert.match(registry, /var color: String\? = nil/);
  assert.match(registry, /func archiveAndRemoveSpace\(_ id: UUID\) -> URL\?/);
  assert.match(registry, /appendingPathComponent\("archived-spaces", isDirectory: true\)/);
  assert.match(registry, /\(try\? data\.write\(to: file, options: \.atomic\)\) != nil else \{ return nil \}[\s\S]{0,120}removeSpace\(id, closingTabs: true\)/);   // 寫成功才移除
  assert.match(registry, /spaces\.filter\(\{ !\$0\.isSessionSpace \}\)\.count > 1 else \{ return nil \}/);   // 最後一個不給刪
  const menu = read('Browser/BrowserSpaceMenu.swift');
  assert.equal((menu.match(/"(graphite|green|blue|purple|yellow|pink|red|orange)"/g) || []).length >= 16, true);
  for (const text of ['改名…', '刪除…', '至少要留一個空間']) assert.ok(menu.includes(text), text);
  assert.match(menu, /event\.type == \.rightMouseDown \|\| \(event\.type == \.leftMouseDown && event\.modifierFlags\.contains\(\.control\)\)/);
  assert.match(read('Browser/BrowserWorkSpaceDesignView.swift'), /ForEach\(store\.spaces\) \{ BrowserSpaceDot\(store: store, space: \$0,/);
});

test('Chat 固定鈕：搬到左上（同 Browser 字形與尺寸），右上不再有；拖曳區讓出那一格', () => {
  const panels = read('Chat/ChatPage+Panels.swift');
  assert.match(panels, /func sidebarPinButton\(sidebarShown: Bool, sidebarWidth: CGFloat\)/);
  assert.match(panels, /Image\(systemName: "sidebar\.leading"\)/);
  assert.match(panels, /\(sidebarShown \? sidebarWidth : WindowChromeMetrics\.trafficLightSafeWidth\) \+ BrowserOmniboxMetrics\.horizontalInset/);
  const strip = panels.slice(panels.indexOf('func rightPanelControlStrip('));
  assert.doesNotMatch(strip.slice(0, 600), /sidebarPinnedPref\.toggle\(\)/);
  // W114：Browser 的側欄被滑鼠喚出時也要有這顆鈕（與紅綠燈）。
  assert.match(read('Chat/ChatPage.swift'), /\.overlay\(alignment: \.topLeading\) \{\s*if !isPanel && \(model\.mode != \.browser \|\| browserWorkSpaceStore\.hoverRailShown\) \{\s*sidebarPinButton\(/);
  assert.match(read('Chat/ChatPage.swift'), /browserWorkSpaceStore\.hoverRailShown = shown/);
  assert.match(read('Browser/BrowserWorkSpaceDesignView.swift'), /sidebarVisible: !store\.focusMode \|\| store\.sidebarInteractionActive \|\| store\.hoverRailShown,/);
  assert.match(panels, /if browserRail \{ browserWorkSpaceStore\.toggleSidebar\(\) \} else \{ sidebarPinnedPref\.toggle\(\) \}/);
  assert.match(read('Shell/AppShell.swift'), /WorkspaceSidebarMetrics\.width \+ ChatPage\.sidebarPinButtonReserve/);
});

test('獨立 Browser：頂列是浮層、平時不在；紅綠燈與拖曳區一起讓開；工具列沒有「+」', () => {
  const design = read('Browser/BrowserWorkSpaceDesignView.swift');
  assert.match(design, /ZStack\(alignment: \.top\) \{\s*browserPageContent[^\n]*\s*if chromeReveal\.revealed \{ workspaceToolbar\.background \{ BrowserFloatingToolbarBackdrop\(\) \}/);
  assert.match(design, /chromeReveal\.holdOpen = hold/);
  assert.match(design, /\.onDisappear \{ chromeReveal\.stop\(\) \}/);
  assert.doesNotMatch(design, /if onClose == nil \{ newTabButton \}/);
  assert.ok(design.split('\n').length <= 1300);
  const reveal = read('Browser/BrowserChromeReveal.swift');
  assert.match(reveal, /static let triggerBand: CGFloat = WindowChromeMetrics\.trafficLightTopInset \+ 4/);   // W123：紅綠燈圓鈕上緣那一條
  assert.match(reveal, /else \{ next = fromTop <= Self\.triggerBand \}/);   // 不再整條頂列高度都算，避免在網頁上緣誤觸
  assert.match(reveal, /Self\.setTrafficLights\(hidden: !sidebarVisible && !revealed, in: window\)/);   // 側欄看得到時紅綠燈跟著側欄
  assert.match(reveal, /TatwoWindowDragNSView\.suppressed = !revealed/);
  assert.match(reveal, /TatwoWindowDragNSView\.suppressed = false\s*if let window \{ Self\.setTrafficLights\(hidden: false, in: window\) \}/);   // 離開 Browser 要還原
  assert.match(read('Shell/WindowChrome.swift'), /override func hitTest\(_ point: NSPoint\) -> NSView\? \{ Self\.suppressed \? nil : super\.hitTest\(point\) \}/);
  assert.match(read('Chat/ChatPage.swift'), /managedByBrowser: model\.mode == \.browser/);
});

test('珍藏的分頁住在珍藏格子上、不列在下面；移出珍藏時分頁回到清單；書籤可就地改名', () => {
  const registry = read('Browser/BrowserTabRegistry.swift');
  assert.match(registry, /var favoriteID: UUID\? = nil/);
  assert.match(registry, /let bound = tabs\.filter \{ \$0\.favoriteID == id \}/);                       // 先認歸屬，不認網址
  assert.match(registry, /edit\(tab\.id\) \{ \$0\.favoriteID = id \}/);
  assert.match(registry, /for index in tabs\.indices where tabs\[index\]\.favoriteID == id \{ tabs\[index\]\.favoriteID = nil \}/);
  assert.match(registry, /func renameBookmark\(_ id: UUID, to name: String\)/);
  const design = read('Browser/BrowserWorkSpaceDesignView.swift');
  assert.match(design, /var activeTabs: \[Tab\] \{ tabs\.filter \{ !\$0\.pinned && \$0\.bookmarkID == nil && \$0\.favoriteID == nil \} \}/);
  const strip = read('Browser/BrowserFavoritesStrip.swift');
  assert.match(strip, /let bound = store\.tabs\.first \{ \$0\.favoriteID == favorite\.id \}/);
  assert.match(strip, /Button\("關閉這個珍藏的分頁"\)/);
  const rows = read('Browser/BrowserBookmarkRows.swift');
  assert.match(rows, /Button\("改名…"\) \{ name = bookmark\.title; renaming = true \}/);
  assert.match(rows, /\.onSubmit \{ store\.registry\.renameBookmark\(bookmark\.id, to: name\); finishRename\(\) \}/);
});
