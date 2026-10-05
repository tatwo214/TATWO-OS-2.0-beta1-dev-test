import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// W184 AB（使用者 09-29：「私訊鈕的ui完全垃圾 應該要參照手機app的規格去設計」「duo的形式已經ok就照你的設計去做」）：
// 私訊框 iPhone Duo 的外殼——四種形態、⌘⌥Tab、轉換動畫、頂列、內橫兩欄、token。原始碼契約；
// 實際算出來的數值、熱鍵註冊、動畫期間原生網頁藏起來、reveal 開到右欄與畫面證據在 `TATWO2_SELFTEST=w184forms`。
const read = (name) => readFileSync(new URL('../App/Sources/Tatwo2/' + name, import.meta.url), 'utf8');
const code = (source) => source.replace(/\/\/[^\n]*/g, '');
const slice = (source, start, end) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = source.indexOf(end, from + start.length);
  assert.ok(to > from, `missing ${end} after ${start}`);
  return source.slice(from, to);
};
const count = (source, text) => source.split(text).length - 1;

const desk = read('DM/GlobalDMDesk.swift');
const deskController = read('DM/GlobalDMDeskController.swift');
const hotkeys = read('DM/GlobalDMHotKeys.swift');
const panels = read('DM/GlobalDMPanelController.swift');
const motion = read('DM/GlobalDMFormMotion.swift');
const phone = read('DM/GlobalDMPhoneBox.swift');
const metrics = read('DM/DMPhoneMetrics.swift');
const strip = read('DM/GlobalDMTargetStrip.swift');
const deskViews = read('DM/GlobalDMDeskViews.swift');
const view = read('DM/GlobalDMView.swift');
const store = read('DM/GlobalDMStore.swift');
const tent = read('DM/GlobalDMTentContent.swift');

