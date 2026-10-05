// W184 G2／G2c／G2d：私訊框 Browser 的側欄、頂列、沒分頁時的搜尋框＋書籤、珍藏、切換空間、新分頁——原始碼契約（每一條旁邊寫「守什麼」）。
// W184 G2d（使用者 09-30 02:4x 實測 .031）：「duo的browser左列欄修到頂天 上方這些功能跟我們設計的 browser space設計不同」
// 「應該是滑鼠指到展開玻璃」「還沒有分頁的搜尋狀態也要一樣」「你就只是把現成的browser space做成duo自適應尺寸而已 不要越搞越遠」。
// 使用者 09-29 17:50：「瀏覽器右側目前用起來不好 改成跟browser space一樣滑鼠指到左列」；17:35：「沒有新增分頁的功能 並且快捷鍵一樣command option t」。
// 使用者 09-29（看了 v2.0.21.029）：「browser的下方改右側好了 並且缺乏目前browser space的書籤、珍藏、switch功能，試圖收納進去。」
// 「switch」＝切換 Browser space 的空間（主視窗側欄那排彩色圓點）。
// 實際行為（真的畫出來量位置、真的滑鼠按、開新分頁不動流程分頁、切換空間、跟主視窗同一元件並排的畫面證據 PNG）在 App 自測
// TATWO2_SELFTEST=w184browser（DM/DMBrowserChromeAcceptance.swift、DMBrowserRailAcceptance.swift、DMBrowserSidebarAcceptance.swift）。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

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

const browser = swift('DM/DMBrowser.swift');
const view = swift('DM/DMBrowserView.swift');
const chrome = swift('DM/DMBrowserChrome.swift');
const phone = swift('DM/DMBrowserPhone.swift');
const rail = swift('DM/DMBrowserRail.swift');
const spaces = swift('DM/DMBrowserSpaces.swift');
const acceptance = swift('DM/DMBrowserRailAcceptance.swift');
const phoneAcceptance = swift('DM/DMBrowserPhoneAcceptance.swift');
const sidebarAcceptance = swift('DM/DMBrowserSidebarAcceptance.swift');
const chromeAcceptance = swift('DM/DMBrowserChromeAcceptance.swift');
const mouseAcceptance = swift('DM/DMBrowserMouseAcceptance.swift');
const desk = swift('DM/GlobalDMDesk.swift');
const deskViews = swift('DM/GlobalDMDeskViews.swift');
const chatPage = swift('Chat/ChatPage.swift');
const hands = swift('New/HandsConnectDMView.swift');
const flowSource = swift('Facade/HandsConnect.swift');
const panels = swift('DM/GlobalDMPanelController.swift');
const contract = read('docs/specs/183-chatgpt-hands/contract.md');
const strip = swift('Browser/BrowserFavoritesStrip.swift');
const rows = swift('Browser/BrowserBookmarkRows.swift');
const dot = swift('Browser/BrowserSpaceMenu.swift');
const controls = swift('Browser/BrowserSidebarControls.swift');

