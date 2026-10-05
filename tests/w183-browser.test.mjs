// W183 R8b：私訊框的 Browser（第三顆圓鈕、手機式瀏覽器、授權頁都開在這裡）——原始碼契約。
// 使用者 09-28 晚：「私訊鈕授權在上方tatwoos跟chatgpt圓鈕新增一欄bowser，以手機ui去搭建瀏覽器，然後授權一率從那邊就不會遺失」
// 「我人不在主設備 我根本按不了授權 可是這些都是我的設備」「私訊鈕的UI邏輯 一率當成手機做搭建」。
// 實際行為在 App 自測 TATWO2_SELFTEST=w183browser（DM/DMBrowserAcceptance.swift）與 w183ui、w183connect（lead-verify 在 mini 跑）。
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
// W184 D（GPT-6 審查 #1）：以視窗計數的「不給擷取」搬到自己的檔（最後一個放手之後再擋到最後一幀）。
const shieldFile = swift('DM/WindowCaptureShield.swift');
const view = swift('DM/DMBrowserView.swift');
const acceptance = swift('DM/DMBrowserAcceptance.swift');
const presenter = swift('New/HandsConnectDMView.swift');
const podDriver = swift('TAP/ChatGPTConnectorPod.swift');
const store = swift('DM/GlobalDMStore.swift');
const gate = swift('Browser/BrowserSensitivePage.swift');
const setup = swift('Facade/HandsSetup.swift');
const remote = swift('Facade/HandsRemote.swift');
const selftest = swift('SelfTest.swift');

