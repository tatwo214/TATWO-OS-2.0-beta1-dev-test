import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// W184 F45（使用者 09-29 晚看了 v2.0.21.030）：
// F4「我看快捷改讓人自定義好了 不要讓ai費工了」：換形態的鍵在直達鍵頁自己設（預設 ⌥⌘Tab）。
// F5「右下小視窗的時候圓鈕展開成視窗 再縮回圓鈕 不要同時存在」：框開著桌面圓鈕不出現；圓鈕長成框、框縮回圓鈕。
// 原始碼契約；實際註冊、取樣、轉向、減少動態效果、外殼沒有內容、畫面證據在 `TATWO2_SELFTEST=w184button`。
const read = (name) => readFileSync(new URL('../App/Sources/Tatwo2/' + name, import.meta.url), 'utf8');
const code = (source) => source.replace(/\/\/[^\n]*/g, '').replace(/\/\*[\s\S]*?\*\//g, '');
const slice = (source, start, end) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = source.indexOf(end, from + start.length);
  assert.ok(to > from, `missing ${end} after ${start}`);
  return source.slice(from, to);
};

const book = read('DM/GlobalDMFormKey.swift');
const hotkeys = read('DM/GlobalDMHotKeys.swift');
const desk = read('DM/GlobalDMDesk.swift');
const views = read('DM/GlobalDMDeskViews.swift');
const phone = read('DM/GlobalDMPhoneBox.swift');
const deskController = read('DM/GlobalDMDeskController.swift');
const panels = read('DM/GlobalDMPanelController.swift');
const morph = read('DM/GlobalDMButtonMorph.swift');

test('F4 form key: stored as one key name, default Tab, bad or reserved values fall back, same rules both ways', () => {
  // 守：只存鍵名；沒存＝Tab（沒改過的人照舊 ⌥⌘Tab）；回到預設＝拿掉記錄。
  assert.match(book, /static let storageKey = "tatwo2\.globalDM\.formKey"/);
  assert.match(book, /static let standard: GlobalDMDirectKey = \.tab/);
  assert.match(book, /if key == standard \{ defaults\.removeObject\(forKey: storageKey\) \} else \{ defaults\.set\(key\.rawValue, forKey: storageKey\) \}/);
  // 守：讀的時候壞值、系統保留鍵（直達鍵的擋鍵清單）、不是英文字母或數字＝Tab。
  const load = slice(book, 'static func load(from defaults: UserDefaults) -> GlobalDMDirectKey {', '\n    }\n');
  assert.match(load, /GlobalDMDirectKeyRules\.blocked\[key\.rawValue\] == nil, key\.isAssignable else \{ return standard \}/);
  // 守：換形態那一列：Tab 可以；系統保留鍵擋；只收英文字母或數字；已經是直達鍵＝不行、說出是哪一個。
  const verdict = slice(book, 'static func verdict(_ key: GlobalDMDirectKey, directKeys:', '\n    }\n');
  assert.match(verdict, /if key == standard \{ return \.ok \}/);
  assert.match(verdict, /guard key\.isAssignable else \{ return \.unsupported \}/);
  assert.match(verdict, /return \.taken\(key, by: owner\)/);
  // 守：直達鍵那一邊照目前換形態的鍵擋（不是寫死 Tab），說明寫「⌥⌘<鍵> 已經用來「換私訊框的形態」」。
  assert.ok(!slice(desk, 'static let blocked: [String: String] = [', ']').includes('"Tab":'), 'Tab is no longer a fixed entry');
  assert.match(desk, /if key == formKey \{ return \.blocked\(key, reason: formKeyReason\(key\)\) \}/);
});