test('sidebar (W184 G2d): the DM sidebar IS the main window\'s BrowserWorkSpaceSidebarList (borrowed; same order, headers and space-name place) — hover-revealed glass, full height, flush left, no handle', () => {
  // 守（主導 09-30 轉使用者：「你就只是把現成的browser space做成duo自適應尺寸而已 不要越搞越遠」「以主視窗真正的 Browser space 側欄為準（讀它的程式、
  // 用同一份元件，別另外抄一份）」；GPT-6 審查 G2d #5）：私訊框側欄裡放的就是主視窗那一份 BrowserWorkSpaceSidebarList（借用模式 BrowserSidebarGuest），
  // 私訊框自己不排任何一段（沒有自己的珍藏、Pinned、資料夾、圓點排法）。
  const side = between(chrome, 'struct DMBrowserSidebar: View {', '// MARK: 珍藏、書籤');
  assert.match(side, /BrowserWorkSpaceSidebarList\(store: store, guest: guest\)/);
  assert.doesNotMatch(code(chrome), /ForEach\(store\.folders\)|ForEach\(store\.pinnedTabs\)|ForEach\(store\.spaces\)|WorkspaceSpaceControls|BrowserSpaceDot\(|BrowserFavoritesStrip\(|BrowserBookmarkRow\(|BrowserBookmarkFolderRow\(|Text\("Pinned"\)|folderSection|pinnedSection/);
  // 守：段落順序只寫在主視窗那一份裡（兩邊同一個組合）：珍藏那一排 → 📌 Pinned → 書籤資料夾 → 分隔線 → 新分頁 → 分頁 → 下載＋空間圓點＋＋（自測 S1）。
  const design = swift('Browser/BrowserWorkSpaceDesignView.swift');
  const list = between(design, 'struct BrowserWorkSpaceSidebarList: View {', 'private var spaceControls: some View {');
  const order = ['BrowserFavoritesStrip(store: store, external: guest?.favorites)', 'pinnedSection', 'folderSection', 'Divider()', 'newTabButton',
    'if let guest { guest.tabs } else { ForEach(store.activeTabs) { tab in tabRow(tab) } }', 'if !store.threadScoped { spaceControls }'].map((part) => list.indexOf(part));
  assert.ok(order.every((at) => at >= 0) && order.every((at, i) => i === 0 || at > order[i - 1]), `list order ${order}`);
  assert.match(design, /Text\("📌"\)\.frame\(width: BrowserSidebarMetrics\.rowIconWidth\)\s*Text\("Pinned"\)\.fontWeight\(\.bold\)/);
  // 守（能力參數；W184 G2 施工單：書籤「只讀＋開啟；改名、刪除、搬移不做（在主視窗做）」）：借用的那一邊沒有右鍵選單、不拖不放、圓點不給編輯、
  // ＋擺著按不下去、不寫主視窗的 sidebarInteractionActive（兩邊同一份 store）；Pinned 那一列、分頁列、新分頁是借用那一邊的；
  // session 空間照一般空間排（私訊框的分頁跟主視窗的分頁清單分開，看不到也開不了聊天旁的分頁）。主視窗那一支（guest＝nil）照舊（自測 S9、M1–M4）。
  assert.match(list, /\.browserSidebarWhen\(guest == nil\) \{ list in\s*list\.contextMenu \{/);
  assert.match(list, /\}\.browserSidebarWhen\(guest == nil\) \{ \$0\.modifier\(BrowserSidebarDrop\(store: store, target: \.tabs\)\) \}/);
  assert.match(list, /if store\.selectedSpace\.isSessionSpace && guest == nil \{\s*sessionSidebar/);
  assert.match(list, /if let guest \{ guest\.interaction\(active\) \} else \{ store\.sidebarInteractionActive = active \}/);
  assert.match(list, /\.onDisappear \{ if let guest \{ guest\.interaction\(false\) \} else \{ store\.sidebarInteractionActive = false \} \}/);
  const sections = between(design, '// MARK: - Sidebar sections: pinned / folders / divider / new tab / tabs', 'private func tabRow(');
  assert.match(sections, /if let guest \{ guest\.pinnedRow\(tab\)\.padding\(\.leading, BrowserSidebarMetrics\.workspaceFaviconSize\) \}\s*else \{ tabRow\(tab\)\.padding\(\.leading, BrowserSidebarMetrics\.workspaceFaviconSize\) \}/);
  assert.match(sections, /\.browserSidebarWhen\(guest == nil\) \{ \$0\.modifier\(BrowserSidebarDrop\(store: store, target: \.pinned\)\) \}/);
  assert.match(sections, /\.browserSidebarWhen\(guest == nil\) \{ row in[^\n]*\n\s*row\.contextMenu \{[\s\S]*?\.dropDestination\(for: String\.self\)/);
  assert.match(sections, /BrowserBookmarkFolderRow\(store: store, folder: folder, external: guest\?\.folder\(folder\)\)/);
  assert.match(sections, /BrowserBookmarkRow\(store: store, bookmark: bookmark, folderID: folder\.id, external: guest\.bookmarks\)/);
  assert.match(sections, /Button \{ if let guest \{ guest\.newTab\(\) \} else \{ store\.addTab\(\); store\.searchFocusRequest \+= 1 \} \}/);
  const controlsSrc = between(design, 'private var spaceControls: some View {', 'private var downloadsPopover: some View {');
  assert.match(controlsSrc, /BrowserSpaceDot\(store: store, space: space, fallbackFill: folderFill, idleFill: palette\.surfaceBorder,\s*editable: guest == nil, choose: guest\?\.selectSpace\)/);
  assert.match(controlsSrc, /\.browserSidebarWhen\(guest != nil\) \{ plus in\s*plus\.disabled\(true\)/);
  assert.match(controlsSrc, /Button \{ downloadsPresented\.toggle\(\) \} label: \{/);   // 下載鈕：兩邊同一顆（私訊框的網頁下載也進同一份下載清單）
  const guestType = swift('Browser/BrowserSidebarGuest.swift');
  assert.match(guestType, /struct BrowserSidebarGuest \{/);
  assert.match(guestType, /func browserSidebarWhen<Changed: View>\(_ condition: Bool, @ViewBuilder _ change: \(Self\) -> Changed\) -> some View \{\s*if condition \{ change\(self\) \} else \{ self \}/);
  // 守：私訊框給的借用——開在私訊框、空間圓點走 DMBrowserSpaces.select、＋ 的說明、下載清單開著＝側欄留著、識別碼照舊。
  assert.match(chrome, /let select: @MainActor \(BrowserWorkSpaceStore\.Space\) -> Void = \{ space in\s*guard let id = space\.registryID else \{ return \}\s*_ = spaces\.select\(registryID: id\)/);
  assert.match(chrome, /selectSpace: select,/);
  assert.match(chrome, /newTab: newTab, newTabIdentifier: "tatwo\.dm\.browser\.newTab"/);
  assert.match(chrome, /spacesIdentifier: "tatwo\.dm\.browser\.spaces"/);
  assert.match(view, /interaction: \{ reveal\.holdSidebar\(\$0\) \}/);
  // 守（GPT-6 審查 G2d #2，自測 S8）：書籤、珍藏、Pinned 開的分頁只在那一列還在側欄上時不列在分頁清單（同主視窗）；來源不在了＝回到清單，不關、不重新載入。
  assert.match(chrome, /case \.bookmark\(let id\)\?: return bookmarks\.contains\(id\)\s*case \.favorite\(let id\)\?: return favorites\.contains\(id\)\s*case \.pinned\(let id\)\?: return pinned\.contains\(id\)\s*case \.typed\?, nil: return false/);
  assert.match(chrome, /let bookmarks = Set\(store\.folders\.flatMap\(\\\.bookmarks\)\.map\(\\\.id\)\)\s*let favorites = Set\(store\.registry\.favorites\.map\(\\\.id\)\)\s*let pinned = Set\(store\.pinnedTabs\.compactMap\(\\\.registryID\)\)/);
  // 平常＝主視窗那一套：玻璃殼 WorkspaceSidebarShell（內距 18）；緊湊（小框＋最高的卡把側欄壓到 160 以下）＝同一片玻璃、內距 8、最下面那一排
  // 跟著列表一起捲、排在列表最後（同一份列表、同一個順序；spec 184 G2d「小框側欄緊湊擺法」；自測 S4–S6、S2d）。
  assert.match(side, /compact: height < DMBrowserPhone\.sidebarCompactHeight/);
  assert.match(chrome, /interaction: interaction, compact: compact, mark: mark\)/);
  assert.match(list, /if guest\?\.compact == true && !store\.threadScoped \{ spaceRow\.padding\(\.top, BrowserSidebarMetrics\.rowHorizontalPadding\) \}/);
  assert.match(design, /@ViewBuilder private var spaceControls: some View \{\s*if guest\?\.compact != true \{ spaceRow \}\s*\}/);
  assert.match(side, /if compact \{[\s\S]*?content\(inset: DMBrowserPhone\.sidebarCompactPadding\)\s*\.padding\(DMBrowserPhone\.sidebarCompactPadding\)[\s\S]*?\.liquidGlassPanelSurface\(cornerRadius: 0\)[\s\S]*?\} else \{[^\n]*\n(?:\s*\/\/[^\n]*\n)*\s*WorkspaceSidebarShell\(width: width\) \{ content\(inset: DMBrowserPhone\.sidebarShellInset\) \}/);
  assert.match(phone, /static let sidebarCompactHeight: CGFloat = 160\s*static let sidebarCompactPadding: CGFloat = 8/);
  assert.match(phone, /static let sidebarShellInset: CGFloat = 18/);
  // 守（GPT-6 審查 G2d #3，自測 S2b、S2d）：列表從頂列（48）下緣再往下 2 開始；避開頂列的那一段固定在捲動區外面（捲過之後列也不會跑到頂列底下）。
  const content = between(chrome, 'private func content(inset: CGFloat) -> some View {', '/// 空間名稱從側欄左緣多遠開始');
  assert.match(content, /VStack\(spacing: 0\) \{\s*Color\.clear\s*\.frame\(height: max\(0, DMBrowserPhone\.sidebarListTop\(topExtension: topInset\) - inset\)\)[\s\S]*?BrowserWorkSpaceSidebarList\(store: store, guest: guest\)\s*\}/);
  assert.doesNotMatch(code(content), /ScrollView/);   // 捲動區只有列表自己那一個
  assert.match(phone, /static let sidebarToolbarClearance: CGFloat = 2/);
  assert.match(phone, /static func sidebarListTop\(topExtension: CGFloat\) -> CGFloat \{ topExtension \+ toolbarHeight \+ sidebarToolbarClearance \}/);
  // 守（主導 09-30：「空間名稱擺的位置要跟主視窗一樣」，自測 S1b、S2c）：主視窗＝頂列、紅綠燈右邊（紅綠燈最右邊再過 10＋8＝appControlLeadingX）、
  // 紅綠燈同一條中心線；私訊框＝頂列那一排、頁面圓鈕右邊（同樣的 10＋8）、圓鈕同一條中心線；內橫右欄的左上沒有圓鈕＝對齊側欄的列。
  // 只顯示（私訊框頂列的空白處是整個框的拖曳區，W184 G1；切空間用最下面那一排圓點，同主視窗那一排）。
  assert.match(phone, /static func sidebarTitleLeading\(form: GlobalDMForm\) -> CGFloat\? \{\s*form\.isDuo \? nil : DMPhone\.sideMargin\(for: form\) \+ DMPhone\.touch \+ WindowChromeMetrics\.headerHorizontalInset \+ WindowChromeMetrics\.controlSpacing/);
  assert.match(phone, /static var sidebarTitleCenter: CGFloat \{ DMPhone\.headerTop \+ DMPhone\.touch \/ 2 - sidebarTitleLift \}/);
  assert.match(swift('Chat/ChatPage+Sidebar.swift'), /browserSpaceSwitcher\.padding\(\.leading, WindowChromeMetrics\.appControlLeadingX\)/);
  assert.match(swift('Shell/WindowChrome.swift'), /static let appControlLeadingX = trafficLightSafeWidth \+ controlSpacing/);
  const title = between(chrome, 'private var spaceTitle: some View {', '/// 借用主視窗那一份側欄');
  assert.match(title, /Text\(store\.selectedSpace\.name\)\s*\.font\(\.system\(size: WorkspaceSidebarMetrics\.spaceSwitcherFontSize, weight: \.bold\)\)\.lineLimit\(1\)/);
  assert.match(title, /height: WorkspaceSidebarMetrics\.spaceSwitcherHeight, alignment: \.leading\)/);
  assert.doesNotMatch(code(title), /\bMenu\b|\bButton\b|renameSpace|addSpace|selectSpace/);   // 只顯示（最寬＝主視窗那個選單的寬 spaceSwitcherMenuWidth）
  assert.match(view, /titleLeading: DMBrowserPhone\.sidebarTitleLeading\(form: form\)/);
  assert.match(view, /@Environment\(\\\.globalDMForm\) private var form/);
  // 守：不再有私訊框自己那一套側欄（上一頁列、網址 pill 卡、四欄珍藏格、44 的書籤列、五格一列的空間圓點、捲動區漸出、把手、G2d 第一版照抄排的列）。
  assert.doesNotMatch(code(view) + code(rail) + code(phone) + code(chrome),
    /DMBrowserSidebarPart|DMBrowserSidebarFavorites|DMBrowserSidebarBookmarks|DMBrowserSidebarSpaces|DMBrowserSidebarScroll|DMBrowserEdgeFade|dmBrowserEdgeFade|DMBrowserAddressField|DMBrowserSpaceDot\b|sidebarCompact\(height:|DMBrowserPinnedHeightKey|sidebarTitleHeight|@ViewBuilder private var rows/);
  assert.doesNotMatch(code(view), /DMBrowserHandle\(/);   // 左緣不畫把手（使用者說過多餘）
  // 守（「左列欄修到頂天」）：側欄貼左緣、從框頂開始（Browser 區上面私訊框頂列那一段也是側欄——dmBrowserTopExtension，排版上移，頂列畫在它上面一層、
  // 頁面圓鈕照舊按得到）；有連線卡片＝停在卡片上面 8，沒有＝到底。滑鼠指到才展開（同主視窗的浮出側欄：從左 8 滑進來＋淡入）；
  // 固定著（頂列最左那顆）＝一直在，頁面讓出那一欄。展開之後指標在伸上去那一段也算在側欄上（自測 S2c、B1）。
  const layer = between(view, 'private func sidebarLayer(size: CGSize, width: CGFloat, cardTop: CGFloat?) -> some View {', '/// 頂列：');
  assert.match(layer, /let height = cardTop\.map \{ max\(0, \$0 - DMBrowserPhone\.sidebarGap\) \} \?\? size\.height/);
  assert.match(layer, /\.frame\(width: width, height: height \+ topExtension, alignment: \.top\)\s*\.clipped\(\)/);
  assert.match(layer, /\.padding\(\.top, -topExtension\)[^\n]*\s*\.offset\(x: shown \? 0 : -DMBrowserPhone\.slide\)/);
  assert.match(view, /@Environment\(\\\.dmBrowserTopExtension\) private var topExtension/);
  assert.match(view, /\.onAppear \{ reveal\.sidebarWidth = width; reveal\.sidebarAbove = topExtension \}/);
  assert.match(phone, /let area = revealed && above > 0\s*\? CGRect\(x: bounds\.minX, y: bounds\.minY - above, width: bounds\.width, height: bounds\.height \+ above\) : bounds/);
  // 私訊框（GlobalDMPhoneBox）：欄畫在頂列底下一層（W184 G3c 的 zIndex −1），欄拿到頂列高度——Browser 側欄往上伸到框頂、頁面圓鈕照舊在最上面。
  // 自測與畫面證據用的一欄版本（PhoneColumns）同一個擺法（整支手機拿到形態：側欄的空間名稱照它擺）。
  const phoneBox = read('App/Sources/Tatwo2/DM/GlobalDMPhoneBox.swift');
  assert.match(phoneBox, /GlobalDMTopBar\(store: store, form: form\)\s*columns\(look, width: width\)[\s\S]{0,400}?\.zIndex\(-1\)\s*\.environment\(\\\.globalDMListBleed, DMPhone\.headerHeight\)/);
  assert.match(phoneBox, /\.accessibilityIdentifier\(form\.isDuo \? "tatwo\.dm\.duo" : "tatwo\.dm\.columns"\)(?:\s*\/\/[^\n]*)*\s*\.environment\(\\\.dmBrowserTopExtension, DMPhone\.headerHeight\)/);
  assert.match(phoneBox, /\.environment\(\\\.globalDMForm, form\)/);
  assert.match(phoneAcceptance, /struct PhoneColumns<Content: View>: View \{[\s\S]*?GlobalDMTopBar\(store: store, form: form\)\s*content\(\)\s*\.zIndex\(-1\)\s*\.environment\(\\\.globalDMListBleed, DMPhone\.headerHeight\)\s*\.environment\(\\\.dmBrowserTopExtension, DMPhone\.headerHeight\)\s*\}\s*\.environment\(\\\.globalDMForm, form\)/);
  assert.match(view, /private var sidebarShown: Bool \{ forced\.contains\(\.sidebar\) \|\| browser\.sidebarPinned \|\| reveal\.isRevealed \|\| voiceOver \}/);
  assert.match(view, /let pushed: CGFloat = browser\.sidebarPinned && !showingTabList \? width : 0/);
  assert.match(phone, /static func sidebarWidth\(for paneWidth: CGFloat\) -> CGFloat \{\s*min\(WorkspaceSidebarMetrics\.width, max\(180, paneWidth - 120\)\)/);
  // 守：滑鼠位置判斷（CEF 會吃 hover，同主視窗 BrowserChromeReveal）：左緣 18 叫出、右緣外 30 留著、離開 0.40 秒才收（同主視窗 ChatPage 的
  // 18／30／0.40）；網頁左邊的內容叫不出來（自測 B1、B2、R7、V1）。側欄上開著下載清單＝留著（同主視窗 sidebarInteractionActive；自測 B4、S9）。
  const zone = between(phone, 'nonisolated static func sidebarZone(', 'nonisolated static func toolbarZone(');
  assert.match(zone, /if fromLeading >= 0 && fromLeading <= DMBrowserPhone\.revealZone \{ return true \}\s*guard revealed else \{ return false \}\s*return fromLeading <= width \+ DMBrowserPhone\.exitZone/);
  assert.match(phone, /static let revealZone: CGFloat = 18/);
  assert.match(phone, /static let exitZone: CGFloat = 30/);
  assert.match(phone, /static let sidebarCloseDelay: Double = 0\.40/);
  assert.match(phone, /closeTask = Task \{ @MainActor \[weak self\] in\s*try\? await Task\.sleep\(nanoseconds: delay\)\s*guard !Task\.isCancelled, let self else \{ return \}/);
  assert.match(phone, /let sidebar = !sidebarPinned && \(holdsSidebar \|\| Self\.sidebarZone\(point, bounds: anchor\.bounds, revealed: isRevealed, width: sidebarWidth,/);
});

test('toolbar (W184 G2d): the Browser space row — sidebar button, back, forward, reload, address | ⋯, translate, extensions, notes; hover-revealed glass across the Browser', () => {
  const bar = between(chrome, 'struct DMBrowserToolbar: View {', '/// 主視窗 auxiliaryBrowserControls 的那兩顆');
  const order = ['BrowserSidebarControls(collapsed: !browser.sidebarPinned, toggle: browser.toggleSidebar)', 'EmbeddedBrowserToolbar(', 'BrowserActionsButton {',
    'BrowserTranslateButton(', 'toolButton("puzzlepiece.extension"', 'toolButton("note.text"'].map((part) => bar.indexOf(part));
  assert.ok(order.every((at) => at >= 0) && order.every((at, i) => i === 0 || at > order[i - 1]), `toolbar order ${order}`);
  // 守：同主視窗 workspaceToolbar 的外觀（BrowserOmniboxMetrics：字級 14、48 高、左右 8、間距 4）；窄的時候翻譯、擴充、註解收進 ⋯。
  assert.match(bar, /\.font\(\.system\(size: BrowserOmniboxMetrics\.iconSize\)\)\s*\.foregroundStyle\(LiquidGlassTokens\.browserOmniboxInk\)\s*\.padding\(\.horizontal, BrowserOmniboxMetrics\.horizontalInset\)\s*\.frame\(height: BrowserOmniboxMetrics\.toolbarHeight\)/);
  assert.match(bar, /static func showsTools\(width: CGFloat\) -> Bool \{ width >= DMBrowserPhone\.toolbarToolsMinWidth \}/);
  assert.match(bar, /BrowserActionsButton \{ menu\(foldedTools: !tools\) \}/);
  // 守：私訊框的網頁都是敏感頁（不注入東西）——翻譯、擴充照主視窗的位置擺著但按不下去；註解綁主視窗分頁清單的分頁，也按不下去；說明寫原因。
  assert.match(bar, /BrowserTranslateButton\(translator: translator, host: nil, size: BrowserOmniboxMetrics\.collapsedHeight,\s*unavailableReason: Self\.translateOff\)/);
  assert.match(chrome, /\.buttonStyle\(\.plain\)\.disabled\(true\)\s*\.help\(reason\)/);
  assert.doesNotMatch(code(chrome), /BrowserExtensionsMenu|showAnnotations|BrowserPageTranslator\(\)\.toggleAuto|translator\.toggleAuto\(\)/);
  // 守：網址那一格＝主視窗那條導覽列（EmbeddedBrowserToolbar）接私訊框的分頁：只照實際載入的頁（W183 R8b）；空白分頁、沒分頁不顯示網址；
  // 重新載入只給一般分頁（流程的頁不動）；上一頁／下一頁叫私訊框的分頁。
  assert.match(bar, /reloadAllowed: tab\.map\(DMBrowser\.reloadable\) \?\? false\)/);
  assert.match(browser, /nonisolated static func reloadable\(_ tab: DMBrowserTabInfo\) -> Bool \{\s*tab\.purpose == \.browse && !tab\.isBlank && !tab\.pageClosed/);
  assert.match(chrome, /case \.goBack: browser\.goBack\(\)\s*case \.goForward: browser\.goForward\(\)\s*case \.reload: browser\.reloadActive\(\)/);
  // 守（GPT-6 審查 G2d #1，自測 T3、T3b）：頁面還在＝原生重新載入（同一個瀏覽器、上一頁／下一頁的紀錄都在；載入失敗的頁也在它自己上面重試）；
  // 只有頁面沒建起來（建立失敗）才重建（reload(_:) 那一條失敗重試：關掉重開）；還在建立＝不動。CEF 那一頁＝最上面那一層的原生 reload。
  const reloadActive = between(browser, 'func reloadActive() {', 'nonisolated static func reloadable(');
  assert.match(reloadActive, /guard let tab = activeTab, Self\.reloadable\(tab\) else \{ return \}\s*if let page = pages\[tab\.id\] as\? DMBrowserWebPage \{\s*page\.page\.reload\(\)\s*return\s*\}\s*guard pageTasks\[tab\.id\] == nil else \{ return \}\s*reload\(tab\.id\)/);
  assert.match(swift('DM/GlobalDMWebSheet.swift'), /func goForward\(\)\s*\/\/\/[^\n]*\n\s*func reload\(\)/);
  assert.match(swift('Browser/BrowserSensitivePage.swift'), /func reload\(\) \{\s*pages\.last\?\.reload\(\)\s*\}/);
  assert.match(swift('Browser/BrowserSensitivePage.swift'), /func reload\(\) \{ stack\.reload\(\) \}/);
  assert.match(chrome, /urlString: tab\.sourceKnown \? tab\.pageURL\?\.absoluteString : nil/);
  assert.match(chrome, /static func showsAddress\(_ tab: DMBrowserTabInfo\?\) -> Bool \{\s*guard let tab else \{ return false \}\s*return !tab\.isBlank/);
  assert.match(chrome, /guard tab\.sourceKnown else \{ return tab\.sourceText \}\s*if tab\.hostMismatch, let expected = tab\.expectedHost \{ return "\\\(tab\.displayHost\)（不是 \\\(expected\)）" \}/);
  // 守：主視窗那幾顆元件只加了「給外面用」的參數，主視窗的用法照舊（init(store:) 綁 store.toggleSidebar；重新載入預設 true）。
  assert.match(controls, /init\(store: BrowserWorkSpaceStore\) \{\s*collapsed = store\.focusMode\s*toggle = store\.toggleSidebar/);
  assert.match(swift('Browser/EmbeddedBrowserToolbar.swift'), /var reloadAllowed = true/);
  // 守（「應該是滑鼠指到展開玻璃」）：平常不在，滑鼠到 Browser 區頂端 20 以內才浮出（同主視窗 W112 頂列：triggerBand、chromeHeight＋10、0.12 秒淡入）；
  // 網址在打字＝留著；橫跨整個 Browser 區、畫在側欄上面（側欄固定著也不擠窄頂列）；玻璃底同主視窗 BrowserFloatingToolbarBackdrop（自測 B3、T5、R12）。
  const tzone = between(phone, 'nonisolated static func toolbarZone(', '/// 掛上（Browser 區進了視窗）');
  assert.match(tzone, /if revealed \{ return fromTop <= DMBrowserPhone\.toolbarHeight \+ DMBrowserPhone\.toolbarStay \}\s*return fromTop <= DMBrowserPhone\.toolbarTrigger/);
  assert.match(phone, /static let toolbarTrigger: CGFloat = 20/);
  assert.match(view, /if toolbar \{\s*toolbarLayer\(width: size\.width\)\s*\.transition\(\.opacity\)/);
  assert.match(view, /\.background \{ BrowserFloatingToolbarBackdrop\(\) \}/);
  assert.match(view, /\.onChange\(of: panel, initial: true\) \{ _, open in\s*reveal\.hold\(open == \.address\)\s*browser\.keepsKeyboard = open != nil/);
  // 守：私訊框左上的頁面圓鈕照舊在私訊框的頂列（Browser 的頂列在它下面、Browser 區的頂端浮出，不擠）。
  assert.match(swift('DM/GlobalDMPhoneBox.swift'), /GlobalDMIconStrip\(store: store, besideBrowser: form\.isDuo\)/);
});

test('no-tab search (W184 G2d): the main window\'s centered search box (BrowserStartSearch) — no tabs or a blank tab; typing opens a general tab', () => {
  const start = swift('Browser/BrowserStartSearch.swift');
  // 守：主視窗與私訊框同一份（從 BrowserWorkSpaceDesignView 抽出來，主視窗的 page 只接自己的動作）。
  assert.match(start, /struct BrowserStartSearch<Field: Hashable, SearchMenu: View>: View \{/);
  assert.match(swift('Browser/BrowserWorkSpaceDesignView.swift'), /private var page: some View \{\s*BrowserStartSearch\(query: \$query, focus: \$focusedField, field: \.search,/);
  const search = between(view, 'private var startSearch: some View {', '/// 同主視窗 BrowserWorkSpaceStore.suggestions');
  assert.match(search, /BrowserStartSearch\(query: \$draft, focus: \$searchFocus, field: \.search, canAddTab: true,/);
  assert.match(search, /identifier: "tatwo\.dm\.browser\.search"/);
  // 守（GPT-6 審查 G2d #5）：搜尋框右鍵＝主視窗那一個搜尋引擎選單（同一個 BrowserSearchEngineMenu、存進同一個 Browser 設定；主視窗也用它）。
  assert.match(search, /onSubmit: submitSearch, onAddTab: \{ _ = browser\.newTab\(\) \}, onSuggestion: pick\) \{\s*BrowserSearchEngineMenu\(engine: engine\) \{ chooseEngine\(\$0\) \}\s*\}/);
  assert.match(view, /engineError = BrowserSearchEngineMenu\.save\(next\)\s*if engineError == nil \{ engine = next \}/);
  assert.match(swift('Browser/BrowserWorkSpaceDesignView.swift'), /private var searchEngineMenu: some View \{\s*BrowserSearchEngineMenu\(engine: settings\.searchEngine\) \{ engine in/);
  assert.match(start, /struct BrowserSearchEngineMenu: View \{[\s\S]*?Picker\("搜尋引擎", selection: Binding\(get: \{ engine \}, set: choose\)\)[\s\S]*?try BrowserSettings\(searchEngine: engine\)\.save\(\)/);
  assert.doesNotMatch(code(view), /\{ EmptyView\(\) \}/);
  // 守：打的字只開 https（同一條 DMBrowserBrowseInput）；開在開始打字的那一個空白分頁（沒有分頁＝新分頁），流程分頁的網址不改。
  assert.match(view, /guard let url = DMBrowserBrowseInput\.resolve\(text, engine: engine\) else \{\s*refusal = \.notSecure\s*return\s*\}/);
  assert.doesNotMatch(code(view), /emptyState|blankView|還沒有分頁/);
});

test('the sidebar never covers the connect card buttons; it gets its own clicks over the CEF page only while it is out', () => {
  // 守（W184 G2c／G2d）：卡片左右 12、離底 30，不動不變窄；側欄停在卡片上面 8（側欄下緣＝卡片頂端－8），
  // 配對卡右上的取消、「輪到你」的取消｜繼續都不會被側欄蓋住（自測 S3、C2、F6）。
  assert.match(view, /\.padding\(\.horizontal, DMBrowserPhone\.cardInset\)\s*\.padding\(\.bottom, DMBrowserPhone\.cardBottom\)/);
  assert.match(view, /let height = cardTop\.map \{ max\(0, \$0 - DMBrowserPhone\.sidebarGap\) \} \?\? size\.height/);
  assert.match(view, /\.onPreferenceChange\(DMBrowserCardTopKey\.self\) \{ top in cardTop = top \}/);
  assert.doesNotMatch(code(view) + code(phone), /cardTrailing/);
  // 守：側欄滑出、固定著時登記 chrome 命中區（網頁讓位），收著時不接點擊（網頁照常點得到）；頂列一出來就登記（主視窗那條導覽列自己也登記）。
  const layer = between(view, 'private func sidebarLayer(size: CGSize, width: CGFloat, cardTop: CGFloat?) -> some View {', '/// 頂列：');
  assert.match(layer, /\.background\(BrowserChromeHitLayer\(isActive: shown\)\)/);
  assert.match(layer, /\.allowsHitTesting\(shown\)/);
  assert.match(between(chrome, 'struct DMBrowserToolbar: View {', '/// 主視窗 auxiliaryBrowserControls 的那兩顆'), /\.background\(BrowserChromeHitLayer\(\)\)/);
  assert.match(between(hands, 'struct HandsConnectFloatCardView: View {', '/// 卡片內容'), /\.liquidGlassPanelSurface\(cornerRadius: DMBrowserPhone\.cardRadius\)\s*\.background\(BrowserChromeHitLayer\(\)\)/);
  // 守（W184 G2d）：蓋住整個頁面框的原生卡片（完成、確認中、打不開）也登記命中區——它們的鈕按得到（原生容器讓位）。
  assert.equal((between(view, 'private func closedView(', '// MARK: 連線卡片、側欄、頂列').match(/\.background\(BrowserChromeHitLayer\(\)\)/g) ?? []).length, 2);
  // 守：自測量卡片的按鈕（右上取消、輪到你的取消｜繼續）畫在哪。
  for (const key of ['card.dismiss', 'card.turnCancel', 'card.continue']) {
    assert.ok(hands.includes(`DMFrameProbe(key: "${key}")`), key);
  }
});

test('bookmarks / favorites / typing open a NEW general tab — never navigate the Pod, pairing or authorisation tabs', () => {
  const open = between(browser, 'func openBrowse(url: URL, title: String?, origin: DMBrowserBrowseOrigin = .typed, typedInto: UUID? = nil) -> DMBrowserBrowseResult {', 'func browseTab(');
  // 守：新分頁（用途 browse、網頁種類）＋自己的頁面；同一個書籤、同網址的一般分頁已經開著＝只切過去（只找一般分頁）。
  assert.match(open, /var tab = DMBrowserTabInfo\(id: UUID\(\), purpose: \.browse, kind: \.web, startURL: start, expectedHost: nil\)/);
  assert.match(open, /tabs\.append\(tab\)[\s\S]*startWebPage\(tab\.id, url: start\)/);
  assert.match(open, /if let existing = browseTab\(origin, url: start\) \{[\s\S]*?select\(existing\.id\)\s*return \.switched\(existing\.id\)/);
  // 守（W184 G2 修正，查證 #6）：同一個書籤、珍藏的一般分頁上次沒開成（載入失敗、頁面沒建起來）＝再按就重新載入那一頁（不是只切過去）；
  // 重新載入只碰一般分頁（reload 先認 purpose == .browse），照它自己的起點重開。
  assert.match(open, /if existing\.problem != nil \|\| \(pages\[existing\.id\] == nil && pageTasks\[existing\.id\] == nil\) \{\s*reload\(existing\.id\)\s*select\(existing\.id\)\s*return \.reloaded\(existing\.id\)/);
  const reload = between(browser, 'private func reload(_ id: UUID) {', '/// 重試開哪個網址');
  // 第三輪（查證 #7）：重試開的是這個分頁自己失敗的那個網址（最後停在的網址；還沒停過＝它的起點），不是別的網址（自測 G13b）。
  assert.match(reload, /guard let tab = tabs\.first\(where: \{ \$0\.id == id \}\), tab\.purpose == \.browse,\s*let target = Self\.retryAddress\(tab\) else \{ return \}/);
  assert.match(reload, /page\.detach\(\)\s*page\.close\(\)[\s\S]*startWebPage\(id, url: target\)/);
  assert.match(browser, /nonisolated static func retryAddress\(_ tab: DMBrowserTabInfo\) -> URL\? \{\s*tab\.pageURL\.flatMap\(browseStart\) \?\? tab\.startURL/);
  assert.match(view, /case \.opened, \.switched, \.reloaded:\s*closePanel\(\)/);
  const find = between(browser, 'func browseTab(_ origin: DMBrowserBrowseOrigin, url: URL) -> DMBrowserTabInfo? {', 'nonisolated static func browseStart(');
  assert.match(find, /let browse = tabs\.filter \{ \$0\.purpose == \.browse \}/);
  assert.match(find, /case \.typed:\s*return nil/);
  // 守：從來不導航現有頁面（沒有 load／navigate 之類的呼叫；頁面只由 startWebPage 新開，不往 pages 裡塞別的頁面）。
  assert.doesNotMatch(code(open) + code(find) + code(reload), /loadURL|\.load\(|navigate|pages\[[^\]]*\]\s*=[^=]/);
  // 守（W184 G2 第三輪，查證 #5；同主視窗 openFavorite）：珍藏先找它自己開的分頁（就算載入時轉址、加 query、SPA 換路由仍是它的，自測 G3c）；
  // 沒有＝只找沒綁定的一般分頁（打網址開的）「現在」停在同一個網址的（GPT-6 6：已經導到別處＝不算，自測 G3b）；書籤開的分頁不拿來比。
  assert.match(find, /if let bound = browse\.first\(where: \{ \$0\.origin == origin \}\) \{ return bound \}/);
  assert.match(find, /guard tab\.origin == \.typed, let current = Self\.currentAddress\(tab\) else \{ return false \}\s*return BrowserTabRegistry\.favoriteURLKey\(current\) == key/);
  assert.doesNotMatch(code(find), /\[tab\.pageURL, tab\.startURL\]/);
  assert.match(browser, /nonisolated static func currentAddress\(_ tab: DMBrowserTabInfo\) -> URL\? \{\s*if let committed = tab\.pageURL \{ return committed \}\s*return tab\.loading && tab\.problem == nil \? tab\.startURL : nil/);
  // 守：只收 https、有網域、沒有帳密；一般網頁不走流程的入口（validatedStart 對 browse 回 nil）。
  assert.match(browser, /nonisolated static func browseStart\(_ url: URL\) -> URL\? \{\s*guard url\.scheme\?\.lowercased\(\) == "https", let host = url\.host, !host\.isEmpty, url\.user == nil, url\.password == nil else \{ return nil \}/);
  assert.match(browser, /case \.browse: return nil/);
  // 守：流程以起點認的只找流程分頁（一般分頁不會被流程接手）。
  assert.match(browser, /func tab\(start url: URL\) -> DMBrowserTabInfo\? \{ tabs\.first \{ \$0\.kind == \.web && \$0\.purpose\.isFlow && \$0\.startURL == url \} \}/);
  // 守：書籤、珍藏從畫面與自測走同一條（DMBrowserShelf）；http 改 https、其他協定不開。
  assert.match(rail, /static func open\(bookmark: BrowserWorkSpaceStore\.Bookmark, in browser: DMBrowser\) -> DMBrowserBrowseResult \{\s*guard let url = URL\(string: bookmark\.url\)\.flatMap\(DMBrowserBrowseInput\.secured\) else \{ return \.refused\(\.notSecure\) \}\s*return browser\.openBrowse\(url: url, title: bookmark\.title, origin: \.bookmark\(bookmark\.id\)\)/);
  assert.match(rail, /return browser\.openBrowse\(url: url, title: favorite\.title, origin: \.favorite\(favorite\.id\)\)/);
  // W184 G2d：側欄上的珍藏那一排、書籤列是主視窗 Browser space 的元件（BrowserFavoritesStrip、BrowserBookmarkRow），私訊框給它們自己的開法。
  assert.match(chrome, /BrowserFavoritesExternal\(open: \{ favorite in finish\(DMBrowserShelf\.open\(favorite: favorite, in: browser\)\) \}/);
  assert.match(chrome, /BrowserBookmarkExternal\(open: \{ bookmark in finish\(DMBrowserShelf\.open\(bookmark: bookmark, in: browser\)\) \}/);
  const secured = between(spaces, 'static func secured(_ url: URL) -> URL? {', 'static func title(');
  assert.match(secured, /scheme == "https" \|\| scheme == "http", let host = parts\.host, !host\.isEmpty,\s*parts\.user == nil, parts\.password == nil else \{ return nil \}/);
  assert.match(secured, /return parts\.url\.flatMap\(DMBrowser\.browseStart\)/);
  // 守：打的字＝同主視窗網址列的解析（BrowserOmniboxResolver、Browser 設定的搜尋引擎），再只留 https。
  assert.match(spaces, /guard !trimmed\.isEmpty, let url = BrowserOmniboxResolver\.resolve\(trimmed, engine: engine\) else \{ return nil \}\s*return secured\(url\)/);
  assert.match(view, /let engine = BrowserGeneralSettings\.load\(\)\.searchEngine/);
});

test('general tabs are not authorisation pages; every flow protection is unchanged', () => {
  // 守：敏感只看流程開的分頁（Computer Use 閘門、截圖保護、「這一頁不給截圖」小標都照 isSensitive）。
  assert.match(browser, /var isSensitive: Bool \{ !pageClosed && purpose\.isFlow \}/);
  assert.match(browser, /var isFlow: Bool \{ self != \.browse \}/);
  assert.match(browser, /var isConnect: Bool \{ self == \.chatgptDeveloper \|\| self == \.chatgptPairing \|\| self == \.chatgptLogin \}/);
  // 守：使用者自己開的一般分頁不叫 Computer Use 的撤銷（它不是敏感頁）、不走開框請求（按的就是框裡的鈕）。
  const open = between(browser, 'func openBrowse(url: URL, title: String?, origin: DMBrowserBrowseOrigin = .typed, typedInto: UUID? = nil) -> DMBrowserBrowseResult {', 'func browseTab(');
  assert.doesNotMatch(code(open), /BrowserSensitivePageGate|GlobalDMOpenRequest|openRequest\(|reveal\(/);
  // 守：流程的入口照舊叫 pageAppeared、照舊走開框請求。
  for (const opener of ['func open(url: URL, purpose: DMBrowserPurpose,', 'func openPod(purpose:', 'func adoptPopup(']) {
    assert.match(between(browser, opener, '\n    }\n'), /BrowserSensitivePageGate\.pageAppeared\(\)/, opener);
  }
  // 守：配對碼只在綁住的 Pod／配對頁看得到時顯示（網頁種類一律 false）；連線卡片只浮在連線分頁上。
  assert.match(browser, /case \.pod: return surface == -1\s*case \.popup\(let key\): return surface == key\s*case \.web: return false/);
  assert.match(view, /return tab\.purpose\.isConnect && connect\.card != nil/);
  // 守：R9「新增 ▾」租約照舊看 ChatGPT Dev 的頁面在不在畫面上（換到一般分頁＝跟換到別的分頁一樣放掉）。
  assert.match(browser, /tab\.purpose == purpose, !tab\.pageClosed,/);
  // 守：使用者關還沒完成的流程分頁＝取消流程；一般分頁沒有取消的路（沒有 cancelActions）。
  assert.match(browser, /let cancel = tab\.done \? nil : cancelActions\[id\]\s*removeTab\(id\)\s*cancel\?\(\)/);
  assert.doesNotMatch(code(open), /cancelActions|fallbackActions/);
  // 守（W184 G2 修正，GPT-6 1、2；查證 #3；第三輪 #1、#2）：分頁數上限不變（6）；一般分頁最多 6−2。滿了先收一個「已完成、不在最前面」的
  // 分頁（完成的頁面早就關了）；絕不收使用者開的一般分頁、還沒完成的流程分頁（不替使用者取消別的流程）、目前在看的分頁；先算、新頁建得起來
  // 才動。還是滿：一般分頁＝一句話；流程分頁（授權頁、Pod）＝暫時多開（不退到 OS 瀏覽器，自測 G6）；網頁開的新視窗＝多開到 6＋4 為止，
  // 到了＝那一個不開、Browser 上一句話、連線中卡片也說（自測 G6b）。
  assert.match(browser, /static let maxTabs = 6/);
  assert.match(browser, /static let maxBrowseTabs = maxTabs - 2/);
  assert.match(browser, /static let popupOverflow = 4/);
  assert.doesNotMatch(code(browser), /makeRoom|userClose\(victim|let victim|hasRoomForFlow|private func room\(\)/);
  const room = between(browser, 'private func browseRoom() -> Room? {', 'private func commitRoom(');
  assert.match(room, /if tabs\.count < Self\.maxTabs \{ return \.free \}\s*guard let done = tabs\.first\(where: \{ \$0\.done && \$0\.id != activeID \}\) else \{ return nil \}\s*return \.evict\(done\.id\)/);
  assert.match(room, /private func flowRoom\(\) -> Room \{\s*browseRoom\(\) \?\? \.free\s*\}/);
  assert.match(room, /private func popupRoom\(\) -> Room\? \{\s*if let room = browseRoom\(\) \{ return room \}\s*return tabs\.count < Self\.maxTabs \+ Self\.popupOverflow \? \.free : nil/);
  assert.doesNotMatch(code(room), /purpose|removeTab|userClose|cancel|close\(/);
  assert.match(browser, /private func commitRoom\(_ room: Room\) \{\s*if case \.evict\(let id\) = room \{ removeTab\(id, restoring: false\) \}\s*\}/);
  assert.match(open, /if tabs\.filter\(\{ \$0\.purpose == \.browse \}\)\.count >= Self\.maxBrowseTabs \{ return \.refused\(\.browseFull\) \}\s*guard let room = browseRoom\(\) else \{ return \.refused\(\.full\) \}[^\n]*\n\s*commitRoom\(room\)/);
  const flowOpen = between(browser, 'func open(url: URL, purpose: DMBrowserPurpose,', '\n    }\n');
  assert.match(flowOpen, /commitRoom\(flowRoom\(\)\)[^\n]*\n\s*let tab = DMBrowserTabInfo/);
  const podOpen = between(browser, 'func openPod(purpose:', '\n    }\n');
  assert.match(podOpen, /guard let page = podPage\(\) else \{ return false \}\s*commitRoom\(flowRoom\(\)\)/);
  const popup = between(browser, 'func adoptPopup(', '\n    }\n');
  assert.match(popup, /onCancel: \(@MainActor \(\) -> Void\)\? = nil, onFull: \(@MainActor \(\) -> Void\)\? = nil\) \{/);
  assert.match(popup, /guard let room = popupRoom\(\) else \{\s*page\.close\(\)\s*notice = Self\.popupRefusedText\s*onFull\?\(\)\s*return\s*\}\s*commitRoom\(room\)/);
  assert.doesNotMatch(code(popup), /userClose|removeTab/);
  assert.match(rail, /if refusal == \.full \|\| refusal == \.browseFull \{\s*GlobalDMChipButton\(title: "所有分頁", action: showTabs\)/);
  // 守：Browser 上那一句話（網頁開的新視窗沒開）：頂上、「這一頁不給截圖」下面；點一下收、8 秒自己收；浮在網頁上拿得到自己的點擊。
  assert.match(browser, /@Published private\(set\) var notice: String\?/);
  assert.match(view, /if let notice = browser\.notice \{[^\n]*\n\s*DMBrowserNoticeBadge\(text: notice\) \{ browser\.clearNotice\(\) \}/);
  // W184 G2d：頂列平常不在：網域對不上、不是 https 的警告一直看得到（頁面頂上的小標；以前寫在網址 pill 上）。
  assert.match(view, /static func text\(_ tab: DMBrowserTabInfo\) -> String\? \{\s*guard tab\.sourceKnown else \{ return nil \}\s*if tab\.hostMismatch, let expected = tab\.expectedHost \{ return "\\\(tab\.displayHost\)・不是 \\\(expected\)" \}\s*if tab\.isInsecure \{ return "\\\(tab\.displayHost\)・連線不安全" \}/);
  assert.match(between(view, 'private var badges: some View {', 'private var startSearch: some View {'), /if let tab = browser\.activeTab, let caution = DMBrowserCautionBadge\.text\(tab\) \{/);
  assert.match(between(phone, 'struct DMBrowserNoticeBadge: View {', '/// W184 G2：自測的量尺'), /\.background\(BrowserChromeHitLayer\(\)\)[\s\S]*\.accessibilityIdentifier\("tatwo\.dm\.browser\.notice"\)/);
  // 守：［連線］的 Pod 分頁照樣開（流程分頁永遠有位子）；Pod 的新視窗到了硬上限＝這次連線作廢、卡片一句話（排到下一輪才作廢，不重入）。
  assert.match(hands, /browser\.openPod\(purpose: \.chatgptDeveloper, currentURL: podURL\(\), onCancel: cancelFlow\)/);
  assert.doesNotMatch(code(hands), /browserFull|hasRoomForFlow/);
  assert.match(hands, /static func invalidateBrowserFull\(\) \{\s*Task \{ @MainActor in HandsConnectFlow\.shared\.invalidate\("browser_full"\) \}/);
  assert.match(hands, /let full = full \?\? \{ HandsConnectPresenter\.invalidateBrowserFull\(\) \}[\s\S]{0,600}onCancel: pairing \? cancel : nil,\s*onFull: full\)/);
  assert.match(flowSource, /case "browser_full": "私訊框的 Browser 分頁太多了，這次連線的新視窗沒開：先關掉幾個分頁，再按一次「連線」"/);
  // 守（第三輪 #3）：「新增 ▾」要登入但 ChatGPT Dev 分頁開不出來（私訊鈕關著）＝照實說，不叫使用者去不存在的分頁登入（自測在 w183browser）。
  const menu = swift('Facade/ChatGPTPluginNewMenu.swift');
  assert.match(menu, /if ready\.needsLogin, !dependencies\.openTab\(\{\}\) \{ return show\(Self\.noPlaceText\) \}/);
  assert.doesNotMatch(code(menu), /_ = dependencies\.openTab\(\{\}\)/);
  // 守：總開關關掉＝全部關（一般分頁也關）；總開關關著不開一般分頁。
  assert.match(open, /guard store\.isEnabled else \{ return \.refused\(\.off\) \}/);
  assert.match(browser, /if !enabled \{ self\?\.closeAll\(cancelling: true\) \}/);
  // 守（W184 G2c／G2d）：側欄、頂列蓋在頁面上只擋一塊，頁面照樣在畫面上：截圖保護、配對碼、「新增 ▾」租約照「頁面在不在畫面上」的原規則
  // （不因側欄、頂列放寬、也不多擋）；「這一頁不給截圖」小標同一條。Computer Use 閘門不看畫面：有敏感分頁就擋。
  // W184 G2d：沒有分頁、空白的新分頁＝主視窗那個置中的搜尋框（頁面容器不掛：原生容器會吃掉搜尋框的點擊）；其他照舊是頁面。
  // W183 R12（主導 1）：pageFrame 多一個 yield（有連線卡片時網頁讓出卡片那一段）；下面守的照舊。
  const frame = between(view, 'private func pageFrame(toolbar: Bool, yield: CGFloat? = nil) -> some View {', 'private var badges: some View {');
  assert.match(frame, /if showsStartSearch \{[^\n]*\n(?:\s*\/\/[^\n]*\n)*\s*startSearch\s*\} else \{\s*DMBrowserPageSurface\(browser: browser, slot: slot\)/);
  assert.match(view, /private var showsStartSearch: Bool \{ browser\.tabs\.isEmpty \|\| browser\.activeTab\?\.isBlank == true \}/);
  const badges = between(view, 'private var badges: some View {', 'private var startSearch: some View {');
  assert.match(badges, /let shielded = !browser\.tabs\.isEmpty\s*&& DMBrowser\.capturesBlocked\(activeSensitive: browser\.activeTab\?\.isSensitive == true, tabList: browser\.isShowingTabList, onScreen: true\)/);
  assert.doesNotMatch(code(view), /pageCovered/);
  assert.match(swift('Browser/BrowserSensitivePage.swift'), /static var isActive: Bool \{\s*browsers\.contains \{ \$0\.value\?\.isSensitive == true \}/);
  // 守（W184 G2 修正，GPT-6 附註；主導裁決）：分「是不是授權頁」看誰開的（流程身分）不看網頁內容——使用者自己開的一般分頁就算是登入頁
  // 也不擋截圖、不擋 Computer Use；契約 §3b 寫明這條邊界與分頁數規則。
  assert.match(contract, /\*\*邊界（W184 G2 修正，GPT-6 附註）\*\*：分「是不是授權頁」看的是誰開的（流程身分），不看網頁內容/);
  assert.match(contract, /就算內容是登入頁、OAuth 頁，也不擋截圖、不擋 Computer Use/);
  assert.match(contract, /不自動關使用者的頁、不替使用者取消別的流程、不收正在看的分頁/);
  assert.match(contract, /\*\*不因為分頁數退到 OS 瀏覽器\*\*/);
  assert.doesNotMatch(contract, /分頁滿了＝流程要開的授權頁、配對頁先收最舊的一般分頁|放不下＝流程收到失敗（授權頁退回 OS 瀏覽器/);
});


test('bookmarks, favorites, spaces are read from the main window\'s Browser space — read and open only; switching = the sidebar dot', () => {
  // 守：資料同主視窗側欄：書籤＝那個 store 的 folders（W184 G2d：私訊框借用的就是主視窗那一份 folderSection）；珍藏＝分頁清單的 favorites
  // （BrowserFavoritesStrip 讀的同一排）；Pinned＝那個 store 的 pinnedTabs。
  assert.match(swift('Browser/BrowserWorkSpaceDesignView.swift'), /ForEach\(store\.folders\) \{ folder in/);
  assert.match(swift('Browser/BrowserWorkSpaceDesignView.swift'), /ForEach\(store\.pinnedTabs\) \{ tab in/);
  // Native W202 receipts verify both mounted favorites strips redraw from their own observed store.
  // 守（W184 G2d）：私訊框用的是同一個元件的「給外面用」那一支（external）：主視窗那一支照舊（點＝store.openFavorite／openBookmark，拖放、右鍵選單），
  // 私訊框那一支只開私訊框自己的分頁、不拖不放、沒有右鍵、沒有音符（自測 M2、M3 用真的滑鼠量兩支）。
  assert.match(strip, /var body: some View \{\s*if let external \{ externalStrip\(external\) \} else \{ strip \}/);
  assert.match(strip, /\.onTapGesture \{ store\.openFavorite\(favorite\.id\) \}/);
  const external = between(strip, 'private func externalStrip(_ external: BrowserFavoritesExternal) -> some View {', 'private func accept(');
  assert.match(external, /\.onTapGesture \{ external\.open\(favorite\) \}/);
  assert.doesNotMatch(code(external), /store\.(openFavorite|close|registry\.(add|remove|move))|dropDestination|onDrag|contextMenu|BrowserAudioNote|audible/);
  assert.match(rows, /var body: some View \{\s*if let external \{ externalRow\(external\) \} else if renaming \{ renameField \} else \{ row \}/);
  const externalRow = between(rows, 'private func externalRow(_ external: BrowserBookmarkExternal) -> some View {', '/// W112（使用者 2026-09-20：「書籤右鍵要可以改名」）');
  assert.match(externalRow, /onSelect: \{ external\.open\(bookmark\) \}/);
  assert.doesNotMatch(code(externalRow), /store\.(openBookmark|closeBookmark|deleteBookmark|saveBookmark|saveDraggedTabs|registry)|dropDestination|onDrag|contextMenu/);
  assert.match(rows, /Button \{ if let external \{ external\.toggle\(\) \} else \{ store\.toggleFolder\(folder\.id\) \} \}/);
  assert.match(rows, /if external == nil, store\.folderHasOpenTabs\(folder\.id\) \{/);
  // 守：切換空間＝同一顆 BrowserSpaceDot：主視窗那一顆（沒給 choose）照舊叫畫出它的那一份 store 的 selectSpace；私訊框那一顆不給編輯（editable＝false），
  // 點下去交給它自己的選擇回呼（GPT-6 審查 G2d #4：DMBrowserSpaces.select 記下使用者的選擇；自測 M4 真的按私訊框側欄的圓點，A→B→A）。
  assert.match(dot, /Button \{ if let choose \{ choose\(space\) \} else \{ store\.selectSpace\(space\.id\) \} \}/);
  assert.match(dot, /var choose: \(@MainActor \(BrowserWorkSpaceStore\.Space\) -> Void\)\? = nil/);
  assert.match(dot, /BrowserRightClickCatcher \{ if editable \{ menuPresented = true \} \}/);
  // W184 G2 修正（GPT-6 5）：程式裡切換空間用空間的 UUID（registryID）在「當下」的 store 重新找——store 的整數 ID 是各自視窗的別名，接管前後
  // 同一個數字可能指到別的空間，不跨 store 傳整數；找不到（已刪）＝不切（自測 G10b）。圓點用的是畫出它的那一份 store 與它自己的空間（同一個 store 的別名）。
  assert.match(spaces, /func select\(registryID: UUID\) -> Bool \{\s*let target = store\s*guard let space = target\.spaces\.first\(where: \{ \$0\.registryID == registryID \}\) else \{ return false \}\s*target\.selectSpace\(space\.id\)/);
  assert.doesNotMatch(code(chrome) + code(rail) + code(spaces), /func select\(_ space|\.select\(space\)/);
  // 守：主視窗的 store 由 ChatPage 交過來（只在正式模式；只收同一份分頁清單的）；沒交過來＝私訊框自己留一份；交接時照私訊框最後一次選的空間切一次
  // （GPT-6 審查 G2d #4：選擇在圓點按下去時記下，不從最後的狀態反推——A→B→A＝選了 A；自測 G10、M4）。一開始的空間被刪掉（store 自己換到
  // 別的空間）不是使用者選的（自測 G10b）。
  assert.match(chatPage, /if model\.isLive \{ DMBrowserSpaces\.shared\.adopt\(browserWorkSpaceStore\) \}/);
  assert.match(spaces, /guard store\.registry === registry, adopted !== store else \{ return \}\s*let chosen = adopted == nil \? chosenAlone : nil/);
  assert.match(spaces, /target\.selectSpace\(space\.id\)\s*if adopted == nil \{ chosenAlone = registryID \}/);
  assert.doesNotMatch(code(spaces), /ownChoice|ownStart/);
  assert.match(spaces, /private weak var adopted: BrowserWorkSpaceStore\?/);
  // 守：只讀＋開啟——私訊框不改名、不刪、不搬、不存書籤與珍藏、不在分頁清單開分頁（那些在主視窗做）。
  assert.doesNotMatch(code(chrome) + code(rail) + code(spaces),
    /\.(addBookmark|removeBookmark|renameBookmark|deleteBookmark|addFavorite|removeFavorite|moveFavorite|importFavorites|openTab|openBookmark|openFavorite|addFolder|renameFolder|renameSpace|setSpaceColor|archiveAndRemoveSpace|removeSpace|addSpace|move|close|closeAll|bind|saveBookmark|bookmarkCurrentTab)\(/);
  // 守：私訊框 Browser 的分頁不進分頁清單（DMBrowser、畫面不碰正式的分頁清單；書籤資料只在 DMBrowserSpaces 讀）。
  assert.doesNotMatch(code(browser) + code(view) + code(chrome), /BrowserTabRegistry\.shared|tabs\.json/);
});

test('tabs in the sidebar: tap a row = switch, × = close (a flow tab still cancels its flow), 新分頁 = DMBrowser.newTab; 📌 Pinned rows open in the DM', () => {
  const side = between(chrome, 'struct DMBrowserSidebar: View {', undefined);
  assert.match(side, /select: \{ browser\.select\(tab\.id\) \}, close: \{ browser\.userClose\(tab\.id\) \}/);
  assert.match(side, /closeHelp: browser\.closingCancels\(tab\.id\) \? "關掉這個分頁（這一次還沒完成，會一起取消）" : "關掉這個分頁"/);
  assert.match(side, /newTab: newTab, newTabIdentifier: "tatwo\.dm\.browser\.newTab"/);   // 新分頁那一列＝主視窗那一列，按下去走 DMBrowser.newTab
  assert.match(view, /DMBrowserSidebar\(browser: browser, spaces: spaces, width: width, height: height, topInset: topExtension,\s*titleLeading: DMBrowserPhone\.sidebarTitleLeading\(form: form\), probe: probe, finish: finish,\s*newTab: \{ _ = browser\.newTab\(\) \}, interaction: \{ reveal\.holdSidebar\(\$0\) \}\)/);
  // 守：同主視窗 tabRow——同一個 BrowserTabRow；× 在 hover 時才出現（自測開著量尺時固定顯示：合成的滑鼠不觸發 hover）；選中的底色與陰影。
  const row = between(chrome, '/// 一列（同主視窗 tabRow', undefined);
  assert.match(row, /let closeVisible = close != nil && \(hovered == probeKey \|\| probe\)/);
  assert.match(row, /BrowserTabRow\(variant: \.workspace, title: title, tabID: tabID, host: host, favicon: favicon, selected: selected,/);
  assert.match(row, /\.background\(selected \? fieldFill : \.clear, in: RoundedRectangle\(cornerRadius: BrowserSidebarMetrics\.rowSpacing\)\)/);
  // 守（W184 G2d：📌 Pinned 那一列，自測 S9）：點＝私訊框開主視窗釘選那一頁的網址（新的一般分頁；http 改 https；同一列再按＝切過去）；
  // × 只關私訊框那一頁（主視窗釘選的分頁不動）。
  assert.match(side, /select: \{ finish\(DMBrowserShelf\.open\(pinned: pin, in: browser\)\) \}/);
  assert.match(side, /if let opened = tab \{ close = \{ browser\.userClose\(opened\.id\) \} \}/);
  assert.match(rail, /static func open\(pinned tab: BrowserWorkSpaceStore\.Tab, in browser: DMBrowser\) -> DMBrowserBrowseResult \{\s*guard let id = tab\.registryID, let url = URL\(string: tab\.url\)\.flatMap\(DMBrowserBrowseInput\.secured\) else \{ return \.refused\(\.notSecure\) \}\s*return browser\.openBrowse\(url: url, title: tab\.title, origin: \.pinned\(id\)\)/);
  assert.match(browser, /case \.bookmark, \.pinned:\s*return browse\.first \{ \$0\.origin == origin \}/);
  // 守：錯誤＝一句話＋最多一顆鈕（頁面頂上）；文案短。
  assert.match(browser, /case \.notSecure: "這個打不開：私訊框的 Browser 只開 https 網頁。"/);
  assert.match(browser, /case \.full: "分頁滿了（最多 \\\(DMBrowser\.maxTabs\) 個），先關掉一個。"/);
  assert.match(browser, /case \.browseFull: "一般網頁最多 \\\(DMBrowser\.maxBrowseTabs\) 個（留位子給授權頁、配對頁），先關掉一個。"/);
});

test('typing (toolbar address and centered search): the page never steals the keyboard while typing; Esc ends typing only', () => {
  // 守：打字時頁面開好、換分頁不把鍵盤搶回頁面；收起輸入、送出＝放手。
  assert.match(browser, /private func focusActive\(\) \{\s*guard !keepsKeyboard, let id = activeID/);
  // 守：打字的時候私訊框拿鍵盤（停靠框平常只在需要時才拿），字才打得進去；只讓框變成 key、不在畫面更新的當下動視窗，不把整個 App 叫到前景。
  assert.match(view, /\.background\(DMBrowserKeyTaker\(active: panel != nil \|\| pendingFocus != nil\)\)/);
  assert.match(view, /guard let self, self\.active, let window = self\.window, window\.isVisible, window\.canBecomeKey, !window\.isKeyWindow else \{ return \}\s*window\.makeKey\(\)/);
  assert.doesNotMatch(code(view) + code(chrome), /NSApp\.activate|activate\(ignoringOtherApps|orderFrontRegardless/);
  // 守（W184 G2 修正，查證 #4）：流程把授權頁、配對頁叫到前面（reveal）＝放掉拿著的鍵盤、畫面收起輸入。
  assert.match(between(browser, 'private func reveal(_ id: UUID) {', 'private func bringToFront('), /keepsKeyboard = false\s*flowRaised &\+= 1\s*openRequest\(request\)/);
  assert.match(view, /\.onChange\(of: browser\.flowRaised\) \{ _, _ in closePanel\(\) \}/);
  // 守（W184 G2 修正，GPT-6 4；查證 #5、#8；G2c／G2d）：Esc——在打字時（頂列網址欄、置中搜尋框）只收輸入（單欄、內橫一樣），不收整個私訊框、
  // 也不給網頁：在打的時候在它的視窗登記（DMBrowserPanelEscapeAnchor，錨一直在、收起的當下就拿掉），私訊框的 Esc 路由先問它；組字中照舊交給輸入法、
  // 倒放照舊最先（自測 G12、G14 用真的 Esc 事件走同一條路由）。
  assert.match(view, /\.background\(DMBrowserPanelEscapeAnchor\(panel: panel, close: closePanel\)\)/);
  assert.match(view, /private var panel: DMBrowserPanel\? \{\s*if addressEditing \{ return \.address \}\s*if searchFocus != nil \|\| \(!draft\.isEmpty && showsStartSearch\) \{ return \.search \}\s*return nil/);
  assert.match(phone, /enum DMBrowserPanel: String, Sendable \{\s*case address\s*case search\s*\}/);
  assert.match(phone, /func registerIfNeeded\(\) \{\s*if let panel, window != nil \{\s*DMBrowserPanelEscape\.register\(self, panel: panel, close: \{ \[weak self\] in self\?\.close\(\) \}\)\s*\} else \{\s*DMBrowserPanelEscape\.unregister\(self\)/);
  const route = between(panels, 'static func routeEscape(', '// MARK: - 換形態（W184 AB）');
  const ime = route.indexOf('if isComposing(in: window) { return event }');
  const tent = route.indexOf('if form == .tent {');
  const panelEsc = route.indexOf('if DMBrowserPanelEscape.closePanel(in: window) { return nil }');
  const browsing = route.indexOf('if store.isBrowsing { return event }');
  assert.ok(ime >= 0 && tent > ime && panelEsc > tent && browsing > panelEsc, `Esc order ime=${ime} tent=${tent} panel=${panelEsc} browsing=${browsing}`);
  assert.match(panels, /private func handleEscape\(_ event: NSEvent\) -> NSEvent\? \{\s*guard let window = event\.window, window === docked \|\| window === floating else \{ return event \}\s*return Self\.routeEscape\(/);
  const escape = between(phone, '@MainActor\nenum DMBrowserPanelEscape {', '/// 墊在 Browser 區後面的錨');
  assert.match(escape, /static func closePanel\(in window: NSWindow\) -> Bool \{\s*entries\.removeAll \{ \$0\.anchor == nil \}\s*guard let entry = entries\.last\(where: \{ \$0\.anchor\?\.window === window \}\) else \{ return false \}\s*entries\.removeAll \{ \$0 === entry \}\s*entry\.close\(\)\s*return true/);
  assert.match(phone, /static func dismantleNSView\(_ view: AnchorView, coordinator: \(\)\) \{\s*DMBrowserPanelEscape\.unregister\(view\)/);
  // 守：收起頂列網址欄＝主視窗那條導覽列的失焦（它自己收起、字還原）。
  assert.match(view, /address = DMBrowserToolbar\.state\(browser\.activeTab\)\.urlString \?\? ""\s*addressFocused = false/);
  // 守：網址 pill 的判斷（鎖頭、警告、尚未確認來源、空白分頁）留著給自測與授權流程核對；這台的名字在 ⋯ 裡。
  assert.match(view, /if tab\.isBlank \{ return "magnifyingglass" \}/);
  assert.match(view, /return warn \? "exclamationmark\.triangle\.fill" : "lock\.fill"/);
  assert.match(chrome, /Button\("這個 Browser 在這台：\\\(DMBrowser\.deviceName\)"\) \{\}\.disabled\(true\)/);
});

test('W184 G2d: no fades on the sidebar — the main window\'s Browser space sidebar has none (the 09-29 fade went with the DM-only column)', () => {
  assert.doesNotMatch(code(view) + code(rail) + code(phone) + code(chrome), /dmBrowserFade|DMBrowserFadeState|fadeStops|fadeStrength|fadeAlpha|edgeFade/);
  assert.doesNotMatch(code(sidebarAcceptance), /fadeChecks|S8 \(W184 G2c second round, lead #7\)/);
});

test('identifiers: the sidebar, toolbar, search and what they open keep tatwo.dm.browser.* ids (and the Browser space components keep theirs)', () => {
  for (const id of ['tatwo.dm.browser.sidebar', 'tatwo.dm.browser.toolbar', 'tatwo.dm.browser.search', 'tatwo.dm.browser.caution', 'tatwo.dm.browser.tabList.newTab',
    '"tatwo.dm.browser"', 'tatwo.dm.browser.page', 'tatwo.dm.browser.closed.close', 'tatwo.dm.browser.problem']) {
    assert.ok(view.includes(id), id);
  }
  for (const id of ['tatwo.dm.browser.newTab', 'tatwo.dm.browser.spaces', 'tatwo.dm.browser.tabRow.', 'tatwo.dm.browser.notes', 'browser.extensions']) {
    assert.ok(chrome.includes(id), id);
  }
  assert.ok(rail.includes('tatwo.dm.browser.note'), 'note');
  for (const id of ['browser.favorite.\\(favorite.id)', 'browser.favorites.strip']) assert.ok(strip.includes(id), id);
  for (const id of ['browser.bookmark.\\(bookmark.id)', 'browser.folder.\\(folder.id)']) assert.ok(rows.includes(id), id);
  assert.ok(controls.includes('.accessibilityIdentifier("browser.sidebarToggle")'));
});

test('self-test (w184browser) covers the sidebar, toolbar and search with counterexamples and side-by-side PNG evidence; isolated, fakes only, no personal data', () => {
  assert.match(phoneAcceptance, /await sidebarChecks\(check\)[^\n]*\n\s*await toolbarChecks\(check\)[^\n]*\n\s*await searchChecks\(check\)[^\n]*\n\s*mainComponentChecks\(check\)[\s\S]{0,200}await shelfChecks\(check\)[\s\S]{0,200}await capacityChecks\(check\)[\s\S]{0,300}await pointerChecks\(check\)[\s\S]{0,300}await panelChecks\(check\)[\s\S]{0,300}await newTabChecks\(check\)/);
  for (const source of [acceptance, chromeAcceptance, sidebarAcceptance, mouseAcceptance]) {
    assert.match(source, /^#if DEBUG/);
    assert.doesNotMatch(source, /DMBrowser\.shared|DMBrowserSpaces\.shared|BrowserTabRegistry\.shared|HandsConnectPresenter\.shared|HandsConnectFlow\.shared|ChatGPTTap\.shared|GlobalDMPanelController\.shared|GlobalDMDeskController\.shared|GlobalDMStore\.shared|URLSession/);
    assert.doesNotMatch(source, /check\(true,/);
    assert.doesNotMatch(source, /@[a-z0-9-]+\.[a-z]{2,}/i);
  }
  assert.match(acceptance, /let registry = BrowserTabRegistry\(storageURL: nil\)/);
  for (const label of ['G1 a bookmark opens a NEW general tab', 'G2 the same bookmark again switches', 'G3 (W184 G2 third round) a favorite opens its own tab', 'G4 general tabs are not authorisation pages',
    'G5 a flow cannot open a general page', 'G7 while the address field is being typed in', 'G8 typing:', 'G9 switching space in the DM Browser',
    'G10 before the main window exists',
    'G3b (W184 G2 fix, GPT-6 6) typed A then navigated to B', 'G6 (W184 G2 fix, third round) full with general tabs', 'G6a a finished tab that is not in front',
    'G6b (W184 G2 fix, third round) full with flow tabs only', 'G10b (W184 G2 fix, GPT-6 5)', 'G11 (W184 G2 fix, 查證 #4; G2d)', 'G12 (W184 G2 fix, G2c, G2d) a real Esc key event',
    'G3c (W184 G2 third round)', 'G13b (W184 G2 third round, 查證 #7)', 'G14 (W184 G2 third round; second round adds a non-NSTextView input; G2d) the Esc order, measured', 'G13 (W184 G2 fix, 查證 #6)',
    'C1 (W184 G2 fix) pointer from the hidden-sidebar state', 'C2 (W184 G2d) the 「輪到你」 card with the full-height sidebar out', 'R7 (W184 G2d) the page\'s left part never brings the sidebar out',
    'R8 (W184 G2d) pressing each part of the Browser space sidebar with a real mouse', 'R12 (W184 G2d) while typing in the toolbar\'s address the toolbar stays',
    'N1 (W184 G2c; G2d) the sidebar\'s 新分頁', 'N2 (W184 G2c; G2d) the tab overview', 'N3 (W184 G2c; G2d) with 4 general tabs', 'N4 (W184 G2c; G2d) ⌘⌥T as a real key event']) {
    assert.ok(acceptance.includes(label), label);
  }
  // W184 G2d（DMBrowserChromeAcceptance.swift）：側欄、頂列、搜尋框、主視窗元件照舊。
  // W184 G2d 追加（主導 09-30、GPT-6 審查 G2d #1–#5）：S1／S1b 側欄就是主視窗那一份、空間名稱擺法同主視窗；S2d 緊湊側欄捲動之後頂列蓋不到列；
  // S8 來源刪掉的分頁回到分頁清單；S9 借用模式的限制（Pinned 開在私訊框、＋按不下去、下載清單開著側欄留著）；T3／T3b 原生重新載入；
  // M4 私訊框的圓點走它自己的選擇回呼（A→B→A）。
  for (const label of ['S1 (W184 G2d; lead 09-30 + GPT-6 G2d #5) the DM sidebar IS the main window\'s BrowserWorkSpaceSidebarList', 'S2 (W184 G2d: 「左列欄修到頂天」)',
    'S1b (W184 G2d; lead 09-30: where the main window really puts the space name)',
    'S2b (W184 G2d second pass) with the sidebar and the toolbar both out', 'S2c (W184 G2d third pass: 「duo的browser左列欄修到頂天」)',
    'S2d (W184 G2d; GPT-6 G2d #3)', 'S8 (W184 G2d; GPT-6 G2d #2)', 'S9 (W184 G2d; lead 09-30 + GPT-6 G2d #5)',
    'S3 (W184 G2d; kept from G2c)', 'T1 (W184 G2d)', 'T2 (W184 G2d) the toolbar is the main window\'s Browser space row', 'T2b in the inner-landscape right column ×0.7',
    'T3 (W184 G2d; GPT-6 G2d #1) pressing the toolbar with a real mouse', 'T3b (W184 G2d; GPT-6 G2d #1)', 'T4 (W184 G2d) translate, extensions and notes',
    'T5 (W184 G2d: 「應該是滑鼠指到展開玻璃」)',
    'Q1 (W184 G2d: 「還沒有分頁的搜尋狀態也要一樣」)', 'Q2 clicking the search box', 'Q3 a new tab is a blank general tab', 'Q4 typed in the blank tab\'s search box',
    'M1 (W184 G2d)', 'M2 (W184 G2d)', 'M3 (W184 G2d)', 'M4 (W184 G2d; GPT-6 G2d #4)']) {
    assert.ok(chromeAcceptance.includes(label), label);
  }
  assert.match(chromeAcceptance, /await scrolledCompactChecks\(check\)\s*await sourceChecks\(check\)\s*await guestRowChecks\(check\)/);
  assert.ok(phoneAcceptance.includes('B4 (W184 G2d) while the sidebar\'s downloads list is open'), 'B4 downloads hold');
  // 守（GPT-6 審查 G2d #6：真的滑鼠路徑）：V 段不開忽略開關、不用 listening:false、不直接叫 evaluate(windowPoint:)——滑鼠移動排進 App 的事件佇列，
  // 由 Browser 區正式掛上的本機監聽收；量移入、移出、收起延遲期間點擊、收框、換形態（V1–V4）。真的 CEF 那一段由主導 .032 實機驗（skip 寫明）。
  assert.match(phoneAcceptance, /await revealChecks\(check\)\s*await realMouseChecks\(check\)/);
  assert.match(mouseAcceptance, /DMBrowserBarReveal\.ignoresRealMouse = false/);
  assert.match(mouseAcceptance, /NSEvent\.mouseEvent\(with: \.mouseMoved,[\s\S]{0,300}NSApp\.postEvent\(event, atStart: false\)/);
  assert.doesNotMatch(code(mouseAcceptance), /listening: false|evaluate\(windowPoint:|reveal\.start\(/);
  for (const label of ['V1 (W184 G2d; GPT-6 G2d #6)', 'V2 (W184 G2d; GPT-6 G2d #6)', 'V3 (W184 G2d; GPT-6 G2d #6)', 'V4 (W184 G2d; GPT-6 G2d #6)']) {
    assert.ok(mouseAcceptance.includes(label), label);
  }
  assert.match(phone, /guard window\.isVisible else \{ return set\(sidebar: false, toolbar: holds, immediately: true\) \}/);
  assert.match(phone, /NotificationCenter\.default\.addObserver\(forName: NSWindow\.didChangeOcclusionStateNotification, object: window,/);
  // W184 G2c 第二輪（DMBrowserSidebarAcceptance.swift）：每一條都是退步時會失敗的反例（G2d 留在新樣子上）。
  for (const label of ['N1b (W184 G2c second round, GPT-6 #3; G2d)', 'N1c (W184 G2c second round, GPT-6 #3)', 'N4b (W184 G2c second round, GPT-6 #1)',
    'N4b-IME (W184 G2c second round, GPT-6 #2)', 'N4b-pass (W184 G2c second round)', 'N4b-control a bare ⌥⌘ press and release does toggle the box',
    'N5 (W184 G2c second round, lead #6)', 'S4 (W184 G2c second round, GPT-6 #4; G2d)', 'S5 (W184 G2c second round, GPT-6 #4; G2d)', 'S6 (W184 G2c second round, GPT-6 #4; G2d)',
    'S7 (W184 G2c second round, GPT-6 #5; G2d)']) {
    assert.ok(sidebarAcceptance.includes(label), label);
  }
  assert.ok(phoneAcceptance.includes('F6b (W184 G2c second round, GPT-6 #4)'), 'F6b smallest boxes');
  // W183 R12：自測多一段（單欄時卡片擺在網頁下面）；其餘順序照舊。
  assert.match(phoneAcceptance, /await newTabChecks\(check\)[\s\S]{0,400}await draftChecks\(check\)\s*await newTabControllerChecks\(check\)\s*directKeyChecks\(check\)\s*await smallBoxChecks\(check\)\s*(?:await r12YieldChecks\(check\)[^\n]*\n\s*)?await manySpacesChecks\(check\)\s*await evidence\(check\)/);
  // 守：畫面證據＝私訊框跟主視窗 Browser space 的同一元件並排（頂列、側欄頂天、沒分頁的搜尋框、內橫右欄、連線卡片＋側欄）。
  for (const png of ['g2d-toolbar.png', 'g2d-sidebar.png', 'g2d-sidebar-top.png', 'g2d-search.png', 'g2d-duo.png', 'g2d-card-sidebar.png', 'g2d-small-manual.png', 'g2d-spaces.png']) {
    assert.ok(chromeAcceptance.includes(png) && phoneAcceptance.includes(png), png);
  }
  assert.match(chromeAcceptance, /BrowserWorkSpaceSidebarList\(store: store\)/);   // 主視窗那一半是真的 BrowserWorkSpaceSidebarList
  assert.match(chromeAcceptance, /BrowserStartSearch\(query: \$query, focus: \$focus, field: 0, canAddTab: store\.canAddTab, suggestions: store\.suggestions\(for: query\),/);
  // 守：真的事件——滑鼠按下用 window.sendEvent、放開先排進 App 的事件佇列（同使用者點的路；按到捲軸這類自己開追蹤迴圈的也不會卡住自測），
  // Esc 排進 App 的事件佇列、走私訊框同一條 routeEscape；舊的 G6（要求一般頁被收掉）拿掉。
  assert.match(acceptance, /NSApp\.postEvent\(up, atStart: false\)\s*window\.sendEvent\(down\)/);
  assert.match(acceptance, /NSApp\.postEvent\(event, atStart: false\)/);
  assert.match(acceptance, /GlobalDMPanelController\.routeEscape\(event, window: window, floating: nil, store: store, form: form\)/);
  assert.doesNotMatch(acceptance, /G6 full:|oldest general tab is closed/);
});

test('W184 G2c／G2d new tab: 新分頁 in the sidebar, ＋ in the overview and the search box, ⌘⌥T in the DM box — a blank general tab, the caret in the centered search; full = one sentence', () => {
  // 使用者 09-29 驗收 .030：「沒有新增分頁的功能 並且快捷鍵一樣command option t」。
  // 守：新分頁＝空白的一般分頁（不是授權頁；照 G2 一般分頁最多 4 個，滿了＝一句話）；已經在空白的新分頁上＝不再多開；畫面照 newTabAsk
  // 把游標放進空白分頁上置中的搜尋框。側欄「新分頁」、總覽的＋、搜尋框的＋、⌘⌥T 都走 DMBrowser.newTab（同一條）。
  assert.match(browser, /var isBlank: Bool \{ purpose == \.browse && startURL == nil \}/);
  const newTab = between(browser, '    func newTab() -> DMBrowserBrowseResult {', 'private func ask(');
  assert.match(newTab, /guard store\.isEnabled else \{ return ask\(\.refused\(\.off\)\) \}/);
  assert.match(newTab, /if let blank = activeTab, blank\.isBlank \{\s*store\.showBrowser\(\)\s*return ask\(\.switched\(blank\.id\)\)/);
  assert.match(newTab, /if tabs\.filter\(\{ \$0\.purpose == \.browse \}\)\.count >= Self\.maxBrowseTabs \{ return ask\(\.refused\(\.browseFull\)\) \}\s*guard let room = browseRoom\(\) else \{ return ask\(\.refused\(\.full\)\) \}/);
  assert.match(newTab, /var tab = DMBrowserTabInfo\(id: UUID\(\), purpose: \.browse, kind: \.web, startURL: nil, expectedHost: nil\)/);
  assert.doesNotMatch(code(newTab), /BrowserSensitivePageGate|GlobalDMOpenRequest|openRequest\(|reveal\(|startWebPage|cancelActions/);
  // 守：打網址、點書籤或珍藏時目前在看的是空白的新分頁＝開在它上面（同一個分頁，不再多開一個）；已經有自己分頁的書籤、珍藏照舊切過去。
  const open = between(browser, 'func openBrowse(url: URL, title: String?, origin: DMBrowserBrowseOrigin = .typed, typedInto: UUID? = nil) -> DMBrowserBrowseResult {', 'func browseTab(');
  const fillAt = 'if let blank = Self.blankToFill(origin: origin, typedInto: typedInto, active: activeTab) {';
  assert.ok(open.indexOf('if let existing = browseTab(origin, url: start)') < open.indexOf(fillAt), 'existing tab first');
  assert.ok(open.indexOf(fillAt) >= 0 && open.indexOf(fillAt) < open.indexOf('Self.maxBrowseTabs'), 'filling a blank tab needs no new slot');
  assert.match(open, /if let blank = Self\.blankToFill\(origin: origin, typedInto: typedInto, active: activeTab\) \{\s*fill\(blank, start: start, title: title, origin: origin\)\s*return \.opened\(blank\)/);
  // 守（W184 G2c 第二輪，GPT-6 #3）：打網址只開在「開始打字的那一個」空白分頁上——送出的當下它得還是空白的一般頁、還是目前那一頁；
  // 換過頁、關掉又被別頁接手＝開新分頁（草稿不填進別的空白頁）。書籤、珍藏＝按下去當下在看的空白分頁（自測 N1b、N1c）。
  assert.match(browser, /nonisolated static func blankToFill\(origin: DMBrowserBrowseOrigin, typedInto: UUID\?, active: DMBrowserTabInfo\?\) -> UUID\? \{\s*guard let active, active\.isBlank else \{ return nil \}\s*if origin == \.typed \{ return typedInto == active\.id \? active\.id : nil \}\s*return active\.id\s*\}/);
  assert.doesNotMatch(code(open), /if let blank = activeTab, blank\.isBlank/);
  // 畫面（W184 G2d）：在搜尋框開始打字、打開頂列的網址欄、要了新分頁時記下那一頁；換頁、開始打字的那一頁關掉＝收起輸入、草稿清掉；
  // 送出帶著那一頁（草稿在畫面上，換了分頁不跟過去）。
  assert.match(view, /\.onChange\(of: browser\.activeID\) \{ _, id in\s*if id != editTarget, panel != nil \|\| !draft\.isEmpty \|\| editTarget != nil \{ closePanel\(\) \}\s*\}/);
  assert.match(view, /\.onChange\(of: browser\.tabs\.map\(\\\.id\)\) \{ _, ids in\s*if let editTarget, !ids\.contains\(editTarget\) \{ closePanel\(\) \}\s*\}/);
  assert.match(view, /\.onChange\(of: searchFocus\) \{ _, field in\s*if field != nil, editTarget == nil \{ editTarget = browser\.activeID \}/);
  assert.match(view, /\.onChange\(of: addressEditing\) \{ _, editing in\s*guard editing else \{ return \}\s*if pendingFocus == \.address \{ pendingFocus = nil \}\s*editTarget = browser\.activeID/);
  assert.match(view, /finish\(browser\.openBrowse\(url: url, title: DMBrowserBrowseInput\.title\(for: text, url: url, engine: engine\), origin: \.typed,\s*typedInto: editTarget\)\)/);
  assert.match(view, /private func submitSearch\(\) \{ open\(draft\) \}/);
  assert.match(view, /private func submitAddress\(\) \{ open\(address\) \}/);
  assert.match(view, /_editTarget = State\(initialValue: panel == nil \? nil : shown\.activeID\)/);
  assert.match(view, /private func closePanel\(\) \{\s*refusal = nil\s*draft = ""\s*editTarget = nil\s*pendingFocus = nil\s*searchFocus = nil/);
  // 守：畫面——側欄「新分頁」、總覽最後一格＋、搜尋框的＋；要了新分頁＝空白分頁上置中的搜尋框拿到游標（框拿到鍵盤的下一輪）；
  // 滿了＝頁面頂上那一句話（DMBrowserRailNote）。
  assert.match(view, /\.onChange\(of: browser\.newTabAsk\) \{ _, ask in\s*guard let ask else \{ return \}\s*closePanel\(\)\s*refusal = ask\.refusal\s*guard ask\.refusal == nil else \{ return \}\s*editTarget = browser\.activeID[^\n]*\n\s*pendingFocus = \.search\s*applyPendingFocus\(\)/);
  assert.match(view, /DispatchQueue\.main\.async \{\s*guard pendingFocus == pending else \{ return \}\s*if pending == \.address, DMBrowserToolbar\.showsAddress\(browser\.activeTab\) \{\s*expansionRequest = true\s*\} else if showsStartSearch \{\s*searchFocus = \.search/);
  assert.match(view, /if let refusal \{\s*DMBrowserRailNote\(refusal: refusal\) \{ showAllTabs\(\) \}/);
  assert.match(view, /ForEach\(browser\.tabs\) \{ tab in card\(tab\) \}\s*newTabCard/);
  assert.match(between(view, 'private var newTabCard: some View {', 'private func card('), /Button \{ browser\.newTab\(\) \}/);
  // 守：⌘⌥T＝私訊框自己的按鍵（本機 keyDown 監聽，不是全域熱鍵）：先看 ⌘⌥T、再照舊走 Esc 的路；只在私訊框是 key 視窗、看得到 Browser
  // （單欄的 Browser 那一頁、內橫右欄）時收；對話、倒放、在設直達鍵、輸入法組字中＝放行；主視窗的 ⌘T（沒有 ⌥）不收。
  assert.match(panels, /guard let event = self\.handleNewTab\(event\) else \{ return nil \}\s*return self\.handleEscape\(event\)/);
  assert.match(panels, /private func handleNewTab\(_ event: NSEvent\) -> NSEvent\? \{\s*guard let window = event\.window, window === docked \|\| window === floating else \{ return event \}\s*return Self\.routeNewTab\(event, window: window, store: store, form: desk\.form, browser: browserServices\.browser \?\? \.shared,\s*hasSecondary: GlobalDMDuo\.shared\.hasSecondary\)/);
  const route = between(panels, 'static func routeNewTab(', '// MARK: - 換形態（W184 AB）');
  // W184 G2c 第二輪（GPT-6 #1、#2）：「看得到 Browser」跟畫面同一個判斷（GlobalDMDuoLayout.showsBrowser：內橫選了左欄對象、兩個旗標都清掉，
  // 還有分頁的右欄照樣是 Browser）；組字看任何文字輸入（NSTextInputClient，網頁輸入框也算），不只 NSTextView（自測 N4b 走正式的面板控制器）。
  assert.match(route, /guard DMBrowserNewTabKey\.matches\(event\), window\.isKeyWindow else \{ return event \}\s*if isComposing\(in: window\) \{ return event \}\s*guard !store\.isEditingDirectKeys,\s*GlobalDMDuoLayout\.showsBrowser\(form: form, browsing: store\.isBrowsing, browsingBeside: store\.isBrowsingBeside,\s*hasTabs: browser\.hasTabs, hasSecondary: hasSecondary\) else \{ return event \}\s*GlobalHotkeyMonitor\.shared\.cancelPendingChord\(\)[^\n]*\n\s*browser\.newTab\(\)\s*return nil/);
  assert.doesNotMatch(code(route), /store\.isBrowsing \|\| store\.isBrowsingBeside|as\? NSTextView/);
  assert.match(panels, /static func isComposing\(in window: NSWindow\) -> Bool \{\s*guard let text = window\.firstResponder as\? NSTextInputClient else \{ return false \}\s*return text\.hasMarkedText\(\)\s*\}/);
  assert.equal((panels.match(/if isComposing\(in: window\) \{ return event \}/g) ?? []).length, 2, 'both ⌘⌥T and Esc use the same composing check');
  assert.match(desk, /static func showsBrowser\(form: GlobalDMForm, browsing: Bool, browsingBeside: Bool, hasTabs: Bool, hasSecondary: Bool\) -> Bool \{\s*if form == \.tent \{ return false \}\s*guard form\.isDuo else \{ return browsing \}\s*return rightColumnShowsBrowser\(browsing: browsing, browsingBeside: browsingBeside, hasTabs: hasTabs, hasSecondary: hasSecondary\)/);
  assert.match(deskViews, /if GlobalDMDuoLayout\.rightColumnShowsBrowser\(browsing: primary\.isBrowsing, browsingBeside: primary\.isBrowsingBeside,\s*hasTabs: browser\.hasTabs, hasSecondary: secondary != nil\) \{/);
  assert.match(desk, /var hasSecondary: Bool \{ created != nil \|\| defaults != nil \}/);
  // 守（主導 #6）：⌥⌘T 不能設成直達鍵（直達鍵是全系統熱鍵，會先拿走這一下）。
  assert.match(desk, /"T": "⌥⌘T 是私訊框 Browser 的「新分頁」"/);
  assert.match(phone, /static let keyCode: UInt16 = 17/);
  assert.match(phone, /event\.type == \.keyDown && event\.keyCode == keyCode\s*&& event\.modifierFlags\.intersection\(\[\.command, \.option, \.control, \.shift\]\) == \[\.command, \.option\]/);
  assert.doesNotMatch(code(panels) + code(phone), /RegisterEventHotKey\([^)]*kVK_ANSI_T|addGlobalMonitorForEvents\(matching: \.keyDown/);
  // 守：自測拿真的鍵盤事件（排進 App 的事件佇列）走同一條 routeNewTab。
  assert.match(acceptance, /GlobalDMPanelController\.routeNewTab\(event, window: window, store: store, form: form\(\), browser: browser,\s*hasSecondary: true\)/);
  // 守（W184 G2c 第二輪，測試缺口）：另外用正式的 GlobalDMPanelController.install／uninstall＋正式的 ⌥⌘ 手勢偵測量（N4b）。
  assert.match(sidebarAcceptance, /let panels = GlobalDMPanelController\(store: store, desk: settings, hostsWindows: true,/);
  assert.match(sidebarAcceptance, /chord\.install\(\)[^\n]*\n\s*panels\.install\(\)\s*desk\.install\(\)/);
  assert.match(sidebarAcceptance, /desk\.uninstall\(\)\s*panels\.uninstall\(\)\s*chord\.uninstall\(\)/);
  assert.match(sidebarAcceptance, /final class ComposingClient: NSView, NSTextInputClient \{/);
});