test('entry DMBrowser: open(url:purpose:), openPod(purpose:), close(purpose:), markDone(purpose:); flow pages only from their flows (W184 G2: typing only opens new general tabs)', () => {
  for (const signature of ['func open(url: URL, purpose: DMBrowserPurpose,', 'func openPod(purpose: DMBrowserPurpose = .chatgptDeveloper,',
    'func close(purpose: DMBrowserPurpose, keepingDone: Bool = false)', 'func markDone(purpose: DMBrowserPurpose)',
    'func adoptPopup(_ page: any DMBrowserPage, key: Int,', 'func focusPopup(key: Int)']) {
    assert.ok(browser.includes(signature), signature);
  }
  for (const purpose of ['case cloudflareLogin = "cloudflare_login"', 'case chatgptDeveloper = "chatgpt_developer"', 'case chatgptPairing = "chatgpt_pairing"',
    'case chatgptLogin = "chatgpt_login"']) {
    assert.ok(browser.includes(purpose), purpose);
  }
  // 對照稿的分頁名字。
  assert.match(browser, /case \.cloudflareLogin: "Cloudflare"\n\s*case \.chatgptDeveloper: "ChatGPT Dev"/);
  // 起點照用途驗（Cloudflare＝HandsCloudflared.loginURL 驗過的；Pod、配對頁不能用網址開）。
  assert.match(browser, /case \.cloudflareLogin: return GlobalDMWebSheet\.cloudflareAuthorization\(url\)\?\.url\n\s*case \.chatgptDeveloper, \.chatgptPairing, \.chatgptLogin: return nil/);
  // 流程的頁只從流程的入口開（沒有能改流程分頁網址的網址列）、不另開視窗、不用 WKWebView、不寫檔。
  assert.doesNotMatch(code(view) + code(browser), /TextField\(|NSWindow\(|NSPanel\(|WKWebView|UserDefaults|FileManager|print\(|NSLog/);
  // W184 G2（使用者 09-29 要在私訊框打網址或搜尋）：打的字只開**新的一般分頁**（openBrowse、用途 browse），不在 Pod、配對、授權分頁裡導航；
  // 流程的入口不收一般網頁（validatedStart 對 browse 回 nil）。W184 G2d：輸入框是主視窗 Browser space 的元件——頂列的網址欄
  // （EmbeddedBrowserToolbar）與沒分頁時置中的搜尋框（BrowserStartSearch）；私訊框自己不做輸入框，兩個都送到同一條 open(_:)。
  const rail = swift('DM/DMBrowserRail.swift');
  const chrome = swift('DM/DMBrowserChrome.swift');
  assert.equal((code(rail) + code(chrome)).match(/TextField\(/g), null, 'no DM-only text field (the inputs are the Browser space components)');
  assert.match(chrome, /EmbeddedBrowserToolbar\(addressText: \$address, addressFieldFocused: focused,/);
  assert.match(view, /BrowserStartSearch\(query: \$draft, focus: \$searchFocus, field: \.search,/);
  assert.match(view, /private func submitSearch\(\) \{ open\(draft\) \}\s*private func submitAddress\(\) \{ open\(address\) \}/);
  // W184 G2c 第二輪：送出帶著開始打字的那一頁（typedInto）——只開在那一個空白分頁上，換過頁＝開新分頁。
  assert.match(view, /finish\(browser\.openBrowse\(url: url, title: DMBrowserBrowseInput\.title\(for: text, url: url, engine: engine\), origin: \.typed,\s*typedInto: editTarget\)\)/);
  assert.match(browser, /case \.browse: return nil/);
  assert.doesNotMatch(code(rail) + code(swift('DM/DMBrowserSpaces.swift')), /NSWindow\(|NSPanel\(|WKWebView|UserDefaults|FileManager|print\(|NSLog/);
  // 分頁數有上限。
  assert.match(browser, /static let maxTabs = 6/);
});

test('opening: the DM box opens by itself, switches to Browser, the tab is in front; all tabs gone → the box goes back as it was', () => {
  const open = between(browser, 'func open(url: URL, purpose: DMBrowserPurpose,', 'func openPod(');
  assert.match(open, /BrowserSensitivePageGate\.pageAppeared\(\)[^\n]*\n\s*reveal\(tab\.id\)\n\s*startWebPage\(tab\.id, url: start\)/);
  const reveal = between(browser, 'private func reveal(_ id: UUID) {', 'private func restoreBox() {');
  // W184 AB（GPT-6 複核 新發現 1）：開框是一個請求；框真的開好之後才切到 Browser、把分頁叫到前面。
  assert.match(reveal, /then: \{ \[weak self\] in self\?\.bringToFront\(id\) \}\)[\s\S]*openRequest\(request\)/);
  assert.match(reveal, /private func bringToFront\(_ id: UUID\) \{\s*store\.showBrowser\(\)\s*activeID = id\s*isShowingTabList = false\s*place\(focus: true\)/);
  const remove = between(browser, 'private func removeTab(', 'private func update(');
  assert.match(remove, /if tabs\.isEmpty \{\s*isShowingTabList = false\s*if restoring \{ restoreBox\(\) \}/);
});

test('tabs never vanish on their own: box closed or hidden = page taken off screen, not destroyed; done = labelled; flow end = caller closes; master switch off = all close', () => {
  const place = between(browser, 'private func place(focus: Bool = false) {', 'private func focusActive() {');
  assert.match(place, /let target = isShowingTabList \? nil : containers\.last\?\.view/);
  assert.match(place, /if tab\.id == activeID, let target \{ page\.attach\(to: target\) \} else \{ page\.detach\(\) \}/);
  assert.doesNotMatch(code(browser), /handoff|asyncAfter|Task\.sleep|Timer/);
  const release = between(browser, 'func release(_ container: NSView) {', 'func containerMoved()');
  assert.doesNotMatch(release, /removeTab|close\(/);
  // W183 R8b 審查（GPT-6、Claude）：完成＝標「完成」、頁面關掉（網頁銷毀、Pod 交回、配對頁關掉）、分頁留著；網址、上一頁／下一頁清掉。
  assert.match(browser, /func markDone\(purpose: DMBrowserPurpose\) \{\s*for tab in tabs where tab\.purpose == purpose \{\s*retire\(tab\.id, done: true, note: nil\)/);
  const retire = between(browser, 'private func retire(', 'private func removeTab(');
  assert.match(retire, /pageTasks\.removeValue\(forKey: id\)\?\.cancel\(\)\s*if let page = pages\.removeValue\(forKey: id\) \{\s*page\.detach\(\)\s*page\.close\(\)/);
  assert.match(retire, /\$0\.pageClosed = true[\s\S]*\$0\.pageURL = nil[\s\S]*\$0\.canGoBack = false\s*\$0\.canGoForward = false/);
  assert.match(browser, /for tab in tabs where tab\.purpose == purpose && !\(keepingDone && tab\.done\) \{\s*removeTab\(tab\.id\)/);
  // 總開關關掉＝全關、還沒完成的流程走取消（連線流程只取消一次）；程序收尾 closeAll() 只關。
  assert.match(browser, /if !enabled \{ self\?\.closeAll\(cancelling: true\) \}/);
  const closeAll = between(browser, 'func closeAll(cancelling: Bool = false) {', '// MARK: - 使用者在 Browser 上按的');
  assert.match(closeAll, /if cancelling \{\s*for tab in tabs where !tab\.done \{/);
  assert.match(closeAll, /if tab\.purpose\.isConnect \{\s*if connectCancelled \{ continue \}/);
  assert.ok(closeAll.indexOf('for tab in tabs { removeTab(tab.id) }') < closeAll.indexOf('for cancel in cancels { cancel() }'));
  // 使用者關還沒完成的分頁＝取消那個流程；完成的只關。
  assert.match(browser, /let cancel = tab\.done \? nil : cancelActions\[id\]\s*removeTab\(id\)\s*cancel\?\(\)/);
  // 畫面：完成的分頁標「完成」；分頁總覽每個分頁一張卡、可關。W184 D：卡片格裡寫綠勾「完成」、右上一顆圓形 ×（對照稿 Outer-Tabs）。
  assert.match(view, /if tab\.done \{\s*Label\("完成", systemImage: "checkmark\.circle\.fill"\)/);
  assert.match(view, /Button \{ browser\.userClose\(tab\.id\) \} label: \{\s*Image\(systemName: "xmark"\)/);
  assert.match(view, /\.help\(browser\.closingCancels\(tab\.id\) \? "關掉這個分頁（這一次還沒完成，會一起取消）" : "關掉這個分頁"\)/);
  // 頁面關掉的分頁＝原生卡片（完成／確認中），不是網頁。
  assert.match(view, /if let tab = browser\.activeTab, tab\.pageClosed \{ closedView\(tab\) \}/);
  // W184 D：兩欄卡片格（間距 12＝DMBrowserPhone.gridSpacing）。
  assert.match(view, /LazyVGrid\(columns: \[GridItem\(\.flexible\(\), spacing: DMBrowserPhone\.gridSpacing\), GridItem\(\.flexible\(\), spacing: DMBrowserPhone\.gridSpacing\)\]/);
});

test('address pill follows the real page; not https or wrong domain is flagged; device chip; back/forward; float card under ChatGPT tabs', () => {
  // W183 R8b 審查（GPT-6）：網址 pill 只照實際載入的 http／https；沒有＝「尚未確認來源」（不拿起點或該在的網域頂替、不給鎖頭）。
  assert.doesNotMatch(code(browser), /shownURL|\?\? expectedHost|pageURL \?\? startURL/);
  assert.match(browser, /var sourceKnown: Bool \{ !pageClosed && pageURL != nil \}/);
  assert.match(browser, /var displayHost: String \{ sourceKnown \? pageURL\.map\(GlobalDMWebSheet\.displayHost\) \?\? "" : "" \}/);
  assert.match(browser, /return pageURL == nil \? "尚未確認來源" : displayHost/);
  assert.match(browser, /var isInsecure: Bool \{ sourceKnown && pageURL\.map \{ !GlobalDMWebSheet\.isSecure\(\$0\) \} == true \}/);
  assert.match(browser, /return !\(host == expected \|\| host\.hasSuffix\("\." \+ expected\)\)/);
  assert.match(browser, /\$0\.pageURL = frame\.url\.flatMap \{ GlobalDMWebPageState\.committed\(\$0\.absoluteString\) \}/);
  assert.match(browser, /\$0\.pageURL = state\.committedURL/);
  assert.match(view, /if !tab\.sourceKnown \{ return "questionmark\.circle" \}\s*return warn \? "exclamationmark\.triangle\.fill" : "lock\.fill"/);
  assert.match(view, /Text\("不是 \\\(expected\)"\)/);
  assert.match(view, /Text\("連線不安全"\)/);
  assert.match(view, /Text\("這台：\\\(DMBrowser\.deviceName\)"\)/);
  assert.match(browser, /static let deviceName: String = \{\s*if let name = \(try\? DeviceIdentityStore\.readLocal\(\)\)\?\.name/);
  // W184 G2d：上一頁、下一頁、網址那一格＝主視窗 Browser space 的導覽列（EmbeddedBrowserToolbar）接私訊框的分頁：上一頁／下一頁照分頁、
  // 網址只照實際載入的頁（對不上、不是 https 寫出來；頂列平常不在，頁面頂上另有一直看得到的警告小標）；「這台：<名稱>」在 ⋯ 裡。
  const chrome = swift('DM/DMBrowserChrome.swift');
  assert.match(chrome, /canGoBack: tab\.canGoBack && !tab\.pageClosed, canGoForward: tab\.canGoForward && !tab\.pageClosed/);
  assert.match(chrome, /case \.goBack: browser\.goBack\(\)\s*case \.goForward: browser\.goForward\(\)/);
  assert.match(chrome, /Button\("這個 Browser 在這台：\\\(DMBrowser\.deviceName\)"\) \{\}\.disabled\(true\)/);
  assert.match(view, /if tab\.hostMismatch, let expected = tab\.expectedHost \{ return "\\\(tab\.displayHost\)・不是 \\\(expected\)" \}/);
  assert.match(gate, /if top\.canGoBack \{ top\.goBack\(\) \} else \{ popTop\(\) \}/);
  assert.match(gate, /if let committed, !committed\.isEmpty \{ state\.committedURL = GlobalDMWebPageState\.committed\(committed\) \}/);
  assert.doesNotMatch(between(gate, 'private func publish() {', 'func goBack() {'), /pages\.reversed\(\)/, 'no borrowing the page underneath');
  // 按了［連線］之後的卡片浮在 ChatGPT 分頁（Pod、配對頁）的頁上（配對碼卡片；對照稿）；Cloudflare 授權分頁上不浮。
  // W184 D：浮在頁上（不再把頁面擠短）；碼要不要顯示由 Browser 這一邊當下算（碼綁住的那一頁正在畫面上）。
  // W184 G2：連線的分頁明列（Pod、配對頁、登入視窗）；使用者自己開的一般網頁上也不浮。
  assert.match(view, /return tab\.purpose\.isConnect && connect\.card != nil/);
  assert.match(browser, /var isConnect: Bool \{ self == \.chatgptDeveloper \|\| self == \.chatgptPairing \|\| self == \.chatgptLogin \}/);
  assert.match(view, /let reveals = connect\.revealsCode\(card\) && browser\.holdsPage\(slot\.container\)\s*(?:return )?HandsConnectFloatingCard\(card: card, flow: flow, presenter: connect, revealsCode: reveals\)/);
  // 玻璃、選中才用強調色（W184 D：選中的分頁卡片 2pt 強調色框、其他 0.5 分隔色）；不用藍色。
  assert.match(view, /shape\.strokeBorder\(active \? LiquidGlassTokens\.brandAccent : Color\(nsColor: \.separatorColor\)/);
  assert.doesNotMatch(view, /\.blue\b|accentColor|borderedProminent|\.bordered\b|NSAlert/);
});

test('kinds: web = R5b sensitive CEF page; Pod = claim/release; Pod popup moved into the tab with its native window hidden', () => {
  assert.match(browser, /self\.pageHost = pageHost \?\? GlobalDMCEFWebPageHost\(\)/);
  // W183 R8b 審查（GPT-6、Claude）：Pod 的畫面是受保護的呈現：別的畫面搶不走、每次放進框裡都放回來；拿下來＝停泊；關掉等連接器放掉、帶回首頁。
  const pod = between(browser, 'final class DMBrowserPodPage: DMBrowserPage {', 'final class DMBrowserPopupPage');
  assert.match(pod, /lease = pod\.beginGuardedPresentation\(\)/);
  assert.match(pod, /container\.addSubview\(view\)\n\s*\}\n\s*pod\.showGuarded\(view, lease: lease\)/);
  assert.match(pod, /func detach\(\) \{\s*pod\.showGuarded\(nil, lease: lease\)/);
  assert.match(pod, /settled \{ pod\.endGuardedPresentation\(lease\) \}/);
  assert.match(pod, /self\.settled = settled \?\? \{ ChatGPTConnectorPod\.shared\.whenSettled\(\$0\) \}/);
  assert.doesNotMatch(code(pod), /pod\.claim\(|pod\.release\(|closeBrowser|\.stop\(\)/, 'the Pod itself is never closed by the Browser');
  const webPod = swift('TAP/TapWebPod.swift');
  assert.match(webPod, /var placementTarget: NSView\? \{\s*if !guards\.isEmpty \{ return guards\.last\(where: \{ \$0\.view != nil \}\)\?\.view \}/);
  assert.match(webPod, /let target = placementTarget \?\? parkingView\(\)/);
  assert.match(webPod, /var isHosted: Bool \{ !guards\.isEmpty \|\| hosts\.contains/);
  assert.match(webPod, /if guards\.isEmpty \{ browser\?\.httpsOnly = false \}/);
  assert.match(podDriver, /func whenSettled\(_ body: @escaping @MainActor \(\) -> Void\) \{\s*if hold == nil, releasing == nil \{ return body\(\) \}/);
  assert.match(podDriver, /self\?\.releasing = nil\s*self\?\.flushSettled\(\)/);
  const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
  assert.match(bridge, /policy\.https_only = owner && \(owner\.sensitivePage \|\| owner\.httpsOnly\);/);
  assert.match(read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/include/TatwoCEFBridge.h'), /@property\(atomic\) BOOL httpsOnly;/);
  const popup = between(browser, 'final class DMBrowserPopupPage: DMBrowserPage {', '/// 私訊框的 Browser（一台一個）');
  assert.match(popup, /window\.alphaValue = 0\s*window\.ignoresMouseEvents = true\s*window\.sharingType = \.none\s*window\.orderOut\(nil\)/);
  assert.match(popup, /popup\.browserActor == \.human && !popup\.agentControlled && popup\.sensitivePage/);
  assert.match(popup, /TatwoCEFContainerTeardownContract\.detachFromHostWindow\(popup\)\s*homeWindow\?\.orderOut\(nil\)\s*popup\.closeBrowser\(\)/);
  // Pod 的原生回報照舊給連線流程（onFrame），另給 Browser 一份；敏感 popup 在 CEF 回呼之外交給 Browser。
  assert.match(podDriver, /onFrame\?\(frame\)\n\s*onDisplayFrame\?\(frame\)/);
  assert.match(podDriver, /Task \{ @MainActor \[weak self, weak popup\] in\s*guard let self, let popup, self\.popups\[key\] != nil else \{ return \}\s*self\.onSensitivePopup\?\(popup, key, pairing\)/);
  // W183 R8b 審查（GPT-6）：受保護呈現時開的登入視窗也是敏感頁、也收進 Browser。
  assert.match(podDriver, /let pairing = hold != nil\s*let sensitive = pairing \|\| surface\(\)\?\.isGuardedPresentation == true/);
  assert.match(browser, /if frame\.popup, frame\.closed \{\s*if tab\.pageClosed \{ return \}[^\n]*\n\s*return removeTab\(tab\.id, closing: false\)/);
});

test('protections kept: Computer Use gate while any sensitive tab exists; no screen capture while an unfinished one is on screen; DM switch off closes all', () => {
  assert.match(gate, /static func register\(_ browser: DMBrowser\)/);
  assert.match(gate, /browsers\.contains \{ \$0\.value\?\.isSensitive == true \}/);
  // W183 R8b 審查：還開著的真網頁才算敏感（完成、撤下＝頁面已關）。W184 G2：流程開的分頁才算（一般網頁不是授權頁）。
  assert.match(browser, /var isSensitive: Bool \{ !pageClosed && purpose\.isFlow \}/);
  // W184 D（使用者截私訊框只截到空白；契約 §3b「敏感範圍」已同步）：不給擷取只在授權頁正在畫面上——選中的是還開著的敏感分頁、
  // 分頁總覽沒開、Browser 在框裡看得到（有框接著頁面、框在視窗裡）。Computer Use 閘門照舊看上面的 isSensitive（有就擋，不跟著放寬）。
  assert.match(browser, /var needsCaptureProtection: Bool \{\s*Self\.capturesBlocked\(activeSensitive: activeTab\?\.isSensitive == true, tabList: isShowingTabList, onScreen: shownWindow != nil\)/);
  assert.match(browser, /nonisolated static func capturesBlocked\(activeSensitive: Bool, tabList: Bool, onScreen: Bool\) -> Bool \{\s*activeSensitive && !tabList && onScreen\s*\}/);
  assert.match(browser, /private var shownWindow: NSWindow\? \{ containers\.last\(where: \{ \$0\.view != nil \}\)\?\.view\?\.window \}/);
  // 畫面上的「這一頁不給截圖」小標用同一條規則。
  assert.match(view, /DMBrowser\.capturesBlocked\(activeSensitive: browser\.activeTab\?\.isSensitive == true, tabList: browser\.isShowingTabList, onScreen: true\)/);
  // 不給擷取以視窗計數：Browser 與連線卡片共用 WindowCaptureShield，最後一個放手才還原。
  const capture = between(browser, 'private func protectCapture() {', 'var isProtectingCapture: Bool');
  assert.match(capture, /WindowCaptureShield\.shared\.hold\(self, window: needsCaptureProtection \? window : nil\)/);
  assert.doesNotMatch(code(browser) + code(presenter), /previousSharing|protectedWindow = /);
  // W184 D（GPT-6 審查 #1）：最後一個放手之後再擋 linger 一小段才還原（退場動畫的尾巴、最後一幀）；這段時間又有人持有＝不還原。
  const shield = between(shieldFile, 'final class WindowCaptureShield {', undefined);
  assert.match(shield, /entry\.holders\.insert\(key\)[\s\S]*window\.sharingType = \.none/);
  assert.match(shield, /guard entry\.holders\.isEmpty, entry\.restore == nil else \{ return \}/);
  assert.match(shield, /guard let self, let entry, entry\.holders\.isEmpty else \{ return \}\s*entry\.restore = nil\s*entry\.window\?\.sharingType = entry\.original/);
  assert.match(shield, /entry\.restore\?\.invalidate\(\)[^\n]*\n\s*entry\.restore = nil\s*entry\.holders\.insert\(key\)/);
  assert.doesNotMatch(code(browser), /final class WindowCaptureShield/, 'one shield only');
  // W184 D：連線卡片只在配對碼正在畫面上時持有（碼遮起來、卡片收起來＝放手）；卡片本身不再整段擋。
  assert.match(presenter, /WindowCaptureShield\.shared\.hold\(self, window: codeOnScreen \? cardWindow : nil\)/);
  assert.match(presenter, /var codeOnScreen: Bool \{\s*guard isShown, codeVisible, case \.pairing\(let view\)\? = currentCard\(\), view\.pairingCode != nil else \{ return false \}\s*return showsSurface\(view\.surface\)/);
  assert.match(presenter, /WindowCaptureShield\.shared\.release\(self\)/);
  // 頁面換了位置（換分頁、分頁總覽、框收起來）連線卡片跟著重看。
  assert.match(presenter, /self\.browser\.watchPlacement\(self\) \{ \[weak self\] in self\?\.refreshCodeShield\(\) \}/);
  assert.match(between(browser, 'private func place(focus: Bool = false) {', 'private func focusActive() {'), /protectCapture\(\)\s*placementChanged\(\)/);
  // 配對碼只在綁住的那一頁正是看得到的那一頁時顯示（流程與畫面兩邊都看）。
  // W184 D（GPT-6 審查 #2）：「看得到」照實際呈現——選中、頁面放在框裡、框的視窗看得到、頁面沒被藏、分頁總覽沒開、不在形態轉換中。
  const surface = between(browser, 'func showsSurface(_ surface: Int) -> Bool {', '// MARK: - 入口');
  assert.match(surface, /guard let id = activeID, let tab = tabs\.first\(where: \{ \$0\.id == id \}\), presents\(id\) else \{ return false \}/);
  // （主導轉達房 AB）原生網頁被形態轉換的遮蔽狀態藏著（isMasking）也不算。
  assert.match(surface, /guard !isShowingTabList, !isTransitioning, !isMasking, id == activeID, let page = pages\[id\][\s\S]*page\.view\.superview === container, !page\.view\.isHiddenOrHasHiddenAncestor, windowShown\(window\)/);
  assert.match(surface, /case \.pod: return surface == -1\s*case \.popup\(let key\): return surface == key\s*case \.web: return false/);
  assert.match(swift('Facade/HandsConnect.swift'), /let code = onAuthorizePage && presenter\.showsSurface\(first\.frame\.surface\) \? tx\.pairingCode : nil/);
  // W184 D：卡片畫碼看的是 context.revealsCode（Browser 當下算好給：碼綁住的那一頁正在畫面上）。
  assert.match(presenter, /if let code = view\.spacedCode, context\.revealsCode, left > 0 \{/);
  assert.match(presenter, /func revealsCode\(_ card: HandsConnectCard\) -> Bool \{\s*guard case \.pairing\(let view\) = card else \{ return false \}\s*return showsSurface\(view\.surface\)/);
  for (const opener of ['func open(url: URL, purpose: DMBrowserPurpose,', 'func openPod(purpose:', 'func adoptPopup(']) {
    assert.match(between(browser, opener, '\n    }\n'), /BrowserSensitivePageGate\.pageAppeared\(\)/, opener);
  }
});

test('callers moved to the Browser: HandsSetup login page, secondary auto-open, R6b Pod and pairing page; ［連線］ card stays native', () => {
  assert.match(setup, /if browser\.open\(url: sheet\.url, purpose: \.cloudflareLogin, onCancel: onCancel, fallback:/);
  // W183 R8b 審查（GPT-6）：授權頁的結論一定帶網址；私訊框不收沒有網址的通知；Cloudflare 分頁以起點網址認（不以用途合併、不換掉別的流程的）。
  assert.match(setup, /static func postLoginPagesDone\(only url: URL\)/);
  assert.match(setup, /static func postLoginPagesWithdrawn\(only url: URL\)/);
  assert.match(setup, /guard let url else \{ return \}\s*NotificationCenter\.default\.post\(name: DMBrowser\.loginPagesNotification, object: url, userInfo: \["state": end\.rawValue\]\)/);
  assert.match(browser, /guard let url = note\.object as\? URL else \{ return \}/);
  assert.match(browser, /if let existing = tab\(start: start\) \{/);
  assert.doesNotMatch(between(browser, 'func open(url: URL, purpose: DMBrowserPurpose,', 'func openPod('), /\$0\.purpose == purpose/);
  assert.match(remote, /if let hook = loginPageDone \{ hook\(url\) \} else \{ HandsSetup\.postLoginPagesDone\(only: url\) \}/);
  assert.match(remote, /let otherRun = status\.setupRun != nil && status\.setupRun != openedRun/);
  assert.match(remote, /if authorized, !timedOut, !otherRun, confirming \|\| openedPageWithdrawn, let url = openedLoginURL/);
  // 本機：cloudflared 結束＝頁面先撤下；授權檔驗過、存進鑰匙圈才標「完成」；其他任何退出都收掉（冪等）。
  assert.match(setup, /endLoginRound\(round, withdraw: code == 0\)/);
  assert.match(setup, /defer \{ endLoginRound\(round\); settleLoginPages\(round, done: false\) \}/);
  // W183 R8 整合：R8c 拿掉了 adopt(account:)（登入只是登入），第 3 步的結尾改成下一個宣告（CommandResult）；守的一樣是「驗過、存好才標完成」。
  const authorize = between(setup, 'private func stepAuthorize(', 'private struct CommandResult');
  assert.ok(authorize.indexOf('settleLoginPages(round, done: true)') > authorize.indexOf('try dependencies.accounts.upsert(accountID: cert.accountID'),
    'done only after the cert is parsed and stored');
  assert.ok(authorize.indexOf('settleLoginPages(round, done: true)') > authorize.indexOf('guard let pem = certText, let cert = HandsCloudflared.parseOriginCert(pem)'));
  assert.match(presenter, /browser\.openPod\(purpose: \.chatgptDeveloper, currentURL: podURL\(\), onCancel: cancelFlow\)/);
  // 這一步不用看 Pod＝從分頁拿下來；配對頁的分頁被關掉、總開關關掉＝取消這次連線。
  assert.match(presenter, /guard visible else \{ return browser\.suspendPod\(\) \}/);
  assert.match(presenter, /purpose: pairing \? \.chatgptPairing : \.chatgptLogin,[\s\S]{0,200}onCancel: pairing \? cancel : nil/);
  assert.match(presenter, /guard !enabled, let self, self\.isShown else \{ return \}\s*self\.cancelFlow\(\)/);
  assert.match(presenter, /browser\.focusPopup\(key: key\)/);
  assert.match(presenter, /case \.loading, \.confirm: return false/);
  assert.match(presenter, /struct HandsConnectSheet: View/);
});

test('icon and store: third round icon Browser, target kept, send blocked while browsing', () => {
  assert.match(store, /items\.append\(GlobalDMIconItem\(kind: \.browser, letter: "B", title: "Browser",/);
  assert.match(store, /case \.browser:\s*showBrowser\(\)/);
  assert.match(store, /guard !isBrowsing else \{ return false \}/);
  assert.equal((store.match(/defaults\.set\(/g) ?? []).length, 2, 'Browser state is memory-only');
});

test('self-test w183browser is registered, DEBUG-only, isolated, fakes only, and never reports a fake CEF pass', () => {
  assert.match(selftest, /TATWO2_SELFTEST"\] == "w183browser"[\s\S]{0,300}DMBrowserAcceptance\.run\(\)/);
  assert.match(acceptance, /^#if DEBUG/);
  assert.match(acceptance, /NativeStagingIsolation\.isEnabled\(environment\), NativeStagingIsolation\.validationError\(environment\) == nil/);
  assert.doesNotMatch(acceptance, /DMBrowser\.shared|HandsConnectPresenter\.shared|ChatGPTTap\.shared|ChatGPTConnectorPod\.shared|URLSession/);
  assert.match(acceptance, /check\.skip\("真的 CEF/);
  assert.match(acceptance, /W183BROWSER SUMMARY passed=\\\(check\.passed\) failures=\\\(check\.failed\) skipped=\\\(check\.skipped\)/);
  for (const label of ['第三顆圓鈕', '點 Browser＝框裡換成手機式瀏覽器', 'DMBrowser.open：私訊框自動打開並切到 Browser', '分頁不會自己消失',
    'markDone：分頁標「完成」、頁面關掉', '還沒完成就關＝取消那個流程', '私訊鈕總開關關掉', 'openPod：Pod 的畫面當一個分頁', 'Pod 開出的配對頁 popup 收進分頁',
    '［連線］確認卡蓋在私訊框上', '連線完成＝分頁標「完成」', '授權完成的通知', '授權與配對時不給擷取',
    // W183 R8b 審查的反例
    '兩個流程的授權頁各一個分頁', '「尚未確認來源」', '不給擷取以視窗計數', '取消連線但還沒完成的 Cloudflare 分頁留著',
    '配對碼只在綁住的那一頁正是現在看得到的那一頁時顯示', 'Pod 受保護的呈現', '連接器 whenSettled', '使用者關掉配對頁的分頁＝取消這次連線',
    '流程只在綁住的配對頁正在畫面上時給碼', 'Pod 這一步不用看＝從分頁拿下來']) {
    assert.ok(acceptance.includes(label), label);
  }
  assert.doesNotMatch(acceptance, /check\(true,/);
});