test('F4 hotkeys: the form key registers only while the box shows; changing it probes, saves and re-registers; reset goes back to Tab', () => {
  assert.match(hotkeys, /@Published private\(set\) var formKey: GlobalDMDirectKey/);
  assert.match(hotkeys, /init\(backend: GlobalDMHotKeyBackend, formDefaults: UserDefaults = \.standard\)/);
  assert.match(hotkeys, /if isBoxShowing \{ entries\.append\(\(key: formKey, action: \.cycleForm\)\) \}/);
  const assign = slice(hotkeys, 'func assignFormKey(keyCode: UInt16, store: GlobalDMStore) -> GlobalDMDirectKeyVerdict {', '\n    }\n');
  assert.match(assign, /let verdict = GlobalDMFormKeyBook\.verdict\(key, directKeys: store\.directKeys\)/);
  assert.match(assign, /if key != GlobalDMFormKeyBook\.standard, !probe\(key\) \{ return \.occupied\(key\) \}/);
  const set = slice(hotkeys, 'private func setFormKey(_ key: GlobalDMDirectKey) {', '\n    }\n');
  assert.match(set, /formKey = key\s*GlobalDMFormKeyBook\.save\(key, to: formDefaults\)\s*refresh\(\)/);
  assert.match(hotkeys, /func resetFormKey\(\) \{\s*guard formKey != GlobalDMFormKeyBook\.standard else \{ return \}\s*setFormKey\(GlobalDMFormKeyBook\.standard\)/);
});

test('F4 direct-key page: a 換形態 row with the current key, 更改 (same recorder), 回到預設; the menu shows the current key', () => {
  const page = slice(views, 'struct GlobalDMDirectKeyPage: View {', 'final class GlobalDMKeyCapture');
  // 守：列在直達鍵頁的最上面；識別碼 tatwo.dm.keys.form／.key／.set／.reset。
  assert.match(page, /VStack\(spacing: 1\) \{\s*formRow[^\n]*\n\s*ForEach\(targets, id: \\\.self\) \{ row\(\$0\) \}/);
  for (const id of ['"tatwo.dm.keys.form"', '"tatwo.dm.keys.form.key"', '"tatwo.dm.keys.form.reset"']) assert.ok(page.includes(id), id);
  assert.match(page, /chip\("更改", identifier: "form\.set"\) \{ capture\.beginForm\(store: store, hotkeys: hotkeys\) \}/);
  // 守（查核 #6）：「換形態」那一列本身照目前的鍵畫（不是整頁找得到 GlobalDMKey(key.display) 就好：row() 也有同一行）：
  // 鍵＝hotkeys.formKey、被佔用看這個鍵、鍵帽與無障礙標籤都是它；改過才有回到預設。
  const formRow = slice(views, 'private var formRow: some View {', 'private func row(');
  assert.match(formRow, /let key = hotkeys\.formKey\n/);
  assert.match(formRow, /let occupied = hotkeys\.failed\.contains\(key\)/);
  assert.match(formRow, /GlobalDMKey\(key\.display\)\s*\.accessibilityLabel\(key\.display\)\s*\.accessibilityIdentifier\("tatwo\.dm\.keys\.form\.key"\)/);
  assert.match(formRow, /if key != GlobalDMFormKeyBook\.standard \{\s*Button \{ hotkeys\.resetFormKey\(\) \}/);
  // 守：同一套等鍵（不另做錄鍵器）：beginForm 走同一個 begin（只收這個面板、熱鍵暫停、Esc 不設了）。
  const capture = slice(views, 'final class GlobalDMKeyCapture', 'struct GlobalDMWindowReader');
  assert.match(capture, /func beginForm\(store: GlobalDMStore, hotkeys: GlobalDMHotKeys\) \{\s*begin\(\.form, store: store, hotkeys: hotkeys\)/);
  assert.match(capture, /enum Slot: Equatable \{ case target\(GlobalDMTarget\), form \}/);
  // 守：不做任意修飾鍵組合（跟直達鍵一樣只收單按或剛好 ⌥⌘）。
  assert.match(capture, /guard modifiers\.isEmpty \|\| modifiers == \[\.command, \.option\] else \{ return event \}/);
  // 守：右鍵選單寫目前的鍵（標題、被佔用的說明）。
  assert.match(phone, /var formKey: GlobalDMDirectKey = GlobalDMFormKeyBook\.standard/);
  assert.match(phone, /"形態（\\\(state\.formKey\.display\) 依序換）"/);
  // 守（查核 #11）：選單、直達鍵頁、圓鈕右鍵、熱鍵、擋鍵說明都不寫死換形態的鍵（兩種順序都擋：App 顯示用的是 ⌥⌘，舊寫法是 ⌘⌥；註解不算）。
  for (const [name, source] of [['GlobalDMPhoneBox', phone], ['GlobalDMDeskViews', views], ['GlobalDMDeskController', deskController],
    ['GlobalDMHotKeys', hotkeys], ['GlobalDMDesk', desk]]) {
    assert.doesNotMatch(code(source), /(⌘⌥|⌥⌘)Tab/, `no hard-coded ⌥⌘Tab / ⌘⌥Tab in ${name}`);
  }
  for (const source of [views, phone]) assert.doesNotMatch(code(source), /\.blue\b|accentColor|borderedProminent|\.bordered\b/);
});

test('F5 the desktop bubble never shows while the floating box is open; the box grows from it and shrinks back into it', () => {
  // 守：縮成圓鈕時框開著＝圓鈕不出現（collapse 當下框開著也不出現）；位置照圓鈕面板算（藏著也算）。
  assert.match(deskController, /if !store\.isFloatingOpen \{ panel\.orderFrontRegardless\(\) \}/);
  assert.match(deskController, /private var bubbleAnchor: NSRect\? \{\s*guard isCollapsed, let bubble else \{ return nil \}/);
  // 守：收起接在 store 改值的那一刻（不 receive(on:)：SwiftUI 拿掉內容的那一格外殼已經在）。
  const wire = slice(deskController, 'private func wireButtonMorph() {', '\n    }\n');
  assert.match(wire, /store\.\$isFloatingOpen\s*\.sink \{/);
  assert.doesNotMatch(wire, /receive\(on:/);
  assert.match(wire, /guard let self, !open, self\.store\.isFloatingOpen else \{ return \}\s*morph\?\.closing\(\)/);
  assert.match(wire, /return self\.isCollapsed && !self\.store\.isFloatingOpen/);
  // 守：恢復主視窗、App 結束＝取消（圓鈕不回來）；換形態、換螢幕＝先到位。
  assert.match(slice(deskController, 'private func endCollapse() {', '\n    }\n'), /panels\.buttonMorph\.cancel\(\)/);
  assert.match(slice(deskController, 'func setForm(_ form: GlobalDMForm, animated: Bool = true) -> Bool {', '\n    }\n'), /panels\.buttonMorph\.finish\(\)[^\n]*\n\s*if transition\.style != \.instant \{ panels\.prepareForm\(\) \}/);
  // 守（查核 #10）：換螢幕的 observer 先叫 finish()（長、縮到一半＝直接到位）再照新螢幕擺圓鈕（不然外殼飛向舊位置、圓鈕在新位置出現）。
  assert.match(deskController, /self\?\.panels\.buttonMorph\.finish\(\)[^\n]*\n\s*self\?\.placeBubble\(\)/);
  // 守（查核 #1）：長、縮途中按到外殼或圓鈕本來的位置＝點圓鈕（同一個開關、走 closing()／presented() 的轉向）；App 結束時拿掉。
  assert.match(wire, /morph\.onClick = \{ \[weak self\] in self\?\.bubbleClicked\(\) \}/);
  assert.match(slice(deskController, 'func uninstall() {', '\n    }\n'), /panels\.buttonMorph\.onClick = nil/);
  assert.match(deskController, /private func bubbleClicked\(\) \{\s*guard store\.isEnabled else \{ return \}\s*if store\.isFloatingOpen \{ store\.isFloatingOpen = false \} else \{ store\.openFloating\(\) \}/);
  // 守：面板控制器只在開框、收框的入口接：出現之前先藏內容、出現之後長；收起（orderOut 之前）縮。
  const show = slice(panels, 'private func showFloating(focus: Bool) {', '\n    }\n');
  assert.match(show, /buttonMorph\.prepare\(panel\)[^\n]*\n[\s\S]*if !panel\.isVisible \{ panel\.orderFrontRegardless\(\) \}\s*refreshBrowserPlacement\(\)\s*if focus \{ panel\.makeKey\(\) \}\s*buttonMorph\.presented\(panel\)/);
  const hide = slice(panels, 'private func hideFloating() {', '\n    }\n');
  assert.match(hide, /buttonMorph\.dismiss\(floating\)[^\n]*\n[^\n]*\n\s*floating\.orderOut\(nil\)/);
  // 守（W184 AB 補查核 #3）：收框的內容淡出途中先不收（淡完 buttonMorph 叫整理）；收掉之後才把淡出的內容透明度還回 1。
  assert.match(hide, /guard !buttonMorph\.isClearing\(floating\) else \{ return \}[^\n]*\n\s*buttonMorph\.dismiss\(floating\)/);
  assert.match(hide, /floating\.orderOut\(nil\)\s*buttonMorph\.hidden\(floating\)/);
  assert.match(slice(panels, 'func install() {', '\n    }\n'), /buttonMorph\.onCleared = \{ \[weak self\] in self\?\.reconcile\(\) \}/);
});

test('W184 AB (F45 #3): closing from bubble mode fades the content out first (0.10 s), the shell under the box, then puts the box away and shrinks; reopening mid-fade turns back', () => {
  const view = read('DM/GlobalDMView.swift');
  // 內容淡出這段時間 GlobalDMFloatingRoot 照樣留著框的內容（store 已經說收起）。
  assert.match(slice(view, 'struct GlobalDMFloatingRoot: View {', '\n}\n'), /if store\.isFloatingOpen \|\| morph\.keepsContent \{\s*GlobalDMBoxHost\(store: store, surface: \.floating, form: desk\.form\)/);
  assert.match(morph, /var keepsContent: Bool \{ phase == \.clearing \}/);
  assert.match(morph, /static let clearOut: Double = 0\.10/);
  // 收的那一刻：停著＝先淡出（長、淡入到一半、換形態途中照舊直接縮）。
  const closing = slice(morph, 'func closing() {', '\n    }\n');
  assert.match(closing, /if phase == \.growing \|\| phase == \.fadingIn \|\| \(panel\.contentView as\? GlobalDMPanelCanvas\)\?\.stage != nil \{\s*return shrink\(panel, bubble: bubbleWindow\)\s*\}\s*clear\(panel, bubble: bubbleWindow\)/);
  const fn = (name) => slice(morph, `private func ${name}(`, '\n    }\n');
  const clear = fn('clear'), finishClearing = fn('finishClearing'), unclear = fn('unclear'), fadeContentOut = fn('fadeContentOut');
  // 外殼停在框的位置、墊在框下面；內容淡 0.10 秒（減少動態效果＝框本身淡 reduceOut、沒有外殼）；t＝0 在外殼建好之後；點擊區擺上；排計時器。
  assert.match(clear, /let built = clearStyle == \.morph \? makeShell\(/);
  assert.ok(clear.indexOf('makeShell(') < clear.indexOf('startedAt = clock()'), 'clear: startedAt after makeShell');
  assert.match(clear, /clearLength = clearStyle == \.morph \? GlobalDMMorphTiming\.clearOut : GlobalDMMorphTiming\.reduceOut/);
  assert.match(clear, /shell\.place\(boxRect\)\s*shell\.panel\.order\(\.below, relativeTo: panel\.windowNumber\)/);
  assert.match(clear, /fadeContentOut\(view, length: clearLength\)/);
  assert.match(clear, /showCatcher\(at: circle, level: bubbleWindow\.level\)/);
  assert.match(clear, /phase = \.clearing\s*schedule\(\)$/);
  assert.doesNotMatch(code(clear), /flush|layoutSubtreeIfNeeded|displayIfNeeded/);
  assert.match(fadeContentOut, /1 - GlobalDMEase\.step\(0, length, \$0\)/);
  assert.match(fadeContentOut, /view\.alphaValue = 0/);
  assert.doesNotMatch(code(fadeContentOut), /flush/);
  // 淡完：同一個外殼從框的位置開始縮（或圓鈕淡入），然後才請面板控制器收框。
  assert.match(finishClearing, /let plan = GlobalDMMorphPlan\(from: clearRect, to: circle, direction: \.shrink\)/);
  assert.match(finishClearing, /front\(shell\.panel\)\s*phase = \.shrinking/);
  assert.match(finishClearing, /bringBubbleBack\(at: GlobalDMMorphTiming\.reduceOut\)/);
  assert.ok(finishClearing.indexOf('onCleared?()') > finishClearing.indexOf('schedule()'), 'finishClearing: the box is put away after the next part started');
  assert.match(slice(morph, 'func tick() {', '\n    }\n'), /if phase == \.clearing \{[^\n]*\n[^\n]*\n\s*guard t >= clearLength - 0\.001 else \{ return manualTime \? show\(at: t\) : schedule\(\) \}\s*return finishClearing\(\)/);
  // 淡出途中又打開：內容從當下的透明度淡回來、外殼與點擊區拆掉。
  assert.match(slice(morph, 'func prepare(_ panel: NSWindow) {', '\n    }\n'), /if phase == \.clearing, box === panel, panel\.isVisible \{ return unclear\(panel\) \}/);
  assert.match(unclear, /let shown = 1 - GlobalDMEase\.step\(0, clearLength, t\)/);
  assert.match(unclear, /shell\?\.remove\(\)\s*shell = nil\s*hideCatcher\(\)/);
  assert.match(unclear, /reveal\(view, at: t, length: back\) \{ shown \+ \(1 - shown\) \* GlobalDMEase\.step\(0, back, \$0\) \}/);
  // 淡出過的內容等框收掉才還原（dismiss 不在 orderOut 之前還原）。
  assert.match(slice(morph, 'func dismiss(_ panel: NSWindow) {', '\n    }\n'), /if panel\.contentView !== cleared \{ release\(panel\.contentView\) \}/);
  assert.match(slice(morph, 'func hidden(_ panel: NSWindow) {', '\n    }\n'), /guard let view = cleared, view === panel\.contentView else \{ return \}\s*cleared = nil\s*release\(view\)/);
});

test('F5 the shell: same spring as the form change, corner 22 → 52, content late, no picture of the box, reduce motion fades', () => {
  const body = code(morph);
  // 守：同一條彈簧（GlobalDMSpring；CASpringAnimation 由 GlobalDMFormStage.spring 建：質量 1、stiffness ω²、damping 2ω），0.6 秒到位。
  assert.match(morph, /maxX = GlobalDMSpring\(origin: rect\.maxX, velocity: speed\.maxX, target: target\.maxX\)/);
  assert.match(morph, /replace\(layer, "w", GlobalDMFormStage\.spring\("bounds\.size\.width", segment\.width, begin: begin\)\)/);
  assert.match(morph, /static var settle: Double \{ DMPhone\.Slide\.settle \}/);
  // 守：圓角＝min(52, 短邊的一半)（圓鈕 44＝22 的圓 → 框 52）。
  assert.match(morph, /min\(DMPhone\.screenRadius, max\(0, min\(size\.width, size\.height\) \/ 2\)\)/);
  // 守：內容後段才淡入（0.36 秒起 0.16 秒；施工單約 0.12–0.22 秒）。
  assert.match(morph, /static let contentIn: Double = 0\.36/);
  assert.match(morph, /static let contentFade: Double = 0\.16/);
  // 守：轉向＝從當下的位置與速度接著走（不排隊、不跳）。
  assert.match(morph, /segments\.append\(GlobalDMMorphSegment\(start: t, direction: direction, from: current\.rect\(at: tau\),\s*speed: current\.speed\(at: tau\), to: target\)\)/);
  // 守：外殼不拍框的內容：這個檔沒有任何拍畫面的呼叫；圖層的內容只有紙紋。
  assert.doesNotMatch(body, /cacheDisplay|bitmapImageRepForCachingDisplay|CGWindowListCreateImage|\.capture\(|screenshot|dataWithPDF/);
  assert.deepEqual(body.match(/\.contents = [^\n]*/g), ['.contents = paper']);
  assert.equal((body.match(/render\(in: cg\)/g) || []).length, 1);
  assert.match(body, /backing\.render\(in: cg\)/);
  // 守：外殼面板不拿焦點（不會變成 key、不啟用 App）、所有桌面都在；只有位置、大小、圓角、透明度的動畫（沒有 transform／3D／縮放）。
  assert.match(morph, /override var canBecomeKey: Bool \{ false \}/);
  assert.match(morph, /styleMask: \[\.borderless, \.nonactivatingPanel\]/);
  assert.match(morph, /panel\.collectionBehavior = \[\.canJoinAllSpaces, \.fullScreenAuxiliary, \.ignoresCycle\]/);
  assert.doesNotMatch(body, /CATransform3D|\.transform\s*=|sublayerTransform|\.mask\s*=|scaleEffect|rotation/);
  // 守（查核 #1，取代原本的「外殼不接滑鼠」）：點外殼＝點圓鈕（開↔收）。外殼面板完全不設 ignoresMouseEvents（true＝點擊穿到後面的 App、
  // 剛開的框被搶走鍵盤焦點；false＝整塊透明的面板都接）；外殼的 hitTest 只認 presentation 的圓角矩形；面板不是 key 也收第一下；按下就算。
  const shellInit = slice(morph, 'init(frame: CGRect, surface: GlobalDMFormStage.Surface, manual: Bool) {', '\n    }\n');
  assert.doesNotMatch(shellInit, /ignoresMouseEvents/);
  const shellView = slice(morph, 'final class GlobalDMMorphShellView: NSView {', '\n}\n');
  assert.match(shellView, /override func hitTest\(_ point: NSPoint\) -> NSView\? \{\s*guard let window, let path = shape\?\(\) else \{ return nil \}[\s\S]*path\.contains\([^\n]*\) \? self : nil/);
  assert.match(shellView, /override func acceptsFirstMouse\(for event: NSEvent\?\) -> Bool \{ true \}/);
  assert.match(shellView, /override func mouseDown\(with event: NSEvent\) \{ withExtendedLifetime\(window\) \{ \(\) -> Void in onPress\?\(\) \} \}/);
  assert.match(morph, /view\.shape = \{ \[weak self\] in self\?\.presentedPath \}/);
  assert.match(morph, /var presentedPath: CGPath \{\s*let rect = presentedRect/);
  assert.match(morph, /shell\.view\.onPress = \{ \[weak self\] in self\?\.pressed\(\) \}/);
  assert.match(morph, /private func pressed\(\) \{ onClick\?\(\) \}/);
  // 守（查核 #1）：圓鈕本來的位置在長、縮途中是一塊看不見的點擊區（連點圓鈕的第二下、縮回途中點圓鈕的位置）：什麼都不畫所以明確
  // ignoresMouseEvents = false、只認圓形、層級同圓鈕；長、縮、淡入、淡出開始時擺上，停下（到位、取消、換螢幕、換形態）拿掉。
  const catcherView = slice(morph, 'final class GlobalDMMorphCatcherView: NSView {', '\n}\n');
  assert.match(catcherView, /NSBezierPath\(ovalIn: bounds\)\.contains\(local\) \? self : nil/);
  assert.match(catcherView, /override func mouseDown\(with event: NSEvent\) \{ withExtendedLifetime\(window\) \{ \(\) -> Void in onPress\?\(\) \} \}/);
  const makeCatcher = slice(morph, 'private func makeCatcher() -> GlobalDMMorphShellPanel {', '\n    }\n');
  assert.match(makeCatcher, /panel\.ignoresMouseEvents = false/);
  assert.match(makeCatcher, /view\.onPress = \{ \[weak self\] in self\?\.pressed\(\) \}/);
  assert.equal((code(morph).match(/ignoresMouseEvents/g) || []).length, 1, 'only the catcher sets ignoresMouseEvents');
  const fn = (name) => slice(morph, `private func ${name}(`, '\n    }\n');
  const grow = fn('grow'), shrinkBody = fn('shrink'), fadeIn = fn('fadeIn'), fadeOut = fn('fadeOut'), settle = fn('settle');
  for (const [name, source] of [['grow', grow], ['shrink', shrinkBody], ['fadeIn', fadeIn], ['fadeOut', fadeOut]]) {
    assert.match(source, /showCatcher\(at: [^\n]*level: bubbleWindow\.level\)/, `${name} puts the click spot on the bubble`);
  }
  assert.match(settle, /shell = nil\s*hideCatcher\(\)/);
  // 守（查核 #2）：t＝0 在外殼（面板、紙紋）建好之後才取、外殼的時間原點也在那之後換算：建窗花的時間不算進動畫（第一格就是起點）。
  for (const [name, source] of [['grow', grow], ['shrink', shrinkBody], ['fadeOut', fadeOut]]) {
    const built = source.indexOf('makeShell('), started = source.indexOf('startedAt = clock()');
    assert.ok(built > 0 && started > built, `${name}: startedAt is taken after makeShell`);
    assert.match(source, /shell\.begin\(at: startedAt\)/, `${name}: the shell's time origin comes from that startedAt`);
  }
  assert.doesNotMatch(code(morph), /let now = clock\(\)|startedAt = now|start: startedAt/);
  assert.match(morph, /func begin\(at start: CFTimeInterval\) \{[\s\S]*origin = manual \? 1_000 : root\.convertTime\(start, from: nil\)/);
  // 守（查核 #5）：正式只有計時器會收尾（外殼拆掉、圓鈕回來）：長、縮、淡入、淡出（含兩個轉向）結尾都排計時器；tick 沒在推時鐘就再排；
  // 計時器加進主執行緒的 common 模式（捲動、拖曳時照樣會叫）。
  for (const [name, source] of [['grow', grow], ['shrink', shrinkBody], ['fadeIn', fadeIn], ['fadeOut', fadeOut]]) {
    assert.match(source, /\n\s*schedule\(\)$/, `${name} ends by scheduling the timer`);
  }
  assert.equal((grow.match(/return schedule\(\)/g) || []).length, 1, 'grow: the turn schedules too');
  assert.equal((shrinkBody.match(/return schedule\(\)/g) || []).length, 1, 'shrink: the turn schedules too');
  assert.match(slice(morph, 'func tick() {', '\n    }\n'), /guard t < end else \{ return settle\(showBubble: true\) \}\s*if manualTime \{ show\(at: t\) \} else \{ schedule\(\) \}/);
  const schedule = fn('schedule');
  assert.match(schedule, /guard !manualTime, phase != \.idle else \{ return \}/);
  assert.match(schedule, /let timer = Timer\(timeInterval: interval, repeats: false\)/);
  assert.match(schedule, /RunLoop\.main\.add\(timer, forMode: \.common\)/);
  // 守（查核 #7）：長的時候外殼在真的框後面（開始、轉向兩處）：框的內容淡入要蓋在外殼上；收的時候外殼在前面（蓋住剛拿掉內容的框）。
  assert.equal((grow.match(/shell\.panel\.order\(\.below, relativeTo: panel\.windowNumber\)/g) || []).length, 2);
  assert.match(shrinkBody, /front\(shell\.panel\)/);
  // 最前面＝浮動：這一層的最前面；停靠（W184 AB）：擺在停靠框或主視窗的正上方（不蓋到別的 App 的視窗）。
  assert.match(slice(morph, 'private func front(_ panel: NSWindow) {', '\n    }\n'), /if let above = anchor\?\(\) \{\s*panel\.order\(\.above, relativeTo: above\.windowNumber\)\s*\} else \{\s*panel\.orderFrontRegardless\(\)\s*\}/);
  // 守：減少動態效果、不同螢幕＝淡入淡出，不長不縮。
  assert.match(morph, /guard !reduceMotion else \{ return \.fade \}/);
  assert.match(morph, /guard let first = screen\(bubble\), let second = screen\(box\), first == second else \{ return \.fade \}/);
  assert.match(morph, /var reduceMotion: @MainActor \(\) -> Bool = \{ NSWorkspace\.shared\.accessibilityDisplayShouldReduceMotion \}/);
  // 守：收的那一刻（可能在 willSet 裡）不 flush、不碰框的畫面。
  const shrink = slice(morph, 'private func shrink(_ panel: NSWindow, bubble bubbleWindow: NSWindow) {', '\n    }\n');
  assert.doesNotMatch(code(shrink), /flush|layoutSubtreeIfNeeded|displayIfNeeded|display\(/);
  // 守：縮是從「看得到的框」開始（換形態途中＝F3 台上的框，不是整塊畫布）；圓鈕的位置在動畫開始那一刻讀面板的 frame（不另存）。
  assert.match(shrink, /let boxRect = Self\.visibleBox\(of: panel\)/);
  assert.match(morph, /if let canvas = panel\.contentView as\? GlobalDMPanelCanvas, let stage = canvas\.stage \{ return stage\.presentedBox \}/);
  assert.match(shrink, /let circle = bubbleWindow\.frame\.insetBy\(dx: margin, dy: margin\)/);
  const presented = slice(morph, 'func presented(_ panel: NSWindow) {', '\n    }\n');
  assert.match(presented, /let target = panel\.frame\.insetBy\(dx: margin, dy: margin\)\s*let circle = bubbleWindow\.frame\.insetBy\(dx: margin, dy: margin\)/);
});

test('executable self-test w184button covers the brief', () => {
  const self = read('SelfTest.swift');
  assert.match(self, /TATWO2_SELFTEST"\] == "w184button" \{ GlobalDMButtonMorphAcceptance\.launch\(\); return \}/);
  const acceptance = read('DM/GlobalDMButtonMorphAcceptance.swift') + read('DM/GlobalDMDockedMorphAcceptance.swift');
  assert.match(acceptance, /^#if DEBUG/);
  assert.match(read('DM/GlobalDMDockedMorphAcceptance.swift'), /^#if DEBUG/);
  assert.match(read('DM/GlobalDMButtonMorphAcceptance.swift'), /await dockedMorphChecks\(check, freshDefaults, model: fixture\.model\)/);
  assert.match(acceptance, /NativeStagingIsolation\.validationError\(environment\) == nil/);
  assert.match(acceptance, /isolated engine homes must be logged out/);
  for (const label of ['K1 nothing stored: the form key is ⌥⌘Tab', 'K1 a stored key reads back (S); broken values and system or TATWO keys',
    'K2 box showing: ⌥⌘Tab is registered and cycles the form', 'K3 changed to ⌥⌘S: registered right away, ⌥⌘Tab no longer changes the form',
    'K3 the chosen key survives a relaunch', 'K4 folding the box releases the custom key too',
    'K5 the form key cannot take a direct key', 'K5 a direct key cannot take the form key', 'K6 system and TATWO keys',
    'K7 a key another app holds is refused and not saved', 'K8 the page circle\'s menu shows the current key',
    'K9 回到預設 brings ⌥⌘Tab back', 'K10 the direct-key page has a 換形態 row showing ⌥⌘Tab', 'K11 the 換形態 row uses the same recorder',
    'M0 not collapsed: the floating box opens directly as before', 'M13 collapsing while the box is open: the desktop bubble does not show',
    'M13 closing it: the box shrinks into the bubble', 'M4 collapsed with the box folded: the desktop bubble shows',
    'M1 the shell corner', 'M2 grow (model)', 'M2 the real box\'s content stays transparent early', 'M2 shrink (model)',
    'M3 turning mid-grow keeps the position and the speed', 'M5 open: the bubble hides and the shell starts on the bubble',
    'M5 open sampled at 0.05 / 0.12 / 0.25 / 0.44 / 0.6 s', 'M5 open: the real box\'s content is transparent at 0.05 / 0.12 / 0.25 s',
    'M6 while the box is open the desktop bubble is never on screen', 'M6 with the box open, a reconcile or a screen change does not bring the bubble back',
    'M5 once it is in place the shell is taken down',
    'M7 the shell holds no picture of the box', 'M7 drawn: the middle of the shell mid-grow is plain paper',
    'M8 close: the shell starts on the box', 'M8 close: the bubble stays hidden until the shell arrives',
    'M8 close: when the shell arrives the bubble shows', 'M9 closing mid-grow turns the same shell around',
    'M9 opening mid-shrink grows back from where the shell is', 'M10 a form change mid-grow', 'M11 a bubble moved elsewhere',
    'M12 reduce motion, open', 'M12 reduce motion, close', 'M14 restoring the main window mid-grow takes the shell down at once',
    'saveFrames(openFrames, prefix: "morph-open"', 'saveFrames(closeFrames, prefix: "morph-close"', '["0.05", "0.12", "0.25"]',
    'keys-page-default.png', 'keys-page-form-key.png', 'W184BUTTON SUMMARY failures=',
    // W184 AB（使用者 09-30：停靠時主視窗裡的私訊鈕跟框同時存在）：停靠的圓鈕 ↔ 停靠框，同一套外殼。
    'N0 (W184 AB, user 09-30 on .031) docked box closed', 'N1 open: the docked button hides and the shell starts on it',
    'N1 open sampled at 0.05 / 0.12 / 0.25 / 0.44 / 0.6 s', 'N1 open: the docked box\'s content is transparent', 'N1 order: at every sample the shell is behind the docked box',
    'N1 once in place the shell is taken down', 'N2 the docked button and the open docked box are never on screen together',
    'N3 close: the content fades out first', 'N3 close: after the fade the box is put away and the shell shrinks into the button',
    'N3 close: when the shell arrives the button shows again', 'N6 pressing the shrinking shell is pressing the button',
    'N5 the main window moving mid-grow', 'N4 reduce motion, open', 'N4 reduce motion, close',
    'N7 (GPT-6 third review #1) moving the main window during the close', 'N8 (GPT-6 third review #2) moving the main window while the box shrinks',
    'N9 (GPT-6 third review #3) resizing only the main window', 'N10 (GPT-6 third review #4) the docked shell and click spot stay on the main window',
    'N11 (S5B) docked → floating hand-off']) {
    assert.ok(acceptance.includes(label), label);
  }
  assert.doesNotMatch(acceptance, /check\(true,/);
  // 守：自測不看這台的「減少動態效果」設定（固定關；M12 自己打開），量內容時內縮超過圓角 52（只比框的中間）。
  assert.match(acceptance, /morph\.reduceMotion = \{ false \}/);
  assert.match(acceptance, /static let inkInset: CGFloat = 60/);
  // 守：畫面證據照點畫（NSGraphicsContext(bitmapImageRep:) 已經照 rep.size 對到像素，不再自己放大一次），而且每一格都驗過外殼畫在對的地方。
  assert.ok(!code(acceptance).includes('scaleBy(x: 2, y: 2)'), 'no second 2x scale on evidence bitmaps');
  assert.match(morph, /let scale = rep\.size\.width \/ region\.width/);
  for (const label of ['M5 evidence frames (0.05 / 0.12 / 0.25 s) draw the shell where its layers are',
    'M8 evidence frames (0.05 / 0.12 / 0.25 s) draw the shell where its layers are']) {
    assert.ok(acceptance.includes(label), label);
  }
  // 守（W184 F45 查核）：每一條查核都有一個退步就會失敗的自測，而且沒有默默不驗的分支（沒跑也記 skip）。
  for (const label of [
    // #1 長、縮途中按外殼／圓鈕的位置＝點圓鈕
    'M17 pressing the shrinking shell is pressing the bubble', 'M17 pressing the growing shell (where the real box does not cover it)',
    'M17 a double-click on the bubble: the second click',
    // #2、#5 真的時鐘：計時器自己收尾；t＝0 在外殼建好之後
    'M15 real clock, open: t = 0 is taken after the shell is built', 'M15 real clock, close', 'M15 real clock, reduce motion',
    // #4、#6 直達鍵頁那一列（不靠無障礙樹）
    'K10 drawn (no accessibility tree needed)', 'K10（改鍵後）無障礙樹拿不到識別碼', 'K10（改鍵後）直達鍵頁畫不出來',
    // #7 外殼在真的框後面、0.44 秒、證據照真實順序
    'M5 order: at every sample', 'M9 order: growing back, the shell goes behind the real box again', 'morph-open-0.44.png',
    // #8 轉向接著原本的速度、圖層照新的一段走
    'carrying its speed (still growing a moment, then back', 'carrying its speed (still shrinking a moment, then growing',
    // #10 長、縮到一半換螢幕
    'M16 a screen change mid-grow puts it straight at its end', 'M16 a screen change mid-shrink puts it straight at its end']) {
    assert.ok(acceptance.includes(label), label);
  }
  // 守（查核 #8）：轉向的速度要真的比方向（>／<），不是「差不到 60pt」這種速度歸零也會過的門檻。
  assert.ok(!acceptance.includes('abs(next.height - after.height) < 60'), 'no loose 60pt speed check');
  assert.match(acceptance, /next\.height > after\.height && onNew16 && onNew30/);
  assert.match(acceptance, /next\.height < after\.height && onNew16 && onNew30/);
  assert.equal((acceptance.match(/let onNew16 = model16\.map \{ near\(next, \$0, 1\) \} \?\? false, onNew30 = model30\.map \{ near\(later, \$0, 1\) \} \?\? false/g) || []).length, 2);
  // 守（查核 #5）：真的時鐘那一段不推時鐘也不叫 tick()（正式只有計時器）。
  const real = slice(acceptance, 'static func realClockChecks(', '// MARK: - 畫面證據');
  assert.match(real, /morph\.manualTime = false\s*morph\.clock = \{ CACurrentMediaTime\(\) \}/);
  assert.doesNotMatch(real, /morph\.tick\(\)|morph\.show\(at:|clock\.now =/);
  // 守（查核 #10）：換螢幕是在長、縮到一半時發（不是停著的時候）。
  const screen = slice(acceptance, '// M16（查核 #10）', '// M10：');
  assert.equal((screen.match(/morph\.show\(at: 0\.12\)\s*NotificationCenter\.default\.post\(name: NSApplication\.didChangeScreenParametersNotification/g) || []).length, 2);
});

// W184 AB（使用者 09-30 在 MacBook 實測 .031：「停靠時主視窗裡的私訊鈕跟框同時存在」）：停靠框開著時主視窗裡那顆圓鈕不出現；
// 打開＝從它長成框、收起＝縮回它；同一套外殼（F45：只畫紙紋底色、不拍內容）；減少動態效果＝淡入淡出。
test('W184 AB docked: the main-window DM button and the open docked box never show together; open grows from it, close shrinks back (same F45 shell)', () => {
  const view = read('DM/GlobalDMView.swift');
  // 面板控制器另一個 GlobalDMButtonMorph：圓鈕＝停靠的圓鈕（停靠顯示中才有）、框＝停靠框。
  assert.match(panels, /let dockedMorph = GlobalDMButtonMorph\(\)/);
  const attach = slice(panels, 'private func attachDocked(to window: NSWindow, from old: GlobalDMDockedPresence, to new: GlobalDMDockedPresence) {', '\n    }\n');
  // 框開著：圓鈕只擺位置、不掛上；出現之前內容先藏、出現之後長；沒有在長（第一次、不能長）就直接藏圓鈕。
  assert.match(attach, /dockedMorph\.prepare\(panel\)[^\n]*\n\s*attach\(panel, to: window, frame: box\.insetBy\(dx: -margin, dy: -margin\)\)\s*dockedMorph\.presented\(panel\)[^\n]*\n\s*if !dockedMorph\.holdsBubble \{ hideDockedButton\(button\) \}/);
  // 框收著：收起的淡出、縮回途中圓鈕等外殼到位才回來；平常照舊掛回主視窗。
  assert.match(attach, /detachBox\(from: window\)\s*if dockedMorph\.holdsBubble \{[\s\S]*?\} else \{\s*attach\(button, to: window, frame: buttonFrame\)\s*\}/);
  assert.equal((attach.match(/attach\(button,/g) || []).length, 1, 'the button is attached only when the box is closed');
  // 收框：淡出途中先不收（淡完 dockedMorph 叫整理）；收的那一刻沒接到的在這裡接；收掉之後內容透明度才還原。主視窗不見了＝不縮、外殼直接拆。
  const detach = slice(panels, 'private func detachBox(from window: NSWindow?, animated: Bool = true) {', '\n    }\n');
  assert.match(detach, /if animated \{\s*guard !dockedMorph\.isClearing\(panel\) else \{ return \}\s*dockedMorph\.dismiss\(panel\)[^\n]*\n\s*\} else \{\s*dockedMorph\.cancel\(\)\s*\}/);
  assert.match(detach, /panel\.orderOut\(nil\)[\s\S]*dockedMorph\.hidden\(panel\)/);
  assert.match(slice(panels, 'private func detachDocked() {', '\n    }\n'), /dockedMorph\.cancel\(\)[^\n]*\n\s*detachBox\(from: docked\?\.parent, animated: false\)/);
  // 接線：收起接在 store 改值的那一刻（不 receive(on:)）；外殼跟主視窗同一層（.normal）、擺在停靠框或主視窗正上方；圓鈕照子視窗的方式藏、放回。
  const wire = slice(panels, 'private func wireDockedMorph() {', '\n    }\n');
  assert.doesNotMatch(wire, /receive\(on:/);
  assert.match(wire, /store\.\$isOpen\s*\.sink \{ \[weak self\] open in\s*guard let self, !open, self\.store\.isOpen else \{ return \}\s*self\.dockedMorph\.closing\(\)/);
  assert.match(wire, /morph\.shellLevel = \.normal/);
  assert.match(wire, /if let docked = self\.docked, docked\.isVisible \{ return docked \}\s*return self\.visibleMainWindow\(\)/);
  assert.match(wire, /morph\.hideBubble = \{ \[weak self\] window in self\?\.hideDockedButton\(window\) \}/);
  assert.match(wire, /morph\.showBubble = \{ \[weak self\] window in self\?\.showDockedButton\(window\) \}/);
  assert.match(wire, /return self\.dockedShown && !self\.store\.isOpen/);
  assert.match(wire, /self\.store\.toggleDocked\(\)/);
  assert.match(slice(panels, 'func install() {', '\n    }\n'), /guard hostsWindows else \{ return \}\s*wireDockedMorph\(\)/);
  assert.match(slice(panels, 'private func hideDockedButton(_ window: NSWindow) {', '\n    }\n'), /window\.parent\?\.removeChildWindow\(window\)/);
  // 換形態、主視窗移動：長、縮到一半＝先到位。
  assert.match(slice(panels, 'func prepareForm() {', '\n    }\n'), /if dockedMorph\.isAnimating \{ dockedMorph\.finish\(\) \}/);
  assert.match(slice(panels, 'func applyForm(_ transition: GlobalDMFormTransition) {', '\n    }\n'), /if dockedMorph\.isAnimating \{ dockedMorph\.finish\(\) \}[^\n]*\n\s*endGrip\(\)/);
  // 停靠框的內容在收起的淡出途中照樣留著。
  assert.match(slice(view, 'struct GlobalDMDockedBoxRoot: View {', '\n}\n'), /if store\.isOpen \|\| morph\.keepsContent \{\s*GlobalDMBoxHost\(store: store, surface: \.docked, form: desk\.form\)/);
  // 外殼那一邊：層級、最前面、圓鈕的藏與放回都可以換（浮動框照舊：.floating、最前面、orderOut／orderFrontRegardless）。
  assert.match(morph, /var shellLevel: NSWindow\.Level = \.floating/);
  assert.match(morph, /if shell\.panel\.level != shellLevel \{ shell\.panel\.level = shellLevel \}/);
  assert.match(slice(morph, 'private func hide(_ bubbleWindow: NSWindow) {', '\n    }\n'), /if let hideBubble \{ hideBubble\(bubbleWindow\) \} else \{ bubbleWindow\.orderOut\(nil\) \}/);
  assert.match(slice(morph, 'private func show(_ bubbleWindow: NSWindow) {', '\n    }\n'), /if let showBubble \{ showBubble\(bubbleWindow\) \} else \{ bubbleWindow\.orderFrontRegardless\(\) \}/);
  assert.doesNotMatch(code(morph), /bubbleWindow\.orderOut\(nil\)\n|bubbleWindow\.orderFrontRegardless\(\)\n\s*\}\n\s*if let layer = bubbleContent/);
  assert.match(slice(morph, 'var holdsBubble: Bool {', '\n    }\n'), /case \.idle: false\s*case \.fadingOut: !bubbleBack\s*case \.growing, \.shrinking, \.fadingIn, \.clearing: true/);
  // GPT-6 第三輪 #1：淡出途中被叫直接到位＝這一次收框算完成（圓鈕回來、請面板控制器收框；自己的整理裡叫的不再通知），收的時候不再縮。
  assert.match(slice(morph, 'func finish(notify: Bool = true) {', '\n    }\n'), /let closing = phase == \.clearing \? box : nil\s*settle\(showBubble: true\)\s*guard let closing else \{ return \}\s*putAway = closing\s*if notify \{ onCleared\?\(\) \}/);
  assert.match(slice(morph, 'func dismiss(_ panel: NSWindow) {', '\n    }\n'), /if putAway === panel \{\s*putAway = nil[^\n]*\n\s*\} else if panel === box, panel\.isVisible/);
  // #1–#3：停靠的長、縮、淡出途中主視窗移動、改大小、換螢幕、全螢幕＝整理裡看到主視窗換了就直接到位（淡出中＝那一輪接著收框）。
  const reconcile = slice(panels, '    func reconcile() {', '\n    }\n');
  assert.match(reconcile, /if dockedMorph\.isAnimating, let started = dockedMorphContent, visibleMainWindow\(\)\.map\(mainContent\(of:\)\) != started \{\s*dockedMorph\.finish\(notify: false\)\s*\}/);
  assert.ok(reconcile.indexOf('dockedMorph.finish(notify: false)') < reconcile.indexOf('attachDocked(to: window'), 'finish before placing');
  assert.match(panels, /guard self\.dockedMorph\.isAnimating \|\| \(self\.canvasPanel != nil && self\.canvasPanel === self\.docked\) else \{ return \}\s*self\.reconcile\(\)/);
  assert.match(wire, /morph\.\$phase\s*\.sink \{ \[weak self\] phase in[\s\S]*?self\.dockedMorphContent = nil[\s\S]*?self\.dockedMorphContent = self\.visibleMainWindow\(\)\.map\(self\.mainContent\(of:\)\)/);
  // #2：放回圓鈕照「現在」的主視窗重算位置。
  assert.match(slice(panels, 'private func showDockedButton(_ window: NSWindow) {', '\n    }\n'), /let frame = dockedPlacement\(in: main\)\.placement\.button\.insetBy\(dx: -GlobalDMLayout\.margin, dy: -GlobalDMLayout\.margin\)\s*attach\(panel, to: main, frame: frame\)/);
  // #4：停靠的外殼與點擊區只在主視窗那個桌面；切桌面＝直接到位、拆掉。
  assert.match(wire, /morph\.joinsAllSpaces = false/);
  assert.match(morph, /static let localSpaces: NSWindow\.CollectionBehavior = \[\.fullScreenAuxiliary, \.ignoresCycle\]/);
  assert.match(morph, /if !joinsAllSpaces \{ shell\.panel\.collectionBehavior = Self\.localSpaces \}/);
  assert.match(slice(morph, 'private func showCatcher(at circle: CGRect, level: NSWindow.Level) {', '\n    }\n'), /let spaces: NSWindow\.CollectionBehavior = joinsAllSpaces \? Self\.allSpaces : Self\.localSpaces/);
  assert.match(wire, /NSWorkspace\.activeSpaceDidChangeNotification[\s\S]*?guard let self, self\.dockedMorph\.isAnimating else \{ return \}\s*self\.dockedMorph\.finish\(notify: false\)\s*self\.reconcile\(\)/);
  assert.match(slice(panels, 'func uninstall() {', '\n    }\n'), /for observer in workspaceObservers \{ NSWorkspace\.shared\.notificationCenter\.removeObserver\(observer\) \}/);
  // S5B：換手時收起那一邊不淡出（頁面與配對碼搬到另一個框，淡出中的那一份會在沒有頁面的框裡照樣畫碼）。
  assert.match(wire, /store\.\$isFloatingOpen\s*\.sink \{ \[weak self\] open in\s*guard let self, open, !self\.store\.isFloatingOpen, self\.dockedMorph\.phase == \.clearing else \{ return \}\s*self\.dockedMorph\.finish\(notify: false\)/);
  assert.match(wire, /guard let self, open, !self\.store\.isOpen, self\.buttonMorph\.phase == \.clearing else \{ return \}\s*self\.buttonMorph\.finish\(notify: false\)/);
});
