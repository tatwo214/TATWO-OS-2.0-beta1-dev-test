// W112 第三批（使用者 2026-09-20：「不然先用apple的吧」）：就地翻譯，後端是 Apple 裝置端翻譯。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const read = p => readFileSync(join(root, p), 'utf8');
const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
const script = bridge.slice(bridge.indexOf('const char kBrowserTranslateScript[]'), bridge.indexOf('class W112TranslateRenderer'));

test('頁面腳本：只動文字節點、跳過不該翻的區塊、可還原、不往 window 掛東西、不連網', () => {
  for (const tag of ['SCRIPT', 'STYLE', 'CODE', 'PRE', 'TEXTAREA', 'INPUT']) assert.ok(script.includes(`'${tag}'`), tag);
  assert.match(script, /el\.isContentEditable/);
  assert.match(script, /getAttribute\('translate'\) === 'no' \|\| el\.classList\.contains\('notranslate'\)/);
  assert.match(script, /parent\.getClientRects\(\)\.length === 0/);                 // 看不到的不翻
  assert.match(script, /node\.nodeValue = raw\.match\(\/\^\\s\*\/\)\[0\] \+ text \+ raw\.match\(\/\\s\*\$\/\)\[0\]/);   // 保留前後空白，版面不動
  assert.match(script, /restore\(\) \{[\s\S]*?node\.nodeValue = raw/);
  assert.doesNotMatch(script, /window\.|globalThis|fetch\(|XMLHttpRequest|innerHTML|document\.write/);
  assert.match(script, /items\.length >= limit \|\| chars > 40000/);               // 一批有上限
});

test('原生通道：只給使用者自己的分頁；逾時會結束；回呼表不放進 C++ 狀態結構', () => {
  const api = bridge.slice(bridge.indexOf('#pragma mark - W112 translate (browser)'), bridge.indexOf('#pragma mark - W112 translate (browser) end'));
  assert.match(api, /!ActorRequestPolicy\(self\)\.human \|\| self\.agentControlled/);
  assert.match(api, /dispatch_after\(dispatch_time\(DISPATCH_TIME_NOW, 6 \* NSEC_PER_SEC\)/);
  assert.match(bridge, /op == "sample" \|\| op == "collect" \|\| op == "apply" \|\| op == "restore"/);   // 白名單
  const state = bridge.match(/struct BrowserState \{([\s\S]*?)#pragma mark - W57a/)[1];
  assert.doesNotMatch(state, /translate/);
  assert.match(read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/include/TatwoCEFBridge.h'), /- \(void\)translateOperation:\(NSString \*\)operation payload:/);
});

test('Swift：Apple 裝置端翻譯、外語才出現、可還原、記住網站；設計檔只多一行', () => {
  const swift = read('App/Sources/Tatwo2/Browser/BrowserPageTranslation.swift');
  assert.match(swift, /#if canImport\(Translation\)\s*import Translation/);
  assert.match(swift, /TranslationSession\.Configuration\(source: Locale\.Language\(identifier: source\), target: Self\.targetLanguage\)/);
  assert.match(swift, /try await session\.prepareTranslation\(\)/);
  assert.match(swift, /return base\(source\) == base\(targetLanguage\.minimalIdentifier\) \? nil : source/);
  assert.match(swift, /operation: "restore"/);
  assert.match(swift, /static let alwaysKey = "tatwo\.browser\.translate\.alwaysHosts"/);
  assert.doesNotMatch(swift, /URLSession|https?:\/\//);
  // W119（使用者 09-20 晚）：翻譯鈕改成自動翻譯的開關，選單（顯示原文／總是翻譯）退場；隱私說明留在按鈕說明文字。
  assert.ok(swift.includes('內容不離開這台設備'));
  assert.doesNotMatch(swift, /menuPresented/);
  const design = read('App/Sources/Tatwo2/Browser/BrowserWorkSpaceDesignView.swift');
  assert.match(design, /browserPageContent\.modifier\(BrowserTranslationHost\(runtime: runtime, translator: translator, tabID: store\.showsStartPage \? nil : store\.selectedRegistryID\)\)/);   // W114：按鈕搬到工具列，translator 由畫面持有
  assert.ok(design.split('\n').length <= 1300);
});
