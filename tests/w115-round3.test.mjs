// W115（使用者 2026-09-20 18:43 回饋）。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('..', import.meta.url));
const app = p => readFileSync(join(root, 'App/Sources/Tatwo2', p), 'utf8');

test('分頁列與珍藏格不是 Button（Button 會吃掉 mouse-down，拖曳起不來）；輔助使用仍是按鈕', () => {
  const row = app('Browser/BrowserTabRow.swift');
  const body = row.slice(row.indexOf('struct BrowserTabRow'), row.indexOf('struct BrowserBotTabRows'));
  assert.doesNotMatch(body, /Button\(action: onSelect\)/);
  assert.match(body, /\.onTapGesture\(perform: onSelect\)/);
  assert.match(body, /\.accessibilityAddTraits\(selected \? \[\.isButton, \.isSelected\] : \.isButton\)/);
  assert.match(body, /\.accessibilityAction \{ onSelect\(\) \}/);
  const strip = app('Browser/BrowserFavoritesStrip.swift');
  assert.doesNotMatch(strip, /Button \{ store\.openFavorite\(favorite\.id\) \} label:/);
  assert.match(strip, /\.onTapGesture \{ store\.openFavorite\(favorite\.id\) \}/);
});

test('⌘T：看著網頁時不換頁、搜尋欄空白、送出開成新分頁；Esc／失焦取消', () => {
  const design = app('Browser/BrowserWorkSpaceDesignView.swift');
  assert.match(design, /if store\.canAddTab \{ if store\.showsStartPage \{ store\.addTab\(\) \} else \{ newTabIntent = true \}; store\.searchFocusRequest \+= 1 \}/);
  assert.match(design, /if newTabIntent \{ newTabIntent = false; addressFocused = false; focusedField = nil; return \}/);   // ⌘T 再按一次＝取消
  assert.match(design, /if newTabIntent \{ newTabIntent = false; store\.addTab\(url: url\);/);
  const toolbar = app('Browser/EmbeddedBrowserToolbar.swift');
  assert.match(toolbar, /addressText = newTabIntent\.wrappedValue \? "" : \(state\.urlString \?\? ""\)/);
  assert.match(toolbar, /newTabIntent\.wrappedValue = false\s*addressFieldFocused\.wrappedValue = false/);
  assert.ok(design.split('\n').length <= 1300);
});

test('翻譯不能用時只變暗、不跳警示；量測用的 view 不吃滑鼠；HID 自測只在有輔助使用權限時送', () => {
  const t = app('Browser/BrowserPageTranslation.swift');
  assert.doesNotMatch(t, /exclamationmark\.triangle/);
  assert.match(t, /\.opacity\(unavailable \? 0\.3 : 1\)/);
  assert.match(app('Shell/TrafficLightAlignedTitle.swift'), /final class PassthroughView: NSView \{ override func hitTest\(_ point: NSPoint\) -> NSView\? \{ nil \} \}/);
  const probe = app('Facade/UIProbe.swift');
  assert.match(probe, /guard AXIsProcessTrusted\(\) else \{ return \["error": "accessibility_permission_required"\] \}/);
  assert.match(app('Facade/OSAgentBridge.swift'), /case "ui_probe":/);
});

test('W117 Fable 額度：讀官方 limits 陣列裡單一模型的週上限（對照官方 CLI 的用量面板）', () => {
  const quota = app('Facade/EngineQuotaDetail.swift');
  assert.match(quota, /let limitEntries = payload\["limits"\] as\? \[\[String: Any\]\] \?\? \[\]/);
  assert.match(quota, /entry\["kind"\] as\? String == "weekly_scoped", let name = modelName\(entry\)/);
  assert.match(quota, /label: "\\\(name\) 週上限", usedPercent: percent/);
  assert.match(quota, /官方這次沒有回傳 limits 陣列/);   // 沒回就明講，不猜
  assert.doesNotMatch(quota, /nimbus_quill/);
});

test('自測 .013 抓到的：分頁存成書籤要搬進書籤列；面板開著時隱形頂列不收；HID 點擊前先把 App 叫到前景', () => {
  assert.match(app('Browser/BrowserTabRegistry.swift'), /func bind\(tab id: UUID, toBookmark bookmarkID: UUID, folderID: UUID\)/);
  assert.match(app('Browser/BrowserWorkSpaceDesignView.swift'), /registry\.bind\(tab: uuid, toBookmark: bookmark\.id, folderID: folderID\); saved = true/);
  assert.match(app('Browser/EmbeddedBrowserToolbar.swift'), /isEditing\.wrappedValue = expanded \}/);
  assert.match(app('Facade/UIProbe.swift'), /NSApp\.activate\(ignoringOtherApps: true\)   \/\/ App 不在前景時/);
});

