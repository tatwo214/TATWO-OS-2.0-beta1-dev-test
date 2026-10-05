// W184 D：私訊框 Browser 與［連線］照手機 App——原始碼契約（每一條旁邊寫「守什麼」）。
// 使用者 09-29：「私訊鈕的ui完全垃圾 應該要參照手機app的規格去設計」、Browser 操作列「做成滑鼠指到才出現」、「duo的形式已經ok就照你的設計去做」；
// 對照稿 https://claude.ai/artifact/RoVoQkiMN13LDhD9Hj2s2g（A-Proto、Outer-Browser-Ack、Outer-Browser-Code、Outer-Tabs、Outer-Connect、Open-*）。
// 實際行為（真的畫出來量位置、點擊讓位、截圖持有者的反例、畫面證據 PNG）在 App 自測 TATWO2_SELFTEST=w184browser（DM/DMBrowserPhoneAcceptance.swift）。
// W184 G2（使用者 09-29：「browser的下方改右側好了 並且缺乏目前browser space的書籤、珍藏、switch功能，試圖收納進去。」）：下方操作列改成
// 右側直欄——這裡守的東西不變（數值從 token 來、平常藏、滑鼠位置判斷、網頁讓位、浮卡不擠頁面、識別碼保留），只是從「底部」改成「右緣」；
// 新的書籤、珍藏、切換空間在 tests/w184-rail.test.mjs。
// W184 G2d（使用者 09-30：「你就只是把現成的browser space做成duo自適應尺寸而已 不要越搞越遠」）：側欄、頂列、沒分頁時的搜尋框改用主視窗
// Browser space 的元件——這裡守的東西不變（數值從 token 來、平常藏、滑鼠位置判斷、網頁讓位、浮卡不擠頁面、識別碼），側欄與頂列的數字改取主視窗的
// （WorkspaceSidebarMetrics、BrowserOmniboxMetrics）；私訊框自己那一套側欄（上一頁列、網址 pill 卡、把手帶）拿掉了，它們的識別碼跟著拿掉。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { testScratch } from './helpers/test-scratch.mjs';