test('W184 R: second temporary click is not swallowed; consent stays explicit and per-chat', () => {
  const controls = slice(read('DM/GlobalDMChatGPTNavigation.swift'), 'struct GlobalDMChatGPTTopControls:', 'struct GlobalDMChatGPTRoundButton:');
  assert.doesNotMatch(code(controls), /\.popover\(/);
  assert.match(controls, /store\.toggleChatGPTTemporary\(\)/);
  assert.match(controls, /ChatGPTTemporaryPersonalizationChoice\(width: min\(290, width\)\)/);
  assert.match(controls, /guard store\.chatGPTSwitchBlocker == nil, session\.conversationID == nil,\s*session\.isTemporary, session\.messages\.isEmpty else \{ return \}/);
  assert.match(controls, /session\.temporaryPersonalized = true/);
  assert.match(controls, /TatwoComposerModeClickAway\(anchor: temporaryAnchor\)/);
  const clicks = read('DM/GlobalDMChatGPTG3cAcceptance.swift');
  for (const condition of ['leftPress.toggled && leftPress.back && !maskedPress.toggled',
    'rightPress.toggled && rightPress.back && session.isTemporary == leftBefore',
    'defaultPrivate && allowed && cleared && asksAgain && kept']) {
    assert.ok(clicks.includes(condition), condition);
  }
});

test('W184 R: pairing body yields height without losing code, copy, warning, or R12 left-page placement', () => {
  const connect = read('New/HandsConnectDMView.swift');
  const pairing = slice(connect, 'private func pairing(_ view:', '// MARK: - W183 R12：兩頁的左頁');
  assert.match(pairing, /if fillsPage \|\| inSheet \{\s*pairingDetails\(view, left: left, remaining: remaining\)/);
  assert.match(pairing, /ScrollView \{\s*pairingDetails\(view, left: left, remaining: remaining\)\s*\}\s*\.frame\(maxHeight: min\(DMBrowserPhone\.cardMaxBody, bodyLimit\)\)/);
  assert.match(pairing, /if let code = view\.spacedCode, context\.revealsCode, left > 0/);
  for (const part of ['DMSecretCode(text: code)', 'actions.copyPairingCode(view)', 'if view.manual', 'card.pairingWarning']) {
    assert.ok(pairing.includes(part), part);
  }
  assert.match(connect, /var cardWithBrowser: Bool \{ floatsInBrowser && !onLeftPage \}/);
  assert.match(read('DM/GlobalDMTaskAcceptance.swift'), /rig\.presenter\.onLeftPage && separate && fullWeb && compact\.frame\("card.frame"\) == nil/);
});

test('A four forms: sizes, ⌘⌥Tab order, old expand sizes mapped, remembered; docked and floating boxes follow the form', () => {
  // 守（A1）：外直 466×678、內橫 890×626、內直 626×890、倒放 678×466。
  for (const [name, w, h] of [['outerPortrait', 466, 678], ['innerLandscape', 890, 626], ['innerPortrait', 626, 890], ['tent', 678, 466]]) {
    assert.match(desk, new RegExp(`case \\.${name}: CGSize\\(width: ${w}, height: ${h}\\)`), name);
  }
  // 守（A2）：外直 → 內橫 → 內直 → 倒放 → 外直。
  assert.match(desk, /var next: GlobalDMForm \{\s*switch self \{\s*case \.outerPortrait: \.innerLandscape\s*case \.innerLandscape: \.innerPortrait\s*case \.innerPortrait: \.tent\s*case \.tent: \.outerPortrait/);
  // 守（A4）：舊值對應（iPhone Duo 打開＝內橫，其他＝外直），沿用同一個鍵、改了才寫；舊的四種名稱不再出現。
  assert.match(desk, /static func stored\(_ raw: String\?\) -> GlobalDMForm \{\s*guard let raw else \{ return \.outerPortrait \}\s*if let form = GlobalDMForm\(rawValue: raw\) \{ return form \}\s*return raw == "iPhoneOpen" \? \.innerLandscape : \.outerPortrait/);
  assert.match(desk, /self\.form = GlobalDMForm\.stored\(defaults\.string\(forKey: Self\.formKey\)\)/);
  for (const old of ['"ChatGPT 快捷視窗"', '"iPhone Duo 闔起"', '"iPhone Duo 打開"', 'GlobalDMExpandSize']) {
    assert.ok(!(desk + deskController + panels + deskViews + view + phone).includes(old), old);
  }
  // 守（A1）：停靠框、浮動框、圓鈕旁的框都照目前形態；放不下等比縮（寬度放不下時高度也跟著縮）。
  assert.match(panels, /let wanted = desk\.form\.size/);
  assert.match(panels, /boxSize: desk\.form\.size/);
  assert.match(read('DM/GlobalDMLayering.swift'), /let tallest = boxSize\.width > maxWidth \? max\(1, \(boxSize\.height \* maxWidth \/ boxSize\.width\)\.rounded\(\.down\)\) : boxSize\.height/);
  // 守（A2）：桌面圓鈕右鍵列四種形態（目前的打勾）。
  assert.match(slice(deskController, 'func makeBubbleMenu() -> NSMenu {', 'func makeAppMenuItems()'), /for form in GlobalDMForm\.allCases \{[\s\S]*item\.state = settings\.form == form \? \.on : \.off/);
});

test('B ⌘⌥Tab: Carbon hotkey only while the box shows, released when folded; one step per finished transition; failure said in the page circle menu', () => {
  // 守：Carbon（不要輔助使用權限），跟其他 ⌥⌘ 熱鍵同一套註冊與移除（成對）。
  assert.match(hotkeys, /RegisterEventHotKey\(keyCode, UInt32\(optionKey \| cmdKey\)/);
  assert.match(desk, /static let tab = GlobalDMDirectKey\(label: "Tab", code: kVK_Tab\)/);
  // W184 F45（使用者：「我看快捷改讓人自定義好了」）：鍵是使用者設的（直達鍵頁「換形態」那一列），預設照舊 Tab；
  // 守的不變：只在框看得到時註冊、按下＝換下一個形態。
  assert.match(hotkeys, /if isBoxShowing \{ entries\.append\(\(key: formKey, action: \.cycleForm\)\) \}/);
  assert.match(read('DM/GlobalDMFormKey.swift'), /static let standard: GlobalDMDirectKey = \.tab/);
  assert.match(hotkeys, /self\.formKey = GlobalDMFormKeyBook\.load\(from: formDefaults\)/);
  // 守：只在框看得到（浮動框開著，或停靠框開著且在畫面上）時註冊，收起就放掉。
  assert.match(deskController, /Publishers\.CombineLatest3\(store\.\$isOpen, store\.\$isFloatingOpen, store\.\$isDockedVisible\)\s*\.map \{ open, floating, docked in floating \|\| \(open && docked\) \}/);
  assert.match(deskController, /\.sink \{ \[weak self\] showing in self\?\.hotkeys\.isBoxShowing = showing \}/);
  assert.match(deskController, /case \.cycleForm: cycleForm\(\)/);
  // W184 F2：轉換中再按＝直接轉向下一個（不排隊、不等）：setForm 不再擋「轉換進行中」；減少動態效果＝淡出淡入。
  const setForm = slice(deskController, 'func setForm(_ form: GlobalDMForm, animated: Bool = true) -> Bool {', '\n    }\n');
  assert.match(setForm, /guard store\.isEnabled else \{ return false \}/);
  assert.doesNotMatch(setForm, /isAnimating/);
  assert.match(setForm, /reduceMotion: NSWorkspace\.shared\.accessibilityDisplayShouldReduceMotion/);
  assert.match(setForm, /panels\.applyForm\(transition\)/);
  // 守：註冊失敗在頁面圓鈕的右鍵選單（W184 F：原本的「⋯」選單）照實說（W184 F45：看的是目前設的鍵、寫的也是它）。
  assert.match(phone, /tabKeyFailed: desk\.hotkeys\.failed\.contains\(desk\.hotkeys\.formKey\), formKey: desk\.hotkeys\.formKey/);
  assert.match(phone, /if state\.tabKeyFailed \{\s*menu\.addItem\(info\("\\\(state\.formKey\.display\) 被別的 App 佔用了，用這裡換形態"/);
});

test('C every form change slides (W184 F2): a critically damped spring (.smooth(duration: 0.42)), pure functions of time; no 3D, scale, rotation or clip keyframes', () => {
  // 使用者 09-29：「變化特效我不喜歡…精煉絲滑」「我要滑開」「往右滑開可以 但倒不行」：舊的四段 3D／縮放／clip 關鍵影格與 640ms 曲線全部拿掉。
  assert.doesNotMatch(code(motion), /rotateX|scaleX|translateY|perspective|CAKeyframeAnimation|clipRect|keyframes|GlobalDMFormEffect|GlobalDMFormCurve|m34/);
  // 查證 #11：禁的是機制不是舊名字——滑的這四個檔裡沒有 3D／縮放／旋轉／遮罩／Core Animation 的動畫。
  for (const [name, source] of [['GlobalDMFormMotion.swift', motion], ['GlobalDMPanelController.swift', panels], ['GlobalDMView.swift', view],
    ['GlobalDMPhoneBox.swift', phone]]) {
    assert.doesNotMatch(code(source), /CATransform3D|CABasicAnimation|CAKeyframeAnimation|CASpringAnimation|CAAnimation|\.transform\s*=|sublayerTransform|\.mask\s*=|rotation3DEffect|scaleEffect|rotationEffect/, name);
  }
  assert.doesNotMatch(metrics, /formDuration/);
  const tokens = slice(metrics, 'enum Slide {', '\n    }\n');
  for (const piece of ['static let response: Double = 0.42', 'static let settle: Double = 0.6', 'static let fadeOut: Double = 0.10',
    'static let fadeIn: Double = 0.22', 'static let dividerIn: Double = 0.3', 'static let dividerOut: Double = 0.6',
    'static let reduceOut: Double = 0.12', 'static let reduceIn: Double = 0.15']) {
    assert.ok(tokens.includes(piece), piece);
  }
  // 阻尼比 1 的彈簧：位置、速度都是時間的純函式（解析解）；轉向＝從現在的位置與速度換目標（不重設速度）。
  const spring = slice(motion, 'struct GlobalDMSpring: Equatable, Sendable {', '\n}\n');
  assert.match(spring, /static let omega = 2 \* Double\.pi \/ DMPhone\.Slide\.response/);
  assert.match(spring, /return target \+ \(d \+ c \* t\) \* exp\(-Self\.omega \* t\)/);
  assert.match(spring, /return \(velocity - Self\.omega \* c \* t\) \* exp\(-Self\.omega \* t\)/);
  const plan = slice(motion, 'struct GlobalDMFormPlan: Equatable, Sendable {', '\n}\n');
  assert.match(plan, /func frame\(at t: Double\) -> GlobalDMSlideFrame \{/);
  assert.match(plan, /segments\.append\(GlobalDMSlideSegment\(start: t, style: current\.style, from: current\.frame\(at: tau\),\s*speed: current\.speed\(at: tau\)/);
  // 換內容先出後進；同一串對話一直是 1；減少動態效果＝淡出、換框、淡入。
  const fade = slice(motion, 'struct GlobalDMFade: Equatable, Sendable {', '\n}\n');
  assert.match(fade, /guard incoming else \{ return origin \* \(1 - GlobalDMEase\.step\(0, out, tau\)\) \}/);
  assert.match(fade, /let start = waits \? out : 0/);
  const segment = slice(motion, 'struct GlobalDMSlideSegment: Equatable, Sendable {', '\n}\n');
  assert.match(segment, /chat = GlobalDMFade\(origin: frame\.chat, incoming: !intoTent, waits: !intoTent && frame\.tent > 0\.001\)/);
  assert.match(segment, /if style == \.fade \{/);
  // 轉換的樣式：滑、減少動態效果、直接換。
  assert.match(motion, /return GlobalDMFormTransition\(from: from, to: to, style: reduceMotion \? \.fade : \.slide\)/);
  // 面板：轉換開始換一次畫布（舊框∪新框）、停下換回剛好是新框；兩次換畫布都在同一次畫面更新（W184 F3：只有這兩次）。
  const apply = slice(panels, 'func applyForm(_ transition: GlobalDMFormTransition) {', '\n    }\n');
  assert.match(apply, /let area = \(canvasFrame \?\? panel\.frame\)\.union\(box\.insetBy\(dx: -margin, dy: -margin\)\)\.union\(target\.insetBy\(dx: -margin, dy: -margin\)\)/);
  assert.match(apply, /panel\.disableScreenUpdatesUntilFlush\(\)/);
  // 查證 #10、#14：遮蔽藏的是這個面板的畫布（host: canvas）；減少動態效果的樣式真的交給 slide（style: transition.style → GlobalDMFormPlan）。
  assert.match(apply, /formMotion\.slide\(from: GlobalDMSlideFrame\.rest\(transition\.from, box: box\), to: transition\.to, target: target,\s*style: transition\.style, host: canvas\)/);
  assert.match(slice(motion, 'func slide(from start: GlobalDMSlideFrame', '\n    }\n'), /plan = GlobalDMFormPlan\(from: start, to: form, target: target, style: style\)/);
  assert.match(apply, /formMotion\.surface = panel === floating \? \.floating : \.docked/);
  // W184 F3（使用者真機 v2.0.21.030：「切換卡頓卡頓的」）：動畫幾何不逐格觸發排版（A3）——模型不再逐格發布 frame、沒有 display link；
  // 只排一個停下的計時器（自測推時鐘時 tick 叫 onTick 讓圖層台停在那一格）。根畫面不再照每一格畫。
  assert.match(slice(motion, 'func tick() {', '\n    }\n'), /guard !plan\.isSettled\(at: t\) else \{ return finish\(\) \}\s*if manualTime \{ onTick\?\(t\) \} else \{ scheduleSettle\(\) \}/);
  assert.match(slice(motion, 'private func scheduleSettle() {', '\n    }\n'), /Timer\(timeInterval: max\(0, plan\.end - elapsed\) \+ 0\.002, repeats: false\)/);
  assert.doesNotMatch(code(motion), /displayLink|CADisplayLink|@Published private\(set\) var frame/);
  assert.doesNotMatch(code(view), /motion\.frame|slide: /);
  assert.doesNotMatch(code(phone), /var slide: GlobalDMSlideFrame/);
  const frameStep = slice(panels, 'private func slideFrame(_ frame: GlobalDMSlideFrame, finished: Bool) {', '\n    }\n');
  assert.match(frameStep, /guard finished, let panel = canvasPanel, let canvas = panel\.contentView as\? GlobalDMPanelCanvas else \{/);
  assert.match(frameStep, /let settled = frame\.box\.insetBy\(dx: -margin, dy: -margin\)/);
  assert.match(frameStep, /canvas\.rest\(\)\s*canvas\.layoutSubtreeIfNeeded\(\)\s*let laidOut = canvas\.host\.layoutCount\s*CATransaction\.commit\(\)\s*panel\.displayIfNeeded\(\)/);
  assert.match(frameStep, /reconcile\(\)\s*$/);
  assert.doesNotMatch(frameStep, /canvas\.place\(/);
  assert.equal(count(frameStep, 'setFrame('), 1, 'the panel is resized only when the slide ends (not every frame)');
  // 逐格的 displayIfNeeded／disableScreenUpdatesUntilFlush 拿掉：只剩換畫布那幾次——換形態的開始、停下，角的縮放的開始、放開（W184 G1b）。
  // ＋W184 AB：新的樣子在動畫開始之後拍（scheduleFresh）那一次。
  assert.equal(count(code(panels), 'disableScreenUpdatesUntilFlush()'), 5);
  assert.equal(count(code(panels), 'panel.displayIfNeeded()'), 5);   // ＋A1：拍不了時直接切到真的框的那一次
  for (const [start, end] of [['func applyForm(_ transition: GlobalDMFormTransition) {', '\n    }\n'],
    ['private func slideFrame(_ frame: GlobalDMSlideFrame, finished: Bool) {', '\n    }\n'],
    ['private func endGrip(_ surface: GlobalDMSurface? = nil) {', '\n    }\n']]) {
    assert.equal(count(slice(panels, start, end), 'disableScreenUpdatesUntilFlush()'), 1, start);
  }
  assert.equal(count(slice(panels, 'case .began:\n            guard grip == nil else { return }', 'case .changed(let delta):'), 'disableScreenUpdatesUntilFlush()'), 1);
  // 開始：先持有遮蔽與「轉換進行中」（原生網頁、配對碼先藏）→ 真的框照新形態、新大小（對話本體 max(舊高, 新高)、貼底）只排一次版 → 拍新的
  // → 真的框透明度 0、圖層台蓋上去。舊的樣子在形態改之前（desk.form 的 willSet）拍，拍的那一刻暫時藏起配對碼與原生網頁。
  const hold = apply.indexOf('formMotion.hold(host: canvas)');
  const layout = apply.indexOf('canvas.host.layoutSubtreeIfNeeded()');
  const fresh = apply.indexOf('canvas.capture(transition.to');
  assert.ok(hold > 0 && layout > hold && fresh > layout, 'hold → layout once → capture the new look');
  // 新的排成剛好新框的大小（停下不用再排）；先擺好真的框再換畫布；原本在最底的列表排完照樣在最底（再排一次讓懶載入的列出來）。
  // W184 AB（R2；GPT-6 審 G3c #4）：捲上去看舊訊息的，換大小之前記下在讀的那一則（頂列底下看得到的第一則），排版之後捲回原來的位置。
  assert.match(apply, /let away = canvas\.listsAwayFromBottom\(\)\s*let reading = canvas\.readingRows\(in: away\)\s*canvas\.place\(box: target, panelFrame: area, margin: margin\)\s*if panel\.frame != area \{ panel\.setFrame\(area, display: false\) \}/);
  assert.match(apply, /canvas\.host\.layoutSubtreeIfNeeded\(\)\s*canvas\.settleLists\(away: away, reading: reading\)/);
  assert.equal(count(apply, 'canvas.host.layoutSubtreeIfNeeded()'), 1);   // 開始：排新形態一次（列表捲回最底、在讀的那一則捲回原位時的再排在 settleLists）
  assert.equal(count(apply, 'layoutSubtreeIfNeeded()'), 2);   // ＋A1：拍不了時直接切到真的框的那一次
  // 整理捲動位置：捲回最底與在讀的那一則同一次再排（懶載入的列排出來）；在讀的那一則還差就再對一次、再排一次——最多兩次（H10 開始 ≤3 次）。
  const settleLists = slice(panels, 'func settleLists(away: Set<ObjectIdentifier>, reading: [ObjectIdentifier: GlobalDMListRows.Snapshot]) {', '\n    }\n');
  assert.match(settleLists, /let pinned = pinBottoms\(except: away\)\s*let kept = keepReading\(reading\)\s*guard pinned \|\| kept else \{ return \}\s*host\.layoutSubtreeIfNeeded\(\)\s*if kept, keepReading\(reading\) \{ host\.layoutSubtreeIfNeeded\(\) \}/);
  assert.equal(count(settleLists, 'layoutSubtreeIfNeeded()'), 2);
  assert.doesNotMatch(apply, /layoutHeight/);
  // W184 AB（.031 真機 Retina）：有舊的圖（第一段形態改之前拍好的、轉向時台上的）＝畫面先動，新的樣子動畫開始之後才拍；沒有才現在拍。
  assert.match(apply, /let freshBox = NSRect\(x: margin, y: margin, width: target\.width, height: target\.height\)\s*let deferFresh = turning \|\| previous != nil/);
  assert.match(apply, /let captured = deferFresh \? nil : canvas\.capture\(transition\.to, box: freshBox, fill: surface\.fill, label: "new/);
  // A1：拍不了（還有配對碼或原生頁）＝不做圖層轉場，直接切到真的框。
  assert.match(apply, /if !deferFresh, captured == nil \{[\s\S]*?canvas\.rest\(\)[\s\S]*?formMotion\.finish\(\)\s*reconcile\(\)\s*return\s*\}/);
  assert.match(apply, /if canvas\.stage == nil \{ canvas\.present\(stage\) \}\s*stage\.run\(segment, old: previous\)\s*if let captured \{\s*let staged = stage\.addFresh\(captured, at: segment\.start\)/);
  // GPT-6 第三輪 #7：新的樣子每一次怎麼了分開記（上台、拍成但台不收、降級），自測逐段斷言「拍成而且真的上台」。
  assert.match(panels, /enum FreshOutcome: Equatable, Sendable \{[\s\S]*?case staged[\s\S]*?case stale[\s\S]*?case degraded/);
  assert.match(slice(panels, 'private func runFresh(_ token: Int) {', '\n    }\n'), /let staged = stage\.addFresh\(captured, at: formMotion\.elapsed\)[\s\S]*outcome: staged \? \.staged : \.stale[\s\S]*outcome: \.degraded/);
  assert.match(read('DM/GlobalDMFormStage.swift'), /@discardableResult\s*func addFresh\(_ fresh: Capture, at start: Double\) -> Bool \{\s*guard let \(segment, swaps\) = waiting else \{ return false \}/);
  assert.doesNotMatch(panels, /freshRuns/);
  assert.match(apply, /if deferFresh \{ scheduleFresh\(panel, canvas: canvas, form: transition\.to, box: freshBox, target: target, fill: surface\.fill\) \}\s*$/);
  // 排程用 run loop 的計時器（common 模式），不用 DispatchQueue.main（主佇列正在跑工作時巢狀的 run loop 輪不到它）；等一格＋4ms。
  const scheduleFresh = slice(panels, 'private func scheduleFresh(', '\n    }\n');
  assert.match(scheduleFresh, /cancelFresh\(\)\s*let token = freshToken/);
  assert.match(scheduleFresh, /Timer\(timeInterval: formMotion\.manualTime \? 0 : 1 \/ fps \+ 0\.004, repeats: false\)/);
  assert.match(scheduleFresh, /RunLoop\.main\.add\(timer, forMode: \.common\)/);
  assert.doesNotMatch(scheduleFresh, /DispatchQueue\.main/);
  const runFresh = slice(panels, 'private func runFresh(_ token: Int) {', '\n    }\n');
  assert.match(runFresh, /guard let pending = pendingFresh, pending\.token == token, token == freshToken else \{ return \}/);
  assert.match(runFresh, /guard let panel = pending\.panel, let canvas = pending\.canvas, canvasPanel === panel, let stage = canvas\.stage, stage\.awaitingFresh,\s*formMotion\.isAnimating else \{ return \}/);
  assert.match(runFresh, /let captured = canvas\.capture\(pending\.form, box: pending\.box, fill: pending\.fill, label: "new[^\n]*\n\s*scale: canvas\.freshScale\(for: pending\.box\.size\)\)/);
  // 新的樣子的像素比例：Retina 上框小（≤1.3M 像素）照視窗的 2x、框大（內直、內橫）1x（早一點換上；停下就是真的框）。
  assert.match(panels, /static let freshPixelBudget: CGFloat = 1_300_000/);
  assert.match(slice(panels, 'func freshScale(for size: CGSize) -> CGFloat {', '\n    }\n'), /guard native > 1 else \{ return native \}\s*return size\.width \* size\.height \* native \* native <= Self\.freshPixelBudget \? native : 1/);
  assert.match(runFresh, /stage\.addFresh\(captured, at: formMotion\.elapsed\)/);
  assert.match(runFresh, /canvas\.rest\(\)[\s\S]*formMotion\.finish\(\)\s*reconcile\(\)/);
  assert.match(slice(panels, 'private func cancelFresh() {', '\n    }\n'), /freshToken &\+= 1\s*pendingFresh = nil\s*freshTimer\?\.invalidate\(\)/);
  // 停下、收框、轉向：還沒拍的新樣子作廢。
  assert.match(slice(panels, 'private func slideFrame(_ frame: GlobalDMSlideFrame, finished: Bool) {', '\n    }\n'), /cancelFresh\(\)/);
  assert.match(slice(panels, 'private func abortCanvas() {', '\n    }\n'), /cancelFresh\(\)/);
  // 舊的樣子 1x 拍（只顯示 0.1–0.4 秒、在動）。
  assert.match(slice(panels, 'func prepareForm() {', '\n    }\n'), /label: "old \\\(desk\.form\.rawValue\)", scale: 1\)/);
  // 舊的樣子在形態改之前拍（setForm 先叫 prepareForm 再改 desk.form）；不在 desk.form 的 willSet 裡拍（會逼 SwiftUI 照舊值重畫、吃掉這次更新）。
  assert.doesNotMatch(code(panels), /formWillChange|desk\.\$form\s*\.sink/);
  const prepare = slice(panels, 'func prepareForm() {', '\n    }\n');
  assert.match(prepare, /canvas\.capture\(desk\.form, box: box, fill: surface\.fill, label: "old/);
  assert.match(slice(deskController, 'func setForm(_ form: GlobalDMForm, animated: Bool = true) -> Bool {', '\n    }\n'),
    /if transition\.style != \.instant \{ panels\.prepareForm\(\) \}[^\n]*\n\s*settings\.form = form/);
  // A1（GPT-6 審查 F3 #1）：拍圖只有一個入口；整段持有配對碼與原生頁的遮蔽（可巢狀、照當下狀態還原），拍前拍後都檢查、不安全就不產圖。
  // W184 AB：拍法換成 CALayer.render（照指定的像素比例重畫圖層樹）；整個面板控制器只有這一個地方畫真的框。
  assert.equal(count(code(panels), 'layer.render(in: cg)'), 1, 'one capture entry point');
  assert.equal(count(code(panels), 'cacheDisplay('), 0, 'no other capture path');
  const capture = slice(panels, 'func capture(_ form: GlobalDMForm, box: NSRect, fill: CGColor, label: String, scale requested: CGFloat? = nil) -> GlobalDMFormStage.Capture? {', '\n    }\n');
  assert.match(capture, /let codes = DMSecretCodeView\.holdForCapture\(\)\s*let mask = GlobalDMNativePageMask\.shared\s*let pages = mask\.begin\(\)\s*mask\.cover\(in: host\)/);
  assert.match(capture, /defer \{\s*if transparent \{ host\.alphaValue = 0 \}\s*mask\.end\(pages\)\s*DMSecretCodeView\.releaseCapture\(codes\)\s*\}/);
  assert.match(capture, /guard sensitiveOnScreen\(label, "before"\) == nil else \{ return refuse\(seq, label\) \}[\s\S]*muteShadows \{ layer\.render\(in: cg\) \}\s*cg\.restoreGState\(\)\s*guard sensitiveOnScreen\(label, "after"\) == nil else \{ return refuse\(seq, label\) \}/);
  assert.match(capture, /let scale = requested \?\? nativeScale/);
  // G1b 第二輪（GPT-6 G1b 審查 #5）：自測裝了像素檢查＝每一次拍成當下就查、記序號（不看環形快取）。
  assert.match(capture, /if let check = Self\.captureAudit \{ audit\(seq, label, \.captured\(markers: check\(image\)\)\) \}/);
  // 拍的那一下陰影全關（CPU 拍圖時每一層陰影都要離屏＋高斯模糊）、同一個關掉動作的 CATransaction 裡照原值還原（畫面伺服器看不到）。
  const mute = slice(panels, 'private func muteShadows(_ body: () -> Void) {', '\n    }\n');
  assert.match(mute, /CATransaction\.begin\(\)\s*CATransaction\.setDisableActions\(true\)/);
  assert.match(mute, /if layer\.shadowOpacity > 0 \{\s*muted\.append\(\(layer, layer\.shadowOpacity\)\)\s*layer\.shadowOpacity = 0/);
  assert.match(mute, /body\(\)\s*for \(layer, opacity\) in muted \{ layer\.shadowOpacity = opacity \}\s*CATransaction\.commit\(\)/);
  assert.doesNotMatch(code(capture), /write\(|FileManager|print\(|NSLog|Logger/);
  // 圓角外（拍到的是框的陰影）清成透明：台上的框比圖大時角落不會多一圈弧線。
  assert.match(capture, /cg\.addRect\(rect\)\s*cg\.addPath\(path\)\s*cg\.setBlendMode\(\.clear\)\s*cg\.fillPath\(using: \.evenOdd\)/);
  const secret = read('DM/DMBrowserPhone.swift');
  assert.match(secret, /view\.isHidden = DMSecretCodeView\.isSuppressed/);
  assert.match(secret, /static var isSuppressed: Bool \{ suppressed \|\| !captureHolds\.isEmpty \}/);
  assert.match(slice(secret, 'static func releaseCapture(_ token: Int) {', '\n    }\n'), /let hidden = isSuppressed\s*for view in live\.allObjects where view\.isHidden != hidden \{ view\.isHidden = hidden \}/);
  const present = slice(panels, 'func present(_ stage: GlobalDMFormStage) {', '\n    }\n');
  assert.match(present, /addSubview\(stage\.view, positioned: \.above, relativeTo: host\)\s*host\.alphaValue = 0/);
  assert.match(slice(panels, 'func rest() {', '\n    }\n'), /stage\?\.remove\(\)[\s\S]*if host\.alphaValue != 1 \{ host\.alphaValue = 1 \}/);
  // 轉換中整理（reconcile）不改畫布（查證 #12：停靠框的 attach、浮動框的 showFloating 各自守；W184 G1b：拖著、縮放中的也一樣）。
  for (const name of ['private func attach(_ panel: GlobalDMPanel, to window: NSWindow, frame: NSRect) {', 'private func showFloating(focus: Bool) {']) {
    assert.match(slice(panels, name, '\n    }\n'), /if !isHeld\(panel\), panel\.frame != frame \{ panel\.setFrame\(frame, display: true\) \}/, name);
  }
  // 框裡：對話欄貼左緣、右欄貼右緣且寬度用內橫最後的寬度、露出多少跟著進度；分隔線跟著對話欄右緣。
  assert.match(phone, /return min\(width, max\(0, width - CGFloat\(duo\) \* \(landWidth - landLeft\)\)\)/);
  assert.match(phone, /max\(0, landWidth - landLeft - DMPhone\.hairline\)/);
  assert.doesNotMatch(code(phone), /\.offset\(|rotationEffect|scaleEffect|rotation3DEffect|\.mask\(/);
});

test('C W184 F3 the slide runs on the render server: a layer stage with the same critically damped spring; only position, size and opacity animate; corner fixed at 52', () => {
  // 使用者真機 v2.0.21.030：「切換卡頓卡頓的」。圖層台用 CASpringAnimation 跑同一條彈簧（質量 1、stiffness＝ω²、damping＝2ω，ω＝2π／0.42），
  // 初速照模型（以整段距離為單位）；對話欄寬、分隔線、兩層內容的透明度用模型逐格算好的關鍵影格。
  const stage = read('DM/GlobalDMFormStage.swift');
  const spring = slice(stage, 'static func spring(_ keyPath: String, _ s: GlobalDMSpring', '\n    }\n');
  assert.match(spring, /let omega = GlobalDMSpring\.omega/);
  assert.match(spring, /animation\.mass = 1\s*animation\.stiffness = CGFloat\(omega \* omega\)\s*animation\.damping = CGFloat\(2 \* omega\)/);
  assert.match(spring, /animation\.initialVelocity = CGFloat\(s\.velocity \/ \(to - from\)\)/);
  assert.match(stage, /func chatWidth\(_ tau: Double\) -> Double \{\s*let frame = segment\.frame\(at: tau\)/);
  // 只有位置、大小、透明度：沒有 transform、3D、旋轉、縮放、遮罩；圓角固定 52、不動畫。
  assert.doesNotMatch(code(stage), /CATransform3D|\.transform\s*=|sublayerTransform|"transform|rotation|\.mask\s*=|m34|"cornerRadius"|affineTransform/);
  const keyPaths = [...code(stage).matchAll(/"([a-zA-Z.]+)"/g)].map((m) => m[1]).filter((k) => /^(position|bounds|opacity|corner|transform|contents)/.test(k));
  assert.ok(keyPaths.length > 5);
  for (const key of keyPaths) {
    assert.ok(['position.x', 'position.y', 'bounds.size.width', 'bounds.size.height', 'opacity'].includes(key), key);
  }
  assert.match(stage, /layer\.cornerRadius = DMPhone\.screenRadius/);
  // 圖只在這個面板自己的圖層裡：不寫檔、不進紀錄；動畫中框上的點擊吃掉（不給底下看不見的內容）。
  assert.doesNotMatch(code(stage), /write\(to|FileManager|NSLog|Logger|print\(/);
  assert.match(stage, /override func hitTest\(_ point: NSPoint\) -> NSView\? \{/);
  // 停下前最後一格＝剛好是新框：模型值設成終點，動畫留著最後的值（fillMode both）。
  assert.match(stage, /animation\.fillMode = \.both\s*animation\.isRemovedOnCompletion = false/);
  // W184 AB（使用者 09-30 .031：「動畫切換展開時 邊線會多幾條」）：墊底的舊對話欄裁成新的對話欄寬（容器比新的寬時那一條露紙，
  // 不露舊輸入框的右端、舊的字）；內橫的右欄跟著分欄進度淡入淡出（剛分欄時貼右緣那一小條不是實心的）。
  const run = slice(stage, 'func run(_ segment: GlobalDMSlideSegment, old: Capture?) {', '\n    }\n');
  assert.match(run, /let newColumn = segment\.form == \.tent \? 0\s*: GlobalDMPhoneLook\(form: segment\.form, slide: nil, size: segment\.target\.size\)\.chatWidth\(in: segment\.target\.width\)/);
  assert.equal(count(run, 'tier: .under)'), 2);
  // GPT-6 第三輪 #5：每一段（含每一次轉向）把「所有」還在的墊底裁成這一段的新欄寬，照原圖的寬算（不只新建的那一張）。
  assert.match(run, /for piece in pieces where piece\.layer\.zPosition < 0 \{ Self\.trim\(piece\.layer, to: newColumn\) \}\s*waiting = \(segment, swaps\)/);
  assert.doesNotMatch(run, /Self\.trim\(under/);
  assert.match(slice(stage, 'static func trim(_ layer: CALayer, to width: CGFloat) {', '\n    }\n'), /let full = CGFloat\(\(contents as! CGImage\)\.width\) \/ max\(layer\.contentsScale, 1\)\s*let kept = width > 0 \? min\(width, full\) : full\s*layer\.bounds\.size\.width = kept\s*layer\.contentsRect = CGRect\(x: 0, y: 0, width: kept \/ full, height: 1\)/);
  assert.match(stage, /rights\.add\(Self\.sampled\("opacity", length: length, begin: begin, \{ Self\.rightShown\(segment\.frame\(at: \$0\)\.duo\) \}\), forKey: "o"\)/);
  assert.match(stage, /static func rightShown\(_ duo: Double\) -> Double \{ GlobalDMEase\.clamp\(duo \/ DMPhone\.Slide\.rightIn\) \}/);
  assert.match(metrics, /static let rightIn: Double = 0\.35/);
});

test('A2 W184 F3 corner radius fixed: the box is 52 in every form and size (no scaling), the composer 40 and concentric', () => {
  // 使用者 09-29 17:10：「r角現在會變 導致輸入筐根外ｒ角不齊」。
  assert.doesNotMatch(code(metrics), /func screenRadius\(for/);
  assert.match(metrics, /static let screenRadius: CGFloat = GlobalDMLayout\.cornerRadius/);
  assert.match(metrics, /static var barRadius: CGFloat \{ concentric\(screenRadius, inset: edgeInset\) \}/);
  assert.match(phone, /radius = DMPhone\.screenRadius/);
  assert.doesNotMatch(code(motion), /radius/i);
  assert.match(read('DM/GlobalDMChatPhone.swift'), /static var composerRadius: CGFloat \{ DMPhone\.barRadius \}/);
});

test('C native pages (CEF) follow a mask held for the whole transition: moved or newly attached pages hidden too; all shown at the end; never reloaded', () => {
  // 主導 09-29：原生網頁畫面不吃 3D／縮放／裁切：動畫期間藏起來、用頁面底色佔位，走完再顯示；不重新載入、不清 browser、不重建。
  // GPT-6 審查 #3：不是動畫開始那一刻拍一張照（搬家的、晚掛上的漏掉，搬走的 Pod 那一格永遠空白）——是照 token 持有的遮蔽狀態。
  assert.match(motion, /protocol GlobalDMNativePageHost: NSView \{\s*\/\/\/[^\n]*\n\s*var keepsPagesHidden: Bool \{ get \}/);
  assert.match(motion, /extension DMBrowserPageContainer: GlobalDMNativePageHost \{\}/);
  const mask = slice(motion, 'final class GlobalDMNativePageMask: ObservableObject {', '/// 舊的一次性介面');
  assert.match(mask, /@Published private\(set\) var isMasking = false/);
  assert.match(mask, /func begin\(\) -> Int \{\s*nextToken \+= 1\s*holders\.insert\(nextToken\)/);
  // 最後一個 token 放手：這一段藏過的全部顯示回來——不看它現在掛在哪（不再有「父容器沒變才還原」）。
  const end = slice(mask, 'func end(_ token: Int) {', '\n    }\n');
  assert.match(end, /guard holders\.remove\(token\) != nil, holders\.isEmpty else \{ return \}/);
  assert.match(end, /for view in hidden\.allObjects \{[\s\S]*view\.isHidden = false/);
  assert.doesNotMatch(mask, /superview === host|superview == host/);
  // 頁面放進框（attach、換容器、新掛上）：遮蔽中藏並記下，平常一定顯示。
  assert.match(mask, /func present\(_ view: NSView, in container: NSView\) \{\s*guard isMasking else \{\s*view\.isHidden = false\s*return\s*\}\s*hide\(view\)\s*paint\(container\)/);
  const browser = read('DM/DMBrowser.swift');
  const attach = slice(browser, 'extension DMBrowserPage {', 'func detach()');
  assert.match(attach, /GlobalDMNativePageMask\.shared\.present\(view, in: container\)/);
  assert.doesNotMatch(attach, /view\.isHidden = false/);
  const podAttach = slice(browser, 'final class DMBrowserPodPage: DMBrowserPage {', 'func detach()');
  assert.match(podAttach, /pod\.showGuarded\(view, lease: lease\)[^\n]*\n\s*GlobalDMNativePageMask\.shared\.present\(view, in: container\)/);
  // 轉換開始＝持有一段遮蔽並藏面板裡現有的頁面（轉向不放手）；停下＝放手（全部回來）。只動 isHidden 與底色：不拿下、不關、不重新載入。
  // W184 F3：遮蔽與「轉換進行中」在拍圖之前就持有（hold）；slide 也走它。
  const hold = slice(motion, 'func hold(host: NSView?) {', '\n    }\n');
  assert.match(hold, /if maskToken == nil \{ maskToken = nativePages\.begin\(\) \}/);
  assert.match(hold, /nativePages\.cover\(in: host\)/);
  assert.match(hold, /if !isAnimating \{ isAnimating = true \}/);
  assert.match(slice(motion, 'func slide(from start: GlobalDMSlideFrame', '\n    }\n'), /hold\(host: host\)\s*scheduleSettle\(\)/);
  const releaseMask = slice(motion, 'private func release(notify: Bool) {', '\n    }\n');
  assert.match(releaseMask, /nativePages\.end\(maskToken\)/);
  assert.match(slice(motion, 'func finish(notify: Bool = true) {', '\n    }\n'), /onFrame\?\(plan\.rest, true\)[\s\S]*release\(notify: notify\)/);
  // 查證 #5：轉換中收框（abortCanvas）不在收框的路徑裡叫排隊的入口：下一輪 run loop 才叫（那時又在轉換就不叫）。
  assert.match(releaseMask, /if notify \{ onIdle\?\(\) \} else \{ idleLater\(\) \}/);
  assert.match(slice(motion, 'private func idleLater() {', '\n    }\n'), /RunLoop\.main\.perform\(inModes: \[\.common\]\)[\s\S]*guard let self, !self\.isAnimating else \{ return \}\s*self\.onIdle\?\(\)/);
  assert.match(slice(panels, 'private func abortCanvas() {', '\n    }\n'), /formMotion\.finish\(notify: false\)/);
  // W184 F2：倒放影片的佔位是黑的（淡入的是暗的，不會先白一下再變黑）；Browser 的佔位照舊是頁面底色。
  assert.match(motion, /var placeholderFill: CGColor \{ NSColor\.textBackgroundColor\.cgColor \}/);
  // W184 F 小修正（真機 v2.0.21.030）：佔位跟停下之後會顯示的一致——真的有影片（借著、要收進來、正帶著離開）才黑，空狀態不塗。
  assert.match(motion, /extension DMTentVideoContainer \{[\s\S]*var placeholderFill: CGColor \{\s*if !subviews\.isEmpty \{ return NSColor\.black\.cgColor \}[^\n]*\n\s*guard let video, video\.entering \|\| video\.leaving \|\| video\.shown != nil \|\| video\.lentTabID != nil else \{ return NSColor\.clear\.cgColor \}\s*return NSColor\.black\.cgColor/);
  // W184 F 小修正（真機：內橫 0.8 倍時模型膠囊被截成「Fa...5.1」）：模型膠囊用自己的寬度、排版優先；記憶膠囊寬度不夠時只留強度。
  assert.match(strip, /GlobalDMChipLabel\(title: title\)\s*\.fixedSize\(\)[^\n]*\n\s*\}\s*\.buttonStyle\(\.plain\)\s*\.layoutPriority\(1\)/);
  assert.match(read('Memory/TatwoMemoryStrengthChip.swift'), /ViewThatFits\(in: \.horizontal\) \{\s*GlobalDMChipLabel\(title: "記憶", value: state\.strength\.title\)\s*GlobalDMChipLabel\(title: state\.strength\.title\)\s*\}/);
  assert.match(motion, /host\.layer\?\.backgroundColor = \(host as\? GlobalDMNativePageHost\)\?\.placeholderFill \?\? fill/);
  assert.doesNotMatch(code(motion), /removeFromSuperview|\.close\(\)|reload|\.claim\(|\.release\(|closeAll|removeTab|DMBrowser\.shared/);
  // 倒放的影片（房 E）照同一個接點；有卡蓋著時遮蔽結束不把影片翻出來。
  assert.match(tent, /GlobalDMNativePageHost/);
  assert.match(motion, /extension DMTentVideoContainer \{[\s\S]*var keepsPagesHidden: Bool \{ covered \}/);
});

test('B／A4 tent never swallows "show me this" entries: direct keys, 到私訊框設定, DMBrowser.reveal, the ［連線］ card stand the phone up first; queued during a transition', () => {
  // GPT-6 審查 #4、複核 新發現 1：入口都帶一個開框請求走 panels.open(_:)（DMBrowser、［連線］卡的預設也是它）；桌面控制器接上關口。
  const open = slice(panels, 'var contentGate:', '/// Esc 只關私訊框');
  assert.match(open, /var contentGate: \(@MainActor \(GlobalDMOpenRequest\) -> Void\)\?/);
  assert.match(open, /func open\(\) \{\s*open\(GlobalDMOpenRequest\(\)\)\s*\}/);
  assert.match(open, /func open\(_ request: GlobalDMOpenRequest\) \{\s*guard let contentGate else \{ return perform\(request\) \}\s*contentGate\(request\)/);
  assert.match(open, /func perform\(_ request: GlobalDMOpenRequest\) \{\s*request\.run\(store: store\) \{ openNow\(\) \}/);
  assert.match(deskController, /panels\.contentGate = \{ \[weak self, weak panels = self\.panels\] request in\s*guard let self else \{ panels\?\.perform\(request\); return \}\s*self\.showContent\(request\)/);
  assert.match(deskController, /panels\.formMotion\.onIdle = \{ \[weak self\] in self\?\.runPendingContent\(\) \}/);
  const show = slice(deskController, 'func showContent(_ request: GlobalDMOpenRequest) {', '\n    }\n');
  // 轉換中＝整個請求排隊（不丟掉）；出列前再驗證；倒放＝先立起（照轉換表與減少動態效果，走 setForm）再做。
  assert.match(show, /guard !request\.isFinished else \{ return \}\s*if panels\.formMotion\.isAnimating \{\s*pendingContent\.append\(request\)\s*return\s*\}/);
  assert.match(show, /guard request\.stillWanted\(in: store\) else \{ return request\.drop\(\) \}\s*if settings\.form == \.tent \{ setForm\(GlobalDMForm\.tent\.next\) \}\s*panels\.perform\(request\)/);
  assert.match(deskController, /private var pendingContent: \[GlobalDMOpenRequest\] = \[\]/);
  // 房 E 倒放卡上的「打開私訊框」：同一條關口（排隊、立起），框本來就開著＝不照 ⌥⌘ 規則重開（非啟用面板點下去不會把停靠框換成浮動框）。
  assert.match(deskController, /func showContent\(_ action: @escaping @MainActor \(\) -> Void\) \{\s*showContent\(GlobalDMOpenRequest\(opensBox: false, then: action\)\)/);
  assert.match(deskController, /private func runPendingContent\(\) \{\s*guard !panels\.formMotion\.isAnimating, !pendingContent\.isEmpty else \{ return \}/);
  // 轉換走完才叫（isAnimating 已經是 false）；接著播下一段時不叫。
  assert.match(motion, /isAnimating = false\s*if notify \{ onIdle\?\(\) \}/);
  // 直達鍵、到私訊框設定：開框與切對象／翻到設定頁是同一個請求（框開好之後才做）；DMBrowser、［連線］卡的預設也帶請求走 panels.open。
  assert.match(deskController, /func openDirect\(_ target: GlobalDMTarget\) \{\s*guard store\.isEnabled else \{ return \}\s*let store = store\s*panels\.open\(GlobalDMOpenRequest\(then: \{\s*store\.select\(target\)\s*store\.validateTarget\(\)\s*\}\)\)/);
  assert.match(deskController, /func openDirectKeySettings\(\) \{\s*guard store\.isEnabled else \{ return \}\s*let store = store\s*panels\.open\(GlobalDMOpenRequest\(then: \{ store\.isEditingDirectKeys = true \}\)\)/);
  for (const file of ['DM/DMBrowser.swift', 'New/HandsConnectDMView.swift']) {
    assert.match(read(file), /self\.openRequest = \{ GlobalDMPanelController\.shared\.open\(\$0\) \}/, file);
  }
  // ⌘⌥Tab（W184 F2）：轉換中不排隊——直接轉向（setForm 不看 isAnimating）；「要看到某個畫面」的入口照舊等轉換停下。
  assert.doesNotMatch(slice(deskController, 'func setForm(_ form: GlobalDMForm, animated: Bool = true) -> Bool {', '\n    }\n'), /isAnimating/);
});

test('B／A4 queued entries (GPT-6 re-check new findings 1–3): the whole entry is one request — cancellable, re-checked before dequeue, the final box state from its own completion', () => {
  const request = read('DM/GlobalDMOpenRequest.swift');
  // 新發現 2：每個請求有 id 與取消句柄；只有一個結果、只報一次（重複取消、做完再取消都不動）。
  assert.match(request, /final class GlobalDMOpenRequest \{\s*let id = UUID\(\)/);
  assert.match(request, /func cancel\(\) \{ finish\(\.cancelled\) \}/);
  assert.match(request, /private func finish\(_ result: GlobalDMOpenOutcome\) \{\s*guard outcome == nil else \{ return \}/);
  assert.match(request, /func stillWanted\(in store: GlobalDMStore\) -> Bool \{\s*outcome == nil && store\.isEnabled && valid\(\)/);
  // 新發現 1、3：出列才驗證、開框；框真的開著才做 then（選頁、選對象、設定旗標）；完成回呼帶這一次開框前後的樣子。
  const run = code(slice(request, 'func run(store: GlobalDMStore, requiresBox: Bool = true, open: @MainActor () -> Void) {', '\n    }\n'));
  assert.match(run, /guard stillWanted\(in: store\) else \{ return drop\(\) \}\s*let before = GlobalDMBoxPresence\(store\)\s*if opensBox \{ open\(\) \}\s*guard outcome == nil else \{ return \}\s*guard store\.isPresented \|\| !requiresBox else \{ return drop\(\) \}\s*then\(\)\s*finish\(\.opened\(before: before, after: GlobalDMBoxPresence\(store\)\)\)/);
  // DMBrowser：開框請求在排的時候分頁不動；框開好才切到 Browser、把分頁叫到前面；分頁拿掉＝撤銷它的；分頁全收＝全部撤銷。
  const browser = read('DM/DMBrowser.swift');
  const reveal = slice(browser, 'private func reveal(_ id: UUID) {', 'private func restoreBox() {');
  assert.match(reveal, /let request = GlobalDMOpenRequest\(valid: \{ \[weak self\] in self\?\.tabs\.contains \{ \$0\.id == id \} == true \},\s*then: \{ \[weak self\] in self\?\.bringToFront\(id\) \}\)/);
  assert.doesNotMatch(slice(reveal, 'private func reveal(_ id: UUID) {', 'private func bringToFront('), /showBrowser|activeID = id|place\(/);
  assert.match(reveal, /private func bringToFront\(_ id: UUID\) \{\s*store\.showBrowser\(\)\s*activeID = id\s*isShowingTabList = false\s*place\(focus: true\)/);
  assert.match(slice(browser, 'private func restoreBox() {', '\n    }\n'), /let pending = Array\(pendingOpens\.values\)\s*pendingOpens = \[:\]\s*for request in pending \{ request\.cancel\(\) \}/);
  assert.match(slice(browser, 'private func removeTab(', 'private func update('), /tabs\.remove\(at: index\)\s*pendingOpens\.removeValue\(forKey: id\)\?\.cancel\(\)/);
  // 新發現 3：完成回呼記最終樣子；使用者在上一次打開之後動過框＝不改記。
  assert.match(reveal, /guard prior != nil, case \.opened\(let before, let after\) = outcome, after\.isOpen else \{ return \}\s*guard applied == nil \|\| applied == BoxState\(before\) else \{ return \}\s*applied = BoxState\(after\)/);
  // ［連線］卡：收卡片＝撤銷；出列前再看卡片還在不在；完成回呼記最終樣子。
  const connect = read('New/HandsConnectDMView.swift');
  assert.match(connect, /let request = GlobalDMOpenRequest\(valid: \{ \[weak self\] in self\?\.isShown == true \}/);
  assert.match(slice(connect, '    func hide() {', '    private func requestBox() {'), /pendingOpen\?\.cancel\(\)/);
  assert.match(connect, /guard isShown, case \.opened\(let before, let after\) = outcome, after\.isOpen else \{ return \}\s*if let applied, applied\.docked != before\.docked \|\| applied\.floating != before\.floating \{ return \}\s*applied = \(after\.docked, after\.floating\)/);
  // 不再用「任一框已開」推定完成。
  assert.doesNotMatch(code(browser) + code(connect), /appliedWatch|recordAppliedBox|store\.\$isOpen, store\.\$isFloatingOpen/);
});

test('C observable form state for other rooms: current form, transition flag, setForm(_:animated:)', () => {
  assert.match(desk, /@Published var form: GlobalDMForm \{/);
  assert.match(deskController, /@Published private\(set\) var isFormTransitioning = false/);
  assert.match(deskController, /panels\.formMotion\.\$isAnimating\s*\.removeDuplicates\(\)\s*\.sink \{ \[weak self\] animating in self\?\.isFormTransitioning = animating \}/);
  assert.match(deskController, /var form: GlobalDMForm \{ settings\.form \}/);
  assert.match(deskController, /@discardableResult\s*func setForm\(_ form: GlobalDMForm, animated: Bool = true\) -> Bool \{/);
  assert.match(motion, /@Published private\(set\) var isAnimating = false/);
});

test('B top bar: only the current page circle top-left (hover opens right; right-click / control-click = the menu); no ⋯, ⌄, ✕, size button, name row or ⌥⌘ line', () => {
  // 守（B4）：數值都從 DMPhone 取（上 14、下 10、左右 16／內橫 20；44 的鈕；圓鈕列 52 → 156、間距 8、外圈 2／1、260ms）。
  assert.match(metrics, /static let headerTop: CGFloat = 14/);
  assert.match(metrics, /static let headerBottom: CGFloat = 10/);
  assert.match(metrics, /static func sideMargin\(for form: GlobalDMForm\) -> CGFloat \{ form\.isDuo \? wideMargin : margin \}/);
  const tokens = slice(metrics, 'enum Strip {', '/// 內橫（對照稿 Open-Landscape-*）');
  for (const piece of ['static let inset: CGFloat = 4', 'static let spacing: CGFloat = 8', 'static var collapsed: CGFloat { touch + inset * 2 }',
    'return inset * 2 + CGFloat(count) * touch + CGFloat(count - 1) * spacing', 'static let currentRing: CGFloat = 2',
    'static let otherRing: CGFloat = 1', 'static let duration: Double = 0.26']) {
    assert.ok(tokens.includes(piece), piece);
  }
  // W184 F（使用者 09-29：右上「⋯」「⌄」「這兩個鈕也是不用的」）：兩顆拿掉，它們的間距 token 一起拿掉。
  assert.doesNotMatch(metrics, /topButtonSpacing/);
  const bar = slice(phone, 'struct GlobalDMTopBar: View', 'enum GlobalDMTopBarLayout');
  // 頂列只剩左上的圓鈕列（右邊是空的 Spacer）；高度照舊 68（上 14、44、下 10），左上圓鈕的位置不變、內容區不跳。
  assert.match(bar, /HStack\(alignment: \.center, spacing: 0\) \{\s*GlobalDMIconStrip\(store: store, besideBrowser: form\.isDuo\)\s*Spacer\(minLength: 0\)\s*\}/);
  assert.doesNotMatch(bar, /GlobalDMMoreButton|GlobalDMCollapseButton|let surface/);
  // W184 F2：換形態途中左右留白連續變（環境值 globalDMSideMargin；停著＝照形態）。
  assert.match(bar, /\.padding\(\.top, DMPhone\.headerTop\)\s*\.padding\(\.bottom, DMPhone\.headerBottom\)\s*\.padding\(\.horizontal, sideMargin \?\? DMPhone\.sideMargin\(for: form\)\)\s*\.frame\(height: DMPhone\.headerHeight\)/);
  assert.doesNotMatch(bar, /isBrowsing|Text\(/, 'the bar is the same in chat and Browser (no name row)');
  // 圓鈕列：52×52 的裁切容器（外距 −4、內距 4），指到展開、移開收回、點別顆收回；展開後目前那顆在最左。
  const icons = slice(strip, 'struct GlobalDMIconStrip: View', 'struct GlobalDMIconButton');
  assert.match(icons, /\.padding\(DMPhone\.Strip\.inset\)\s*\.frame\(width: DMPhone\.Strip\.width\(count: items\.count, open: open\), height: DMPhone\.Strip\.collapsed, alignment: \.leading\)\s*\.clipShape\(Capsule\(\)\)/);
  assert.match(icons, /\.padding\(-DMPhone\.Strip\.inset\)/);
  assert.match(icons, /GlobalDMGlassCapsule\(\)\s*\.shadow\(/);
  assert.match(icons, /hover\.picked\(\)/);
  assert.match(icons, /\.allowsHitTesting\(open \|\| isCurrent\)/);
  assert.match(phone, /static func order\(_ items: \[GlobalDMIconItem\], current: String\) -> \[GlobalDMIconItem\] \{\s*items\.filter \{ \$0\.id == current \} \+ items\.filter \{ \$0\.id != current \}/);
  assert.match(phone, /return \.timingCurve\(c\.x1, c\.y1, c\.x2, c\.y2, duration: DMPhone\.Strip\.duration\)/);
  // 圓鈕樣子照舊（頭像、logo、地球），44；目前那顆 2pt 強調色外圈、其他 1pt 淡框。
  assert.match(strip, /static let iconSize: CGFloat = DMPhone\.touch/);
  // W184 F：右上的 ⋯ 更多、⌄ 收起不在了（所有形態）；收起靠 ⌥⌘ 與 Esc。
  assert.doesNotMatch(code(phone), /struct GlobalDMMoreButton|struct GlobalDMCollapseButton|struct GlobalDMTopBarIcon|systemImage: "ellipsis"|systemImage: "chevron\.down"|buttonsFrame/);
  // 原本「⋯」的選單改成目前那顆圓鈕的右鍵選單：只接右鍵與 control＋點（左鍵、滑鼠移動照常給圓鈕），VoiceOver 的「顯示選單」同一份。
  assert.match(icons, /\.modifier\(GlobalDMPageMenu\(active: isCurrent, store: store, anchor: menuAnchor, surface: surface\)\)\s*\.modifier\(GlobalDMCurrentTargetMark\(active: isCurrent, name: item\.title\)\)/);
  const pageMenu = slice(phone, 'struct GlobalDMPageMenu: ViewModifier', '/// 頁面圓鈕右鍵選單（原本的「⋯ 更多」）現在該有什麼');
  assert.match(pageMenu, /if active \{\s*content\s*\.overlay \{ GlobalDMPageMenuCatcher\(store: store, anchor: anchor, surface: surface\) \}\s*\.accessibilityAction\(\.showMenu\) \{ anchor\.view\?\.showMenu\(nil\) \}/);
  assert.match(pageMenu, /return event\.type == \.rightMouseDown \|\| \(event\.type == \.leftMouseDown && event\.modifierFlags\.contains\(\.control\)\)/);
  assert.match(pageMenu, /override func hitTest\(_ point: NSPoint\) -> NSView\? \{\s*guard Self\.opensMenu\(Self\.currentEvent\(\)\), bounds\.contains\(convert\(point, from: superview\)\) else \{ return nil \}\s*return self/);
  assert.match(pageMenu, /override func rightMouseDown\(with event: NSEvent\) \{ showMenu\(event\) \}/);
  assert.match(pageMenu, /override func mouseDown\(with event: NSEvent\) \{\s*guard event\.modifierFlags\.contains\(\.control\) else \{ return super\.mouseDown\(with: event\) \}\s*showMenu\(event\)/);
  assert.match(pageMenu, /static var currentEvent: @MainActor \(\) -> NSEvent\? = \{ NSApp\.currentEvent \}/);
  assert.match(pageMenu, /static var makeMenu: @MainActor \(GlobalDMStore, GlobalDMSurface\) -> NSMenu = \{ GlobalDMMoreMenu\.make\(for: \$0, surface: \$1\) \}/);
  assert.match(pageMenu, /if let event \{ NSMenu\.popUpContextMenu\(menu, with: event, for: view\) \} else \{ GlobalDMMoreMenu\.popUp\(menu, below: view\) \}/);
  // W184 F2：私訊框照手機做，不加說明字：圓鈕的提示回到原本的字（沒有「（右鍵：…）」）。
  assert.doesNotMatch(strip, /右鍵：形態/);
  assert.match(strip, /\.help\(item\.device\.map \{ "\\\(item\.help\)（在「\\\(\$0\)」上）" \} \?\? item\.help\)/);
  // 右鍵選單知道自己在哪個框（收起私訊框收它）：手機把 surface 放進環境，圓鈕列帶給選單。
  assert.match(strip, /\.modifier\(GlobalDMPageMenu\(active: isCurrent, store: store, anchor: menuAnchor, surface: surface\)\)/);
  // 拿掉：✕、尺寸鈕、名字行、⌥⌘ 提示列。
  for (const gone of ['GlobalDMBoxControls', 'GlobalDMSizeMenuButton', 'GlobalDMChordHint', 'targetNameHeight', 'rectangle.expand.vertical']) {
    assert.ok(!(view + deskViews + phone + read('DM/GlobalDMLayering.swift')).includes(gone), gone);
  }
});

test('G1b drag = the system window drag (released → saved), two corners scale in proportion (the dragged corner follows, the opposite one stays), the only range limit is 44pt of the top bar; bubble mode remembered apart', () => {
  // 使用者 09-29：「左下也可以調尺寸好了」「拖拽範圍跟體驗有很多問題」（拖的時候卡、跟不上滑鼠／範圍太小／不知道哪裡能抓／縮成圓鈕時拖不動）。
  const placement = slice(desk, 'struct GlobalDMBoxPlacement: Equatable, Sendable {', '\n}\n');
  assert.match(placement, /static let minScale: CGFloat = 0\.7\s*static let maxScale: CGFloat = 1\.3/);
  assert.match(placement, /static let grabbable: CGFloat = 44/);
  // 記住的是「框右下角相對於參考範圍右下角的位移」＋比例；沒拖過、沒縮放過＝跟改之前一模一樣；唯一限制＝頂列至少 44pt 在範圍裡（不再整個推回範圍）。
  assert.match(placement, /guard !isStandard else \{ return base \}/);
  assert.match(placement, /return Self\.keepGrabbable\(CGRect\(x: corner\.x - size\.width, y: corner\.y, width: size\.width, height: size\.height\), in: area\)/);
  const keep = slice(placement, 'static func keepGrabbable(_ box: CGRect, in area: CGRect) -> CGRect {', '\n    }\n');
  assert.match(keep, /box\.origin\.y = min\(box\.minY, area\.maxY - box\.height\)\s*box\.origin\.y = max\(box\.minY, area\.minY \+ grabbable - box\.height\)\s*box\.origin\.x = min\(box\.minX, area\.maxX - grabbable\)\s*box\.origin\.x = max\(box\.minX, area\.minX \+ grabbable - box\.width\)/);
  // 兩個角：拖的角跟著滑鼠（投影到對角線），對角固定；0.7–1.3，上限受範圍（右上角再受上緣）限制。
  const resized = slice(placement, 'static func resized(_ start: CGRect, corner: GlobalDMResizeCorner, base: CGSize, by delta: CGSize,', '\n    }\n');
  assert.match(resized, /let fixed = corner == \.topRight \? CGPoint\(x: start\.minX, y: start\.minY\) : CGPoint\(x: start\.maxX, y: start\.maxY\)/);
  assert.match(resized, /let along = \(\(dragged\.x - fixed\.x\) \* sign \* width \+ \(dragged\.y - fixed\.y\) \* sign \* height\) \/ \(width \* width \+ height \* height\)/);
  // G1b 第二輪（GPT-6 G1b 審查 #2）：比例的合法區間——上限（1.3、放得進範圍、右上角拉不超過上緣）、下限（0.7、縮完頂列照樣至少 44pt 在範圍裡）；
  // 縮放途中就夾在區間裡（放開不再推，固定的角不動）；夾完跟開始差不到 1pt＝框原樣、比例原樣。
  assert.match(resized, /let legal = legalScales\(start, corner: corner, base: base, area: area\)[\s\S]*let scale = min\(max\(along, legal\.lower\), legal\.upper\)\s*guard abs\(scale - initial\) \* max\(width, height\) >= 1 else \{ return \(start, initial\) \}/);
  const legal = slice(placement, 'static func legalScales(_ start: CGRect, corner: GlobalDMResizeCorner, base: CGSize, area: CGRect) -> (lower: CGFloat, upper: CGFloat) {', '\n    }\n');
  assert.match(legal, /upper = min\(upper, \(area\.maxY - start\.minY - 0\.5\) \/ height\)\s*lower = max\(lower, \(area\.minX \+ grabbable - start\.minX \+ 0\.5\) \/ width, \(area\.minY \+ grabbable - start\.minY \+ 0\.5\) \/ height\)/);
  assert.match(legal, /lower = max\(lower, \(start\.maxX - \(area\.maxX - grabbable\) \+ 0\.5\) \/ width\)/);
  assert.match(desk, /enum GlobalDMResizeCorner: String, Equatable, Sendable \{\s*case topRight, bottomLeft/);
  // 圓鈕模式：放開蓋到圓鈕＝往最近的一邊讓開；位置相對於圓鈕，另存一份。
  // G1b 第二輪（GPT-6 G1b 審查 #4）：四個讓開的方向各自先照範圍夾好、拿掉夾完還疊著的、挑最短；都不行試斜的；再不行＝開在圓鈕旁。
  const clearing = slice(placement, 'static func clearing(_ box: CGRect, bubble: CGRect, in area: CGRect, fallback: CGRect,', '\n    }\n');
  assert.match(clearing, /let legal = moves\.map \{ keepGrabbable\(box\.offsetBy\(dx: \$0\.width, dy: \$0\.height\), in: area\) \}\.filter \{ !overlaps\(\$0\) \}/);
  assert.match(clearing, /return keepGrabbable\(fallback, in: area\)/);
  for (const name of ['private func floatingFrame(screen current: NSScreen?) -> NSRect {', 'private func finishDrag(_ reason: String = "release") {', 'private func endGrip(_ surface: GlobalDMSurface? = nil) {']) {
    assert.match(slice(panels, name, '\n    }\n'), /GlobalDMBoxPlacement\.clearing\([^\n]*bubble: bubble, in: [^\n]*, fallback: [^\n]*\)/, name);
    assert.doesNotMatch(slice(panels, name, '\n    }\n'), /keepGrabbable\(GlobalDMBoxPlacement\.clearing/, name);
  }
  assert.match(desk, /static let bubblePlacementKey = "tatwo2\.globalDM\.placement\.bubble"/);
  assert.match(desk, /func saveBubblePlacement\(_ placement: GlobalDMBoxPlacement\) \{/);
  assert.match(desk, /static let floatingPlacementKey = "tatwo2\.globalDM\.placement\.floating"/);
  assert.match(desk, /static let dockedPlacementKey = "tatwo2\.globalDM\.placement\.docked"/);
  assert.match(desk, /guard !placement\.isStandard else \{ return defaults\.removeObject\(forKey: key\) \}/);
  // 範圍：浮動框＝整個 visibleFrame（面板不被系統往選單列下推）；停靠框＝整個內容區、可以蓋到輸入框（預設擺法照舊避開）。
  assert.match(panels, /override func constrainFrameRect\(_ frameRect: NSRect, to screen: NSScreen\?\) -> NSRect \{ frameRect \}/);
  assert.match(slice(panels, 'private func floatingPlacementGeometry(screen current: NSScreen?) -> GlobalDMPlacementGeometry {', '\n    }\n'),
    /return GlobalDMPlacementGeometry\(standard: standard, reference: visible, bounds: visible, composer: nil\)/);
  assert.match(slice(panels, 'private func dockedGeometry(_ placed: GlobalDMDockedPlaced) -> GlobalDMPlacementGeometry? {', '\n    }\n'),
    /bounds: placed\.content/);
  assert.doesNotMatch(slice(panels, 'private func userBox(_ placement: GlobalDMBoxPlacement, _ geometry: GlobalDMPlacementGeometry) -> NSRect {', '\n    }\n'), /avoidComposer/);
  // 原生拖曳：按下交給 performDrag（視窗伺服器帶著走）；拖著的面板整理不動它；放開才算位置、存下來，頂列不到 44pt 才短動畫推回。
  assert.match(panels, /static var windowDrag: @MainActor \(NSWindow, NSEvent\) -> Void = \{ window, event in window\.performDrag\(with: event\) \}/);
  const begin = slice(panels, 'func beginWindowDrag(_ surface: GlobalDMSurface, event: NSEvent) {', '\n    }\n');
  assert.match(begin, /panel\.isMovable = true\s*Self\.windowDrag\(panel, event\)\s*finishDragWhenReleased\(\)/);
  // G1b 第二輪（GPT-6 G1b 審查 #1）：按下那一刻就定好存到哪一份（浮動／停靠／圓鈕模式）與幾何參考；放開、途中收框、途中換模式都照它存。
  assert.match(begin, /if surface == \.floating, let bubble = floatingAnchor\?\(\) \{\s*drag = GlobalDMDragContext\(panel: panel, surface: surface, key: \.bubble/);
  assert.match(begin, /drag = GlobalDMDragContext\(panel: panel, surface: surface, key: \.docked, placement: desk\.placement\(\.docked\),\s*geometry: geometry/);
  const finish = slice(panels, 'private func finishDrag(_ reason: String = "release") {', '\n    }\n');
  assert.match(finish, /guard let context = drag else \{ return \}\s*drag = nil/);
  assert.match(finish, /switch context\.key \{/);
  assert.match(finish, /landed = GlobalDMBoxPlacement\.keepGrabbable\(box, in: geometry\.bounds\)/);
  assert.match(finish, /desk\.savePlacement\(placement, for: \.docked\)/);
  assert.match(finish, /desk\.savePlacement\(placement, for: \.floating\)/);
  assert.match(finish, /desk\.saveBubblePlacement\(placement\)/);
  assert.doesNotMatch(finish, /floatingAnchor|placementGeometry\(for:|visibleMainWindow/);
  assert.match(finish, /guard reason == "release" else \{ return \}[\s\S]*panel\.animator\(\)\.setFrame\(frame, display: true\)/);
  assert.match(slice(panels, 'func reconcile() {', '\n    }\n'), /if let drag, drag\.surface == \.floating, \(drag\.key == \.bubble\) != \(floatingAnchor\?\(\) != nil\) \{ finishDrag\("mode"\) \}/);
  assert.match(slice(panels, 'private func endGestures(_ surface: GlobalDMSurface, reason: String) {', '\n    }\n'), /if drag\?\.surface == surface \{ finishDrag\(reason\) \}\s*endGrip\(surface\)/);
  assert.match(panels, /private func isHeld\(_ panel: GlobalDMPanel\) -> Bool \{\s*if panel === canvasPanel \|\| panel === dragPanel \{ return true \}/);
  for (const name of ['private func attach(_ panel: GlobalDMPanel, to window: NSWindow, frame: NSRect) {', 'private func showFloating(focus: Bool) {']) {
    assert.match(slice(panels, name, '\n    }\n'), /if !isHeld\(panel\), panel\.frame != frame \{ panel\.setFrame\(frame, display: true\) \}/, name);
  }
  // 縮放：快照預覽（拍一張、面板一次換成最大的畫布、途中只動圖層台，不排版、不逐事件改面板）；放開才照新大小排一次、存下來。
  const grip = slice(panels, 'func handleGrip(_ kind: GlobalDMBoxGrip.Kind, surface: GlobalDMSurface, phase: GlobalDMBoxGrip.Phase) {', '\n    }\n');
  assert.match(grip, /guard hostsWindows, isInstalled, case \.resize\(let corner\) = kind else \{ return \}\s*if case \.ended = phase \{\s*guard grip\?\.surface == surface else \{ return \}\s*endGrip\(surface\)\s*reconcile\(\)\s*return\s*\}/);
  assert.match(grip, /let capture = canvas\.capture\(desk\.form, box: hostBox, fill: surfaceColors\.fill, label: "resize"\)/);
  assert.match(grip, /stage\.set\(box: resized\.box, form: desk\.form\)/);
  assert.doesNotMatch(slice(grip, 'case .changed(let delta):', 'case .ended:'), /setFrame|layoutSubtreeIfNeeded/);
  const endGrip = slice(panels, 'private func endGrip(_ surface: GlobalDMSurface? = nil) {', '\n    }\n');
  assert.match(endGrip, /canvas\.rest\(\)\s*canvas\.layoutSubtreeIfNeeded\(\)/);
  // 換形態、收框前先結束並存下進行中的縮放；拖著的時候換形態不滑（放開才照新形態擺）。
  assert.match(slice(panels, 'func applyForm(_ transition: GlobalDMFormTransition) {', '\n    }\n'), /endGrip\(\)[\s\S]{0,400}guard transition\.style != \.instant, dragPanel == nil,/);
  assert.match(slice(panels, 'private func hideFloating() {', '\n    }\n'), /endGestures\(\.floating, reason: "hidden"\)/);
  assert.match(slice(panels, 'private func detachBox(from window: NSWindow?, animated: Bool = true) {', '\n    }\n'), /endGestures\(\.docked, reason: "hidden"\)/);
  assert.match(slice(panels, 'func reconcile() {', '\n    }\n'), /if let canvasPanel, canvasPanel === docked, let started = canvasContent,\s*visibleMainWindow\(\)\.map\(mainContent\(of:\)\) != started \{\s*abortCanvas\(\)\s*\}/);
  assert.match(panels, /forName: NSWindow\.didMoveNotification[\s\S]{0,500}guard let self, fromMain else \{ return \}[\s\S]{0,300}guard self\.dockedMorph\.isAnimating \|\| \(self\.canvasPanel != nil && self\.canvasPanel === self\.docked\) else \{ return \}\s*self\.reconcile\(\)/);
  // 抓取區：頂列空白處（倒放：上緣那一條）；右上角、左下角各 40×40（角標＝跟框同心的短弧，約 14pt 才出現）；雙擊不做任何事。
  // W184 AB（使用者 09-30：「上方不要拖拽槓 不好看」）：頂列正中間的小把手拿掉（頂列、倒放的上緣都不畫）；頂列照樣能拖，能抓的提示＝游標。
  assert.match(phone, /\.background \{\s*GlobalDMBoxGrip\(kind: \.move, surface: surface\)\s*\}/);
  assert.doesNotMatch(phone, /GlobalDMGrabHandle|Capsule\(\)\s*\.fill\(onDark/);
  assert.match(phone, /struct GlobalDMTentGrabBand: View \{[\s\S]*?GlobalDMBoxGrip\(kind: \.move, surface: surface\)\s*\.frame\(maxWidth: \.infinity\)\s*\.frame\(height: DMPhone\.touch\)\s*\.frame\(maxHeight: \.infinity, alignment: \.top\)\s*\}/);
  // 游標：頂列空白處＝張開的手（面板不是主視窗時照樣：滑鼠移動時看那一點是不是真的落在抓取區上），按下握拳。
  assert.match(phone, /let options: NSTrackingArea\.Options = \[\.cursorUpdate, \.activeAlways, \.inVisibleRect, \.mouseEnteredAndExited, \.mouseMoved\]/);
  assert.match(phone, /let blank = location\.map\(isBlank\(at:\)\) \?\? false\s*if blank \{\s*NSCursor\.openHand\.set\(\)\s*\} else if showsHand \{\s*NSCursor\.arrow\.set\(\)\s*\}/);
  assert.match(phone, /guard let root = window\?\.contentView\?\.superview \?\? window\?\.contentView else \{ return false \}\s*return root\.hitTest\(location\) === self/);
  assert.match(phone, /GlobalDMBoxGrip\(kind: \.resize\(\.topRight\), surface: surface\)/);
  assert.match(phone, /GlobalDMBoxGrip\(kind: \.resize\(\.bottomLeft\), surface: surface\)/);
  assert.match(phone, /static let cornerSize: CGFloat = 40\s*static let cornerReach: CGFloat = 14/);
  assert.doesNotMatch(metrics, /enum Handle \{/);
  assert.match(read('DM/GlobalDMTentPane.swift'), /GlobalDMTentGrabBand\(\)/);
  assert.match(phone, /distance >= DMPhone\.screenRadius - DMPhone\.edgeInset && distance <= DMPhone\.screenRadius \+ GlobalDMBoxGrip\.cornerReach/);
  assert.match(phone, /case \.resize\(\.topRight\): "tatwo\.dm\.grip\.resize"\s*case \.resize\(\.bottomLeft\): "tatwo\.dm\.grip\.resize\.bottomLeft"/);
  assert.match(phone, /guard event\.clickCount == 1 else \{ return \}/);
  assert.match(phone, /NSCursor\.closedHand\.set\(\)\s*Self\.windowDrag\(surface, event\)/);
  assert.match(phone, /NSCursor\.frameResize\(position: corner == \.topRight \? \.topRight : \.bottomLeft, directions: \.all\)/);
  assert.match(phone, /override var mouseDownCanMoveWindow: Bool \{ false \}/);
  // 右鍵選單：拖過或縮放過才出現「回到預設位置與大小」（縮成圓鈕時看圓鈕那一份）。
  assert.match(phone, /if state\.movedOrScaled \{\s*let reset = AssistantModelMenuItem\(title: "回到預設位置與大小", run: actions\.resetPlacement\)/);
  assert.match(phone, /resetPlacement: \{ GlobalDMPanelController\.shared\.resetPlacement\(surface\) \}/);
});

test('B page circle menu (was ⋯): four forms (current ticked) with ⌘⌥Tab, direct keys, ⌥⌘ and the accessibility item, collapse / restore; a system menu', () => {
  const menu = slice(phone, 'static func make(_ state: GlobalDMMoreMenuState, actions: Actions) -> NSMenu {', 'static func make(for store: GlobalDMStore, surface: GlobalDMSurface) -> NSMenu {');
  // W184 F：tatwo.dm.more 從右上的 ⋯ 改掛在這份選單上。
  assert.match(menu, /let menu = NSMenu\(title: "更多"\)\s*menu\.identifier = NSUserInterfaceItemIdentifier\("tatwo\.dm\.more"\)/);
  // 守：標題說明換形態的鍵（W184 F45：寫目前設的鍵，預設 ⌥⌘Tab）。
  assert.match(menu, /NSMenuItem\.sectionHeader\(title: "形態（\\\(state\.formKey\.display\) 依序換）"\)/);
  assert.match(menu, /heading\.identifier = NSUserInterfaceItemIdentifier\("tatwo\.dm\.size"\)/);
  assert.match(menu, /for form in GlobalDMForm\.allCases \{[\s\S]*item\.state = state\.form == form \? \.on : \.off/);
  assert.match(menu, /AssistantModelMenuItem\(title: "直達鍵…", run: actions\.openDirectKeys\)/);
  assert.match(menu, /info\("要在其他 App 用 ⌥⌘，要開裝置控制和資料取用（舊稱輔助使用）權限"/);
  assert.match(menu, /AssistantModelMenuItem\(title: "打開裝置控制和資料取用（舊稱輔助使用）設定…", run: actions\.openAccessibility\)\s*open\.identifier = NSUserInterfaceItemIdentifier\("tatwo\.dm\.accessibility"\)/);
  assert.match(menu, /"恢復主視窗　⌥⌘↑"/);
  assert.match(menu, /"縮成桌面圓鈕　⌥⌘↓"/);
  // W184 F2：最下面「收起私訊框」（tatwo.dm.close）：收這份選單所在的那個框（浮動框收浮動、停靠框收停靠，同以前的 ⌄）。
  assert.match(menu, /menu\.addItem\(\.separator\(\)\)\s*let close = AssistantModelMenuItem\(title: "收起私訊框", run: actions\.close\)\s*close\.identifier = NSUserInterfaceItemIdentifier\("tatwo\.dm\.close"\)\s*menu\.addItem\(close\)\s*return menu/);
  assert.match(phone, /static func close\(_ store: GlobalDMStore, surface: GlobalDMSurface\) \{\s*if surface == \.floating \{ store\.isFloatingOpen = false \} else \{ store\.isOpen = false \}/);
  assert.match(phone, /close: \{ \[store\] in close\(store, surface: surface\) \}/);
  // 直達鍵＝打開既有的直達鍵頁。
  assert.match(phone, /store\.isEditingDirectKeys = true/);
  // 系統選單：右鍵在滑鼠那裡跳出、VoiceOver 從圓鈕下方跳出；不用藍色系統鈕。
  assert.match(phone, /menu\.popUp\(positioning: nil, at: point, in: view\)/);
  for (const source of [phone, tent, motion, strip]) {
    assert.doesNotMatch(code(source), /\.blue\b|accentColor|borderedProminent|\.bordered\b|NSAlert|\.menuStyle\(\.button\)/);
  }
});

test('A5／B3 inner landscape: one top bar over two columns; left = this chat (same view in every form), right = Browser or the other chat', () => {
  const box = slice(phone, 'struct GlobalDMPhoneBox: View', '// MARK: - 頂列');
  // 一條頂列；左欄永遠是同一個 GlobalDMBox（HStack 的第一個），外直↔內橫↔內直換形態時對話不重建。
  assert.equal(count(box, 'GlobalDMTopBar(store: store, form: form)'), 1);
  // W184 F2：欄是一個 ZStack：右欄（有進度時）在底下、貼右緣、寬度用內橫最後的寬度、只露出對話欄右邊那一段；分隔線跟著對話欄右緣；
  // 對話欄（同一個 GlobalDMBox，永遠是 ZStack 的最後一個，換形態不重建）貼左緣。
  // W184 G3c（房 C，使用者：「文字頂部漸淡應頂天」）：右欄的裁切往上多留頂列那一段（右欄的訊息列表也延伸到框的上緣）——
  // .padding(.top, 頂列高).clipped().padding(.top, −頂列高)；守的東西不變：右欄貼右緣、寬度用內橫最後的寬度、左右只露出對話欄右邊那一段。
  assert.match(box, /if look\.duo > 0 \{\s*GlobalDMDuoBox\(primary: store, secondary: secondary, model: model, surface: surface, services: browserServices\)\s*\.frame\(width: look\.rightWidth\)\s*\.frame\(width: max\(0, width - chatWidth\), alignment: \.trailing\)\s*(?:\/\/[^\n]*\n\s*)*\.padding\(\.top, DMPhone\.headerHeight\)\s*\.clipped\(\)\s*\.padding\(\.top, -DMPhone\.headerHeight\)\s*\.padding\(\.leading, chatWidth\)/);
  assert.match(box, /Rectangle\(\)\s*\.fill\(Color\.primary\.opacity\(0\.12\)\)\s*\.frame\(width: DMPhone\.hairline\)[\s\S]{0,160}\.padding\(\.leading, chatWidth\)\s*\.opacity\(look\.divider\)/);
  // W183 R12（主導 1，任務版面）：左欄的 GlobalDMBox 包在 GlobalDMTaskCover 裡（任務的左頁蓋在上面；對話不拆）；守的一樣：永遠是同一個、ZStack 的最後一個。
  assert.match(box, /\}\s*(?:\/\/[^\n]*\n\s*)*GlobalDMTaskCover\(store: store\) \{\s*GlobalDMBox\(store: store, model: model, surface: surface, role: form\.isDuo \? \.duoLeading : \.single\)\s*\}\s*\.frame\(width: chatWidth\)\s*\}/);
  assert.match(metrics, /static let duoLeadingFraction: CGFloat = 400 \/ 890/);
  assert.match(metrics, /static let hairline: CGFloat = 0\.5/);
  // 右欄：Browser（有分頁，或按了 Browser 圓鈕；reveal 也開到這裡）否則另一個對象（第二個 store，沒有頂列、不開 Browser）。
  const right = slice(deskViews, 'struct GlobalDMDuoBox: View', '// MARK: - 框內「設定直達鍵」');
  assert.match(right, /DMBrowserPane\(store: primary, browser: services\.browser, flow: services\.flow, connect: services\.connect\)/);
  assert.match(right, /_browser = ObservedObject\(wrappedValue: services\.browser \?\? \.shared\)/);
  assert.match(right, /GlobalDMBox\(store: secondary, model: model, surface: surface, role: \.duoTrailing\)/);
  // DMBrowser.reveal（授權頁、配對頁）在內橫開到右欄、左欄不動；左欄照常送出（isBrowsing 不動，送出的守門照舊）。
  assert.match(store, /func showBrowser\(\) \{\s*isPickerOpen = false\s*isEditingDirectKeys = false\s*guard !browsesBeside else \{ isBrowsingBeside = true; return \}/);
  assert.match(store, /func send\(\) -> Bool \{\n\s*guard !isBrowsing else \{ return false \}/);
  assert.match(deskController, /store\.browsesBeside = form\.isDuo/);
  // 內橫右欄的網頁拿著鍵盤時 Esc 給網頁（同單欄 Browser）。
  assert.match(panels, /if store\.isBrowsingBeside, let responder = window\.firstResponder as\? NSView, GlobalDMNativePageMask\.isInsideNativePage\(responder\) \{/);
  // 單欄時 Browser 開著＝那一欄換成 Browser；內橫的左欄不換。
  assert.match(view, /if store\.isBrowsing, role\.showsBrowser \{\s*(?:\/\/[^\n]*\n\s*)?DMBrowserPane\(store: store, browser: browserServices\.browser/);
  // GPT-6 審查 #5：框裡的 Browser 用哪一份由面板控制器從根畫面給（正式＝nil＝.shared；自測接假的 Browser 驗截圖保護）。
  assert.match(panels, /GlobalDMFloatingRoot\(store: store, desk: desk, morph: buttonMorph\)\s*\.environment\(\\\.globalDMBrowserServices, browserServices\)/);
  assert.match(panels, /GlobalDMDockedBoxRoot\(store: store, desk: desk, morph: dockedMorph\)\s*\.environment\(\\\.globalDMBrowserServices, browserServices\)/);
  assert.match(phone, /private struct GlobalDMBrowserServicesKey: EnvironmentKey \{\s*static let defaultValue = GlobalDMBrowserServices\(\)/);
});

test('tent: no top bar, the whole box is GlobalDMTentContent (room E fills it with the video pane)', () => {
  const box = slice(phone, 'struct GlobalDMPhoneBox: View', '// MARK: - 頂列');
  // W184 F2：兩層（對話、倒放）；換到／離開倒放時先出後進，停著只有其中一層。
  assert.match(box, /if look\.showsTent \{\s*GlobalDMTentContent\(store: store\)/);
  // 倒放那一層沒有頂列：頂列只在對話那一層。
  assert.doesNotMatch(slice(box, 'if look.showsTent {', '\n            }\n'), /GlobalDMTopBar|GlobalDMIconStrip|GlobalDMPageMenu/);
  assert.match(box, /if look\.showsChat \{\s*VStack\(spacing: 0\) \{\s*GlobalDMTopBar\(store: store, form: form\)/);
  assert.match(desk, /static func topBarCount\(form: GlobalDMForm\) -> Int \{ form == \.tent \? 0 : 1 \}/);
  // W184 E：房 AB 的「倒放」佔位字換成房 E 的倒放畫面（影片子畫面、空狀態、三種卡：GlobalDMTentPane）。
  // 守的東西不變：倒放整塊都是房 E 的內容（沒有頂列），識別碼 tatwo.dm.tent 留在這一塊上。
  assert.match(tent, /GlobalDMTentPane\(store: store, model: model, video: \.shared\)/);
  assert.match(tent, /\.accessibilityIdentifier\("tatwo\.dm\.tent"\)/);
});

test('B4 tokens: the shell only uses DMPhone numbers (fonts 17/15/13/11, 44 touch, concentric corner fixed at 52)', () => {
  // W184 F3（使用者 09-29 17:10：「r角現在會變 導致輸入筐根外ｒ角不齊」）：圓角任何形態、大小、轉場中都是 52（不再等比、不走彈簧）。
  assert.doesNotMatch(code(metrics), /func screenRadius\(for/);
  assert.match(phone, /radius = DMPhone\.screenRadius/);
  assert.match(phone, /\.modifier\(GlobalDMBoxChrome\(cornerRadius: look\.radius\)\)/);
  assert.match(phone, /\.environment\(\\\.globalDMScreenRadius, look\.radius\)/);
  // 這幾個檔（與圖示列那段）不寫死字級數字：只用 DMPhone.TextSize。
  const iconSection = slice(strip, 'enum GlobalDMIconStripLayout', '// MARK: - 左右捲的一排');
  for (const [name, source] of [['GlobalDMPhoneBox.swift', phone], ['GlobalDMTentContent.swift', tent], ['icon strip', iconSection]]) {
    assert.doesNotMatch(source, /\.font\(\.system\(size: \d/, name);
    assert.doesNotMatch(source, /\.frame\(width: (2[0-9]|3[0-9]), height/, `${name}: buttons are at least 44`);
  }
  // W184 F：頂列能按的只剩左上的頁面圓鈕（右上 44 的 ⋯、⌄ 拿掉）：它照舊 44。
  assert.match(iconSection, /let size = GlobalDMIconStripLayout\.iconSize[\s\S]*\.frame\(width: size, height: size\)/);
  assert.match(strip, /static let iconSize: CGFloat = DMPhone\.touch/);
});

test('identifiers: old ones kept on their successors, new ones named tatwo.dm.<name>', () => {
  for (const id of ['tatwo.dm.target', 'tatwo.dm.size', 'tatwo.dm.accessibility', 'tatwo.dm.duo',
    'tatwo.dm.floatingBox', 'tatwo.dm.box', 'tatwo.dm.more', 'tatwo.dm.header', 'tatwo.dm.form.', 'tatwo.dm.grip.move', 'tatwo.dm.grip.resize']) {
    assert.ok(phone.includes(`"${id}`), id);
  }
  // W184 F：tatwo.dm.more 掛在頁面圓鈕的右鍵選單上（NSMenu 本身）；tatwo.dm.accessibility 照舊在選單項上。
  // W184 F2：tatwo.dm.close 回來了：掛在右鍵選單最下面的「收起私訊框」（收這份選單所在的那個框）。
  assert.ok(phone.includes('close.identifier = NSUserInterfaceItemIdentifier("tatwo.dm.close")'), 'tatwo.dm.close sits on 收起私訊框');
  assert.ok(strip.includes('"tatwo.dm.targets.strip"') && strip.includes('"tatwo.dm.icon." + item.id'));
  assert.ok(tent.includes('"tatwo.dm.tent"'));
  assert.match(read('DM/GlobalDMDeskController.swift'), /setAccessibilityIdentifier\("tatwo\.dm\.desk\.bubblePanel"\)/);
});

test('executable self-test w184forms covers the brief', () => {
  const self = read('SelfTest.swift');
  assert.match(self, /TATWO2_SELFTEST"\] == "w184forms"[\s\S]{0,200}GlobalDMFormsAcceptance\.run\(\)/);
  const acceptance = read('DM/GlobalDMFormsAcceptance.swift') + read('DM/GlobalDMFormsSafetyAcceptance.swift') + read('DM/GlobalDMFormsGripAcceptance.swift')
    + read('DM/GlobalDMFormsEdgeAcceptance.swift');
  assert.match(read('DM/GlobalDMFormsEdgeAcceptance.swift'), /^#if DEBUG/);
  assert.match(slice(read('DM/GlobalDMFormsAcceptance.swift'), 'static func run() async throws -> Bool {', 'W184FORMS SUMMARY'), /await edgeLineChecks\(check, freshDefaults, model: fixture\.model\)/);
  assert.match(acceptance, /^#if DEBUG/);
  assert.match(acceptance, /NativeStagingIsolation\.validationError\(environment\) == nil/);
  assert.match(acceptance, /isolated engine homes must be logged out/);
  for (const label of ['A1 four forms: outer portrait 466×678', 'A1 ⌘⌥Tab order', 'A2 every form shrinks proportionally',
    'A2 docked inner landscape in a narrow window keeps its proportions', 'A3 old expand sizes map',
    'B1 ⌘⌥Tab is not registered while the box is folded', 'B1 folding the box releases ⌘⌥Tab right away',
    'B2 each ⌘⌥Tab moves to the next form', 'B3 during a transition ⌘⌥Tab and setForm turn straight to the new form',
    'B5 the page circle\'s menu says ⌘⌥Tab is taken', 'C1 every change slides (menu jumps too)', 'C2 a critically damped spring, response 0.42',
    'the bottom-right corner stays, the left and top edges move one way, at 0.6 s it is the new box (≤1pt)',
    'C4 into inner landscape: the chat column narrows from the whole box to the left column',
    'C4 out of inner landscape: the chat column widens to the whole box', 'C5 swapping content (a form ↔ the tent): at 0.10 s both layers are ≤ 0.05',
    'C5 the two layers are never half-transparent together', 'C6 turning mid-way keeps the position and speed (no jump)',
    'C7 reduce motion: the whole box fades out (0.12 s), switches to the new box, fades in (0.15 s)',
    'C8 a native page is only hidden while the transition holds the mask',
    'C8 counterexample: a page moved to another container during the transition is still shown again',
    'C8 counterexample: a page attached (or re-attached elsewhere) during the transition stays hidden',
    'C8 outside a transition attach always shows the page', 'C8 a card covering the tent video keeps it hidden',
    'C8 a slide keeps native pages hidden the whole way', 'D7 收起私訊框 (tatwo.dm.close) is the last item and closes the box the menu sits on',
    'H1 outer portrait → inner landscape → inner portrait → outer portrait on the real panel: the chat is the same GlobalDMBox all along',
    'H2 while sliding the stage layers only animate position, size and opacity', 'H3 each slide drawn from the real panel\'s layer stage at 0.03 / 0.08 / 0.14 / 0.24 / 0.6 s into a PNG strip',
    'H4 the canvas is swapped in once', 'H4 (d) turning mid-way (outer portrait → inner landscape → inner portrait)',
    'H5 once it settles the panel is exactly the new box + margin',
    'D20 the only limit is 44pt of the top bar inside', 'D20 a remembered place is laid out by the same rule',
    'D20 the docked box can go anywhere in the main window\'s content, over the composer too', 'D21 remembered per box — floating, docked and the desktop-bubble box apart',
    'D22 two corners scale in proportion', 'D23 desktop-bubble mode: a box dropped over the bubble', 'D10 回到預設位置與大小 shows in the page circle\'s menu only after a drag or a resize',
    'D8 (G1b) the top-bar grip hands a press to the system window drag', 'D24 the native drag path (injected press on the top-bar grip)',
    'D25 on a real floating panel the box can sit mostly off-screen', 'D26 corner resize on a real panel', 'D33 counterexample (GPT-6 G1b #2)', 'D32 counterexample (GPT-6 G1b #2)', 'D23 counterexample (GPT-6 G1b #4)', 'D27 counterexample (GPT-6 G1b #4)', 'D31 counterexample (GPT-6 G1b #1) mode switch mid-drag', 'D31 counterexample (GPT-6 G1b #1) collapsing mid-drag', 'D30 (GPT-6 G1b #6)', 'D16 counterexample (G1b): a form change while the window server drags the box',
    'D27 desktop-bubble mode: the box opens beside the bubble, can be dragged', 'D28 in all four forms', 'D29 cursors', 'D11 PNGs: scaled to 0.7, scaled to 1.3, dragged to the top-left corner',
    'G1 tent + a direct key: the phone stands up', 'G2 during a transition 到私訊框設定 is queued',
    'G3 tent + a flow opening its page (DMBrowser.reveal)', 'G3 a reveal during a transition is queued',
    'G4 outside the tent a direct key opens right away', 'G5 counterexample (new finding 1): docked box open → 到私訊框設定 queued',
    'G5 a direct key queued over a docked box', 'G6 counterexample (new finding 2): cancel first, dequeue later',
    'G6 counterexample (new finding 2): the ［連線］ card shown during a transition', 'G6 re-checked before dequeue', 'G6 cancelling twice reports once',
    'G6 two pages queued in one transition', 'G7 counterexample (new finding 3): docked box open → a flow\'s page queued',
    'G7 counterexample (new finding 3): the ［連線］ card the same way', 'G7 a change the user made after the open is kept', 'G8 the tent card\'s 打開私訊框 stands up and switches to the chat without reopening', 'D2 open strip: the current page first', 'D3 hover opens the strip',
    'D5 page circle\'s menu: the four forms (current ticked)', 'D5 page circle\'s menu: direct keys, the ⌥⌘ note',
    'D4 the bar is still 68 high in chat and Browser alike and the strip keeps its place top-left',
    'D6 the page circle keeps its place top-left', 'D6 nothing is drawn top-right in any form with a top bar: ⋯ and ⌄ are gone',
    'D6 the bar is 68 high whether the strip is folded or open', 'no top bar draws the grab handle any more', 'DK1 counterexample: forcing the dark appearance on the paper theme', 'DK2 (W184 AB, GPT-6 third review #6) the real main window', 'DK3 (W184 AB, GPT-6 third review #6) the Island keeps following the system',
    'E4 (W184 AB, GPT-6 third review #5) turning again before the slide stops', 'H12 (W184 AB, GPT-6 third review #7) the deferred new look',
    'AB (GPT-6 third review #7) every Retina-sized run', 'DK1 (W184 AB, .031 on the real device) with the system dark, the paper theme (fable5) keeps the whole app light',
    'AB (.031 on a Retina MacBook: 251ms) press to first moving frame with Retina-sized captures',
    'AB with Retina-sized captures the new look is on the stage ≤150ms after the slide started in every direction', 'E1 (W184 AB, user 09-30 on .031: extra edge lines while the switch expands)',
    'E2 (W184 AB) while the chat container is wider than the new chat column', 'E3 (W184 AB) the inner-landscape right column follows the split', 'D7 right-click on the page circle opens the menu',
    'D7 control-click on the page circle opens the same menu', 'D7 a plain click is not taken', 'D7 VoiceOver\'s show-menu (the circle\'s AX action',
    'D7 counterexample (GPT-6 #6): a real left click on the page circle', 'D15 counterexample (GPT-6 #7): the move and both resize grips have identifiers',
    'H4 (b) the layer stage runs the model', 'H10 (a) the real SwiftUI box lays out only when the slide starts', 'H11 (c) the stop frame', 'H11 the pictures have nothing outside the 52 corner', 'F3 capture: every shadow is muted while capturing', 'H12 ',
    'the panel changes size exactly twice per transition (start, stop)', 'H7 the chat column on the stage follows the model',
    'H2 on the real panel the stage only animates position, size and opacity', 'H9 the Browser page and the tent video in the panel\'s canvas stay hidden',
    'H8 reduce motion on the real panel', 'the same scroll view keeps its visible message within 20pt',
    'H6 the docked box slides too', 'D12 counterexample (GPT-6 #4): moving the main window while the docked box slides',
    'D12 counterexample (GPT-6 #4): making the main window smaller', 'D13 (G1b) the docked box can be dropped anywhere in the main window\'s content, over the composer too',
    'T3 counterexample (fix-check #7)', 'S8', 'T4 counterexample (real device v2.0.21.030)', 'C9 (real device, inner landscape at 0.8)',
    'D14 counterexample (verify #5)', 'T1 counterexample (verify #6)', 'T2 counterexample (verify #8)',
    'S0 the authorisation page is on screen in the real floating box', 'SB0 the pairing page and its code are on screen',
    'S1', 'S2', 'S3', 'S4', 'S5', 'S6', 'S7 after every scenario the native-page mask is released', 'S9 (A6) every picture the layer stage used', 'A1 counterexamples (GPT-6 F3 #1)', 'S10 (A6) mid-slide the code appearing', 'H13 (A4)', 'H14 (A2)', 'H12 (F3)', 'H12 (A3)', 'H12 (A3, W184 AB) the streaming case really streams',
    'A2 the box corner stays 52 in every form at 0.7 / 1 / 1.3 scale and the composer stays 40', 'A2 drawn: every form at 0.7 and 1.3 keeps the 52 corner',
    'D7 the right-click menu has every item the ⋯ menu had', 'E1 inner landscape: left = this target',
    'E1 one top bar across both columns', 'E2 in inner landscape DMBrowser.reveal opens the page in the right column',
    'E3 with the Browser in the right column the left column still sends', 'F1 each of the four forms rendered to PNG',
    'F2 outer portrait with the strip open', 'F3 inner landscape, one top bar over two columns', 'W184FORMS SUMMARY failures=']) {
    assert.ok(acceptance.includes(label), label);
  }
  assert.doesNotMatch(acceptance, /check\(true,/);
  // W184 AB（.031 真機：深色模式下 fable5 紙底照樣淺、字卻變白）：紙底固定淺色的主題＝App 固定淺色外觀；極光＝跟系統。
  const theme = read('Visual/TatwoTheme.swift');
  assert.match(theme, /var fixedLightAppearance: Bool \{ !usesGlass \}/);
  assert.match(slice(theme, 'private func apply() {', '\n    }\n'), /applyAppearance\(\)/);
  // W192b 深色證據只在 DEBUG 覆寫；正式版紙主題與不重複設定外觀的保證照舊。
  assert.match(slice(theme, 'private func applyAppearance() {', '\n    }\n'), /var wanted: NSAppearance\.Name\? = active\.palette\.fixedLightAppearance \? \.aqua : nil\s*#if DEBUG\s*if ProcessInfo\.processInfo\.environment\["TATWO2_SELFTEST_DARK"\] == "1" \{ wanted = \.darkAqua \}\s*#endif\s*guard app\.appearance\?\.name != wanted else \{ return \}\s*app\.appearance = wanted\.flatMap \{ NSAppearance\(named: \$0\) \}/);
  // 主導裁決（GPT-6 第三輪 #6）：fable5＝整個 App 一致的淺色紙主題；本來就跟著系統明暗的 Island 照舊跟系統。
  // 跟著系統的外觀放在 Island 那個檔（tests/island-hover.test.mjs 單獨編譯它也編得過）。
  const island = read('Shell/TatwoIslandShell.swift');
  assert.match(island, /enum TatwoSystemAppearance \{[\s\S]*?static var isDark: @MainActor \(\) -> Bool = \{ UserDefaults\.standard\.string\(forKey: "AppleInterfaceStyle"\) == "Dark" \}/);
  assert.match(island, /AppleInterfaceThemeChangedNotification/);
  assert.match(island, /TatwoSystemAppearance\.follow\(self\)/);
  assert.doesNotMatch(theme, /enum TatwoSystemAppearance/);
  // DK2 用真的主視窗（TatwoWorkOSWindow＋App 的外框與紙底）＋真的 Browser 網址列；不是另建的單行字視窗。
  const forms = read('DM/GlobalDMFormsAcceptance.swift');
  const dk2 = slice(forms, 'static func realMainWindowOmnibox() -> (ok: Bool, note: String) {', '\n    }\n\n');
  assert.match(dk2, /TatwoWorkOSWindow\(/);
  assert.match(dk2, /window\.configureTatwoChrome\(\)\s*window\.applyTatwoWindowSurface\(\)/);
  assert.match(dk2, /EmbeddedBrowserToolbar\(/);
  assert.doesNotMatch(slice(forms, 'static func darkModeChecks(', 'static func realMainWindowOmnibox'), /Text\("深色系統下看得清楚的字/);
});

// W184 F3T（GPT-6 審查 F3 第 4、5 條；房 F3T 只寫測試）：換形態的回歸自測（DM/GlobalDMFormsRegressionAcceptance.swift）。
// 這裡守的是「那幾條自測真的在、量的東西與門檻沒被放鬆」；實際的數字、畫面在 `TATWO2_SELFTEST=w184forms` 的 R1–R5。
test('W184 F3T regression self-test (GPT-6 F3 #4, #5): bottom anchor, reading old messages, composing input, start cost, always settles', () => {
  const forms = read('DM/GlobalDMFormsAcceptance.swift');
  const regression = read('DM/GlobalDMFormsRegressionAcceptance.swift');
  const body = code(regression);
  // 守：w184forms 的 run 真的呼叫新檔（在 SUMMARY 之前），新檔只在 DEBUG 編譯。
  assert.match(slice(forms, 'static func run() async throws -> Bool {', 'W184FORMS SUMMARY'), /await regressionChecks\(check, freshDefaults, model: fixture\.model\)/);
  assert.match(regression, /^#if DEBUG/);
  assert.match(regression, /#endif\s*$/);
  // 守：換形態走使用者的入口（桌面控制器的 setForm）；轉向＝動畫中再 setForm 一次（不是自測直接叫 applyForm 繞過入口）。
  assert.match(body, /let accepted = desk\.setForm\(segment\.to\)/);
  assert.match(body, /landing\.turned = desk\.setForm\(turnTo\) && panels\.formMotion\.isAnimating && canvas\.stage != nil/);
  assert.doesNotMatch(body, /panels\.applyForm\(|panels\.prepareForm\(/);
  // 守（#4）：一圈裡有變矮、變高，兩段中途轉向（動畫中第 9、8 格再換）。
  assert.match(body, /RegressionSegment\(to: \.innerLandscape, label: "outer→land \(shorter\)"\)/);
  assert.match(body, /RegressionSegment\(to: \.outerPortrait, label: "innerP→outer \(shorter\)"\)/);
  assert.match(body, /turnAt: 9, turnTo: \.innerPortrait/);
  assert.match(body, /turnAt: 8, turnTo: \.innerLandscape/);
  // 守（#4 R1、R2）：門檻照施工單——停下離最底 ≤1pt；看舊訊息 ±20pt（同 H1）且不被拉到最底；停下那一刻（同一個 tick 裡：先量位置、
  // 再看停著的樣子）與 0.15 秒後各量一次。
  assert.match(body, /static let regressionBottomTolerance: CGFloat = 1\n/);
  assert.match(body, /static let regressionReadingTolerance: CGFloat = 20\n/);
  // W193：冷初始化只加一段不計分轉換，回外直後仍重設並跑原本的閱讀位置斷言。
  const warmup = body.indexOf('let coldMarkers = readMarkers(list, "cold-probe-start")');
  const reset = body.indexOf('label: "W193 unscored return to outer"', warmup);
  const scored = body.indexOf('let start = await regressionScroll(list, fromTopRetrying: 200)', reset);
  assert.ok(warmup >= 0 && reset > warmup && scored > reset);
  assert.ok(body.includes('W193 R2 unscored cold probe held='));
  assert.match(body, /if !panels\.formMotion\.isAnimating \{\s*atStop\(\)\s*stopState = settledState\(\)\s*break/);
  assert.match(body, /let stopOK = atStop\.map \{ abs\(\$0\) <= bottomTolerance \} \?\? false\s*let laterOK = abs\(later\) <= bottomTolerance/);
  // 守（#4 R2）：看舊訊息的「位置」照畫面判斷——看得到的那一塊讀出每一則的開頭（Vision）。W184 AB（GPT-6 審 G3c #4）：在讀的那一則＝
  // 頂列底下看得到的第一則（開頭那一行在頂列下緣 DMPhone.headerHeight 以下），不是藏在頂列底下只露一截的那一則；停下那一刻與 0.15 秒後
  // 在畫面上找同一則，上下差 ≤20pt，而且沒被拉到最底（捲動位移本身在欄寬不同的形態之間會因為重新換行而變，不拿它比）。
  assert.match(body, /let read = regressionReadLines\(canvas\.host, rect: canvas\.host\.convert\(list\.contentView\.bounds, from: list\.contentView\)\)/);
  assert.match(body, /let request = VNRecognizeTextRequest\(\)/);
  assert.match(body, /let covered = max\(0, DMPhone\.headerHeight - viewportTop\)/);
  assert.match(body, /func firstBelow\(_ markers: \[\(marker: String, y: CGFloat\)\]\) -> \(marker: String, y: CGFloat\)\? \{\s*markers\.first \{ \$0\.y >= covered \}\s*\}/);
  assert.match(body, /func found\(_ markers: \[\(marker: String, y: CGFloat\)\]\) -> CGFloat\? \{ markers\.first \{ \$0\.marker == anchor\.marker \}\?\.y \}/);
  assert.match(body, /let stopOK = stopY\.map \{ abs\(\$0 - anchor\.y\) <= readingTolerance \} \?\? false\s*let laterOK = laterY\.map \{ abs\(\$0 - anchor\.y\) <= readingTolerance \} \?\? false\s*let notPulled = \(atStop\?\.bottom \?\? 0\) > readingTolerance && bottom > readingTolerance\s*let held = slid\(segment, landing\) && same && stopOK && laterOK && notPulled/);
  // 原案例：固定捲到離最上面 200pt（不對齊；起點離 200 超過 2pt＝不過），讀不到＝不過。另加：房 C 的對齊（第一則在頂列底下 16pt）守頂列底下
  // 露出的下一則；反例：關掉產品守住在讀的那一則（自測才有的開關），這一組要抓得到。
  assert.match(body, /let start = await regressionScroll\(list, fromTopRetrying: 200\)/);
  assert.match(body, /readingHeld = abs\(start - 200\) <= 2 && startBottom >= 400/);
  assert.match(body, /readingNotes\.append\("start: offset \\\(fmt\(start\)\), NOTHING READ below the top bar/);
  assert.match(body, /guard let row = rows\.current\[id\], row\.top \+ row\.lead <= -12, row\.bottom > covered,\s*let reading = firstBelow\(markers\), reading\.marker != first\.marker else \{ return \(first, nil, markers\) \}/);
  assert.match(body, /GlobalDMPanelCanvas\.keepsReading = false\s*let bare = await placeAligned\("counter-start"\)/);
  assert.match(body, /if let moved = result\.moved, moved <= readingTolerance \{ continue \}\s*caught = true/);
  assert.match(body, /GlobalDMPanelCanvas\.keepsReading = true\s*print\("W184FORMS NOTE R2 counterexample/);
  // 守（#4，查核加強 #5）：「離最底多近算在最底」兩邊都釘住（產品的線是 8pt）——離最底 90pt 看訊息：變矮的兩段（外直→內橫、內直→外直）
  // 最上面那一則與位置不變、沒被拉到最底（線放寬就抓得到）；離最底 4pt 算在最底：變矮停下拉回最底、變高回來還在最底（線收窄就抓得到）。
  assert.match(body, /static let regressionNearBottom: CGFloat = 90\n/);
  assert.match(body, /static let regressionPinnedBottom: CGFloat = 4\n/);
  assert.match(body, /\(true, RegressionSegment\(to: \.innerLandscape, label: "outer→land \(shorter\)"\)\),\s*\(false, RegressionSegment\(to: \.innerPortrait, label: "land→innerP \(taller, not judged\)"\)\),\s*\(true, RegressionSegment\(to: \.outerPortrait, label: "innerP→outer \(shorter\)"\)\)/);
  // 起點：捲到離最底 90pt（重試到位），不對齊（W184 AB：舊的做法把讀到的第一則對齊到頂端 2pt——G3c 以後那裡在頂列底下，對齊會捲過最底）；
  // 判定同上：頂列底下看得到的第一則。起點離最底 20–150pt（過了 8pt 線、還在最底附近）。
  assert.match(body, /let nearStart = await regressionScroll\(list, fromBottom: nearBottom\)/);
  assert.doesNotMatch(body, /fromBottom: start - \(top\.y - 2\)|placeNearBottom/);
  assert.match(body, /guard let nearAnchor = firstBelow\(startMarkers\) else \{\s*held = false/);
  assert.match(body, /let result = await judge\(step\.segment, nearAnchor\)\s*held = held && nearStart >= 20 && nearStart <= nearBottom \+ 60 && result\.held/);
  // W184 AB（j-int 063110 查證）：「最底上面一點點」一定判定——讀不到字＝不過（不是 skip）；前面幾項留下的尾巴（H12 串流那幾列，帶讀得到的
  //「第 1xx 個回答」）與乾淨的尾巴（最後接新的問答）兩種都判。
  assert.doesNotMatch(body, /check\.skip\("R2 最底上面一點點|check\.skip\("R2 看舊訊息：這個環境讀不出/);
  assert.match(body, /notes\.append\("\\\(step\.segment\.label\): NOTHING READ below the top bar at the start/);
  assert.match(body, /let leftover = await nearBottomGroup\("tail left by earlier checks"\)/);
  assert.match(body, /let clean = await nearBottomGroup\("clean tail"\)/);
  // 乾淨的尾巴：接上新列後照正式的 onChange 通知畫面（自測的模型是 fixture，不接引擎的 onChange），等最後一則真的畫出來才開始；
  // 沒進來＝不過（寫明），不是 skip。
  assert.match(body, /engine\.appendOfflineRows\(threadID: assistant, rows: rows\)\s*model\.objectWillChange\.send\(\)/);
  assert.match(body, /if GlobalDMListRows\.of\(list\)\?\.current\["w184f3t-clean-15"\] != nil \{\s*arrived = true/);
  assert.match(body, /cleanNotes = \["clean tail: the 16 new rows never showed up in the list \(3s\)"\]/);
  assert.match(body, /check\(leftover\.held && cleanHeld,/);
  // 產品的規則（純計算）也在自測裡釘住：只露一截的不算、字那一行露出來的泡泡算、一則長的佔滿就是它；差距先用它自己、沒量到用最近的。
  assert.match(body, /check\(halfHidden == "below" && bubbleShows == "edge" && answerCut == "next" && tall == "tall"/);
  assert.match(forms, /text: "第 \\\(100 \+ count\) 個回答（串流中的回覆第 \\\(count\) 段）：動畫期間內容還在長。"/);
  assert.match(body, /let pinnedStart = await regressionScroll\(list, fromBottom: regressionPinnedBottom\)/);
  assert.match(body, /pinnedHeld = pinnedHeld && slid\(segment, landing\) && same && stopOK && abs\(later\) <= bottomTolerance/);
  // 守（#4 R3）：組字中的輸入框——setMarkedText 造組字、比 first responder、marked range 與文字、已確定文字、選取範圍（整組相等才算）。
  assert.match(body, /composer\.setMarkedText\(composingText, selectedRange: NSRange\(location: 1, length: 2\)/);
  assert.match(body, /RegressionComposing\(responder: window\.firstResponder === composer, marked: range, markedText: markedText,\s*committed: committedText, selected: composer\.selectedRange\(\)\)/);
  assert.match(body, /let same = atStop == baseline && later == baseline && inTree/);
  // 守（#5 R4）：從按下去之前量到第一個看得到的畫面（display link 第一格），門檻 150ms。查核加強 #4：每個方向各量三次、各自的中位數逐一比
  //（不是三個方向混在一起取中位數）；另量三次真的時鐘轉向的開始成本（從第二次按下去到之後的第一格）；內橫右欄的第二個 store 在 setForm
  // 裡照正式那樣同步（自測自己的 suite、右欄的對象先記一條 session：不叫醒 ChatGPT）。
  assert.match(body, /let pressed = CACurrentMediaTime\(\)[^\n]*\n\s*result\.accepted = desk\.setForm\(to\)/);
  assert.match(body, /if let first = stamps\.first\(where: \{ \$0 >= returned \}\) \{ result\.toFrame = \(first - pressed\) \* 1000 \}/);
  assert.match(body, /static let regressionStartBudget: Double = 150\n/);
  assert.match(body, /static let regressionStartRounds = 3\n/);
  assert.match(body, /let values = plainRuns\.filter \{ \$0\.label == label \}\.map \{ firstVisible\(\$0\) \}/);
  assert.match(body, /check\(allStaged && perDirection\.allSatisfy \{ \$0\.values\.count == rounds && \$0\.median >= 0 && \$0\.median <= regressionStartBudget \},/);
  assert.doesNotMatch(body, /median >= 0 && median <= regressionStartBudget/, 'no single median over all directions');
  assert.match(body, /result\.turnPressed = CACurrentMediaTime\(\)[^\n]*\n\s*result\.turnAccepted = desk\.setForm\(turn\.to\)/);
  assert.match(body, /result\.turnToFrame = \(first - result\.turnPressed\) \* 1000/);
  assert.match(body, /turnMedian >= 0\s*&& turnMedian <= regressionStartBudget/);
  assert.match(body, /let duo = GlobalDMDuo\(defaults: duoDefaults\)/);
  assert.match(body, /defaults\.set\(GlobalDMTarget\.thread\(session\.id\)\.storageValue, forKey: GlobalDMStore\.lastTargetKey\)/);
  assert.match(body, /panels: panels, duo: duo, browser: browser\)/);
  // 守（#5 R5）：每一段收尾驗——不在轉換、圖層台拆掉（查核加強 #1：畫布上沒有圖層台的 view，點擊在框中央與每一個輸入框中心都打到真的框）、
  // 真的框透明度 1、遮蔽放掉（頁面顯示回來、佔位色還原）、配對碼的轉換遮蔽關掉、面板在該在的位置。
  assert.match(body, /let ok = !animating && !staged && alpha == 1 && filled && placed && !masking && hiddenPages == 0 && pagesShown && pageBack && tentBack\s*&& !codeSuppressed && stageViews == 0 && clicks\.ok && hostShown/);
  assert.match(body, /let stageViews = canvas\.subviews\.filter \{ \$0 is GlobalDMStageView \}\.count/);
  assert.match(body, /let composers = DMBrowserPhoneAcceptance\.views\(ChatComposerTextView\.ComposerNSTextView\.self, in: host\)/);
  assert.match(body, /let hit = canvas\.hitTest\(canvas\.convert\(point, to: superview\)\)\s*if hit\.map\(\{ \$0\.isDescendant\(of: host\) \}\) != true \{/);
  // 反例（自測自己放一個圖層台的 view，不動產品程式）：停著的樣子要抓到它（找到那個 view、框中央的點擊打到它），拿掉之後又是乾淨的。
  assert.match(body, /canvas\.addSubview\(leftover, positioned: \.above, relativeTo: canvas\.host\)/);
  assert.match(body, /check\(!withLeftover\.ok && withLeftover\.detail\.contains\("stageViews=1"\) && withLeftover\.detail\.contains\("centre → GlobalDMStageView"\)\s*&& withoutLeftover\.ok,/);
  // 守（#5 R5）：計時器晚到（主執行緒卡 0.3 秒橫跨該停下的時間、動畫中段卡 0.3 秒）、display link 全停、event tracking 模式、配對碼畫回來。
  assert.match(body, /\.blockAcrossStop\(length: 0\.3\)/);
  assert.match(body, /\.block\(at: 0\.15, length: 0\.3\)/);
  assert.match(body, /RunLoop\.main\.run\(mode: \.eventTracking/);
  assert.match(body, /static let regressionSettleSlack: Double = 0\.25\n/);
  assert.match(body, /DMBrowserPhoneAcceptance\.codeDrawn\(in: panel\) && !DMSecretCodeView\.suppressed && WindowCaptureShield\.shared\.isShielding\(panel\)/);
  // 守（查核加強 #3）：display link 全停＝面板移到所有螢幕之外（框跟每個螢幕都不相交）＋自測自己的 link 停掉（之後一格都沒有），照樣準時收好。
  assert.match(body, /\.linksStopped\(at: 0\.15\)/);
  assert.match(body, /panel\.setFrameOrigin\(regressionOffscreenOrigin\(\)\)/);
  assert.match(body, /result\.offscreen = !NSScreen\.screens\.contains \{ \$0\.frame\.intersects\(panel\.frame\) \}/);
  // 移開之後綁在畫布上的 link 一格都沒收到（＝綁在面板 view 上的 display link 在所有螢幕之外真的停了）也要成立。
  assert.match(body, /check\(onTime\(stopped\) && stopped\.offscreen && stopped\.framesOffscreen == 0 && stopped\.pausedAt > 0 && stopped\.ticksAfterPause == 0,/);
  assert.match(body, /let stoppedOK = codedStopped\.offscreen && codedStopped\.framesOffscreen == 0 && codedStopped\.pausedAt > 0 && codedStopped\.ticksAfterPause == 0/);
  // 守（查核加強 #2）：真的時鐘的轉向（0.3 秒；卡住主執行緒的那一段 0.35 秒），轉向那一刻用 plan.end − elapsed 重算該停下的時間，
  // 停下晚不超過 0.1 秒（計時器沒扣掉已經走的時間就晚 ≥0.3 秒）；轉向要在第一段該停下之前（動畫中）；配對碼那一組也有一段轉向。
  assert.match(body, /static let regressionTurnAt: Double = 0\.3\n/);
  assert.match(body, /static let regressionBlockedTurnAt: Double = 0\.35\n/);
  assert.match(body, /static let regressionTurnSlack: Double = 0\.1\n/);
  assert.match(body, /let end = panels\.formMotion\.plan\?\.end \?\? 0\s*result\.settleAt = result\.turnReturned \+ max\(0, end - panels\.formMotion\.elapsed\)/);
  // 轉向至少在第 3×slack 秒（≥0.3 秒）：計時器沒扣掉已經走的時間就晚這麼多（這一段有抓到它的力氣）。
  assert.match(body, /slide\.turnStart >= turnSlack \* 3 && slide\.turnStart < slide\.firstEnd\s*&& slide\.finished && slide\.late <= turnSlack \* 1000 && slide\.cleanAtStop && slide\.cleanLater/);
  assert.match(body, /turn: \(at: regressionTurnAt, to: \.innerPortrait\)\)/);
  assert.match(body, /\.blockAcrossStop\(length: 0\.3\),\s*label: "outer→land turned at 0\.35s→innerP[^"]*",\s*turn: \(at: regressionBlockedTurnAt, to: \.innerPortrait\)\)/);
  assert.match(body, /blockedTurn\.turnStart >= turnSlack \* 3 && blockedTurn\.turnStart < blockedTurn\.firstEnd && blockedTurn\.blockEnd > blockedTurn\.settleAt\s*&& blockedTurn\.cleanAtStop && blockedTurn\.cleanLater && blockedTurn\.lateAfterRelease <= turnSlack/);
  assert.match(body, /check\(turnRuns\.count == rounds && turnRuns\.allSatisfy \{ turnedOnTime\(\$0\) \},/);
  assert.match(body, /check\(settled && stoppedOK && turnedOnTime\(codedTurn\) && codeBack\(\),/);
  for (const label of [
    'R1 (F3T, GPT-6 F3 #4) bottom anchor on the real panel', 'R2 (F3T, GPT-6 F3 #4) reading old messages',
    'R2 (W184 AB, GPT-6 G3c #4; extra case, kept beside the original)', 'R2 (W184 AB, GPT-6 G3c #4) counterexample',
    'R2 rule (W184 AB, GPT-6 G3c #4)',
    'R2 (F3T, GPT-6 F3 #4) reading just above the bottom', 'R1 (F3T, GPT-6 F3 #4) within 8pt of the bottom counts as at the bottom',
    'R3 (F3T, GPT-6 F3 #4) composing', 'R4 (F3T, GPT-6 F3 #5) start cost measured from before the user\'s entry',
    'R4 (F3T, GPT-6 F3 #5) start cost of a real-clock turn',
    'R5 (F3T, GPT-6 F3 #5) late settle timer', 'R5 (F3T, GPT-6 F3 #5) main thread blocked 0.3s mid-slide',
    'R5 (F3T, GPT-6 F3 #5) display link stopped mid-slide', 'R5 (F3T, GPT-6 F3 #5) the run loop held in event-tracking mode',
    'R5 (F3T, GPT-6 F3 #5) a real-clock turn mid-slide', 'R5 (F3T, GPT-6 F3 #5) a real-clock turn (setForm again 0.35s in) with the main thread blocked',
    'R5 (F3T, GPT-6 F3 #5) with a pairing code on screen', 'R5 (F3T, GPT-6 F3 #5) every segment above ends clean',
    'R5 (F3T, GPT-6 F3 #5) counterexample: a layer-stage view left on the canvas after a stop']) {
    assert.ok(regression.includes(label), label);
  }
  // 守：沒有永遠會過的斷言。
  assert.doesNotMatch(regression, /check\(true,/);
});

// W184 F3T（查核加強 #3）：換形態的收尾只靠停下的計時器（GlobalDMFormMotion.scheduleSettle）——這三個產品檔不准有 display link
//（CADisplayLink、NSView／NSWindow／NSScreen 的 displayLink(…)、CVDisplayLink）。R5「display link stopped」那一段把面板移到所有螢幕之外、
// 停掉自測自己的 link：產品若自己加一條 link 來收尾（例如串流中的動畫），面板離開螢幕、螢幕睡眠、被整個蓋住時那條 link 不回呼＝轉換收不掉，
// 而那一段自測不一定停得到產品的 link（還在跑就照樣準時收，退步漏掉）。要加 link 的人先改 R5 那一段（讓它停得到產品的 link）再改這裡。
test('W184 F3T the form change settles on its timer, never on a display link in the product (R5 "display link stopped")', () => {
  for (const [name, source] of [['GlobalDMFormMotion.swift', motion], ['GlobalDMFormStage.swift', read('DM/GlobalDMFormStage.swift')],
    ['GlobalDMPanelController.swift', panels]]) {
    assert.doesNotMatch(code(source), /displayLink\(|CADisplayLink|CVDisplayLink/, name);
  }
  // 收尾的計時器在 .common 模式（選單開著、拖曳中照樣會響）：R5 event tracking 那一段靠它。
  assert.match(slice(motion, 'private func scheduleSettle() {', '\n    }\n'), /RunLoop\.main\.add\(timer, forMode: \.common\)/);
});

// W184 AB（R2；GPT-6 審 G3c 第 4 條）：列表頂天以後，使用者在讀的是「頂列底下看得到的第一則」；換形態時守住它的位置（F3 的錨點）。
test('W184 AB R2 (GPT-6 G3c #4): a form change keeps the message being read — the first one whose start shows below the top bar', () => {
  const anchor = read('DM/GlobalDMListAnchor.swift');
  // 守：規則——在捲動區裡、跨過頂列下緣以下的；第一行字在頂列下緣以下（最多 3pt 在底下：行框到字形頂端）的最上面那一則；
  // 沒有＝跨過頂列下緣的那一則（一則長的佔滿）。
  assert.match(anchor, /static let lineSlack: CGFloat = 3\n/);
  assert.match(anchor, /let shown = rows\.filter \{ \$0\.value\.bottom > covered && \$0\.value\.top < viewport \}/);
  assert.match(anchor, /shown\.filter\(\{ \$0\.value\.top \+ \$0\.value\.lead >= covered - lineSlack \}\)\.min\(by: \{ \$0\.value\.top < \$1\.value\.top \}\)/);
  assert.match(anchor, /if let spanning = shown\.max\(by: \{ \$0\.value\.top < \$1\.value\.top \}\)/);
  // 守：只看現在畫面上的——捲過以後沒再量的列（捲出去不畫，遮罩不重算）位置是舊的，不算（j-int 073855 量到一則早就捲走的串流列被當成在讀的）。
  assert.match(anchor, /let offset = content\.minY - frame\.minY\s*rows\[id\] = Row\(top: frame\.minY, bottom: frame\.maxY, lead: lead, offset: offset, fresh: true\)\s*latestOffset = offset/);
  assert.match(anchor, /var current: \[String: Row\] \{\s*rows\.filter \{ abs\(\$0\.value\.offset - latestOffset\) <= 0\.5 \}\s*\}/);
  assert.match(anchor, /var reading: \(id: String, top: CGFloat\)\? \{\s*Self\.reading\(current, covered: covered, viewport: viewport\)\s*\}/);
  // 守：差距——它自己這一輪量過就用它；沒量到用這一輪量過、之前也在、離它最近的那一則；什麼都沒量到＝不動（nil）。
  assert.match(anchor, /let now = current\.filter \{ \$0\.value\.fresh \}\s*if let row = now\[snapshot\.id\] \{ return row\.top - snapshot\.top \}/);
  assert.match(anchor, /for \(id, row\) in now \{\s*guard let before = snapshot\.tops\[id\] else \{ continue \}/);
  assert.match(anchor, /func snapshot\(\) -> Snapshot\? \{\s*guard let reading else \{ return nil \}\s*let result = Snapshot\(id: reading\.id, top: reading\.top, tops: current\.mapValues\(\\\.top\)\)\s*beginPass\(\)/);
  // 守：位置記錄掛在捲動區裡（找得到「這個捲動區的列表」），點不到、不進輔助使用。
  assert.match(anchor, /if let probe = view as\? GlobalDMListRowsProbeView, probe\.enclosingScrollView === scroll \{ return probe\.rows \}/);
  assert.match(anchor, /override func hitTest\(_ point: NSPoint\) -> NSView\? \{ nil \}/);
  assert.match(anchor, /override func isAccessibilityElement\(\) -> Bool \{ false \}/);
  // 守：列表接線——每一則的遮罩量到位置時記下（第一行字離上緣：我說的泡泡＝上內距）；捲出懶載入範圍就忘掉；記錄掛在捲動區的內容裡。
  const list = slice(view, 'struct GlobalDMMessageList: View', 'struct GlobalDMComposer: View');
  assert.match(list, /@State private var rows = GlobalDMListRows\(\)/);
  assert.match(list, /\.environment\(\\\.globalDMRowLead, bubble\.kind == \.mine \? GlobalDMChatLayout\.userBubbleVerticalPadding : 0\)/);
  assert.match(list, /\.onDisappear \{ rows\.forget\(bubble\.id\) \}/);
  assert.match(list, /\.background\(alignment: \.topLeading\) \{\s*GlobalDMListRowsProbe\(rows: rows\)\.frame\(width: 1, height: 1\)\.accessibilityHidden\(true\)\s*\}\s*\}\s*\.coordinateSpace\(name: Self\.space\)/);
  assert.match(list, /\.environment\(\\\.globalDMListRows, rows\)/);
  assert.match(list, /let _ = rows\?\.record\(id, frame: frame, content: proxy\.frame\(in: \.named\(GlobalDMMessageList\.contentSpace\)\), lead: lead,\s*covered: topInset - GlobalDMChatLayout\.listTop, viewport: viewport\)/);
  assert.match(list, /\.frame\(minHeight: viewportHeight, alignment: \.bottom\)\s*(?:\/\/[^\n]*\n\s*)*\.coordinateSpace\(name: Self\.contentSpace\)/);
  // 守：面板控制器——只記捲上去看舊訊息（away）的列表；排版之後照差距捲（上下限內），捲了就重新看哪幾則量過、要再排一次。
  const readingRows = slice(panels, 'func readingRows(in away: Set<ObjectIdentifier>)', '\n    }\n');
  assert.match(readingRows, /for scroll in scrollLists\(\) where away\.contains\(ObjectIdentifier\(scroll\)\) \{\s*guard let rows = GlobalDMListRows\.of\(scroll\), let snapshot = rows\.snapshot\(\) else \{ continue \}/);
  const keep = slice(panels, 'func keepReading(_ reading: [ObjectIdentifier: GlobalDMListRows.Snapshot]) -> Bool {', '\n    }\n');
  assert.match(keep, /let drift = rows\.drift\(from: snapshot\)/);
  assert.match(keep, /let y = min\(limit, max\(0, document\.isFlipped \? visible\.minY \+ \(drift \?\? 0\) : visible\.minY - \(drift \?\? 0\)\)\)/);
  assert.match(keep, /guard let drift, abs\(drift\) > 0\.5, abs\(y - visible\.minY\) > 0\.5 else \{ continue \}\s*rows\.beginPass\(\)\s*scroll\.contentView\.scroll\(to: NSPoint\(x: visible\.minX, y: y\)\)\s*scroll\.reflectScrolledClipView\(scroll\.contentView\)/);
  // 守：自測的反例開關只在 DEBUG（正式版一定守）。
  assert.match(panels, /#if DEBUG\s*guard Self\.keepsReading else \{ return \[:\] \}\s*#endif/);
  assert.match(panels, /#if DEBUG\s*\/\/\/[^\n]*\n\s*static var keepsReading = true/);
});

// W184 AB（H12；j-int 074819 查到：20 次串流更新一次都沒進畫面，A3「排版跟著內容更新」照樣過）：串流那一段要真的串流——
// 每一次更新照正式的 onChange 通知模型（自測的模型是 fixture，不接引擎的 onChange），每一次都要進到列表、排出位置；一次都沒進＝不過。
test('W184 AB H12: the streaming slide really streams — every update reaches the list, none reaching it fails', () => {
  const forms = read('DM/GlobalDMFormsAcceptance.swift');
  const anchor = read('DM/GlobalDMListAnchor.swift');
  const realRun = slice(forms, 'func realRun(_ from: GlobalDMForm, _ to: GlobalDMForm, stream: Bool = false) -> RealRun {', '\n        }\n');
  // 每一次更新：接一列、照正式的 onChange 通知畫面、記下是哪一則與什麼時候。
  assert.match(realRun, /engine\.appendOfflineRows\(threadID: thread, rows: \[ChatMessage\(id: id, role: \.assistant,[\s\S]{0,200}?\)\]\)\s*(?:\/\/[^\n]*\n\s*)*model\.objectWillChange\.send\(\)\s*sent\.update \{ \$0\.append\(\(id, CACurrentMediaTime\(\)\)\) \}/);
  // 停下之後再給 0.1 秒，看每一次更新進到列表（列表拿到那一則）、排出位置（遮罩量到它）了沒。
  assert.match(realRun, /GlobalDMListRows\.listedForSelfTest\[update\.id\]\.map \{ \(\$0 - update\.at\) \* 1000 \},\s*GlobalDMListRows\.laidOutForSelfTest\[update\.id\]\.map \{ \(\$0 - update\.at\) \* 1000 \}/);
  assert.match(view, /let _ = GlobalDMListRows\.noteListed\(bubbles\)/);
  assert.match(anchor, /if Self\.laidOutForSelfTest\[id\] == nil \{ Self\.laidOutForSelfTest\[id\] = CACurrentMediaTime\(\) \}/);
  // 判定：每一次都進到列表而且排出位置才算串流；一次都沒進＝不過（寫明），A3 的排版次數只在真的串流時才判。
  assert.match(forms, /let streamedIn = streaming\.updates > 0 && streaming\.reached == streaming\.updates && streaming\.laidOut == streaming\.updates/);
  assert.match(forms, /\(streaming\.reached == 0 \? "NO CONTENT UPDATE REACHED THE LIST — the streaming case measured nothing; " : ""\) \+ streaming\.arrivalText/);
  assert.match(forms, /check\(streamedIn && streaming\.during <= streaming\.updates \* 3 \+ 2 && streaming\.during < streaming\.frames,/);
  assert.match(forms, /print\("W184FORMS NOTE H12 streaming updates: \\\(streaming\.arrivalText\)"\)/);
});
