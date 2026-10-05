import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';

// W179 E 房：桌面圓鈕、展開尺寸、⌥⌘＋自訂鍵、設定開關（spec R7、R8）的原始碼契約。
const read = (name) => readFileSync(new URL('../App/Sources/Tatwo2/' + name, import.meta.url), 'utf8');
const code = (source) => source.replace(/\/\/[^\n]*/g, '');
const slice = (source, start, end) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = source.indexOf(end, from + start.length);
  assert.ok(to > from, `missing ${end} after ${start}`);
  return source.slice(from, to);
};

test('collapse orders the main window out without the close confirmation or an activation-policy change', () => {
  const desk = read('DM/GlobalDMDeskController.swift');
  const collapse = slice(desk, 'func collapse() {', 'func restore() {');
  assert.match(collapse, /machine\.collapse\(enabled: store\.isEnabled, frame: window\?\.frame\)/);
  assert.match(collapse, /window\?\.orderOut\(nil\)/);
  assert.doesNotMatch(code(collapse), /\.close\(\)|performClose|TatwoInterruptConfirmationPresenter/);
  assert.doesNotMatch(code(desk), /setActivationPolicy|TatwoInterruptConfirmationPresenter|performClose|\.close\(\)/);
  // Restore returns to the saved frame; the bubble goes away; a main window shown some other way also restores.
  const restore = slice(desk, 'func restore() {', 'private func mainWindowReturned');
  assert.match(restore, /case \.frame\(let frame\):[\s\S]*window\.setFrame\(restorable\(frame\), display: false\)[\s\S]*makeKeyAndOrderFront/);
  assert.match(restore, /case \.reopen:[\s\S]*\.tatwoOpenWorkOSWindow/);
  // ⌥⌘↑ outside the collapsed state does nothing (it is not even registered then): no activating TATWO.
  const notCollapsed = slice(restore, 'case .notCollapsed:', 'case .frame(');
  assert.doesNotMatch(code(notCollapsed), /activate|makeKeyAndOrderFront|tatwoOpenWorkOSWindow/);
  assert.match(code(notCollapsed), /^case \.notCollapsed:\s*return\s*$/);
  assert.match(desk, /NSWindow\.didBecomeKeyNotification, NSWindow\.didBecomeMainNotification/);
  assert.match(desk, /if case \.frame\(let saved\) = machine\.restore\(\) \{\s*let frame = restorable\(saved\)\s*if window\.frame != frame \{ window\.setFrame\(frame, display: true\) \}/);
  // The saved frame is checked against the screens that exist now (display unplugged / resolution changed).
  assert.match(desk, /GlobalDMDeskLayout\.restorableFrame\(saved: saved, visibleFrames: visibleFrames,/);
  assert.match(desk, /NSScreen\.screens\.map\(\\\.visibleFrame\)/);
  const layout = slice(read('DM/GlobalDMDesk.swift'), 'static func restorableFrame(', 'static func defaultBubbleOrigin');
  assert.match(layout, /if reachable \{ return saved \}/);
  assert.match(layout, /\?\? main/);
  assert.match(layout, /let size = CGSize\(width: min\(saved\.width, target\.width\), height: min\(saved\.height, target\.height\)\)/);
  assert.match(desk, /store\.isFloatingOpen = false\s*bubble\?\.orderOut\(nil\)/);
  // The collapsed state is memory-only: a relaunch always shows the normal main window.
  const logic = read('DM/GlobalDMDesk.swift');
  assert.match(logic, /struct GlobalDMDeskMachine: Equatable/);
  assert.match(logic, /private\(set\) var phase: Phase = \.window/);
  assert.doesNotMatch(slice(logic, 'struct GlobalDMDeskMachine', 'enum GlobalDMOpenAction'), /UserDefaults|defaults\./);
  // Turning the DM off while collapsed brings the main window back.
  assert.match(desk, /guard let self, !enabled, self\.isCollapsed else \{ return \}\s*self\.restore\(\)/);
});

test('desk bubble: 44pt, every Space and full-screen app, draggable, remembered, default bottom-right inset 24', () => {
  const desk = read('DM/GlobalDMDeskController.swift');
  const make = slice(desk, 'private func makeBubble() -> GlobalDMPanel {', 'private func bubbleClicked()');
  assert.match(make, /styleMask: \[\.borderless, \.nonactivatingPanel\]/);
  assert.match(make, /panel\.collectionBehavior = \[\.canJoinAllSpaces, \.fullScreenAuxiliary, \.ignoresCycle\]/);
  assert.match(make, /panel\.canHide = false/);
  assert.match(make, /panel\.hidesOnDeactivate = false/);
  assert.match(make, /panel\.becomesKeyOnlyIfNeeded = true/);
  assert.match(desk, /settings\.saveBubbleOrigin\(GlobalDMDeskLayout\.placeBubble\(saved: dropped/);
  assert.match(desk, /NSScreen\.screens\.first\?\.visibleFrame/);
  const logic = read('DM/GlobalDMDesk.swift');
  assert.match(logic, /static let bubbleInset: CGFloat = 24/);
  assert.match(logic, /CGPoint\(x: visible\.maxX - bubbleInset - GlobalDMLayout\.buttonSize, y: visible\.minY \+ bubbleInset\)/);
  assert.match(logic, /defaults\.set\(\[Double\(origin\.x\), Double\(origin\.y\)\], forKey: Self\.bubbleOriginKey\)/);
  const views = read('DM/GlobalDMDeskViews.swift');
  // Same look as the in-window DM button (reuses GlobalDMRoundButton, 44pt).
  assert.match(views, /GlobalDMRoundButton\(isOpen: store\.isFloatingOpen\) \{\}/);
  assert.match(views, /override func mouseDragged[\s\S]*window\.setFrameOrigin/);
  assert.match(views, /override func rightMouseDown[\s\S]*showMenu\(with: event\)/);
  assert.match(views, /Task\.sleep\(for: \.milliseconds\(550\)\)[\s\S]*self\.showMenu\(with: nil\)/);
  assert.match(views, /setAccessibilityIdentifier\("tatwo\.dm\.desk\.bubble"\)/);
  // Clicking the bubble (or ⌥⌘) opens B's floating box beside the bubble; clicking again closes it.
  assert.match(desk, /if store\.isFloatingOpen \{ store\.isFloatingOpen = false \} else \{ store\.openFloating\(\) \}/);
  const panels = read('DM/GlobalDMPanelController.swift');
  assert.match(panels, /if let bubble = floatingAnchor\?\(\) \{/);
  assert.match(panels, /GlobalDMDeskLayout\.boxBeside\(bubble: bubble, wanted: wanted, visible: visible\)/);
  assert.match(desk, /panels\.floatingAnchor = \{ \[weak self\] in self\?\.bubbleAnchor \}/);
});

test('four forms (W184 AB), proportional shrink to fit, remembered (old sizes mapped); docked and floating boxes follow the form', () => {
  const logic = read('DM/GlobalDMDesk.swift');
  // 守：四種形態的尺寸（W184 spec A1：外直 466×678、內橫 890×626、內直 626×890、倒放 678×466）與 ⌘⌥Tab 的順序（A2）。
  for (const [name, w, h] of [['outerPortrait', 466, 678], ['innerLandscape', 890, 626], ['innerPortrait', 626, 890], ['tent', 678, 466]]) {
    assert.match(logic, new RegExp(`case \\.${name}: CGSize\\(width: ${w}, height: ${h}\\)`), name);
  }
  assert.match(logic, /case \.outerPortrait: \.innerLandscape\s*case \.innerLandscape: \.innerPortrait\s*case \.innerPortrait: \.tent\s*case \.tent: \.outerPortrait/);
  // 守（A4）：舊的四種展開尺寸不再出現；舊值對應：iPhone Duo 打開＝內橫，其他＝外直（沿用同一個鍵，改了才寫）。
  for (const title of ['"私訊框"', '"ChatGPT 快捷視窗"', '"iPhone Duo 闔起"', '"iPhone Duo 打開"']) assert.ok(!logic.includes(title), title);
  assert.match(logic, /return raw == "iPhoneOpen" \? \.innerLandscape : \.outerPortrait/);
  assert.match(logic, /nonisolated static let formKey = "tatwo2\.globalDM\.expandSize"/);
  assert.match(logic, /let scale = min\(1, width \/ size\.width, height \/ size\.height\)/);
  assert.match(logic, /var isDuo: Bool \{ self == \.innerLandscape \}/);
  assert.match(logic, /didSet \{ if form != oldValue \{ defaults\.set\(form\.rawValue, forKey: Self\.formKey\) \} \}/);
  const panels = read('DM/GlobalDMPanelController.swift');
  assert.match(panels, /let wanted = desk\.form\.size/);
  assert.match(panels, /desk\.\$form\.removeDuplicates\(\)/);
  // 守（A1）：停靠框也照目前形態、等比縮（W184 前固定 466×678）。
  assert.match(panels, /boxSize: desk\.form\.size/);
  const layering = read('DM/GlobalDMLayering.swift');
  assert.match(layering, /let tallest = boxSize\.width > maxWidth \? max\(1, \(boxSize\.height \* maxWidth \/ boxSize\.width\)\.rounded\(\.down\)\) : boxSize\.height/);
  const view = read('DM/GlobalDMView.swift');
  // 守（A1）：停靠框、浮動框都照目前形態畫整支手機（面板大小由控制器照形態決定）。
  // W184 F3：換形態的動畫是面板畫布上的圖層台，根畫面一律照形態停著的樣子畫（不再逐格照 motion.frame）。
  assert.match(view, /GlobalDMBoxHost\(store: store, surface: \.floating, form: desk\.form\)/);
  assert.match(view, /GlobalDMBoxHost\(store: store, surface: \.docked, form: desk\.form\)/);
  // 守（A5）：內橫的右欄拿第二個 store（另一個對象的對話）。
  assert.match(view, /GlobalDMPhoneBox\(store: store, model: model, surface: surface, form: form,\s*secondary: form\.isDuo \? GlobalDMDuo\.shared\.secondary : nil\)/);
  assert.match(logic, /GlobalDMStore\(defaults: defaults,\s*refreshChatGPTToolCatalog: refreshChatGPTToolCatalog,\s*directKeys: false\)/);
  assert.match(logic, /static func defaultSecondary\(primary: GlobalDMTarget, sessions: \[UUID\], chatGPTAvailable: Bool\)/);
  // 守（A2）：桌面圓鈕的右鍵／按住選單列四種形態（勾目前的）＋恢復主視窗。
  const desk = read('DM/GlobalDMDeskController.swift');
  const menu = slice(desk, 'func makeBubbleMenu() -> NSMenu {', 'func makeAppMenuItems()');
  assert.match(menu, /NSMenuItem\(title: "展開成"/);
  assert.match(menu, /for form in GlobalDMForm\.allCases \{/);
  assert.match(menu, /item\.state = settings\.form == form \? \.on : \.off/);
  assert.match(menu, /menu\.addItem\(\.separator\(\)\)\s*menu\.addItem\(restoreMenuItem\(\)\)/);
  assert.match(desk, /NSMenuItem\(title: "恢復主視窗"/);
  assert.match(desk, /@objc private func expandFromMenu\(_ sender: NSMenuItem\) \{[\s\S]{0,200}setForm\(form\)/);
});

test('hotkeys use Carbon RegisterEventHotKey (no accessibility permission), registered and removed in pairs', () => {
  const hot = read('DM/GlobalDMHotKeys.swift');
  assert.match(hot, /import Carbon/);
  assert.match(hot, /RegisterEventHotKey\(keyCode, UInt32\(optionKey \| cmdKey\)/);
  assert.match(hot, /OptionBits\(kEventHotKeyExclusive\)/);
  assert.match(hot, /UnregisterEventHotKey\(ref\)/);
  assert.match(hot, /InstallEventHandler\(GetEventDispatcherTarget\(\), globalDMCarbonHotKeyHandler/);
  assert.match(hot, /RemoveEventHandler\(handler\)/);
  assert.doesNotMatch(hot, /AXIsProcessTrusted|addGlobalMonitorForEvents/);
  // Every refresh removes everything first; off / suspended / uninstalled leave nothing registered.
  const refresh = slice(hot, 'private func refresh() {', 'func pressed(');
  assert.match(refresh, /for id in registered\.keys \{ backend\.unregister\(id: id\) \}\s*registered = \[:\]/);
  assert.match(refresh, /guard isInstalled, enabled, !isSuspended else/);
  // W189 DM-02：兩顆箭頭只在 App 前景處理，完全不註冊或探測全系統箭頭。
  assert.doesNotMatch(refresh.split('func handleAppKey')[0], /key: \.up|key: \.down|idleArrow/);
  assert.match(hot, /addLocalMonitorForEvents/);
  assert.match(hot, /handleAppKey\(event, appActive: NSApp\.isActive\)/);
  assert.match(hot, /guard isInstalled, enabled, !isSuspended, appActive/);
  // W184 AB：⌘⌥Tab 只在私訊框看得到時註冊、收起就放掉（不搶別的 App 的鍵）；按下＝換下一個形態。
  // W184 F45：鍵是使用者設的（預設 Tab）；守的不變。
  assert.match(refresh, /if isBoxShowing \{ entries\.append\(\(key: formKey, action: \.cycleForm\)\) \}/);
  assert.match(hot, /var isBoxShowing = false \{ didSet \{ if isBoxShowing != oldValue \{ refresh\(\) \} \} \}/);
  assert.match(read('DM/GlobalDMDesk.swift'), /static let tab = GlobalDMDirectKey\(label: "Tab", code: kVK_Tab\)/);
  const deskWire = read('DM/GlobalDMDeskController.swift');
  assert.match(deskWire, /Publishers\.CombineLatest3\(store\.\$isOpen, store\.\$isFloatingOpen, store\.\$isDockedVisible\)\s*\.map \{ open, floating, docked in floating \|\| \(open && docked\) \}\s*\.removeDuplicates\(\)\s*\.sink \{ \[weak self\] showing in self\?\.hotkeys\.isBoxShowing = showing \}/);
  assert.match(deskWire, /case \.cycleForm: cycleForm\(\)/);
  assert.match(hot, /var isCollapsed = false \{ didSet \{ if isCollapsed != oldValue \{ refresh\(\) \} \} \}/);
  assert.match(hot, /func uninstall\(\) \{[\s\S]*refresh\(\)\s*backend\.deactivate\(\)/);
  assert.match(hot, /store\.\$isEnabled\.dropFirst\(\)/);
  assert.match(hot, /store\.\$directKeys\.dropFirst\(\)/);
  // A Carbon hotkey swallows its keyDown, so the ⌥⌘ chord of that press is cancelled.
  assert.match(hot, /GlobalHotkeyMonitor\.shared\.cancelPendingChord\(\)/);
  const monitor = read('DM/GlobalHotkeyMonitor.swift');
  assert.match(monitor, /func cancelPendingChord\(\) \{\s*detector\.keyDown\(at: ProcessInfo\.processInfo\.systemUptime\)/);
  const shell = read('Shell/AppShell.swift');
  assert.match(shell, /GlobalDMPanelController\.shared\.install\(\)[^\n]*\n\s*GlobalDMDeskController\.shared\.install\(\)/);
  assert.match(shell, /GlobalHotkeyMonitor\.shared\.uninstall\(\)\s*GlobalDMDeskController\.shared\.uninstall\(\)/);
  assert.match(shell, /for item in GlobalDMDeskController\.shared\.makeAppMenuItems\(\) \{ appMenu\.addItem\(item\) \}/);
  const desk = read('DM/GlobalDMDeskController.swift');
  assert.match(desk, /NSMenuItem\(title: "縮成私訊鈕", action: #selector\(collapseFromMenu\(_:\)\),\s*keyEquivalent: Self\.arrowKey\(NSDownArrowFunctionKey\)\)/);
  assert.match(desk, /keyEquivalent: Self\.arrowKey\(NSUpArrowFunctionKey\)\)/);
  assert.match(desk, /case \.collapse: collapse\(\)\s*case \.restore: restore\(\)\s*case \.direct\(let target\): openDirect\(target\)/);
  assert.match(desk, /@Published private\(set\) var isCollapsed = false \{ didSet \{ hotkeys\.isCollapsed = isCollapsed \} \}/);
});

test('direct keys: default ⌥⌘G = ChatGPT, blocked list with plain reasons, conflicts and occupied keys explained', () => {
  const logic = read('DM/GlobalDMDesk.swift');
  const blocked = slice(logic, 'static let blocked: [String: String] = [', ']');
  for (const [name, combo] of [['Esc', '⌥⌘Esc'], ['D', '⌥⌘D'], ['H', '⌥⌘H'], ['M', '⌥⌘M'], ['W', '⌥⌘W'],
    ['Space', '⌥⌘Space'], ['I', '⌥⌘I'], ['Down', '⌥⌘↓'], ['Up', '⌥⌘↑'], ['B', '⌥⌘B'], ['T', '⌥⌘T']]) {
    assert.match(blocked, new RegExp(`"${name}": "${combo} `), combo);
  }
  // W184 G2c 第二輪：⌥⌘T 是私訊框 Browser 的「新分頁」（私訊框自己的按鍵）；設成直達鍵＝全系統熱鍵先拿走、新分頁就按不到。
  assert.match(blocked, /"T": "⌥⌘T 是私訊框 Browser 的「新分頁」"/);
  // 守：換形態的鍵照樣擋（W184 F45：不再寫死 Tab——照目前換形態的鍵動態擋，說明「⌥⌘<鍵> 已經用來「換私訊框的形態」」；預設 Tab）。
  assert.match(logic, /static func formKeyReason\(_ key: GlobalDMDirectKey\) -> String \{ "\\\(key\.display\) 已經用來「換私訊框的形態」" \}/);
  assert.match(logic, /formKey: GlobalDMDirectKey = GlobalDMFormKeyBook\.current\(\)\) -> GlobalDMDirectKeyVerdict \{\s*if let reason = blocked\[key\.rawValue\] \{ return \.blocked\(key, reason: reason\) \}\s*if key == formKey \{ return \.blocked\(key, reason: formKeyReason\(key\)\) \}/);
  // 守（兩個方向都擋）：換形態那一列不能選直達鍵、也不能選系統保留鍵；直達鍵在框裡設時照目前的換形態鍵擋。
  const formBook = read('DM/GlobalDMFormKey.swift');
  assert.match(formBook, /if let reason = GlobalDMDirectKeyRules\.blocked\[key\.rawValue\] \{ return \.blocked\(key, reason: reason\) \}/);
  assert.match(formBook, /if let owner = owners\.first \{ return \.taken\(key, by: owner\) \}/);
  assert.match(read('DM/GlobalDMHotKeys.swift'), /GlobalDMDirectKeyRules\.verdict\(key, for: target, in: store\.directKeys, formKey: formKey\)/);
  // Every ⌥⌘＋letter/digit shortcut TATWO itself uses must be blocked, or the exclusive Carbon hotkey steals it in-app.
  const root = new URL('../App/Sources/Tatwo2/', import.meta.url);
  const walk = (dir) => readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const url = new URL(entry.name + (entry.isDirectory() ? '/' : ''), dir);
    return entry.isDirectory() ? walk(url) : entry.name.endsWith('.swift') ? [url] : [];
  });
  const own = new Set();
  for (const file of walk(root)) {
    const text = readFileSync(file, 'utf8');
    for (const m of text.matchAll(/keyboardShortcut\("([a-z0-9])", modifiers: \[(\.command, \.option|\.option, \.command)\]\)/g)) {
      own.add(m[1].toUpperCase());
    }
  }
  assert.ok(own.has('B'), 'the ⌥⌘B browser toggle is found');
  for (const letter of own) assert.match(blocked, new RegExp(`"${letter}": "⌥⌘${letter} `), `app shortcut ⌥⌘${letter} is blocked`);
  assert.match(logic, /case \.blocked\(_, let reason\): reason \+ "，不能用。"/);
  assert.match(logic, /已經給「\\\(title\(other\)\)」用了/);
  assert.match(logic, /被別的 App 佔用了，換一個鍵試試。/);
  assert.match(logic, /只能用英文字母或數字/);
  assert.match(logic, /guard let chatGPTKey = GlobalDMDirectKey\(rawValue: "G"\) else \{ return \[:\] \}\s*return \[\.chatGPT: chatGPTKey\]/);
  // Keys are physical positions (IME-independent): kVK_ANSI_* codes.
  assert.match(logic, /\("G", kVK_ANSI_G\)/);
  const store = read('DM/GlobalDMStore.swift');
  assert.match(store, /@Published private\(set\) var directKeys: \[GlobalDMTarget: GlobalDMDirectKey\]/);
  assert.match(store, /self\.directKeys = directKeys \? GlobalDMDirectKeyBook\.load\(from: defaults\) : \[:\]/);
  const set = slice(store, 'func setDirectKey(', '// MARK: - 送出');
  assert.match(set, /GlobalDMDirectKeyRules\.verdict\(key, for: target, in: directKeys\)/);
  assert.match(set, /GlobalDMDirectKeyBook\.save\(next, to: defaults\)/);
  const hot = read('DM/GlobalDMHotKeys.swift');
  const assign = slice(hot, 'func assign(keyCode: UInt16', '\n    }\n');
  assert.match(assign, /guard probe\(key\) else \{ return \.occupied\(key\) \}/);
  // Direct key = open (never toggle) per B's docked-vs-floating rule, then switch to that target.
  const desk = read('DM/GlobalDMDeskController.swift');
  // W184 AB（GPT-6 複核 新發現 1）：開框與切對象是同一個請求——框真的開好之後才切（排隊、換手都不會弄丟）。
  assert.match(desk, /func openDirect\(_ target: GlobalDMTarget\) \{\s*guard store\.isEnabled else \{ return \}\s*let store = store\s*panels\.open\(GlobalDMOpenRequest\(then: \{\s*store\.select\(target\)/);
  const panels = read('DM/GlobalDMPanelController.swift');
  const open = slice(panels, 'func open() {', '/// Esc 只關私訊框');
  assert.match(open, /GlobalDMOpenAction\.resolve\(enabled: store\.isEnabled, floatingOpen: store\.isFloatingOpen/);
  assert.match(open, /mainWindowVisible: mainWindowOnScreenForUser\(\) != nil/);
  assert.match(logic, /return docks \? \.openDocked : \.openFloating/);
});

test('in-box key page: picker row, per-row key hints, capture pauses hotkeys, Esc leaves the page', () => {
  const view = read('DM/GlobalDMView.swift');
  const dmStore = read('DM/GlobalDMStore.swift');
  // W180 A3：「設定直達鍵」是框頂圖示列最後一顆（⌘）；ChatGPT 與各 session 的直達鍵寫在圖示說明與 session 清單每列右側。
  assert.match(dmStore, /kind: \.directKeys, letter: "⌘", title: "設定直達鍵…"/);
  assert.match(dmStore, /case \.directKeys:\s*isPickerOpen = false\s*isEditingDirectKeys\.toggle\(\)/);
  assert.match(view, /if store\.isEditingDirectKeys \{\s*GlobalDMDirectKeyPage\(store: store\)/);
  assert.match(dmStore, /help: keyed\("ChatGPT", \.chatGPT\)/);
  assert.match(view, /trailing: keyHint\(target\)/);
  assert.match(view, /if let key = store\.directKeys\[target\] \{ return AnyView\(GlobalDMKey\(key\.display\)\) \}/);
  const views = read('DM/GlobalDMDeskViews.swift');
  assert.match(views, /var list: \[GlobalDMTarget\] = \[\.assistant\] \+ store\.recentSessions\(\)\.map \{ \.thread\(\$0\.id\) \} \+ \[\.chatGPT\]/);
  assert.match(views, /hotkeys\.isSuspended = true\s*monitor = NSEvent\.addLocalMonitorForEvents\(matching: \.keyDown\)/);
  assert.match(views, /hotkeys\?\.isSuspended = false/);
  // 守：按下的鍵照對象存成直達鍵（W184 F45：同一套等鍵多一種「換形態」那一列）。
  assert.match(views, /case \.target\(let target\): verdict = hotkeys\.assign\(keyCode: event\.keyCode, to: target, store: store\)/);
  assert.match(views, /case \.form: verdict = hotkeys\.assignFormKey\(keyCode: event\.keyCode, store: store\)/);
  assert.match(views, /\.onDisappear \{ capture\.end\(\) \}/);
  // Capture is scoped to the DM panel it lives in, made key first; only bare keys or exactly ⌥⌘＋key count.
  const capture = slice(views, 'final class GlobalDMKeyCapture', 'struct GlobalDMWindowReader');
  assert.match(capture, /guard let window = \(hostWindow \?\? NSApp\.currentEvent\?\.window\) as\? GlobalDMPanel else \{ return \}\s*[^\n]*\n\s*window\.makeKey\(\)/);
  // 守：只收這個面板的按鍵（W184 F45：等的可以是某個對象或「換形態」那一列）。
  assert.match(capture, /guard let slot, let store, let hotkeys, let window, event\.window === window else \{ return event \}/);
  assert.match(capture, /guard modifiers\.isEmpty \|\| modifiers == \[\.command, \.option\] else \{ return event \}/);
  // It ends when the panel resigns key, the app resigns active, the box is no longer showing, or the page is left.
  assert.match(capture, /forName: NSWindow\.didResignKeyNotification, object: window/);
  assert.match(capture, /forName: NSApplication\.didResignActiveNotification/);
  assert.match(capture, /CombineLatest4\(store\.\$isOpen, store\.\$isFloatingOpen, store\.\$isDockedVisible,\s*store\.\$isEditingDirectKeys\)/);
  assert.match(capture, /if !editing \|\| !\(floating \|\| \(open && docked\)\) \{ self\?\.end\(\) \}/);
  assert.match(views, /\.background\(GlobalDMWindowReader\(capture: capture\)\)/);
  const desk = read('DM/GlobalDMDeskController.swift');
  assert.match(slice(desk, 'func collapse() {', 'func restore() {'), /store\.isEditingDirectKeys = false/);
  const panels = read('DM/GlobalDMPanelController.swift');
  assert.match(panels, /if store\.isEditingDirectKeys \{ store\.isEditingDirectKeys = false; return nil \}/);
  for (const file of ['DM/GlobalDMDeskViews.swift', 'DM/GlobalDMView.swift']) {
    assert.doesNotMatch(read(file), /\.blue\b|accentColor|borderedProminent|\.bordered\b/, file);
  }
});

test('settings: a 私訊鈕 block in an existing tab (not OS page / setup guide), glass chips, per-key disable controls', () => {
  const island = read('New/TatwoIslandSettingsView.swift');
  assert.match(island, /styleCard\s*GlobalDMSettingsCard\(\)/);
  const views = read('DM/GlobalDMDeskViews.swift');
  const card = slice(views, 'struct GlobalDMSettingsCard: View {', 'private var cardBackground');
  assert.match(card, /Text\("私訊鈕"\)/);
  assert.match(card, /isOn: \$store\.isEnabled/);
  assert.match(card, /"單按 ⌥⌘ 開關私訊框"/);
  assert.match(card, /@AppStorage\(GlobalDMDeskSettings\.chordToggleKey\) private var chordToggle = true/);
  assert.match(card, /OSChipButton\(title: "到私訊框設定"/);
  assert.match(card, /GlobalDMDeskController\.shared\.openDirectKeySettings\(\)/);
  assert.match(card, /setDirectKey\(nil, for: target\)/);
  assert.match(card, /其他 App/);
  assert.doesNotMatch(card, /TextField/);
  // The single ⌥⌘ switch gates the chord monitor.
  const monitor = read('DM/GlobalHotkeyMonitor.swift');
  assert.match(monitor, /if detector\.flagsChanged\(flags, at: event\.timestamp\), GlobalDMDeskSettings\.chordToggleEnabled\(\) \{/);
  assert.match(read('DM/GlobalDMDesk.swift'), /defaults\.object\(forKey: chordToggleKey\) as\? Bool \?\? true/);
});

test('Bot page no longer re-renders on every DM keystroke', () => {
  const bot = read('Bot/BotStudioPage.swift');
  assert.doesNotMatch(bot, /GlobalDMStore\.shared/);
  assert.match(bot, /@AppStorage\(GlobalDMStore\.enabledKey\) private var globalDMEnabled = true/);
});

test('executable self-test covers sizes, blocked keys, key storage, bubble position and the collapse machine', () => {
  const self = read('SelfTest.swift');
  assert.match(self, /TATWO2_SELFTEST"\] == "w179desk"/);
  assert.match(self, /GlobalDMDeskAcceptance\.run\(\)/);
  const acceptance = read('DM/GlobalDMDeskAcceptance.swift');
  assert.match(acceptance, /^#if DEBUG/);
  assert.doesNotMatch(acceptance, /GlobalDMCarbonHotKeys|RegisterEventHotKey|NSPanel\(|makeKeyAndOrderFront/);
  for (const combo of ['⌥⌘Esc', '⌥⌘D', '⌥⌘H', '⌥⌘M', '⌥⌘W', '⌥⌘Space', '⌥⌘I', '⌥⌘↓', '⌥⌘↑', '⌥⌘B', '⌥⌘Tab', '⌥⌘T']) {
    assert.ok(acceptance.includes(`("${combo.replace('⌥⌘', '').replace('↓', 'Down').replace('↑', 'Up')}", "${combo}")`), combo);
  }
  for (const label of ['890×626 scales down proportionally on a small screen', 'is blocked: ',
    'a key another target uses is refused and names that target',
    'default direct key: only ⌥⌘G = ChatGPT, nothing written until changed', 'direct keys survive a relaunch',
    'last form and the dragged bubble position survive a relaunch', 'default bubble: main screen bottom-right, inset 24',
    'a key held by another app is refused and not saved', 'uninstall removes every hotkey; register and unregister are paired',
    '⌥⌘↑ restores the original position and size', 'a relaunch never starts collapsed',
    'direct key opens the box on that target', 'inner landscape: right column defaults to the latest session',
    '⌘⌥Tab is registered while the box shows and cycles the form', 'folding the box releases ⌘⌥Tab right away',
    '⌘⌥Tab held by another app is reported (the page circle\'s menu says so)', 'four forms: outer portrait 466×678',
    'saved frame on an unplugged display is restored onto the main screen', 'while collapsed neither arrow is registered globally',
    '⌥⌘↑ does nothing before collapsing', "a stored ⌥⌘B (TATWO's own browser key) is dropped on load",
    'W179DESK SUMMARY failures=']) {
    assert.ok(acceptance.includes(label), label);
  }
});