const read = (p) => readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const swift = (p) => read('App/Sources/Tatwo2/' + p);
const code = (source) => source.replace(/^\s*\/\/.*$/gm, '').replace(/\/\/[^\n"]*$/gm, '');
const between = (source, start, end) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = end ? source.indexOf(end, from + start.length) : source.length;
  assert.ok(to > from, `missing ${end} after ${start}`);
  return source.slice(from, to);
};

const phone = swift('DM/DMBrowserPhone.swift');
const view = swift('DM/DMBrowserView.swift');
const browser = swift('DM/DMBrowser.swift');
const shieldFile = swift('DM/WindowCaptureShield.swift');
const connect = swift('New/HandsConnectDMView.swift');
const sheet = swift('DM/GlobalDMWebSheet.swift');
const gate = swift('Browser/BrowserSensitivePage.swift');
const menu = swift('Facade/ChatGPTPluginNewMenu.swift');
const acceptance = swift('DM/DMBrowserPhoneAcceptance.swift');
const rail = swift('DM/DMBrowserRail.swift');
const spaces = swift('DM/DMBrowserSpaces.swift');
const w183 = swift('DM/DMBrowserAcceptance.swift');
const selftest = swift('SelfTest.swift');
const chrome = swift('DM/DMBrowserChrome.swift');

test('D tokens: the numbers come from the approved mock and from DMPhone (no hard-coded sizes in the views)', () => {
  // 守：頁面框 上 4、左右下 12（＝DMPhone.edgeInset）、圓角 28（＝DMPhone.cardRadius）。W184 G2d：左邊不再留把手帶（使用者說過多餘）；
  // 把手的數字留在 DMBrowserPhone 給房 C 的 ChatGPT 抽屜（DMBrowserHandle）。
  for (const line of ['static let pageTop: CGFloat = 4', 'static var pageSide: CGFloat { DMPhone.edgeInset }', 'static var pageBottom: CGFloat { DMPhone.edgeInset }',
    'static var pageRadius: CGFloat { DMPhone.cardRadius }',
    'static var handleStrip: CGFloat { DMPhone.Drawer.handle }', 'static var handleLength: CGFloat { DMPhone.touch }', 'static let handleThickness: CGFloat = 5',
    // 守（W184 G2d）：側欄、頂列的數字取主視窗 Browser space 的——側欄寬 WorkspaceSidebarMetrics.width（框窄＝跟著縮）、左緣 18 叫出、右緣外 30 留著、
    // 離開 0.40 秒才收、從左 8 滑進來（0.24／0.22 秒）；頂列 BrowserOmniboxMetrics.toolbarHeight、頂端 20 叫出、48＋10 留著、0.12 秒淡入。
    'static func sidebarWidth(for paneWidth: CGFloat) -> CGFloat {', 'static var sidebarMaxWidth: CGFloat { WorkspaceSidebarMetrics.width }',
    'static let revealZone: CGFloat = 18', 'static let exitZone: CGFloat = 30', 'static let sidebarCloseDelay: Double = 0.40', 'static let slide: CGFloat = 8',
    'static let sidebarOpenDuration: Double = 0.24', 'static let sidebarCloseDuration: Double = 0.22', 'static let fadeDuration: Double = 0.18', 'static let sidebarGap: CGFloat = 8',
    'static var toolbarHeight: CGFloat { BrowserOmniboxMetrics.toolbarHeight }', 'static let toolbarTrigger: CGFloat = 20', 'static let toolbarStay: CGFloat = 10',
    'static let toolbarFade: Double = 0.12', 'static let toolbarToolsMinWidth: CGFloat = 420',
    // 守（W184 G2d 尺寸自適應）：側欄矮過 160（小框＋最高的連線卡）＝緊湊擺法，玻璃內距 8（主視窗那一套是 18）。
    'static let sidebarCompactHeight: CGFloat = 160', 'static let sidebarCompactPadding: CGFloat = 8',
    // 守：分頁總覽底部「完成」那一條照舊 高 56、圓角 28、左右下 12。
    'static let barHeight: CGFloat = 56', 'static var barRadius: CGFloat { barHeight / 2 }', 'static var barInset: CGFloat { DMPhone.edgeInset }',
    // 守：浮卡 左右 12、離底 30、內距 16、圓角 28（側欄停在卡片上面，卡片不讓位、不變窄）；碼 34 等寬、字距 0.16em。
    'static var cardInset: CGFloat { DMPhone.edgeInset }', 'static let cardBottom: CGFloat = 30',
    'static var cardPadding: CGFloat { DMPhone.margin }', 'static let codeSize: CGFloat = 34', 'static var codeTracking: CGFloat { codeSize * 0.16 }',
    // 守：小標 離頂 10、26 高、深色 0.78；分頁總覽 6／16／12、間距 12、卡片圓角 24、縮圖 150、關掉鈕 28。
    'static let badgeTop: CGFloat = 10', 'static let badgeHeight: CGFloat = 26', 'static let badgeOpacity: Double = 0.78',
    'static let listTop: CGFloat = 6', 'static let gridSpacing: CGFloat = 12', 'static let tabCardRadius: CGFloat = 24',
    'static let thumbnailHeight: CGFloat = 150', 'static let closeSize: CGFloat = 28']) {
    assert.ok(phone.includes(line), line);
  }
  // 守（W184 G2c）：左側抽屜的把手帶、滑出的數字放在 DMPhone（Browser 左列、ChatGPT 私訊的左側抽屜兩邊共用）。
  const metrics = swift('DM/DMPhoneMetrics.swift');
  for (const line of ['enum Drawer {', 'static let handle: CGFloat = 22', 'static let slide: CGFloat = 18', 'static let slideDuration: Double = 0.22',
    'static let fadeDuration: Double = 0.18']) {
    assert.ok(between(metrics, 'enum Drawer {', '\n    }\n').includes(line), line);
  }
  // 守：sheet 離頂 96、上圓角 40、下圓角＝框 52、遮罩 0.22、grabber 36×5、內容 10／16／16 間距 18、群組 26、列高 48／52、分段 34。
  for (const line of ['static let topInset: CGFloat = 96', 'static let topRadius: CGFloat = 40', 'static var bottomRadius: CGFloat { GlobalDMLayout.cornerRadius }',
    'static let dimOpacity: Double = 0.22', 'static let grabberSize = CGSize(width: 36, height: 5)', 'static let contentTop: CGFloat = 10',
    'static let contentSpacing: CGFloat = 18', 'static let groupRadius: CGFloat = 26', 'static let rowHeight: CGFloat = 48', 'static let navRowHeight: CGFloat = 52',
    'static let segmentHeight: CGFloat = 34']) {
    assert.ok(sheet.includes(line), line);
  }
  // 守：字級只用 17／15／13／11（畫面裡沒有寫死的字級數字；碼的 34 從 token 來）。W184 G2 的直欄、sheet、選單也一樣。
  // W184 G2d：頂列、側欄是主視窗 Browser space 的元件，字級照它們自己的（BrowserOmniboxMetrics、BrowserSidebarMetrics；也不寫死數字）。
  for (const [name, source] of [['DMBrowserView', view], ['DMBrowserPhone', phone], ['HandsConnectDMView', connect], ['DMBrowserRail', rail], ['DMBrowserChrome', chrome]]) {
    assert.doesNotMatch(code(source), /\.system\(size: \d/, `${name}: font sizes only from DMPhone.TextSize / DMBrowserPhone.codeSize / the Browser space metrics`);
  }
  // 守：不用藍色系統鈕、不用 borderedProminent。
  assert.doesNotMatch(code(view) + code(phone) + code(connect) + code(rail) + code(chrome), /\.blue\b|Color\.blue|accentColor|borderedProminent|\.bordered\b|NSAlert|\.alert\(/);
});

test('D1 (W184 G2d) the page fills the Browser (12 margins, no handle strip); the sidebar and toolbar are the Browser space\'s, hidden until the pointer reaches the left / top edge', () => {
  // 守：頁面框 上 4、左右下 12 的外距（左邊的把手帶拿掉了）；側欄固定著＝頁面讓出側欄那一欄（同主視窗）。
  // W183 R12（主導 1）：pageFrame 多一個 yield（有連線卡片時網頁讓出卡片那一段）；下面守的照舊。
  const frame = between(view, 'private func pageFrame(toolbar: Bool, yield: CGFloat? = nil) -> some View {', 'private var badges: some View {');
  // W183 R12（主導 1）：下外距＝至少 12；單欄有連線浮卡時再讓到卡片上緣（max(pageBottom, yield)）；沒有卡片＝照舊 12。
  assert.match(frame, /\.padding\(\.top, DMBrowserPhone\.pageTop\)\s*\.padding\(\.horizontal, DMBrowserPhone\.pageSide\)\s*\.padding\(\.bottom, max\(DMBrowserPhone\.pageBottom, yield \?\? 0\)\)/);
  assert.match(frame, /\.overlay\(pageShape\.strokeBorder\(Color\(nsColor: \.separatorColor\), lineWidth: DMPhone\.hairline\)\)/);
  // W183 R12（主導 1）：網頁多帶 yield（單欄有連線浮卡時下緣讓到卡片上緣），前面多一行註解；排法照舊。
  assert.match(view, /HStack\(spacing: 0\) \{\s*Color\.clear\.frame\(width: pushed\)\s*Group \{\s*if showingTabList \{\s*DMBrowserTabList\(browser: browser\)\s*\} else \{\s*(?:\/\/[^\n]*\n\s*)?pageFrame\(toolbar: toolbar, yield: /);
  assert.doesNotMatch(code(view), /DMBrowserHandle\(/);
  // 守：出不出來只看滑鼠在不在左緣／上緣（或 VoiceOver 開著、自測固定展開；側欄固定著、網址在打字＝留著）；收著時不接點擊、也不讓網頁讓位。
  assert.match(view, /private var sidebarShown: Bool \{ forced\.contains\(\.sidebar\) \|\| browser\.sidebarPinned \|\| reveal\.isRevealed \|\| voiceOver \}/);
  assert.match(view, /forced\.contains\(\.toolbar\) \|\| reveal\.toolbarRevealed \|\| voiceOver \|\| addressEditing \|\| pendingFocus == \.address/);
  const bar = between(view, 'private func sidebarLayer(size: CGSize, width: CGFloat, cardTop: CGFloat?) -> some View {', '/// 頂列：');
  assert.match(bar, /\.background\(BrowserChromeHitLayer\(isActive: shown\)\)/);
  assert.match(bar, /\.offset\(x: shown \? 0 : -DMBrowserPhone\.slide\)\s*\.opacity\(shown \? 1 : 0\)\s*\.allowsHitTesting\(shown\)\s*\.animation\(\.easeInOut\(duration: shown \? DMBrowserPhone\.sidebarOpenDuration : DMBrowserPhone\.sidebarCloseDuration\), value: shown\)/);
  // 守：玻璃＝主視窗的側欄殼（WorkspaceSidebarShell：LiquidGlassPanelCard 直角、頂天）；寬照框寬（最寬 250）、貼左緣、從最上面開始。
  assert.match(bar, /DMBrowserSidebar\(browser: browser, spaces: spaces, width: width,/);
  assert.match(bar, /let height = cardTop\.map \{ max\(0, \$0 - DMBrowserPhone\.sidebarGap\) \} \?\? size\.height/);
  assert.match(chrome, /WorkspaceSidebarShell\(width: width\) \{/);
  // 守：頂列＝主視窗那一排（DMBrowserToolbar）、玻璃底同主視窗（BrowserFloatingToolbarBackdrop）、橫跨整個 Browser 區。
  assert.match(view, /DMBrowserToolbar\(browser: browser, address: \$address, focused: \$addressFocused, expansionRequest: \$expansionRequest,/);
  assert.match(view, /\.frame\(width: width, alignment: \.leading\)\s*\.background \{ BrowserFloatingToolbarBackdrop\(\) \}/);
  // 守：CEF 會吃 hover——展開與否用滑鼠位置判斷（本 App 與別的 App 的滑鼠移動、追蹤區），不用 SwiftUI 的 onHover（側欄裡一列的 × 用 onHover，
  // 同主視窗的分頁列：那時指標已經在側欄上）。
  assert.doesNotMatch(code(view) + code(phone) + code(rail), /\.onHover\b/);
  assert.match(phone, /NSEvent\.addLocalMonitorForEvents\(matching: \[\.mouseMoved, \.leftMouseDragged\]\)/);
  assert.match(phone, /NSEvent\.addGlobalMonitorForEvents\(matching: \[\.mouseMoved\]\)/);
  assert.match(phone, /NSTrackingArea\(rect: \.zero, options: \[\.activeAlways, \.inVisibleRect, \.mouseEnteredAndExited, \.mouseMoved\], owner: self\)/);
  assert.match(phone, /let fromLeading = point\.x - bounds\.minX\s*if fromLeading >= 0 && fromLeading <= DMBrowserPhone\.revealZone \{ return true \}\s*guard revealed else \{ return false \}\s*return fromLeading <= width \+ DMBrowserPhone\.exitZone/);
  // 守：狀態不在 SwiftUI 畫面更新的當下發布（掛上、拿下來都下一輪）。
  assert.match(phone, /DispatchQueue\.main\.async \{ \[weak self\] in\s*guard let self, self\.window != nil else \{ return \}\s*self\.reveal\?\.start\(self\)/);
  // 守：浮在網頁上的東西拿得到自己的點擊：頁面容器讓位給登記的 chrome 命中區（同主視窗 Browser）；容器本身還是 R8b 那一個。
  assert.match(view, /override func hitTest\(_ point: NSPoint\) -> NSView\? \{\s*if let window, let superview,\s*BrowserChromeHitLayer\.LayerView\.ownsChromePoint\(superview\.convert\(point, to: nil\), in: window\) \{\s*return nil/);
  assert.match(swift('DM/GlobalDMFormMotion.swift'), /extension DMBrowserPageContainer: GlobalDMNativePageHost \{\}/);
});

test('D2 tab overview = a two-column card grid with a neutral thumbnail (never a snapshot of a sensitive page) + 完成', () => {
  const list = between(view, 'struct DMBrowserTabList: View {', 'struct DMBrowserPageSurface: NSViewRepresentable {');
  assert.match(list, /Text\("\\\(browser\.tabs\.count\) 個分頁・授權頁與配對頁都會開在這裡，不會自己消失"\)/);
  assert.match(list, /LazyVGrid\(columns: \[GridItem\(\.flexible\(\), spacing: DMBrowserPhone\.gridSpacing\), GridItem\(\.flexible\(\), spacing: DMBrowserPhone\.gridSpacing\)\]/);
  // 守：縮圖區是中性色塊——不拍授權頁、配對頁的畫面（截圖保護不能從縮圖漏出去）。
  assert.match(list, /Rectangle\(\)\s*\.fill\(Color\.primary\.opacity\(DMBrowserPhone\.thumbnailOpacity\)\)\s*\.frame\(height: DMBrowserPhone\.thumbnailHeight\)/);
  assert.doesNotMatch(code(view) + code(phone), /cacheDisplay|bitmapImageRep|CGWindowListCreateImage|takeSnapshot|ImageRenderer|SCScreenshot/);
  // 守：選中的 2pt 強調色框、其他 0.5 分隔色；右上圓形關掉鈕照舊會取消還沒完成的流程（userClose）；點卡片＝換到那一頁。
  assert.match(list, /lineWidth: active \? DMBrowserPhone\.tabCardRing : DMPhone\.hairline/);
  assert.match(list, /Button \{ browser\.userClose\(tab\.id\) \} label: \{/);
  assert.match(list, /Button \{ browser\.select\(tab\.id\) \} label: \{/);
  // 守：狀態：完成＝綠勾、進行中＝強調色。
  assert.match(list, /Label\("完成", systemImage: "checkmark\.circle\.fill"\)[\s\S]{0,200}LiquidGlassTokens\.loopsPositive/);
  assert.match(list, /Text\(tab\.loading \? "載入中…" : "進行中"\)/);
  // 守：底部玻璃膠囊裡右邊「完成」（強調色膠囊），識別碼沿用舊「收起」的 tatwo.dm.browser.tabList.close。
  assert.match(list, /DMPhoneCapsuleButton\(title: "完成", prominent: true\) \{ browser\.isShowingTabList = false \}[\s\S]{0,120}\.accessibilityIdentifier\("tatwo\.dm\.browser\.tabList\.close"\)/);
});

test('D3 the pairing card floats on the page (the page is not squeezed); cancel top-right; big monospaced code only while its page is on screen', () => {
  // 守：卡片在 ZStack 裡浮著（不是頁面下面的一列）。
  const layout = between(view, 'private func layout(_ size: CGSize) -> some View {', '// MARK: 頁面');
  assert.match(layout, /ZStack\(alignment: \.topLeading\) \{/);
  assert.match(layout, /if let card \{ cardLayer\(card, size: size\) \}/);
  // W184 G2c／G2d：卡片左右 12、離底 30，不動、不變窄；側欄停在卡片上面 8（側欄下緣跟著卡片頂端），卡片的按鈕永遠不會被側欄蓋住。
  const card = between(view, 'private func cardLayer(_ card: HandsConnectCard, size: CGSize) -> some View {', '/// 側欄：');
  assert.match(card, /\.padding\(\.horizontal, DMBrowserPhone\.cardInset\)\s*\.padding\(\.bottom, DMBrowserPhone\.cardBottom\)/);
  assert.match(card, /Color\.clear\.preference\(key: DMBrowserCardTopKey\.self, value: proxy\.frame\(in: \.named\(Self\.space\)\)\.minY\)/);
  assert.match(layout, /sidebarLayer\(size: size, width: width, cardTop: card == nil \? nil : cardTop\)/);
  assert.match(view, /let height = cardTop\.map \{ max\(0, \$0 - DMBrowserPhone\.sidebarGap\) \} \?\? size\.height/);
  assert.doesNotMatch(code(view) + code(phone), /cardTrailing/);
  // 守：卡片那一塊的點擊給卡片（網頁讓位）。
  assert.match(connect, /\.liquidGlassPanelSurface\(cornerRadius: DMBrowserPhone\.cardRadius\)\s*\.background\(BrowserChromeHitLayer\(\)\)/);
  const pairing = between(connect, 'private func pairing(_ view: HandsConnectPairingView) -> some View {', '// MARK: - sheet 裡的清單樣子');
  // 守：頂列「配對碼・只在這台」＋右上取消 chip；碼 34 等寬、字距 0.16em、置中；複製提示與剩餘時間。
  assert.match(pairing, /Text\(face\.title\)[\s\S]{0,120}Spacer\(minLength: 8\)\s*if !inSheet \{ dismissChip \}/);
  // W184 D（GPT-6 審查 #1）：碼畫在 DMSecretCode 自己的 NSView 上（34 等寬半粗、字距 0.16em、置中；放不下等比縮到 0.6）。
  assert.match(pairing, /DMSecretCode\(text: code\)\s*\.frame\(maxWidth: \.infinity\)\s*\.transaction \{ \$0\.animation = nil \}/);
  assert.match(phone, /\.font: NSFont\.monospacedSystemFont\(ofSize: size, weight: \.semibold\),[\s\S]{0,120}\.kern: DMBrowserPhone\.codeTracking \* scale/);
  // W183 R12：兩頁時同一句說「右邊的頁面」（context.sided）；守的一樣：碼只在它那一頁在畫面上時顯示。
  assert.match(pairing, /Text\(context\.sided\("複製後貼到上面的頁面・\\\(remaining\)"\)\)/);
  // 守：交易編號（網頁上同一組，T15／契約 §3）照樣在卡上；手動模式明講無法確認來源。
  assert.match(pairing, /Text\("交易 \\\(view\.displayCode\)（網頁上要一樣）・回到 \\\(view\.callbackHost\)・還可以錯 \\\(view\.attemptsLeft\) 次"\)/);
  assert.match(pairing, /if view\.manual \{\s*Text\("手動模式：TATWO 無法確認這一頁是你剛剛自己建立的連接器打開的/);
  // 守：碼只在綁住的那一頁正在畫面上時顯示（Browser 當下算；換分頁、分頁總覽、框收起來＝遮起來）；碼的無障礙標籤不唸出碼。
  assert.match(pairing, /let left = max\(Int\(view\.expiresAt\.timeIntervalSince\(timeline\.date\)\), 0\)/);
  assert.match(pairing, /if let code = view\.spacedCode, context\.revealsCode, left > 0 \{/);
  assert.match(pairing, /GlobalDMChipButton\(title: copiedCode \? "已複製" : "複製"\)/);
  assert.match(pairing, /copiedCode = actions\.copyPairingCode\(view\)/);
  assert.match(pairing, /\.disabled\(context\.cancelling \|\| view\.attemptsLeft <= 0\)/);
  assert.match(pairing, /\.accessibilityIdentifier\("tatwo\.dm\.handsConnect\.copyCode"\)/);
  // W184 R：配對內容抽成 pairingDetails（浮卡自己捲、左頁沿用整頁捲）。
  // 仍精確守「碼被遮住」的分支，不能誤抓新的「浮卡／整頁」排版分支。
  const details = between(pairing, 'private func pairingDetails(', null);
  const hidden = between(details, '            } else {', '// 交易編號');
  assert.match(hidden, /Text\(left == 0 \? "配對碼已過期，請重新連線。"/);
  assert.doesNotMatch(code(hidden), /DMSecretCode\(|copyPairingCode\(/);
  assert.match(phone, /setAccessibilityLabel\("配對碼"\)\s*setAccessibilityIdentifier\("tatwo\.dm\.handsConnect\.code"\)/);
  assert.match(view, /let reveals = connect\.revealsCode\(card\) && browser\.holdsPage\(slot\.container\)\s*(?:return )?HandsConnectFloatingCard\(card: card, flow: flow, presenter: connect, revealsCode: reveals\)/);
  // 守：Browser 換了畫面上的 Pod 頁（shownSurface）下一輪 run loop 就發布——卡片不用等流程下一次核對；不在畫面更新的當下發布；
  // 用 run loop 不用 main queue（巢狀的 run loop 也輪得到，自測 w184browser F7 驗）。
  assert.match(browser, /@Published private\(set\) var shownSurface: Int\?/);
  assert.match(between(browser, 'private func placementChanged() {', 'private func place(focus: Bool = false) {'),
    /RunLoop\.main\.perform\(inModes: \[\.common\]\) \{ \[weak self\] in\s*MainActor\.assumeIsolated \{\s*guard let self, self\.pendingPlacement == now else \{ return \}\s*self\.shownSurface = now\.surface/);
  // 守：值跟上一次一樣也發布（新建的 Browser 畫面第一次算的時候頁面還沒放進去，要靠這一次重算；自測 F7a 每一次畫都數）。
  assert.doesNotMatch(between(browser, 'private func placementChanged() {', 'private func place(focus: Bool = false) {'), /shownSurface != now/);
  assert.match(acceptance, /F7 once the pairing page is placed the Browser publishes it/);
  assert.match(acceptance, /F7a a fresh Browser pane/);
});

test('D3 production code-visibility gate rejects hidden, missing and expired pairing codes', () => {
  const pairing = between(connect, 'private func pairing(_ view: HandsConnectPairingView) -> some View {', '// MARK: - sheet 裡的清單樣子');
  const remaining = pairing.match(/let left = max\(Int\(view\.expiresAt\.timeIntervalSince\(timeline\.date\)\), 0\)/)?.[0];
  const guardLine = pairing.match(/if let code = view\.spacedCode,[^\n]+\{/)?.[0];
  assert.ok(remaining && guardLine, 'extract the real visibility condition rather than reimplement it');
  const dir = testScratch('pairing-visibility-'), source = join(dir, 'main.swift'), binary = join(dir, 'check');
  writeFileSync(source, `import Foundation
struct View { let spacedCode: String?; let expiresAt: Date }
struct Context { let revealsCode: Bool }
struct Timeline { let date: Date }
func visible(_ view: View, _ context: Context, _ timeline: Timeline) -> Bool {
  ${remaining}
  ${guardLine} _ = code; return true }
  return false
}
let now = Date(timeIntervalSince1970: 100)
for code: String? in [nil, "fixture"] {
  for reveals in [false, true] {
    for seconds: Double in [-1, 0, 0.5, 1, 60] {
      let result = visible(View(spacedCode: code, expiresAt: now.addingTimeInterval(seconds)),
                           Context(revealsCode: reveals), Timeline(date: now))
      precondition(result == (code != nil && reveals && seconds >= 1))
    }
  }
}
print("PAIRING VISIBILITY PASS")
`);
  const build = spawnSync('swiftc', [source, '-o', binary], { encoding: 'utf8', timeout: 60_000 });
  assert.equal(build.status, 0, build.stderr);
  const run = spawnSync(binary, [], { encoding: 'utf8', timeout: 10_000 });
  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /PAIRING VISIBILITY PASS/);
});

test('D4 ［連線］ confirm = bottom sheet (取消｜連上 ChatGPT｜連線, one cancel only); 「輪到你勾選」 is a floating card (取消／繼續)', () => {
  const layer = between(connect, 'struct HandsConnectDMLayer: View {', '// MARK: - W184 D：卡片畫出來要的資料與按鈕');
  // 守：遮罩 0.22（點了不關）、sheet 從下滑出到離頂 96。
  assert.match(layer, /Color\.black\.opacity\(GlobalDMWebSheetLayout\.dimOpacity\)\s*\.contentShape\(Rectangle\(\)\)\s*\.onTapGesture \{\}/);
  assert.match(layer, /HandsConnectSheet\(card: card, flow: flow, presenter: presenter\)\s*\.padding\(\.top, GlobalDMWebSheetLayout\.topInset\)[^\n]*\n(\s*\/\/[^\n]*\n)*\s*\.transition\(presenter\.revealsCode\(card\) && card\.carriesCode \? \.identity : \.move\(edge: \.bottom\)\)/);
  const sheetView = between(connect, 'struct HandsConnectSheetView: View {', 'struct HandsConnectConfirmContent: View {');
  // 守：grabber、頂列左取消（玻璃膠囊）、中標題、右「連線」（強調色膠囊）；往下拉超過一段＝取消（同按取消）。
  assert.match(sheetView, /grabber\s*header\(face\)/);
  assert.match(sheetView, /DMPhoneCapsuleButton\(title: face\.dismissTitle\) \{ actions\.dismiss\(\) \}\s*\.disabled\(context\.cancelling\)[\s\S]{0,120}\.accessibilityIdentifier\("tatwo\.dm\.handsConnect\.cancel"\)/);
  // W183 R10：卡上沒有下一層了（專案、記憶頁拿掉），右上「連線」只剩一種情況；按連線＝同意那一句也掛在它的 help。
  assert.match(sheetView, /case \.confirm:\s*DMPhoneCapsuleButton\(title: "連線", prominent: true\) \{ actions\.connect\(\) \}\s*\.help\(HandsConnectFlow\.consentLine\)[^\n]*\n\s*\.accessibilityIdentifier\("tatwo\.dm\.handsConnect\.connect"\)/);
  assert.match(sheetView, /let dismiss = value\.translation\.height > GlobalDMWebSheetLayout\.pullToDismiss && !context\.cancelling/);
  assert.match(sheetView, /\.clipShape\(GlobalDMWebSheetLayout\.shape\)/);
  // 守：舊的確認卡底部第二顆「取消」拿掉（只留頂列一顆）。
  assert.doesNotMatch(code(connect), /OSChipButton\(title: "取消"\)/);
  assert.equal((code(between(connect, 'struct HandsConnectConfirmContent: View {', '// MARK: - 按了［連線］之後')).match(/actions\.dismiss\(\)/g) ?? []).length, 0,
    'the confirm content has no cancel of its own');
  // 守：帳號、主機、網址、授權後回到（T15）都在卡上；不宣稱驗證了帳號。
  // W183 R11（使用者 09-30「關鍵是 ui要簡單好懂而不是砸文字做解釋」；主導：「用圖示加一行字，不放大段說明」）：取代四列清單——
  // 帳號→主機是一條路（兩個圖示＋名字；帳號唸「Pod 目前帳號」），網址、全部專案、授權後回到哪收成一行等寬小字（照樣都在卡上）。
  const confirm = between(connect, 'struct HandsConnectConfirmContent: View {', '// MARK: - 按了［連線］之後');
  assert.match(confirm, /HandsConnectRoute\(account: account, host: offer\.hostName\.isEmpty \? offer\.hostDeviceID : offer\.hostName\)/);
  assert.match(confirm, /end\(symbol: "bubble\.left\.and\.bubble\.right\.fill", name: account \?\? "還沒登入", label: "Pod 目前帳號"\)/);
  assert.match(confirm, /end\(symbol: "desktopcomputer", name: host, label: "主機"\)/);
  assert.match(confirm, /return "\\\(offer\.publicHost\)・\\\(projectsText\(offer\)\)・授權後回到 \\\(back\)"/);
  assert.match(confirm, /let back = offer\.callbackHosts\.isEmpty \? "chatgpt\.com" : offer\.callbackHosts\.joined\(separator: "、"\)/);
  assert.match(confirm, /Text\(Self\.facts\(offer\)\)\s*\.font\(\.system\(size: DMPhone\.TextSize\.caption, design: \.monospaced\)\)/);
  assert.doesNotMatch(connect, /已驗證/);
  // W183 R10（使用者 09-29「這邊要勾選也太怪」；取代 W184 D 的「L0／L1／L2 分段＋專案、記憶按進下一層」）：卡上不選範圍——等級、專案、記憶
  // 一組只顯示（中央設定的等級＋這台全部專案；交易類只能看），［連線］旁一行小字＝按連線就同意；不是系統分段元件、沒有勾選框、沒有按鈕。
  assert.doesNotMatch(connect, /struct HandsConnectScopeChooser|HandsConnectLevelSegments|HandsConnectNavRow|actions\.chooseLevel|open\(\.projects\)|open\(\.memory\)/);
  // W183 R11：等級、專案、記憶照舊一組只顯示——能做什麼是圖示 chip（L2＝Codex、記憶；記憶下面「讀・遮敏感」）＋一行白話；
  // 等級的字（HandsState.levelLabel）與整段說明（levelText）在無障礙與滑過的提示；專案＝這台全部（N 個）在那一行小字。
  // W183 R12（使用者 09-30 裁決：拿掉等級選擇；主導：確認卡不顯示等級膠囊，直接寫能力）：圖示 chip 拿掉，一行能力（HandsConnectAbility.line）；
  // 無障礙那一句也從等級的字（HandsState.levelLabel）換成那一行能力。
  assert.doesNotMatch(code(confirm), /HandsConnectAbilityChips|HandsState\.levelLabel/);
  assert.match(confirm, /static func line\(_ offer: HandsConnectOffer\) -> String \{ HandsConnectAbility\.line\(level: offer\.scope\.level\) \}/);
  assert.match(confirm, /\.accessibilityLabel\("\\\(Self\.line\(offer\)\)；專案：\\\(Self\.projectsText\(offer\)\)；記憶：\\\(HandsConnectCardBody\.memorySummary\(level: offer\.scope\.level\)\)"\)/);
  assert.match(confirm, /\.help\(HandsConnectCardBody\.levelText\(offer\.scope\.level\)\)/);
  assert.match(connect, /static func memorySummary\(level: Int\) -> String \{ level >= 1 \? "讀・遮敏感" : "不碰" \}/);
  assert.match(confirm, /Text\(HandsConnectFlow\.consentLine\)[\s\S]{0,320}\.accessibilityIdentifier\("tatwo\.dm\.handsConnect\.consent"\)/);
  assert.doesNotMatch(code(confirm), /pickerStyle\(\.segmented\)|\.toggleStyle\(\.checkbox\)|Button\(|onTapGesture/);
  // 守：「輪到你勾選」是浮卡、對照稿的兩句；底下「取消｜繼續」（取消在主要動作前面）。
  // W183 R10 取代「TATWO 不會替你勾」：按［連線］＝同意、TATWO 代勾；這張卡只剩退路（這次沒辦法代勾、或代勾沒勾到）。
  assert.match(connect, /static let ackTitle = "輪到你：勾選「I understand」"/);
  assert.match(connect, /static let ackLine = "TATWO 這次沒辦法替你勾：勾完按繼續（Create 由 TATWO 按）。"/);
  assert.match(connect, /static let tickMissedLine = "TATWO 沒勾到：自己勾完按繼續（Create 由 TATWO 按）。"/);
  assert.match(connect, /let ack = text == HandsConnectFlow\.riskAckCardText \|\| text == HandsConnectFlow\.tickMissedCardText/);
  const turn = between(connect, 'private var turn: some View {', 'private func manual(');
  assert.match(turn, /DMPhoneCapsuleButton\(title: face\.dismissTitle, grow: true\) \{ actions\.dismiss\(\) \}[\s\S]{0,160}\.accessibilityIdentifier\("tatwo\.dm\.handsConnect\.cancel"\)(?:\s*\.background \{ if probes \{ DMFrameProbe\(key: "card\.turnCancel"\) \} \}[^\n]*)?\s*\}\s*DMPhoneCapsuleButton\(title: "繼續", prominent: true, grow: true\) \{ actions\.continueAfterUser\(\) \}\s*\.accessibilityIdentifier\("tatwo\.dm\.handsConnect\.continue"\)/);
  assert.match(turn, /\.accessibilityIdentifier\("tatwo\.dm\.handsConnect\.ack"\)/);
  // 守：錯誤＝一句話＋一顆鈕（needsManual 兩條路：手動、再連一次）；按鈕只經 live 的 actions 接到流程。
  assert.match(connect, /case \.needsManual\(let text\):\s*return HandsConnectCardFace\(kind: \.status, title: connectTitle, line: text, mark: \.warning, actions: \[\.manual, \.retry\]/);
  assert.match(connect, /case \.refused\(let text\), \.failed\(let text\):\s*return HandsConnectCardFace\(kind: \.status, title: connectTitle, line: text, mark: \.warning, actions: \[\.retry\]/);
  assert.match(connect, /HandsConnectCardActions\(dismiss: \{ flow\.dismiss\(\) \}, connect: \{ flow\.connect\(\) \}, continueAfterUser: \{ flow\.continueAfterUser\(\) \},/);
});

test('D5 capture is blocked only while an authorisation page or the pairing code is on screen; every other protection unchanged', () => {
  // 守：Browser 的規則（選中的是還開著的敏感分頁、分頁總覽沒開、Browser 在框裡看得到）；小標同一條。
  assert.match(browser, /nonisolated static func capturesBlocked\(activeSensitive: Bool, tabList: Bool, onScreen: Bool\) -> Bool \{\s*activeSensitive && !tabList && onScreen\s*\}/);
  assert.match(browser, /WindowCaptureShield\.shared\.hold\(self, window: needsCaptureProtection \? window : nil\)/);
  assert.match(view, /if shielded \{\s*DMBrowserShieldBadge\(\)/);
  // 守：連線卡片的規則＝配對碼真的在畫面上；兩個持有者照舊以視窗計數（最後一個放手才還原）。
  assert.match(connect, /private func refreshCodeShield\(\) \{\s*WindowCaptureShield\.shared\.hold\(self, window: codeOnScreen \? cardWindow : nil\)/);
  const shield = between(shieldFile, 'final class WindowCaptureShield {', undefined);
  assert.match(shield, /guard let self, let entry, entry\.holders\.isEmpty else \{ return \}\s*entry\.restore = nil\s*entry\.window\?\.sharingType = entry\.original/);
  // 守（不動）：Computer Use 閘門——有敏感分頁就擋（不管在不在畫面上）、連線卡片在畫面上整段、配對頁視窗還開著。
  // W184 G2：敏感只看流程開的分頁（授權頁、Pod、配對頁、登入視窗）頁面還開著；使用者自己開的一般網頁不是授權頁。
  assert.match(browser, /var isSensitive: Bool \{ tabs\.contains\(where: \\\.isSensitive\) \}/);
  assert.match(browser, /var isSensitive: Bool \{ !pageClosed && purpose\.isFlow \}/);
  assert.match(browser, /var isFlow: Bool \{ self != \.browse \}/);
  assert.match(gate, /browsers\.contains \{ \$0\.value\?\.isSensitive == true \} \|\| !BrowserTabRegistry\.withSensitiveTabs\.isEmpty\s*\|\| HandsConnectPresenter\.anySensitive/);
  // W183 R11：只剩結果的卡片（已連線、已斷線）不算連線過程（連上之後在閘門外看得到狀態）；過程的卡片、配對頁視窗、build 設定卡照舊算。
  assert.match(connect, /static var anySensitive: Bool \{\n\s*shown\.contains \{ \$0\.value\?\.inProcess == true \} \|\| ChatGPTConnectorPod\.sensitivePopupCount > 0 \|\| HandsBuildScreenGate\.isShown\n\s*\}/);
  assert.match(between(connect, '    func show() {', '    func hide() {'), /BrowserSensitivePageGate\.pageAppeared\(\)/);
  // 守（不動）：只准 https 的起點、不進紀錄（沒有檔案、沒有日誌）、popup 原生視窗不給擷取且收起來、配對碼只在綁住的那一頁看得到時、
  // 關掉未完成分頁＝取消流程。
  assert.match(browser, /case \.cloudflareLogin: return GlobalDMWebSheet\.cloudflareAuthorization\(url\)\?\.url/);
  assert.doesNotMatch(code(browser) + code(view) + code(phone) + code(rail) + code(spaces), /FileManager|UserDefaults|NSLog|print\(/);
  assert.match(browser, /window\.alphaValue = 0\s*window\.ignoresMouseEvents = true\s*window\.sharingType = \.none\s*window\.orderOut\(nil\)/);
  assert.match(browser, /case \.pod: return surface == -1\s*case \.popup\(let key\): return surface == key\s*case \.web: return false/);
  assert.match(browser, /let cancel = tab\.done \? nil : cancelActions\[id\]\s*removeTab\(id\)\s*cancel\?\(\)/);
  // 守：契約 §3b「敏感範圍」與 spec 184 D5 同步（規則寫下來，審查照它對）。
  const contract = read('docs/specs/183-chatgpt-hands/contract.md');
  assert.match(contract, /螢幕擷取（W184 D 改[^\n]*只在\*\*授權頁或配對碼正在畫面上\*\*時擋/);
  assert.match(contract, /Computer Use 都不准以 TATWO 為目標；螢幕擷取/);
  assert.match(read('docs/specs/184-dm-iphone-duo/spec.md'), /\| D5 \|[^\n]*已同步 `docs\/specs\/183-chatgpt-hands\/contract\.md` §3b「敏感範圍」/);
});

test('lead: the R9 「新增 ▾」 Pod lease stays while the ChatGPT Dev page is on screen, including the inner-landscape right column', () => {
  // 守：舊的只看主 store 的 isBrowsing（內橫時 Browser 在右欄會被誤判成不在、提早放掉租約）；改看 ChatGPT Dev 的頁面真的在畫面上。
  assert.match(menu, /boxClosed: \{ ChatGPTPluginNewMenu\.leftDevTab\(store: DMBrowser\.shared\.store, browser: DMBrowser\.shared\) \}/);
  assert.match(menu, /static func leftDevTab\(store: GlobalDMStore, browser: DMBrowser\) -> Bool \{\s*!store\.isEnabled \|\| !browser\.showsPage\(\.chatgptDeveloper\)/);
  assert.doesNotMatch(code(between(menu, 'static func live() -> Dependencies {', 'podAlive:')), /isBrowsing/);
  // 守（GPT-6 審查 #2）：租約看「還在私訊框裡給使用者用」——視窗排在畫面上（orderOut＝離開、放租約）；短暫的形態轉換、
  // 原生網頁暫時藏起來、被別的視窗蓋住都不算離開（不看 isTransitioning、isHidden、occlusion）。
  const shows = between(browser, 'func showsPage(_ purpose: DMBrowserPurpose) -> Bool {', 'private func transitionChanged(');
  assert.match(shows, /guard !isShowingTabList, let id = activeID, let page = pages\[id\], let tab = tabs\.first\(where: \{ \$0\.id == id \}\),\s*tab\.purpose == purpose, !tab\.pageClosed,\s*let container = containers\.last\(where: \{ \$0\.view != nil \}\)\?\.view, let window = container\.window, window\.isVisible,\s*page\.view\.superview === container else \{ return false \}/);
  assert.doesNotMatch(code(shows), /isTransitioning|isHidden|occlusion|windowShown/);
  assert.match(acceptance, /E1 \(lead, R9 gap\)/);
  assert.match(acceptance, /let oldRuleDrops = !h\.store\.isEnabled \|\| \(!h\.store\.isOpen && !h\.store\.isFloatingOpen\) \|\| !h\.store\.isBrowsing/);
});

test('identifiers: every Browser and ［連線］ identifier from the inventory is kept; new pieces get new tatwo.dm.* ids', () => {
  const toolbar = read('App/Sources/Tatwo2/Browser/EmbeddedBrowserToolbar.swift');
  assert.match(toolbar, /\.accessibilityElement\(children: \.contain\)\s*\.accessibilityIdentifier\("browser-navigation-bar"\)/);
  for (const id of ['tatwo.dm.browser"', 'tatwo.dm.browser.device', 'tatwo.dm.browser.done',
    'tatwo.dm.browser.waiting', 'tatwo.dm.browser.closed.close', 'tatwo.dm.browser.problem', 'tatwo.dm.browser.elsewhere',
    'tatwo.dm.browser.tabStrip', 'tatwo.dm.browser.tab." + tab.purpose.rawValue',
    'tatwo.dm.browser.tabList"', 'tatwo.dm.browser.tabList.close"', 'tatwo.dm.browser.tabList.card." + tab.purpose.rawValue',
    'tatwo.dm.browser.tabList.close." + tab.purpose.rawValue', 'tatwo.dm.browser.page', 'tatwo.dm.browser.tabList.bar', 'tatwo.dm.browser.addressHost',
    '"tatwo.dm.browser.tabList.newTab"',
    // W184 G2d：新的
    'tatwo.dm.browser.sidebar', 'tatwo.dm.browser.toolbar', 'tatwo.dm.browser.search', 'tatwo.dm.browser.caution']) {
    assert.ok(view.includes(id), id);
  }
  // W184 G2d：側欄、頂列、置中搜尋框是主視窗 Browser space 的元件，帶著它們自己的識別碼（browser.sidebarToggle、browser-navigation-bar、
  // browser.omnibox、browser.favorites.strip、browser.favorite.<id>、browser.folder.<id>、browser.bookmark.<id>、browser.tab.<id>、
  // browser.space.<id>、browser.translate、browser.extensions）；私訊框自己那一套（上一頁列 back／forward／tabs、網址卡 addressCard、
  // pageTitle、還沒有分頁 empty、空白分頁 blank、左列 bar、DMBrowserSidebarPart）跟著拿掉。私訊框自己組的幾塊用 tatwo.dm.browser.*。
  for (const id of ['"tatwo.dm.browser.newTab"', '"tatwo.dm.browser.spaces"', '"tatwo.dm.browser.tabRow." + tab.purpose.rawValue', '"tatwo.dm.browser.notes"']) {
    assert.ok(chrome.includes(id), id);
  }
  assert.doesNotMatch(code(view) + code(phone) + code(chrome), /DMBrowserSidebarPart|"tatwo\.dm\.browser\.(back|forward|tabs|addressCard|pageTitle|empty|blank|bar)"/);
  assert.ok(phone.includes('tatwo.dm.browser.shield'), 'tatwo.dm.browser.shield');
  // W184 D（GPT-6 審查 #1）：配對碼的識別碼跟著碼搬到 DMSecretCodeView（AppKit 設的）。
  assert.ok(phone.includes('setAccessibilityIdentifier("tatwo.dm.handsConnect.code")'), 'tatwo.dm.handsConnect.code');
  for (const id of ['tatwo.dm.handsConnect"', 'tatwo.dm.handsConnect.float', 'tatwo.dm.handsConnect.cancel', 'tatwo.dm.handsConnect.connect',
    'tatwo.dm.handsConnect.continue', 'tatwo.dm.handsConnect.manual', 'tatwo.dm.handsConnect.retry',
    // 新的
    'tatwo.dm.handsConnect.ack',
    // W183 R10：範圍一組只顯示、按連線＝同意那一行、交易類只能看那一行、代填沒成那一行。
    'tatwo.dm.handsConnect.scopeSummary"', 'tatwo.dm.handsConnect.consent"', 'tatwo.dm.handsConnect.readOnly"', 'tatwo.dm.handsConnect.autoFillFailed"']) {
    assert.ok(connect.includes(id), id);
  }
  // W183 R10（使用者 09-29「這邊要勾選也太怪」）：卡上的範圍選擇整段拿掉——選等級的分段、專案列、找專案、下一層的專案／記憶頁與返回鈕的識別碼
  // 跟著那些元件一起拿掉（不是改名藏起來）。
  assert.doesNotMatch(connect, /"tatwo\.dm\.handsConnect\.(scope|levelLine|project|projectFilter|dropped|projectsEmpty|projectsUnchecked|projects|memory|back)"|tatwo\.dm\.handsConnect\.level\\\(level\)/);
});

test('GPT-6 review #1/#2: every frame that still draws the pairing code keeps its window uncapturable; the code shows only while its page is really presented', () => {
  // 守 #1：碼畫在 DMSecretCodeView 自己的 NSView 上——進了哪個視窗就持有那個視窗（WindowCaptureShield），離開＝放手，視窗照 linger 再擋一小段。
  assert.match(phone, /override func viewDidMoveToWindow\(\) \{\s*super\.viewDidMoveToWindow\(\)\s*WindowCaptureShield\.shared\.hold\(self, window: window\)/);
  assert.match(shieldFile, /static let linger: TimeInterval = 0\.45/);
  assert.match(shieldFile, /let timer = Timer\(timeInterval: Self\.linger, repeats: false\)[\s\S]{0,400}RunLoop\.main\.add\(timer, forMode: \.common\)/);
  // 守 #1：帶著碼的卡片、sheet 退場不播動畫；碼與「遮起來」那一句互換也不播動畫（不留碼淡出的中間幀）。
  assert.match(phone, /func dmCardTransition\(showingSecret: Bool\) -> AnyTransition \{\s*showingSecret \? \.identity : \.move\(edge: \.bottom\)\.combined\(with: \.opacity\)/);
  assert.match(view, /\.transition\(dmCardTransition\(showingSecret: reveals && card\.carriesCode\)\)/);
  // 守 #2：轉換一開始，畫著的碼同步藏起來（在動畫的第一個畫面之前）；轉換期間畫面怎麼重算都不顯示；結束才又顯示。
  assert.match(phone, /static func suppress\(_ on: Bool\) \{\s*suppressed = on\s*guard on else \{ return \}\s*for view in live\.allObjects \{ view\.isHidden = true \}/);
  // W184 F3（A1）：轉換中或拍私訊框的圖時都藏著（isSuppressed＝suppressed 或拍圖持有中）。
  assert.match(phone, /func updateNSView\(_ view: DMSecretCodeView, context: Context\) \{\s*view\.text = text\s*view\.isHidden = DMSecretCodeView\.isSuppressed/);
  assert.match(browser, /private func transitionChanged\(_ on: Bool\) \{\s*guard on != isTransitioning else \{ return \}\s*isTransitioning = on\s*DMSecretCodeView\.suppress\(isTransitioning \|\| isMasking\)\s*placementChanged\(\)/);
  // 守（主導轉達房 AB）：原生網頁的遮蔽狀態 GlobalDMNativePageMask.isMasking 也算：遮蔽中＝頁面不在畫面上、碼同步藏起來；租約（showsPage）不看它。
  assert.match(browser, /private func maskChanged\(_ on: Bool\) \{\s*guard on != isMasking else \{ return \}\s*isMasking = on\s*DMSecretCodeView\.suppress\(isTransitioning \|\| isMasking\)\s*placementChanged\(\)/);
  assert.match(browser, /maskWatch = GlobalDMNativePageMask\.shared\.\$isMasking\.sink \{ \[weak self\] on in MainActor\.assumeIsolated \{ self\?\.maskChanged\(on\) \} \}/);
  assert.match(browser, /guard !isShowingTabList, !isTransitioning, !isMasking, id == activeID/);
  // 守（主導轉達房 AB：open() 在倒放、轉換中會排隊）：框真的打開之後才記「打開後的樣子」（Browser 與［連線］卡都是），流程結束照樣收回。
  // W184 AB（GPT-6 複核 新發現 2、3）：開框是一個請求——記在這一次請求的完成回呼（不用「任一框已開」推定）；流程結束撤銷還沒出列的。
  for (const [name, source] of [['DMBrowser', browser], ['HandsConnectDMView', connect]]) {
    assert.match(source, /request\.whenFinished \{ \[weak self\] outcome in self\?\.openFinished\(/, name);
    assert.match(source, /case \.opened\(let before, let after\) = outcome, after\.isOpen else \{ return \}/, name);
    assert.doesNotMatch(code(source), /appliedWatch|recordAppliedBox/, name);
  }
  for (const label of ['H6 counterexample (room AB\'s native-page mask)', 'H7 counterexample: the Browser\'s open() is queued', 'H7 counterexample: the ［連線］ card\'s open() is queued']) {
    assert.ok(acceptance.includes(label), label);
  }
  // 正式的 Browser 跟著桌面控制器的 isFormTransitioning（第一次有框接頁面時才訂，同步送來）。
  assert.match(browser, /static let shared = DMBrowser\(transitions: \{ GlobalDMDeskController\.shared\.\$isFormTransitioning\.eraseToAnyPublisher\(\) \}\)/);
  assert.match(browser, /transitionWatch = transitionSource\(\)\.sink \{ \[weak self\] on in MainActor\.assumeIsolated \{ self\?\.transitionChanged\(on\) \} \}/);
  // 守 #2：實際呈現＝看得到的視窗（排在畫面上、沒被整個蓋住）；視窗蓋住／orderOut／回來都重算。
  assert.match(browser, /static func windowShowsPages\(_ window: NSWindow\) -> Bool \{\s*window\.isVisible && window\.occlusionState\.contains\(\.visible\)/);
  assert.match(browser, /self\.windowShown = windowShown \?\? \{ DMBrowser\.windowShowsPages\(\$0\) \}/);
  assert.match(browser, /forName: NSWindow\.didChangeOcclusionStateNotification[\s\S]{0,300}guard let self, let window, window === self\.shownWindow else \{ return \}\s*self\.placementChanged\(\)/);
  // 守 #1（跨視窗換手）：兩個 Browser 畫面同時在時，只有頁面真的放在自己框裡的那一個畫碼（自測 I4：舊視窗把碼收掉、還原）。
  assert.match(browser, /func holdsPage\(_ container: NSView\?\) -> Bool \{\s*guard let container else \{ return false \}\s*return containers\.last\(where: \{ \$0\.view != nil \}\)\?\.view === container/);
  assert.match(view, /let container = DMBrowserPageContainer\(frame: \.zero\)\s*container\.owner = browser\s*slot\?\.container = container\s*browser\.claim\(container\)/);
  assert.match(view, /DMBrowserPageSurface\(browser: browser, slot: slot\)/);
  // 守 #1／#2：框換了（停靠框↔浮動框、新建的畫面）也重發，舊的畫面才會把碼收起來、新的才會畫碼。
  assert.match(browser, /let now = Placement\(surface: surface, container: containers\.last\(where: \{ \$0\.view != nil \}\)\?\.view\.map \{ ObjectIdentifier\(\$0\) \}\)/);
  // 反例自測（GPT-6 審查 #6）：退場中碼仍畫著、轉換中的碼、停靠 panel 只 orderOut 不 unmount、真的拆畫面（不是直接 release）、換手。
  for (const label of ['H1 counterexample: the docked panel only ordered out', 'H2 counterexample: the native page is hidden', 'H3 counterexample: the form transition starts',
    'H4 the 「新增 ▾」 lease is kept through a short form transition', 'H5 counterexample: an ordered-out window never counts as showing pages',
    'I0 the pairing code is drawn on the page', 'I1 counterexample (GPT-6 #1): opening the tab overview', 'I2 counterexample: cancelling with the code up',
    'I3 counterexample: collapsing the box for real', 'I4 counterexample: handing the Browser to another window', 'I5 counterexample (GPT-6 #2): a form transition starts']) {
    assert.ok(acceptance.includes(label), label);
  }
  assert.match(acceptance, /for window in windows where codeDrawn\(in: window\) && !WindowCaptureShield\.shared\.isShielding\(window\) \{ held = false \}/);
  assert.match(acceptance, /let close = sample\(\[window\]\) \{ window\.contentView = nil \}/);
});

test('self-test w184browser is registered, DEBUG-only, isolated, fakes only, with counterexamples for every capture rule and PNG evidence', () => {
  assert.match(selftest, /TATWO2_SELFTEST"\] == "w184browser"[\s\S]{0,300}DMBrowserPhoneAcceptance\.run\(\)/);
  assert.match(acceptance, /^#if DEBUG/);
  assert.match(acceptance, /NativeStagingIsolation\.isEnabled\(environment\), NativeStagingIsolation\.validationError\(environment\) == nil/);
  assert.doesNotMatch(acceptance, /DMBrowser\.shared|HandsConnectPresenter\.shared|HandsConnectFlow\.shared|ChatGPTTap\.shared|ChatGPTConnectorPod\.shared|URLSession/);
  assert.doesNotMatch(acceptance, /check\(true,/);
  assert.match(acceptance, /W184BROWSER SUMMARY passed=\\\(check\.passed\) failures=\\\(check\.failed\) skipped=\\\(check\.skipped\)/);
  assert.match(acceptance, /check\.skip\("真的 CEF 網頁上/);
  for (const label of ['A1 page frame', 'A2 (W184 G2d) the sidebar and toolbar take the main window', 'A2b the tab overview keeps', 'A3 floating card', 'A4 「這一頁不給截圖」badge', 'A5 tab overview', 'A6 ［連線］ sheet',
    'B1 (W184 G2d, same as the main window\'s Browser space)', 'B2 in a real window', 'B3 the toolbar comes out at the top 20pt',
    // 施工單「自測要有反例」：敏感分頁開著但在看對話＝可截；切到敏感分頁＝不可截；碼顯示＝不可截；碼遮起來＝可截；兩個持有者最後一個放手才還原。
    'D5-1 counterexample: a sensitive tab is open but the box shows the conversation', 'D5-2 switching to the sensitive tab',
    'D5-3 counterexample: a finished (non-sensitive) tab in front', 'D5-4 counterexample: the tab overview is open', 'D5-5 counterexample: collapsing the box',
    'D5-6 the ［連線］ card by itself no longer blocks capture', 'D5-7 two holders on one window', 'D5-8 counterexample: the code is covered',
    // W183 R10：C1 改成「只剩退路」的那一張（TATWO 這次沒辦法代勾／沒勾到；警語改了一句話說原因）。
    'C1 W183 R10 risk tick fallback only', 'C4 errors: one sentence', 'E1 (lead, R9 gap)', 'E2 the lease is let go',
    'F1 rendered (W184 G2d): the page fills the Browser', 'F2 sidebar and toolbar hidden', 'F3 (W184 G2d: 「左列欄修到頂天」)', 'F3b the toolbar out is the Browser space row',
    'F4 over the page the sidebar and the toolbar get their own clicks', 'F6 (W184 G2d) the pairing card floats on the page',
    'G evidence PNGs']) {
    assert.ok(acceptance.includes(label), label);
  }
  // W183 R10：卡上沒有專案那一層了——第二張是「這台有交易類專案」的確認卡（只能看那一行）。W184 G2d：側欄、頂列、搜尋框的證據跟主視窗的同一元件並排。
  for (const png of ['browser-ack-card.png', 'browser-code-card.png', 'browser-tabs.png', 'connect-sheet.png', 'connect-sheet-trading.png',
    'g2d-toolbar.png', 'g2d-sidebar.png', 'g2d-search.png', 'g2d-duo.png', 'g2d-card-sidebar.png']) {
    assert.ok(acceptance.includes(png), png);
  }
  // 守：畫面證據的碼、帳號、主機都是假的（Primary One、example.com），不寫設備名、使用者名稱、信箱。
  assert.doesNotMatch(acceptance, /@[a-z0-9-]+\.[a-z]{2,}/i);
  // 守：w183browser 的截圖段照新規則改寫，反例與標籤都在。
  assert.match(w183, /W184 D：截圖只擋授權頁與配對碼——卡片本身不再持有視窗/);
  assert.match(w183, /let cardAlone = presenter\.captureProtectedWindow == nil && shield\.holders\(of: window\) == 0 && HandsConnectPresenter\.anySensitive/);
});