test('W115d ⌘T 取消是明確收面板，不靠焦點變化推導', () => {
  const toolbar = readFileSync(new URL('../App/Sources/Tatwo2/Browser/EmbeddedBrowserToolbar.swift', import.meta.url), 'utf8');
  assert.match(toolbar, /\.onChange\(of: newTabIntent\.wrappedValue\) \{ was, now in\s+if was, !now, isExpanded \{ dismissEditor\(\.escape\) \}/);
});

test('W116g 完整模式子視窗：位置由 Swift 交、原生端只認實驗旗標與 defaults 裡的測試擴充路徑', () => {
  const bridge = readFileSync(join(root, 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm'), 'utf8');
  const embed = readFileSync(join(root, 'App/Sources/Tatwo2/Browser/BrowserChromeStyleEmbed.swift'), 'utf8');
  assert.match(bridge, /static BOOL W116OpenChromeWindow\(NSString \*url, bool frameless, bool embedded = false\)/);
  assert.match(bridge, /bool IsFrameless\(CefRefPtr<CefWindow>\) override \{ return frameless_; \}/);   // 參數留著；W131 起擴充介面用一般視窗
  assert.match(bridge, /\[child orderWindow:NSWindowAbove relativeTo:parent\.windowNumber\]/);
  // 外來命令列的 load-extension 一律先移除；只有實驗旗標開著、defaults 明確給了存在的資料夾才載入。
  assert.ok(bridge.indexOf('command_line->RemoveSwitch("load-extension");') < bridge.indexOf('command_line->AppendSwitchWithValue("load-extension"'));
  assert.match(bridge, /stringForKey:@"tatwo\.browser\.devLoadExtension"/);
  assert.doesNotMatch(embed, /import TatwoCEFBridge/);
  assert.match(readFileSync(join(root, 'App/Sources/Tatwo2/Browser/BrowserWorkSpaceEmbeddedChrome.swift'), 'utf8'), /static func extensionSurfaceFrame\(for window: NSWindow\?, sidebarInset: CGFloat\) -> NSRect/);
  // W143：擴充介面改當主視窗的子視窗（跟著移動、永遠在上面），主畫面不再疊任何東西。
  assert.match(bridge, /\[parent addChildWindow:child ordered:NSWindowAbove\]/);
  // W145：擴充頁開著時蓋掉底下的網頁（不再疊兩層）。
  assert.match(readFileSync(join(root, 'App/Sources/Tatwo2/Browser/BrowserWorkSpaceDesignView.swift'), 'utf8'), /\.modifier\(BrowserChromeStyleEmbedLayer\(reveal: chromeReveal, surfaceChanged: \{ restoreAddress\(\) \}\)\)/);
});

test('W119 翻譯鈕是自動翻譯開關；換頁續翻；取文字逾時不會卡在轉圈', () => {
  const swift = readFileSync(join(root, 'App/Sources/Tatwo2/Browser/BrowserPageTranslation.swift'), 'utf8');
  assert.match(swift, /static let autoKey = "tatwo\.browser\.translate\.auto"/);
  assert.match(swift, /if autoEnabled \{ startManually\(\) \} else \{ restore\(\) \}/);
  assert.match(swift, /if self\.autoEnabled \|\| URL\(string: url\)\?\.host\.map\(Self\.alwaysHosts\.contains\) == true \{ self\.start\(\) \}/);
  // 離開迴圈一定收掉「翻譯中」；取文字失敗先重試，不直接 break。
  assert.match(swift, /defer \{\s+if current == generation, phase == \.translating\(source: source\) \{/);
  assert.match(swift, /misses \+= 1\s+if misses >= 4 \{ break \}/);
  assert.match(swift, /\.accessibilityValue\(translator\.autoEnabled \? "開" : "關"\)/);
});

test('W119b 第一批譯文寫回就收掉轉圈，不等整頁翻完', () => {
  const swift = readFileSync(join(root, 'App/Sources/Tatwo2/Browser/BrowserPageTranslation.swift'), 'utf8');
  const apply = swift.indexOf('applied += pairs.count');
  const settle = swift.indexOf('if current == generation, phase == .translating(source: source) { phase = .translated(source: source) }', apply);
  assert.ok(apply > 0 && settle > apply && settle - apply < 700, 'settle right after the first apply');
});

test('W120 按「-」關掉正在看的書籤分頁＝回 Browser 首頁，不跳到清單第一個', () => {
  const design = readFileSync(join(root, 'App/Sources/Tatwo2/Browser/BrowserWorkSpaceDesignView.swift'), 'utf8');
  assert.match(design, /stayOnStartPage = stayOnStartPage \|\| tab\.id == selectedID; close\(tab\.id\)/);
  assert.match(design, /stayOnStartPage = stayOnStartPage \|\| closing\.contains \{ \$0\.id == selectedID \}/);
  assert.match(design, /selectedID = stayOnStartPage \? -1 : \(tabs\.first\?\.id \?\? -1\)/);
  assert.match(design, /didSet \{ if selectedID >= 0 \{ stayOnStartPage = false \};/);
  assert.ok(design.split('\n').length <= 1300);
});

test('W122 拼圖鈕展開的是選單（不是對話框）：已裝的擴充可釘選、管理與商店各有去處', () => {
  const menu = readFileSync(join(root, 'App/Sources/Tatwo2/Browser/BrowserExtensionsMenu.swift'), 'utf8');
  const chrome = readFileSync(join(root, 'App/Sources/Tatwo2/Browser/BrowserWorkSpaceEmbeddedChrome.swift'), 'utf8');
  const design = readFileSync(join(root, 'App/Sources/Tatwo2/Browser/BrowserWorkSpaceDesignView.swift'), 'utf8');
  assert.doesNotMatch(design, /sheet\(isPresented: \$extensionsPresented\)/);   // 不再是對話框
  assert.equal(chrome.split('.popover(isPresented: $extensionsPresented').length - 1, 2);
  // 商店＝一般網頁，開新分頁；chrome:// 與 chrome-extension:// 走完整模式的介面（CEF Alloy 白名單不含它們）。
  // W126：商店與管理頁都走視窗內的完整模式介面——安裝擴充要 Chrome 的 ExtensionInstallPrompt，嵌入的分頁沒有那個視窗。
  // W139（使用者：「新增在左列新分頁很難嗎」）：商店開在左列新分頁；只有 chrome:// 的管理頁才用擴充視窗。
  assert.match(menu, /row\("擴充商店", systemImage: "bag"\) \{ openTab\("https:\/\/chromewebstore\.google\.com\/"\); dismiss\(\) \}/);
  assert.match(chrome, /openTab: \{ url in if let target = URL\(string: url\) \{ store\.addTab\(url: target\) \} \}/);
  const embed = readFileSync(join(root, 'App/Sources/Tatwo2/Browser/BrowserChromeStyleEmbed.swift'), 'utf8');
  // W135：不再在網頁區上疊橫幅與錨點；擴充視窗就是一個開在網頁區位置的一般視窗，用自己的關閉鈕收掉。
  // W143（W142 退場）：把 Chrome style 的 contentView 搬進我們的視窗，畫面進得來、滑鼠事件進不來
  //（Chromium 的事件橋還綁在原本那個 NSWindow 上）。改走子視窗，宿主 view 與重新掛載一併移除。
  assert.doesNotMatch(embed, /BrowserChromeStyleEmbedHost|hostReady/);
  assert.doesNotMatch(readFileSync(join(root, 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/include/TatwoCEFBridge.h'), 'utf8'),
                      /attachChromeStyleEmbeddedToHost/);
  // W147：定位點回來了，但只回報網頁區位置（視窗座標）、不吃事件；W135 移除的是疊在網頁上的橫幅＋錨點追位置那一套。
  assert.match(embed, /struct BrowserChromeStyleEmbedAnchor: NSViewRepresentable/);
  assert.match(embed, /override func hitTest\(_ point: NSPoint\) -> NSView\? \{ nil \}/);
  assert.match(readFileSync(join(root, 'App/Sources/Tatwo2/Browser/ChromiumCEFBackend.swift'), 'utf8'), /forName: BrowserChromeStyleEmbedState\.pageRectChanged/);
  const backend = readFileSync(join(root, 'App/Sources/Tatwo2/Browser/ChromiumCEFBackend.swift'), 'utf8');
  assert.match(backend, /extensionSurfaceFrame\(for: window\)/);
  // W136：擴充視窗讓出整條頂列高度（否則蓋住拼圖鈕）；選單在它開著時多一列可以關掉它。
  assert.match(readFileSync(join(root, 'App/Sources/Tatwo2/Browser/BrowserWorkSpaceEmbeddedChrome.swift'), 'utf8'),
               /height: max\(300, frame\.height - BrowserOmniboxMetrics\.toolbarHeight\)/);
  assert.match(menu, /row\("關閉擴充功能視窗", systemImage: "xmark\.circle"\) \{ surface\.close\(\); dismiss\(\) \}/);
  // W143：主視窗改變大小時，擴充視窗要跟著重貼位置（子視窗只跟著移動，不跟著縮放）。
  assert.match(backend, /NSWindow\.didResizeNotification/);
  // W129（使用者 09-21：「工具列變很奇怪」）：擴充介面本身就有 Chrome 的工具列，我們的頂列不要再疊上去。
  assert.match(design, /if chromeReveal\.revealed \{ workspaceToolbar/);
    // W127：擴充介面的彈出不另開視窗（裝完擴充那個長得像 Chrome 的視窗）；空白新分頁直接忽略。
  const bridge2 = readFileSync(join(root, 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm'), 'utf8');
  assert.match(bridge2, /class SpikeClient final : public CefClient, public CefLifeSpanHandler/);
  assert.match(bridge2, /url\.rfind\("chrome:\/\/newtab", 0\) == 0/);
  assert.match(bridge2, /if \(!blank && frame\) frame->LoadURL\(target_url\);\s+return true;/);
  // W128：核心自己開的獨立視窗要被收編回網頁區；對話框（小視窗、sheet、panel）不動，否則擋掉安裝確認。
  assert.match(bridge2, /static BOOL W116IsAdoptableBrowserWindow\(NSWindow \*window\)/);
  assert.match(bridge2, /window\.frame\.size\.width < 500 \|\| window\.frame\.size\.height < 400/);
  assert.match(bridge2, /\[window isKindOfClass:NSPanel\.class\] \|\| window\.sheetParent/);
  assert.match(bridge2, /NSWindowDidBecomeKeyNotification/);
  // W130：覆蓋視窗要拿得到 key，否則一般網頁的點擊與鍵盤全被丟掉（chrome:// 內建頁不受影響，容易誤判）。
  // W131：不用子視窗（子視窗＋無邊框會吃掉網頁的滑鼠按鍵），改成同層級的一般視窗疊在主視窗上。
  assert.match(bridge2, /W116OpenChromeWindow\(url, false\)/);
  // W133：不論有沒有邊框都要記住把手，否則重用／定位／關閉全部失效。
  assert.match(bridge2, /g_w116_embedded_window = window;\s+\+\+g_w116_live_windows;\s+window->SetTitle\("TATWO OS · 擴充功能"\);/);
  assert.doesNotMatch(bridge2, /if \(frameless_\) g_w116_embedded_window = window;/);
  assert.match(bridge2, /\[child orderWindow:NSWindowAbove relativeTo:parent\.windowNumber\]/);
  // W143：同層疊窗留成退路（overlayMode=sibling），預設改回子視窗。
  assert.match(bridge2, /\[parent addChildWindow:child ordered:NSWindowAbove\]/);
  assert.match(bridge2, /tatwo\.browser\.extensions\.overlayMode/);
  assert.match(bridge2, /\[window makeKeyAndOrderFront:nil\];   \/\/ W130/);
  assert.match(bridge2, /\[parent makeKeyAndOrderFront:nil\];   \/\/ 焦點交還主視窗/);
  // 隱藏＝暫時收起（收編的視窗只 orderOut），關閉＝連收編來的一起關掉。
  assert.match(bridge2, /\+ \(void\)hideChromeStyleEmbedded \{[\s\S]{0,120}W116StopAdopting\(NO\);/);
  assert.match(bridge2, /\+ \(void\)closeChromeStyleEmbedded \{\s+W116StopAdopting\(YES\);/);
  assert.match(bridge2, /if \(native\.isVisible\) \{ \[native orderOut:nil\]; \[native close\]; \}/);
  // W134：關閉要先關瀏覽器本體，否則 CanClose 會把 CefWindow::Close() 擋下來。
  assert.match(bridge2, /browser->GetHost\(\)->CloseBrowser\(true\); break;/);
  // W140：擴充自己的頁面（chrome-extension://）開在分頁；只有核心內建的管理頁還走擴充視窗。
  assert.match(menu, /row\("進階管理（瀏覽器內建頁）", systemImage: "slider\.horizontal\.3"\) \{ openManager\("chrome:\/\/extensions"\); dismiss\(\) \}/);
  // W141（.044 實測）：chrome-extension:// 在嵌入分頁也載不起來（開出 about:blank），所以擴充自己的頁面回到擴充視窗。
  assert.match(menu, /private func openExtensionPage\(_ item: BrowserExtensionInventory\.Item\) \{ openManager\(item\.actionURL\) \}/);
  assert.match(chrome, /BrowserPinnedExtensionButtons\(size: BrowserOmniboxMetrics\.collapsedHeight, openPage: openExtensionPage\)/);
  // 釘選
  assert.match(menu, /Image\(systemName: pinned\.contains\(item\.id\) \? "pin\.fill" : "pin"\)/);
  assert.match(menu, /BrowserExtensionInventory\.Pins\.toggle\(item\.id\)/);
  // W124：選單開著時隱形頂列不准收（否則選單失去錨點就關閉）；選單不要太寬。
  assert.match(design, /addressFocused \|\| addressEditing \|\| findPresented \|\| tabSearchPresented \|\| extensionsPresented,/);
  assert.match(menu, /\.frame\(width: 200\)/);
  // W125：貼在網頁區上的擴充管理，橫幅不要出現「實驗」。
  for (const literal of (embed.split('\n').filter(l => !l.trim().startsWith('//')).join('\n').match(/(Text|Button)\("[^"]*"/g) || []))
    assert.ok(!literal.includes('實驗'), literal);
  const inventory = readFileSync(join(root, 'App/Sources/Tatwo2/Browser/BrowserExtensionInventory.swift'), 'utf8');
  assert.match(inventory, /appendingPathComponent\("tatwo2\/chromium\/cef-root", isDirectory: true\)/);
  assert.match(inventory, /__MSG_/);
  assert.match(inventory, /default_icon/);
  for (const literal of (menu.split('\n').filter(l => !l.trim().startsWith('//')).join('\n').match(/(Text|Toggle|Label|Button|row)\("[^"]*"/g) || []))
    assert.ok(!literal.includes('實驗'), literal);
  // W137（.040 自測：開過擴充視窗之後頂列再也不浮出，所有入口失效）：不再抑制頂列；視窗銷毀要回報，狀態才會清掉。
  assert.match(design, /if chromeReveal\.revealed \{ workspaceToolbar/);
  assert.doesNotMatch(design, /extensionSurface\.url == nil/);
  assert.match(embed, /static let destroyed = Notification\.Name\("tatwo\.browser\.chromeStyleSpike\.embed\.destroyed"\)/);
  assert.match(bridge2, /postNotificationName:@"tatwo\.browser\.chromeStyleSpike\.embed\.destroyed"/);
  // W138：主視窗一成為 key 就把擴充視窗重新排上去，否則點擊會讓主視窗把它蓋住。
  assert.match(bridge2, /if \(window && window == g_w116_embed_parent && g_w116_embedded_window\) \{/);
  assert.match(bridge2, /\[surface orderWindow:NSWindowAbove relativeTo:window\.windowNumber\]/);
  // W143：子視窗模式下 AppKit 自己維持疊放順序，重抬只在同層模式做。
  assert.match(bridge2, /surface\.parentWindow != window/);
  assert.doesNotMatch(bridge2, /\[host addSubview:content\]/);
});

test('W144 進階管理不像另一個視窗：沒有 Chrome 工具列、沒有標題列與紅綠燈、不能單獨拖走；換分頁就收起', () => {
  const bridge = readFileSync(join(root, 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm'), 'utf8');
  assert.match(bridge, /return embedded_ \? CEF_CTT_NONE : CEF_CTT_NORMAL;/);
  assert.match(bridge, /CefRefPtr<CefView> toolbar = embedded_ \? nullptr : view_->GetChromeToolbar\(\);/);
  assert.match(bridge, /W116OpenChromeWindow\(url, false, W116UseChildWindow\(\)\)/);
  assert.match(bridge, /child\.titleVisibility = NSWindowTitleHidden;/);
  assert.match(bridge, /child\.movable = NO;/);
  assert.match(bridge, /NSWindowStyleMaskFullSizeContentView\) & ~NSWindowStyleMaskResizable/);
  const design = readFileSync(join(root, 'App/Sources/Tatwo2/Browser/BrowserWorkSpaceDesignView.swift'), 'utf8');
  assert.match(design, /post\(name: \.init\("tatwo\.browser\.workspace\.selection"\)/);
  assert.doesNotMatch(design.split('struct BrowserWorkSpaceDesignView')[0], /BrowserChromeStyleEmbedState/);   // store 的獨立測試不連這個檔
  const embed = readFileSync(join(root, 'App/Sources/Tatwo2/Browser/BrowserChromeStyleEmbed.swift'), 'utf8');
  assert.match(embed, /forName: Self\.workspaceSelection[\s\S]{0,120}self\?\.close\(\)/);
});

test('W146 擴充頁開著時工具列固定顯示；改 styleMask 後逼核心重排，隱形標題列不留空白', () => {
  const reveal = readFileSync(join(root, 'App/Sources/Tatwo2/Browser/BrowserChromeReveal.swift'), 'utf8');
  assert.match(reveal, /if holdOpen \|\| surfaceHold \|\| Date\(\) < graceUntil/);
  const embed = readFileSync(join(root, 'App/Sources/Tatwo2/Browser/BrowserChromeStyleEmbed.swift'), 'utf8');
  assert.match(embed, /reveal\.surfaceHold = open/);
  const bridge = readFileSync(join(root, 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm'), 'utf8');
  assert.match(bridge, /for \(double delay : \{0\.3, 1\.0\}\)[\s\S]{0,500}settled\.size\.height - 1\) display:YES\];\s+W116PinFrame\(w, settled\);/);
  assert.match(bridge, /static void W116PinFrame\(NSWindow \*w, NSRect target\)/);
});

test('W148 擴充頁頂端貼齊工具列（定位點不吃安全區域）；網址位置顯示「擴充功能」', () => {
  const embed = readFileSync(join(root, 'App/Sources/Tatwo2/Browser/BrowserChromeStyleEmbed.swift'), 'utf8');
  assert.match(embed, /\.allowsHitTesting\(false\)\s*\/\/[^\n]*\n\s*\/\/[^\n]*\n?\s*\.ignoresSafeArea\(\)|\.ignoresSafeArea\(\)/);
  const design = readFileSync(join(root, 'App/Sources/Tatwo2/Browser/BrowserWorkSpaceDesignView.swift'), 'utf8');
  assert.match(design, /labelOverride: BrowserChromeStyleEmbedState\.shared\.url != nil \? "擴充功能" : nil/);
});

test('W152 擴充自己開的頁面改開在左列新分頁：讀網址列→交給外部連結佇列→關掉那個 Chrome 視窗；讀不到才收編', () => {
  const bridge = readFileSync(join(root, 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm'), 'utf8');
  assert.match(bridge, /static NSString \*W116FindAddressText\(id element, int depth\)/);
  assert.match(bridge, /postNotificationName:@"tatwo\.browser\.chromeStyleSpike\.strayURL"/);
  assert.match(bridge, /if \(attempt < 3\)[\s\S]{0,900}W116DockWindow\(window\);/);
  assert.match(bridge, /if \(W116IsAdoptableBrowserWindow\(window\)\) \{ \[window orderOut:nil\]; W116RedirectOrDock\(window, 0\); \}/);
  const backend = readFileSync(join(root, 'App/Sources/Tatwo2/Browser/ChromiumCEFBackend.swift'), 'utf8');
  assert.match(backend, /BrowserExternalURLQueue\.shared\.enqueue\(\[url\]\)/);
});

test('W153 結束 App 前先關掉擴充用的 Chrome 瀏覽器並等它銷毀，CEF 才拆 profile', () => {
  const bridge = readFileSync(join(root, 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm'), 'utf8');
  const shutdown = bridge.slice(bridge.indexOf('+ (void)shutdown {'));
  assert.ok(shutdown.indexOf('[self closeChromeStyleEmbedded];') > 0);
  assert.ok(shutdown.indexOf('[self closeChromeStyleEmbedded];') < shutdown.indexOf('DrainCEFReferencesForShutdown()'));
  assert.match(bridge, /\+\+g_w116_live_windows;/);
  assert.match(bridge, /if \(g_w116_live_windows > 0\) --g_w116_live_windows;/);
});

test('W153b 使用者確認結束後、App 還在正常運轉時就關掉擴充用瀏覽器並等它銷毀，再放行結束', () => {
  const shell = readFileSync(join(root, 'App/Sources/Tatwo2/Shell/AppShell.swift'), 'utf8');
  assert.match(shell, /ChromeStyleSpike\.drainForTermination \{ sender\.reply\(toApplicationShouldTerminate: true\) \}/);
  assert.match(shell, /if decision == \.terminateNow, ChromeStyleSpike\.needsTerminationDrain/);
  const backend = readFileSync(join(root, 'App/Sources/Tatwo2/Browser/ChromiumCEFBackend.swift'), 'utf8');
  assert.match(backend, /TatwoCEFRuntime\.chromeStyleLiveWindowCount\(\) == 0 \|\| Date\(\) > deadline/);
});

test('W154 讀不到網址的空白新分頁視窗直接關掉；結束前的等待也把收編來的核心視窗算進去', () => {
  const bridge = readFileSync(join(root, 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm'), 'utf8');
  assert.match(bridge, /\[title containsString:@"New Tab"\][\s\S]{0,200}\[window performClose:nil\];/);
  assert.match(bridge, /for \(NSWindow \*window in g_w116_adopted\) if \(window\.isVisible\) \+\+adopted;/);
});
