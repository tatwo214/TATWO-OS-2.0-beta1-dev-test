import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';

// W184 H4（使用者 09-30：「輸入筐我認為要改成我們設計好的coder輸入筐 並且我想將全部同款的自研輸入筐優化 將記憶、模型、ultrawork、速度
// 全部收進模式選擇裡，並在裡面可以個別挑選…最後套用在當前的所有自研輸入筐裡」；「這是舊版的拉條」）：「模式選擇」chip＋模式卡（ULTRAWORK 卡擴充）
// 的原始碼契約。值真的變了、送出時讀的參數、每個輸入框卡片開與關的畫面與識別碼在 `TATWO2_SELFTEST=w184mode`。
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

const mode = read('Chat/TatwoComposerMode.swift');
const card = read('Chat/TatwoComposerModeCard.swift');
const chrome = read('Chat/ChatComposerChrome.swift');
const chip = slice(chrome, 'struct ChatComposerModeChip: View', 'struct ChatComposerSendButton');
const composer = read('Chat/ChatPage+Composer.swift');
const dmView = read('DM/GlobalDMView.swift');
// 整合（W184 G3c 拿掉了 GlobalDMComposerSurface，外框改成同心玻璃膠囊）：切到下一個 struct；守的東西不變。
const dmComposer = slice(dmView, 'struct GlobalDMComposer: View', 'struct GlobalDMKey: View');
const bot = read('Bot/BotStudioMainSlot.swift');
const botComposer = slice(bot, 'struct BotStudioComposer: View', 'struct BotStudioPartnerChip');
const space = read('Space/SpaceSetupComposerToolbar.swift');
const pane = read('Assistant/AssistantSpacePane.swift');   // W184 H4b：TATWO 助理頁
const builder = slice(read('Space/SpaceSetupPreviewView.swift'), 'private struct SpaceSetupBuilderView: View', '/// TODO(W33 integration)');   // W184 H4b：Space 搭建的輸入框（玻璃卡）
const track = slice(card, 'struct TatwoComposerFilledTrack: View', '// MARK: - 卡浮在輸入框上方');

test('H4 the old gradient track is back (「這是舊版的拉條」): one glass bar filled from the left, drawn directly in the card', () => {
  // 守：#26 整條玻璃軌道底＋#24 左錨定、寬度隨檔位增長的漸層填充（不是一顆顆按鈕、不是移動的小塊）。
  assert.equal(count(track, '.fill(LiquidGlassTokens.ultraworkGradient)'), 2, 'base bar + fill, both the ultrawork gradient');
  assert.ok(track.includes('#26：連續玻璃軌道底') && track.includes('#24：填充式玻璃滑軌'));
  assert.ok(track.includes('.frame(width: geometry.fillWidth(ratio: ratio), height: height)'));
  // W184 H4 修正（查核 #14）：上面幾條只比得到註解與片段；這兩條比程式本身（去掉註解）整串——底條＝整條寬、一直看得到
  // （亮 0.30、關 0.16），填色＝左錨定、寬度照檔位；底條改成填色的寬、或透明度調成 0，這裡就失敗（畫面另有 w184mode T4 量像素）。
  const trackCode = code(track);
  assert.match(trackCode, /shape\s*\.fill\(LiquidGlassTokens\.ultraworkGradient\)\s*\.opacity\(lit \? 0\.30 : 0\.16\)\s*\.overlay \{[^}]*\}\s*\.frame\(width: width, height: height\)/,
    'base bar: the whole width, always visible');
  assert.match(trackCode, /shape\s*\.fill\(LiquidGlassTokens\.ultraworkGradient\)\s*\.overlay \{[^}]*\}\s*\.frame\(width: geometry\.fillWidth\(ratio: ratio\), height: height\)\s*\.opacity\(lit \? 1 : LiquidGlassTokens\.tintOpacity\)/,
    'fill: anchored left, as wide as the level');
  assert.match(card, /func fillWidth\(ratio: CGFloat\) -> CGFloat \{\s*segmentWidth \+ min\(max\(ratio, 0\), 1\) \* laneWidth/);
  assert.ok(track.includes('.strokeBorder(LiquidGlassTokens.glassRimGradient, lineWidth: 1)'));
  assert.ok(track.includes('.foregroundStyle(filled ? LiquidGlassTokens.browserInk : Color.secondary)'), 'filled stops use readable ink on the pastel gradient, the rest secondary');
  // 手感照舊：滑鼠由 ChatSliderPointerOverlay 接、放開時中點遲滯＋方向、值放開當下就寫回。
  assert.ok(track.includes('ChatSliderPointerOverlay('));
  assert.ok(card.includes('let midpointHysteresis = min(CGFloat(0.04), CGFloat(5) / laneWidth)'));
  assert.match(track, /withTransaction\(releaseTransaction\) \{[\s\S]*?onCommit\(next\)/);
  // 卡裡一律直接畫拉條（不再有「點開後才展開」的膠囊、不再是五顆分開的按鈕）；Off 照舊可選（電源）。
  const mainPage = slice(card, 'private var mainPage: some View', '// MARK: 標題');
  // W184 H4 修正（查核 #1、#3）：拉條下面可以有一行說明（私訊框）；拉條固定在上面、不在會捲的那一段裡。
  // W184 H4 修正第二輪（GPT-6 H4b 審查 #6）：電源（關閉 ultrawork）跟 S～XXL 並排、一起固定在上面（不在會收掉的底列裡）。
  assert.match(code(mainPage), /if let collaboration = mode\.collaboration \{\s*VStack\(alignment: \.leading, spacing: 6\) \{\s*HStack\(spacing: 8\) \{\s*collaborationTrack\(collaboration\)\s*powerButton\(collaboration\)\s*\}/);
  assert.ok(mainPage.indexOf('collaborationTrack(collaboration)') < mainPage.indexOf('TatwoComposerModeFitScroll('), 'S～XXL stays above the scrolling part');
  assert.doesNotMatch(code(card), /ultraworkOffActivationPill|collaborationControlExpanded|ForEach\(options, id: \\\.self\)/);
  assert.match(card, /identifiers: options\.map \{ "ultrawork-mode-\\\(\$0\.title\.lowercased\(\)\)" \}/);
  assert.ok(card.includes('collaboration.setLevel(.off)') && card.includes('.accessibilityIdentifier("tatwo.composer.mode.off")'));
  // fable5 也是拉條，漸層＝fable5 的和諧色階（珊瑚橘→鼠尾草綠→古金），由主題的 accentPink／Violet／Blue 決定。
  assert.match(read('Visual/LiquidGlassTokens.swift'),
    /static var ultraworkGradient: LinearGradient \{\s*LinearGradient\(\s*colors: \[accentPink, accentViolet, accentBlue\]/);
  const theme = read('Visual/TatwoTheme.swift');
  for (const piece of ['// 珊瑚橘（褪色花）', '// 鼠尾草綠（圖鑑葉）', '// 古金 / 赭黃（花蕊）']) assert.ok(theme.includes(piece), piece);
  assert.doesNotMatch(code(track), /usesGlass/, 'no theme branch that would turn the bar into a single colour');
  // 拉條去哪了：git 歷史寫在檔頭（1.0 8227fb91 改成五顆按鈕；2.0 153bbc51 照搬那一版）。
  assert.ok(card.includes('8227fb91') && card.includes('153bbc51') && card.includes('2e407f0a'));
});

test('H4 one card = the ULTRAWORK card extended: header, S～XXL, 身份與模型, 速度, 推理強度, 記憶, footer; existing tokens only', () => {
  const mainPage = slice(card, 'private var mainPage: some View', '// MARK: 標題');
  const order = ['header', 'collaborationTrack(collaboration)', 'modelSection', 'stepsSection(speed)', 'stepsSection(effort)',
    'stepsSection(memory)', 'footer'];
  let at = -1;
  for (const piece of order) {
    const next = mainPage.indexOf(piece, at + 1);
    assert.ok(next > at, `order: ${piece}`);
    at = next;
  }
  const header = slice(card, 'private var header: some View', '// MARK: S～XXL');
  for (const piece of ['.tracking(1.2)', '.foregroundStyle(LiquidGlassTokens.brandAccent)', 'LiquidGlassTokens.loopsPositive',
    '.background(tone.opacity(0.10), in: Capsule())']) {
    assert.ok(header.includes(piece), piece);
  }
  assert.ok(card.includes('.liquidGlassPanelSurface(cornerRadius: metrics.cornerRadius)'), 'same glass panel as the old card');
  assert.ok(card.includes('.background(Color.white.opacity(0.045), in: shape)') && card.includes('.strokeBorder(row.tint.opacity(0.20), lineWidth: 1)'),
    'model rows look like the old 身份與模型 rows');
  assert.ok(card.includes('.chatMenuRowHover(isSelected: option.isSelected)'), 'model list rows like the old picker');
  // W184 H4 修正（查核 #3、#11）：卡從下緣往上長，上緣不超過 topClearance（主視窗讓出頂列、私訊框讓出陰影邊＋頂列）；放不下時標題與 S～XXL
  // 固定在上面、中間那一段（身份與模型、速度、推理強度、記憶）自己捲。Plan 畫布那張不量（側欄自己會捲）。
  assert.match(mainPage, /TatwoComposerModeFitScroll\(limit: fit\.scrollLimit, onHeight: \{ sectionsHeight = \$0 \},\s*focusID: keyTarget\.flatMap\(Self\.scrollID\)\) \{\s*VStack\(alignment: \.leading, spacing: metrics\.spacing\) \{\s*if !mode\.models\.isEmpty \{ modelSection \}/);
  assert.ok(card.includes('.onGeometryChange(for: CGFloat.self) { proxy in proxy.frame(in: .global).maxY.rounded() } action: { bottom in'));
  assert.ok(card.includes('return max(0, cardBottom - metrics.topClearance)'));
  // W184 H4 修正（GPT-6 H4 審查 #8）：守「卡的總高度不超過可用高度」——以前 max(minimumScroll, available - fixed) 與清單「至少三列」
  // 都可能讓卡比可用高度高、上緣超出去。現在：TatwoComposerModeFit 先縮中間（到 minimumScroll）→ 收底列 → 收 S～XXL 下面的說明 →
  // 收標題 → 中間再縮到沒有（S～XXL 一直留著）；最後整張卡 frame(maxHeight: available)＋clipped 保證不超過（自測 F1–F3 算、R14 畫出來量）。
  assert.match(code(card), /\.frame\(maxHeight: available, alignment: \.top\)\s*\.clipped\(\)/, 'hard cap on the whole card');
  assert.doesNotMatch(code(card), /max\(metrics\.minimumScroll, available - fixed\)|max\(metrics\.listRowHeight \* 3/, 'no floor that can exceed the room');
  const plan = slice(card, 'static func plan(available: CGFloat?, sizes s: Sizes, minimumScroll: CGFloat)', '\n    }\n}');
  const steps = ['fit.showsFooter = false', 'fit.showsNote = false', 'fit.showsHeader = false', 'fit.showsSections = false'].map((piece) => plan.indexOf(piece));
  assert.ok(steps.every((at, i) => at > 0 && (i === 0 || at > steps[i - 1])), 'order: footer → note → title → middle');
  assert.doesNotMatch(plan, /track/, 'S～XXL is never dropped');
  assert.match(card, /let listCap = min\(metrics\.listMaxHeight, available\.map \{ max\(0, \$0 - chrome\) \} \?\? metrics\.listMaxHeight\)/);
  // 審查 #4：捲的時候墊可視範圍的定位點，交給裡面的拉條（被捲走、落在固定區上的按下不接）。
  const fit = slice(card, 'struct TatwoComposerModeFitScroll<Content: View>: View', '// MARK: - 舊版填充式玻璃拉條');
  assert.match(fit, /if let limit, height > limit \+ 0\.5 \{\s*ScrollViewReader \{ proxy in\s*ScrollView\(\.vertical, showsIndicators: true\) \{\s*measured\s*\.environment\(\\\.tatwoComposerModeViewport, viewport\)\s*\}[\s\S]*?\}\s*\.frame\(height: limit\)\s*\.background\(TatwoComposerModeViewportMarker\(viewport: viewport\)\)/);
  assert.ok(card.includes('topClearance: WindowChromeMetrics.bandHeight + 8') && card.includes('topClearance: GlobalDMLayout.margin + DMPhone.headerHeight'));
  assert.match(composer, /TatwoComposerModeCard\(mode: coderComposerMode\(ultraworkOnly: planInspectorPresented\), metrics: \.main,\s*fitsAbove: !planInspectorPresented\)/);
  // W184 H4 修正（審查 #7）：主視窗 Coder 的卡也掛在整個輸入框上（跟私訊框、助理頁、Space 一樣量輸入框真的上緣、點外面不吞那一下）；
  // 視窗內浮層（ChatPage+Panels）不再畫模式卡、不再是離整頁底 104 的固定點——只留一套。自測 R2／R2b／R13 的仿製照這個掛法。
  const panels = read('Chat/ChatPage+Panels.swift');
  const overlay = slice(panels, 'func chatFloatingPanelOverlay(contentMaxWidth: CGFloat?)', 'var workspaceUtilityContextMenu');
  assert.doesNotMatch(code(overlay), /showUltraworkPanel|ultraworkCollaborationPanel/, 'the window overlay no longer draws the mode card');
  assert.match(composer, /\.liquidGlassPanelSurface\(cornerRadius: LiquidGlassTokens\.radiusPrimary\)\s*\.globalDMComposerFrame\(\.coder, active: surface == \.window\)\s*(?:\/\/[^\n]*\n\s*)*\.tatwoComposerModeCard\(isPresented: \$showUltraworkPanel\) \{\s*TatwoComposerModeCard\(mode: coderComposerMode\(\), metrics: \.main\)/);
  const mimic = slice(read('Chat/TatwoComposerModeAcceptance.swift'), 'struct CoderOverlayFrame: View {', 'private struct SendMarker');
  assert.match(mimic, /composer\s*\.tatwoComposerModeCard\(isPresented: \$open\) \{\s*TatwoComposerModeCard\(mode: mode, metrics: \.main\)/);
  assert.doesNotMatch(code(mimic), /\.padding\(\.bottom, 104\)/, 'the self-test copy no longer uses the fixed 104 anchor');
  // 模型清單在卡裡換頁（不另開面板）；角色清單沿用舊識別碼。
  assert.ok(card.includes('"ultrawork-role-model-picker"') && card.includes('"tatwo.composer.mode.models"'));
  for (const id of ['"ultrawork-role-primary"', '"tatwo.composer.mode.model"', '"tatwo.composer.mode.speed"',
    '"tatwo.composer.mode.effort"', '"tatwo.composer.mode.memory"']) {
    assert.ok(mode.includes(id), id);
  }
  assert.match(mode, /static let identifier = "tatwo\.composer\.mode"\s*static let cardIdentifier = "tatwo\.composer\.mode\.card"/);
  for (const source of [card, mode, chip]) {
    assert.doesNotMatch(code(source), /borderedProminent|\.blue\b|accentColor|\.tint\(|Color\(red:/, 'no blue system buttons, no new colours');
  }
});

test('H4 chip: one glass chip with the summary; every part keeps an old identifier; any part opens the card; narrow = shorter', () => {
  assert.ok(chip.includes('ViewThatFits(in: .horizontal) {\n            row(short: false)\n            row(short: true)'));
  assert.ok(chip.includes('.accessibilityElement(children: .contain)') && chip.includes('.accessibilityIdentifier(TatwoComposerMode.identifier)'));
  assert.ok(chip.includes('Button(action: action) { label(item.element, short: short) }')
    && chip.includes('.accessibilityIdentifier(item.element.identifier)') && chip.includes('.onTapGesture(perform: action)'));
  assert.ok(chip.includes('.chatGlassChip(isSelected: selected)'), 'main window: same glass chip as the model chip');
  // 摘要：模型（含速度或推理強度）・記憶・ultrawork（關＝淡）。
  assert.ok(mode.includes('text: active ? "ultrawork \\(level.title)" : "ultrawork"'));
  // W184 H4 修正（查核 #6）：窄的時候看得出哪一段是什麼——記憶寫「記淺」（關著照舊「記憶關」）、圖示照樣畫（ultrawork 關著只剩淡圖示）。
  assert.ok(mode.includes('Segment(id: "memory", text: "記憶\\(state.strength.title)",') && mode.includes('short: memoryShort(state.strength),'));
  assert.ok(mode.includes('strength == .off ? "記憶\\(strength.title)" : "記\\(strength.title)"'));
  assert.ok(chip.includes('let visible = segments.filter { !(short ? $0.short : $0.text).isEmpty || $0.icon != nil }'));
  assert.ok(chip.includes('if let icon = segment.icon {') && !chip.includes('if let icon = segment.icon, !short'));
  assert.ok(chip.includes('.background(TatwoComposerModeChipAnchor())'), 'every mode chip carries its own anchor (click-away, real-click self-test)');
  // W184 H4 修正（審查 #1）：chip 不寫送不出去的推理強度（只有會送到的 Codex 系才寫）。
  assert.match(mode, /let suffix: String\? = route\.supportsNativeSpeedControl \? speedTitle\(model\.selectedSpeedTier\)\s*: \(route\.supportsNativeReasoningControl && forwardsEffort\(route\) \? model\.selectedEffort\.compactDisplayName : nil\)/);
  // 每一段沿用舊 chip 的識別碼（私訊框的自測、自動化照舊找得到）。
  for (const id of ['identifier: "chat-composer-model"', 'identifier: "tatwo-memory-strength"', 'identifier: "chat-composer-ultrawork"',
    'identifier: "tatwo.dm.model"', 'identifier: "space-composer-model"', 'identifier: "bot-composer-model"']) {
    assert.ok(mode.includes(id), id);
  }
});

test('H4 applied to every same-style composer (Coder, DM, Bot Studio, Space setup); ChatGPT composers and the offline bar untouched', () => {
  // 主視窗 Coder：記憶 chip、模型 chip、ultrawork 膠囊 → 一顆；卡照舊在視窗內浮層（showUltraworkPanel）。
  const toolbar = slice(composer, 'func composerToolbar(compactToolbar: Bool)', 'func composerSendButton(');
  assert.ok(toolbar.includes('composerModeChip(compact: compactToolbar)'));
  assert.doesNotMatch(code(toolbar), /TatwoMemoryStrengthChip|modelCollaborationComposerPill|modelMenu\(|ultraworkComposerPill/);
  assert.match(composer, /TatwoComposerModeCard\(mode: coderComposerMode\(ultraworkOnly: planInspectorPresented\), metrics: \.main,/);
  assert.match(slice(composer, 'func toggleComposerModeCard()', 'func coderComposerMode('), /showUltraworkPanel = willShow/);
  // W184 H4 修正（查核 #4 → 審查 #7）：chip 一律在輸入框上方開同一張完整的卡（計劃書側欄開不開都一樣）；側欄開關的當下收起。
  assert.match(composer, /\.tatwoComposerModeCard\(isPresented: \$showUltraworkPanel\) \{\s*TatwoComposerModeCard\(mode: coderComposerMode\(\), metrics: \.main\)/);
  assert.match(composer, /\.onChange\(of: planInspectorPresented\) \{ _, _ in\s*if showUltraworkPanel \{ showUltraworkPanel = false \}/);
  // 私訊框（助理、Coder session）：記憶＋模型 → 一顆；ChatGPT 對象的那一支照 ChatGPT 原版（房 C），不動。
  assert.ok(dmComposer.includes('GlobalDMModeChip(store: store, isOpen: $modeOpen, anchor: modeAnchor)'));
  assert.ok(dmComposer.includes('.tatwoComposerModeCard(isPresented: $modeOpen, anchor: modeAnchor) { GlobalDMModeCard(store: store) }'));
  assert.doesNotMatch(code(dmComposer), /GlobalDMMemoryChip\(store: store\)|GlobalDMModelChip\(store: store\)/);
  assert.ok(dmComposer.includes('GlobalDMChatGPTComposerLayers(store: store'));
  assert.ok(dmComposer.includes('.onChange(of: target) { _, _ in modeOpen = false }'));
  // Bot Studio（展示）與 Space 搭建。
  assert.ok(botComposer.includes('ChatComposerModeChip(segments: mode.segments') && botComposer.includes('TatwoComposerMode.botStudio('));
  assert.ok(botComposer.includes('.tatwoComposerModeCard(isPresented: modeOpen, anchor: modeAnchor)'));
  assert.doesNotMatch(botComposer, /這隻用哪個模型跑（展示・切換未生效）"\)|自己做，還是找群一起（展示・切換未生效）"\)/);
  assert.ok(space.includes('let mode = TatwoComposerMode.spaceSetup(domain: domain)') && space.includes('ChatComposerModeChip(segments: mode.segments'));
  assert.doesNotMatch(space, /private var modelMenu|ChatComposerCollaborationLabel\(/);
  // 沒有模型、速度、記憶、協作可選的不套：遠端離線的唯讀列、Bot 頁（檔位來自 bot.json）、Space 正式搭建對話、ChatGPT 的輸入框。
  // （TATWO 助理 Space 的輸入框 Assistant/AssistantSpacePane.swift 同款、該套：W184 H4b 已套用，見下面「H4b TATWO 助理頁」那一組。）
  for (const file of ['New/RemoteOfflineThreadView.swift', 'Bot/BotPage.swift', 'Space/SpaceLiveSetupView.swift',
    'DM/GlobalDMChatGPTComposer.swift', 'TAP/ChatGPTSpace.swift']) {
    assert.doesNotMatch(read(file), /ChatComposerModeChip|TatwoComposerModeCard/, file);
  }
});

test('H4 behavior unchanged: every control calls what the old chip or menu called', () => {
  // Coder：換模型＝原本 selectRouteChoice 那三步（換路由；推理強度、速度不在新模型允許的檔位就換預設），抽成一個函式兩邊共用。
  const apply = slice(mode, 'static func applyCoderRoute(', '/// Coder 輸入框：');
  for (const piece of ['model.setSingleModel(choice.id, syncCollaborationLead: model.collaborationLevel != .off)',
    'if choice.supportsNativeReasoningControl, !choice.allowedEfforts.contains(model.selectedEffort) {',
    'model.selectedEffort = choice.defaultEffort',
    'if choice.supportsNativeSpeedControl, !choice.allowedSpeedTiers.contains(model.selectedSpeedTier) {',
    'model.selectedSpeedTier = choice.defaultSpeedTier ?? choice.allowedSpeedTiers.first ?? .fast']) {
    assert.ok(apply.includes(piece), piece);
  }
  assert.match(slice(composer, 'func selectRouteChoice(_ choice: ChatRouteChoice)', 'func modelPickerInlineRouteRow'),
    /DispatchQueue\.main\.async \{\s*(?:\/\/[^\n]*\n\s*)*TatwoComposerMode\.applyCoderRoute\(choice, to: model\)/);
  const coder = slice(mode, 'static func coder(model: ChatPageModel,', '/// ultrawork 開著時「身份與模型」的角色列');
  assert.match(coder, /Collaboration\(level: level\) \{\s*model\.setCollaborationLevel\(\$0\)\s*if let effort = collaborationEffort\(\$0, route: model\.routeChoice\) \{ model\.selectedEffort = effort \}/);
  for (const piece of [
    'speedSteps(route: route, selected: model.selectedSpeedTier) { model.selectedSpeedTier = $0 }',
    'effortSteps(route: route, selected: model.selectedEffort) { model.selectedEffort = $0 }',
    'choose: { id in chooseModel(ChatRouteChoice.resolve(id, deviceID: model.modelSelectionDeviceID)) }',   // W189 B：模型清單照執行設備解析
    'rows += roleRows(level: level, roleModelID: roleModelID, chooseRole: chooseRole,']) {
    assert.ok(coder.includes(piece), piece);
  }
  // 角色列（Coder 與私訊框 session 共用）：主導＋照檔位的每一個副手，點了走原本的角色路徑。
  const roleRows = slice(mode, 'static func roleRows(level: ChatCollaborationLevel,', '// MARK: - 私訊框');
  for (const piece of ['UltraworkRoleConfiguration.auxiliaryCount(for: level)', 'choose: { id in chooseRole(ChatRouteChoice.resolve(id), slot) }',
    'options: routeOptions(selectedID: modelID, isDisabled: isDisabled)']) {
    assert.ok(roleRows.includes(piece), piece);
  }
  // W184 H4 修正（審查 #3）：檔位＝Coder 開著的那一條自己記住的（不是共用的一個值）。
  assert.ok(coder.includes('let level = model.ultraworkSettings(for: model.selectedThreadID).collaborationLevel'));
  // W184 H4 修正（審查 #9）：模型清單與每一個角色清單照「這一輪實際在哪台跑」標停用；走主設備的不拿這台擋。
  assert.equal(count(coder, 'isDisabled: { model.coderRouteBlocked($0) }'), 2);
  // 本機跑＝照這台的停用；走別台（MacBook 的 Coder 走主設備）＝照那台自己在 get_document 回報的 blockedEngines，不拿這台擋那台；
  // 舊版主設備沒回報＝不知道，不擋（那台自己會擋）。
  assert.match(read('Chat/TatwoComposerModeUltrawork.swift'), /func coderRouteBlocked\(_ kind: ClaudeSidecar\.Kind\) -> Bool \{\s*guard let remote = selectedRemote else \{ return isEngineDisabled\(kind\) \}\s*let engine = remoteSessions\.first \{ \$0\.device\.id == remote\.deviceID \}\?\.engine\s*return engine\?\.hostBlockedEngines\?\.contains\(kind\.rawValue\) \?\? false/);
  const getDocument = slice(read('Facade/OSAgentBridge.swift'), 'case "get_document":', 'case "transcript":');
  assert.match(getDocument, /let blockedEngines = ClaudeSidecar\.Kind\.allCases\.filter \{ model\.isEngineDisabled\(\$0\) \}\.map\(\\\.rawValue\)/);
  assert.match(getDocument, /"blockedEngines": snapshot\.3,/);
  const remoteEngine = read('Facade/RemoteLiveEngine.swift');
  assert.equal(count(remoteEngine, '(result["blockedEngines"] as? [String]).map(Set.init)'), 2, 'polled and first/refresh document both read it');
  assert.match(remoteEngine, /hostBlockedEngines = fetched\.blocked/);
  const wiring = slice(composer, 'func coderComposerMode(ultraworkOnly: Bool = false)', 'func modelCollaborationComposerPill');
  // W184 H4 修正（查核 #4）：角色照舊走 selectCollaborationRoleModel；計劃書側欄開著時輸入框上方那張卡換完照樣開著。
  for (const piece of ['roleModelID: { collaborationRoleModelID(for: $0) }', 'selectCollaborationRoleModel(choice, for: slot)',
    'let keepsCard = planInspectorPresented && showUltraworkPanel', 'if keepsCard { showUltraworkPanel = true }',
    'chooseModel: { selectRouteChoice($0) }']) {
    assert.ok(wiring.includes(piece), piece);
  }
  // W184 H4 修正（查核 #8、#10）：「模型」＝這一輪真的用的模型：ultrawork 開著也在（排在角色前面）；Plan 畫布那張（ultraworkOnly）沒有。
  const singleAt = coder.indexOf('if !ultraworkOnly {\n            let pending');
  assert.ok(singleAt > 0 && singleAt < coder.indexOf('if level != .off {'), 'the 模型 row comes before the roles and only outside the Plan canvas');
  assert.doesNotMatch(code(coder), /\} else \{\s*let pending = model\.pendingRouteChoice/, 'no longer only when ultrawork is off');
  // 換模型時速度照新模型允許的檔位：沒有速度檔的模型不列速度。
  assert.match(mode, /guard route\.supportsNativeSpeedControl else \{ return nil \}\s*return Steps\(title: "速度", options: route\.allowedSpeedTiers\.map/);
  // W184 H4 修正（審查 #1）：推理強度照「實際會送到那個引擎的能力」：只有 Codex 系每一輪帶 effort（ClaudeSidecar.sendCommand 只給 codex），
  // 其他引擎照樣列出、變淡、寫一句原因——不亮著卻不送。sendCommand 改了（別家也收 effort），這裡也要跟著改。
  assert.match(mode, /static func forwardsEffort\(_ route: ChatRouteChoice\) -> Bool \{\s*AssistantModelRouting\.engineKind\(for: route\) == \.codex\s*\|\| \(route\.runtimeAdapter == \.claudeCLI && route\.profile\.hasEngineCapabilityReport\)\s*\}/);   // W189 B：Claude 引擎回報支援時也轉推理強度
  assert.match(mode, /guard route\.supportsNativeReasoningControl else \{ return nil \}\s*let options = route\.allowedEfforts\.map[^\n]*\n\s*guard forwardsEffort\(route\) else \{\s*return Steps\(title: "推理強度", options: options, selectedID: nil, isEnabled: false, note: effortNotForwarded,/);
  assert.match(read('Engine/ClaudeSidecar.swift'), /if kind == \.codex \|\| kind == \.claude \{\s*\/\/ Bind model\/options to this queued turn, not mutable sidecar state\.\s*if let model \{ o\["model"\] = model \}\s*if let reasoningEffort \{ o\["effort"\] = reasoningEffort \}/);
  // Space 搭建：寫回原本那幾個欄位；正式搭建不能選協作、選了 Bot 模型沿用 Bot、不列推理強度與速度。
  const setup = slice(mode, 'static func spaceSetup(domain:', '// MARK: - Bot Studio');
  for (const piece of ['domain?.selectComposerRoute(id)', 'domain?.composerCollaboration = $0', 'domain?.composerSpeed = $0',
    'domain?.composerEffort = $0', 'isEnabled: !production', 'isEnabled: !usesBot', 'if !production {']) {
    assert.ok(setup.includes(piece), piece);
  }
  // Bot：記憶不顯示（Bot 不帶使用者的記憶）；展示不能改。
  const botMode = slice(mode, 'static func botStudio(', '\n    }\n');
  assert.doesNotMatch(botMode, /mode\.memory|memorySteps/);
  assert.match(botMode, /isEnabled: false/);
  // W184 H4 修正（查核 #7）：派工方式是跟「模型」同款的停用列，不是只有一格的拉條（一格＝整條填滿，看起來是一顆方塊按鈕）。
  assert.match(botMode, /let scope = ModelRow\(id: "scope", role: "派工"/);
  assert.doesNotMatch(code(botMode), /Steps\(title: "派工方式"/);
});

test('H4 DM size: phone tokens (17/15/13/11, 44 to press, concentric 28 − 12); the card floats above the composer; click-away passes the click on', () => {
  const dm = slice(card, 'static var dmPhone: TatwoComposerModeMetrics {', '/// 這張卡用到的字級');
  for (const piece of ['DMPhone.TextSize.caption', 'DMPhone.TextSize.secondary', 'DMPhone.TextSize.footnote', 'DMPhone.touch',
    'DMPhone.cardRadius', 'DMPhone.concentric(DMPhone.cardRadius, inset: DMPhone.edgeInset)', 'padding: DMPhone.edgeInset']) {
    assert.ok(dm.includes(piece), piece);
  }
  assert.doesNotMatch(dm.replace(/width: 340|badgeHeight: 24|listHeaderHeight: 24|listMaxHeight: 320|spacing: 12|roleWidth: 44/g, ''),
    /: \d+(?:\.\d+)?[,)]/, 'every other DM number comes from a DMPhone token');
  // W184 H4 修正（查核 #16）：私訊框的 chip 與卡真的用手機尺寸（常數對了不夠，要接到在畫的那兩個元件）。
  assert.ok(slice(card, 'struct GlobalDMModeChip', 'struct GlobalDMModeCard').includes('style: .dmPhone'));
  assert.ok(slice(card, 'struct GlobalDMModeCard', 'private struct GlobalDMModeObserver').includes('metrics: .dmPhone'));
  // W184 H4 修正（查核 #12）：每個輸入框的開關真的接上（自測 R7 另外真的去點）：私訊框 toggle、主視窗 toggleComposerModeCard、
  // Bot／Space 自己的開關、卡墊著點外面收起的那一層。
  assert.ok(slice(card, 'struct GlobalDMModeChip', 'struct GlobalDMModeCard').includes('withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) { isOpen.toggle() }'));
  assert.match(slice(composer, 'func composerModeChip(compact: Bool)', 'func toggleComposerModeCard()'), /\{\s*toggleComposerModeCard\(\)\s*\}/);
  assert.ok(botComposer.includes('modeOpenChoice = !(modeOpenChoice ?? modeCardOpen)'));
  assert.ok(space.includes('modeOpen.toggle()'));   // W184 H4b：開關是上一層傳下來的 Binding（modeOpen），chip 只管切換
  const popover = slice(card, 'struct TatwoComposerModePopover<Card: View>: ViewModifier', 'extension View {');
  assert.ok(popover.includes('.background(TatwoComposerModeClickAway(anchor: anchor) { isPresented = false })'), 'click-away under the card');
  // 守：卡的下緣在輸入框上緣上方 gap、右緣對齊（高 0 的框貼在上緣、卡照 bottomTrailing 往上長；自測 R0 用純紅探針量過）。
  assert.ok(popover.includes('.frame(width: proxy.size.width, height: 0, alignment: .bottomTrailing)'), 'the card grows upward from the top edge');
  assert.ok(popover.includes('.offset(y: -gap)'), 'gap above the composer');
  assert.doesNotMatch(code(popover), /alignmentGuide/, 'the first try (alignment guide in the overlay) did not take effect');
  const away = slice(card, 'final class TatwoComposerModeClickAwayView: NSView', '// MARK: - 私訊框的包裝');
  assert.ok(away.includes('NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown])'));
  assert.match(away, /MainActor\.assumeIsolated \{ self\?\.handle\(event\) \}\s*return event/, 'the click still reaches what is under it');
  assert.ok(away.includes('override func hitTest(_ point: NSPoint) -> NSView? { nil }'));
  // 按在任何一顆模式選擇 chip 上不算點外面（chip 自己開關）：每顆 chip 墊的定位點都登記著。
  assert.ok(away.includes('var chips = TatwoComposerModeChipAnchorView.frames(in: window)'));
  assert.match(away, /static func shouldClose\(click point: NSPoint\?, card: NSRect, chips: \[NSRect\]\) -> Bool \{\s*guard let point else \{ return true \}\s*if card\.contains\(point\) \{ return false \}\s*return !chips\.contains \{ \$0\.contains\(point\) \}/);
  assert.match(away, /override func viewDidMoveToWindow\(\) \{\s*super\.viewDidMoveToWindow\(\)\s*if window == nil \{ Self\.live\.remove\(self\) \} else \{ Self\.live\.add\(self\) \}/);
  assert.ok(dmComposer.includes('.onChange(of: store.isPickerOpen) { _, open in if open { modeOpen = false } }'));
});

test('H4b TATWO assistant page: memory and model are one 模式選擇 chip; the card hangs on the whole composer; the rules are the DM assistant\'s', () => {
  // 守：助理頁的輸入框跟 Coder 同一套——記憶、模型收進一顆「模式選擇」chip（在工具列、送出／停止鈕前面），不再有第二顆記憶或模型 chip；
  // 卡浮在整個輸入框（玻璃卡）上方 8、右緣對齊；開關是頁面這一層的 modeOpen，chip 與卡接同一個。
  const composerFn = slice(pane, 'private func composer(column: CGFloat)', 'private var isConnecting');
  assert.match(composerFn, /ChatComposerToolbarRow\(compact: compact\) \{\s*Spacer\(minLength: compact \? 8 : 14\)\s*(?:\/\/[^\n]*\n\s*)*AssistantSpaceModeChip\(model: model, isOpen: modeOpen\)\s*(?:\/\/[^\n]*\n\s*)*if model\.assistantIsRunning \{/);
  assert.doesNotMatch(code(pane), /TatwoMemoryStrengthChip\(|AssistantModelMenu\(model: model\)/, 'no separate memory or model chip next to the mode chip');
  // 守：卡掛在玻璃卡後面（跟 Coder、私訊框一樣量整個輸入框的上緣），不是掛在工具列上。
  assert.match(composerFn, /\.liquidGlassPanelSurface\(cornerRadius: LiquidGlassTokens\.radiusPrimary\)\s*\.globalDMComposerFrame\(\.tatwo, active: surface == \.window\)\s*(?:\/\/[^\n]*\n\s*)*\.tatwoComposerModeCard\(isPresented: modeOpen\) \{ AssistantSpaceModeCard\(model: model\) \}/);
  assert.match(pane, /private var modeOpen: Binding<Bool> \{\s*Binding\(get: \{ modeOpenChoice \?\? modeCardOpen \}, set: \{ modeOpenChoice = \$0 \}\)/);
  assert.ok(pane.includes('var modeCardOpen = false') && pane.includes('@State private var modeOpenChoice: Bool?'), 'the self-test can draw the card open');
  // 守：chip 與卡都讀 TatwoComposerMode.assistantSpace，看 model 與別台記憶的暫存（值一變就重畫，同原本記憶 chip 看的東西）。
  const chipView = slice(pane, 'private struct AssistantSpaceModeChip: View', 'private struct AssistantSpaceModeCard: View');
  assert.ok(chipView.includes('let mode = TatwoComposerMode.assistantSpace(model: model)') && chipView.includes('@ObservedObject private var pending = TatwoMemoryStrengthPending.shared'));
  assert.ok(chipView.includes('ChatComposerModeChip(segments: mode.segments, selected: isOpen, help: mode.help)')
    && chipView.includes('withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) { isOpen.toggle() }') && chipView.includes('.layoutPriority(1)'));
  const cardView = pane.slice(pane.indexOf('private struct AssistantSpaceModeCard: View'));
  assert.ok(cardView.includes('TatwoComposerModeCard(mode: TatwoComposerMode.assistantSpace(model: model), metrics: .main)')
    && cardView.includes('@ObservedObject private var pending = TatwoMemoryStrengthPending.shared'));
  // 守：每個按鈕叫的還是原本助理頁 chip 叫的那一個函式（只換 UI）：模型清單＝助理的選單（停用的引擎標「已停用」）、選了 setAssistantModel、
  // 回覆中不能換；記憶＝助理那一條；ultrawork 助理不帶（拉條在、變淡、寫原因）；識別碼與名稱沿用助理頁原本的。
  const assistantMode = slice(mode, 'static func assistantSpace(model: ChatPageModel)', 'fileprivate static func applyPreferenceSteps(');
  for (const piece of ['let canChoose = !model.assistantIsRunning', 'let title = model.assistantModelChipTitle',
    'assistantOptions(model.assistantModelOptions)', 'choose: { [weak model] id in model?.setAssistantModel(id) }',
    'isEnabled: canChoose', 'dimmed: !canChoose', 'identifier: "tatwo-assistant-model"', 'label: "助理的模型"',
    'model.memoryChipState(.assistant)', 'model?.setMemoryStrength($0, for: .assistant)',
    'mode.help = canChoose ? "助理的模型，不更動 Coder" : "回覆中不換模型"']) {
    assert.ok(assistantMode.includes(piece), piece);
  }
  assert.match(assistantMode, /mode\.collaboration = Collaboration\(level: \.off, isEnabled: false,\s*note: "助理不使用 ultrawork", setLevel: \{ _ in \}\)/);
  // 守：速度、推理強度（本機那一條的偏好；別台上的變淡）＝私訊框與助理頁共用同一個函式，一個地方改、兩邊一樣。
  assert.ok(assistantMode.includes('applyPreferenceSteps(to: &mode, model: model,'));
  assert.ok(slice(mode, 'static func dm(store: GlobalDMStore)', 'static func dmLocalThread(').includes('applyPreferenceSteps(to: &mode, model: model, local: local, route: route, canChoose: canChoose, elsewhere: elsewhere)'));
  const tuning = slice(mode, 'fileprivate static func applyPreferenceSteps(', '// MARK: - Space 搭建');
  for (const piece of ['model.localLiveForBridge?.threadRecord(local)', 'TatwoComposerMode.dmSetPreferences(model: model, threadID: local, route: route, speed: newTier, effort: newEffort)',
    'speedSteps(route: route, selected: tier, isEnabled: canChoose) { write($0, nil) }', 'effortSteps(route: route, selected: effort, isEnabled: canChoose) { write(nil, $0) }',
    'speedSteps(route: route, selected: nil, isEnabled: false) { _ in }', 'effortSteps(route: route, selected: nil, isEnabled: false) { _ in }',
    '"\\(elsewhere)：速度、推理強度照那台的設定"']) {
    assert.ok(tuning.includes(piece), piece);
  }
  // 助理頁沒有 GlobalDMStore：直接讀 ChatPageModel；模式卡的識別碼與 Coder、私訊框同一組。
  assert.ok(!assistantMode.includes('GlobalDMStore') && !assistantMode.includes('store.'));
  assert.doesNotMatch(code(pane), /route\.title|assistantRouteChoice\.title/, 'the pane draws no model name of its own');
  assert.doesNotMatch(code(pane), /chatNoteTypography/, 'standard note sizes, as before');
});

test('H4b Space setup: the card hangs on the whole composer (the glass card), not on the toolbar; the open state is handed up as a Binding', () => {
  // 守：卡浮在整個輸入框上方 8、右緣對齊（原本掛在工具列上方 8＝在輸入框裡面，蓋住打字區 59pt）。工具列只剩那顆 chip，開關是傳進來的
  // @Binding modeOpen；卡與開關的 @State 在 SpaceSetupPreviewView 的搭建輸入框（玻璃卡）那一層，卡掛在 .liquidGlassPanelSurface 後面。
  assert.match(space, /@Binding var modeOpen: Bool/);
  assert.ok(space.includes('ChatComposerModeChip(segments: mode.segments, selected: modeOpen, help: mode.help)') && space.includes('.layoutPriority(1)'));
  assert.doesNotMatch(code(space), /tatwoComposerModeCard|TatwoComposerModeCard|modeOpenChoice|modeAnchor|modeCardOpen/, 'the toolbar no longer hangs the card');
  assert.match(builder, /@State private var modeOpen = false/);
  assert.ok(builder.includes('SpaceSetupComposerToolbar(domain: domain, compact: composerWidth < 720, modeOpen: $modeOpen)'));
  assert.match(builder, /\.liquidGlassPanelSurface\(cornerRadius: LiquidGlassTokens\.radiusPrimary\)\s*(?:\/\/[^\n]*\n\s*)*\.tatwoComposerModeCard\(isPresented: \$modeOpen\) \{\s*TatwoComposerModeCard\(mode: TatwoComposerMode\.spaceSetup\(domain: domain\), metrics: \.main\)\s*\}/);
  // 順序：玻璃卡 → 模式卡（overlay，量整張玻璃卡）→ 量寬度的 background；模式卡不在玻璃卡裡面那個 VStack、不在工具列上。
  const at = (piece) => builder.indexOf(piece);
  assert.ok(at('SpaceSetupComposerToolbar(') < at('.liquidGlassPanelSurface(') && at('.liquidGlassPanelSurface(') < at('.tatwoComposerModeCard(') && at('.tatwoComposerModeCard(') < at('.background {'));
  assert.equal(count(builder, 'tatwoComposerModeCard'), 1);
  // 自測的 SpaceComposerFrame 是這一段的仿製（整頁不在自測裡畫）：掛法要一樣——傳 Binding 給工具列、卡掛在玻璃卡後面。
  const acceptance = read('Chat/TatwoComposerModeAcceptance.swift');
  const frame = slice(acceptance, 'struct SpaceComposerFrame: View', 'struct AssistantPaneFrame: View');
  assert.ok(frame.includes('SpaceSetupComposerToolbar(domain: domain, compact: false, modeOpen: $open)'));
  assert.match(frame, /\.liquidGlassPanelSurface\(cornerRadius: LiquidGlassTokens\.radiusPrimary\)[\s\S]*?\.tatwoComposerModeCard\(isPresented: \$open\) \{\s*TatwoComposerModeCard\(mode: TatwoComposerMode\.spaceSetup\(domain: domain\), metrics: \.main\)/);
  // 守的東西不變：正式搭建對話（SpaceLiveSetupView）沒有模型可選，不套；Space 的規則照舊在 TatwoComposerMode.spaceSetup。
  assert.doesNotMatch(read('Space/SpaceLiveSetupView.swift'), /ChatComposerModeChip|TatwoComposerModeCard/);
});

test('H4 self-test w184mode is registered with one line and covers the brief', () => {
  const self = read('SelfTest.swift');
  assert.equal(count(self, 'TatwoComposerModeAcceptance'), 1);
  assert.match(self, /TATWO2_SELFTEST"\] == "w184mode" \{ TatwoComposerModeAcceptance\.launch\(\); return \}/);
  const acceptance = read('Chat/TatwoComposerModeAcceptance.swift');
  assert.match(acceptance, /^#if DEBUG/);
  assert.ok(acceptance.includes('NativeStagingIsolation.validationError(environment) == nil'));
  assert.ok(acceptance.includes('isolated engine homes must be logged out'));
  assert.ok(acceptance.includes('environment["TATWO2_SELFTEST_ARTIFACTS"]'));
  // W184 H4 修正（GPT-6 H4 審查 #10）：新的幾段在 TatwoComposerModeAcceptanceFix.swift（同一個自測），標籤一起算。
  const fix = read('Chat/TatwoComposerModeAcceptanceFix.swift');
  assert.match(fix, /^#if DEBUG/);
  // W184 H4 修正第二輪（GPT-6 H4b 審查）：N／U／V／X 在 TatwoComposerModeAcceptanceRound2.swift（同一個自測），標籤一起算。
  const round2 = read('Chat/TatwoComposerModeAcceptanceRound2.swift');
  assert.match(round2, /^#if DEBUG/);
  const all = acceptance + fix + round2;
  for (const label of ['T1 filled glass track', 'K1 click-away', 'K2 the DM card and chip only use the phone font tokens',
    'C2 model row', 'C3 速度 → 標準', 'C4 推理強度 → 低', 'C5 (審查 #1) switching to', 'C6 記憶 → 深', 'C7 (審查 #3) S～XXL → L',
    'C8 (state, not the send path)',
    'C9 (審查 #3) the power button', 'C11 記憶 only in Coder chats', 'D1 DM assistant', 'D3 記憶 → 淺', 'D4 a Coder session in the DM',
    'D5 a Bot thread shows no memory', 'D6 the ChatGPT target has no mode card', 'S4 real build', 'B1 Bot Studio',
    'R0 the card floats above the composer', 'R1 [', 'R2 [', 'R3 [', 'R5 [', 'R6 [',
    'closed shows no card; open adds the card above', 'the card\'s drawn bottom edge is at least 8 above',
    // W184 H4 修正：查核各條的反例（SKIP 的字串不算涵蓋——R4／識別碼在 ssh 的閘門裡永遠 SKIP，所以另有真的點、量像素的）。
    'D1b (查核 #17)', 'D-speed (查核 #1) DM assistant', 'D-ultrawork (審查 #3、#5)', 'D-roles (審查 #5)', 'D-speed (查核 #1) DM session', 'D7 (查核 #1)',
    'D8 (查核 #15)', 'C7b (查核 #8)', 'C10 (查核 #10)', 'B2 (查核 #7)', 'T4 [', 'R7 [', 'R8 [', 'R9 [', 'K4 the card grows up',
    // W184 H4b：TATWO 助理頁（卡逐項跟私訊框助理的一樣、四樣各自改了值真的變、接主設備／回覆中／停用的引擎）、真的 AssistantSpacePane 的卡在輸入框上方、
    // 助理頁與 Space 卡開著時真的點在卡上（拉條、模型列進清單再點另一個模型）、Space 的卡以整個輸入框為準。
    'A1 TATWO assistant page', 'A2 the page\'s card equals the DM assistant\'s card', 'A3 the 模型 row', 'A4 速度 and 推理強度', 'A5 記憶 →',
    'A6 assistant on the primary', 'A6 while it answers', 'A7 a disabled engine', 'R10 [', 'R6 [', 'Space setup preview (card hangs on the whole composer)',
    'R7 [', 'R11 [TATWO assistant page]', 'a real click on the other 速度 step', 'a real click on the 記憶 step', 'a real click on the 模型 row opens the model list',
    'a real click on a row of the model list changes the assistant\'s model', 'R12 [Space setup]', 'a real click on the XL stop',
    // W184 H4 修正（GPT-6 H4 審查）：#1／#2／#5 真的送出的參數（替身腳本記下 sidecar 收到的）、#3 隔離與存檔、#2 遠端那一包與主設備收下、
    // #4 捲動後點固定區、#6 鍵盤矩陣、#7 Coder 量真的上緣＋點送出不吞、#8 高度上限、#9 照實際執行的設備標停用。
    'C7c (審查 #5)', 'C12 (審查 #9)', 'S5 (審查 #9)', 'P1 (審查 #2、#5)', 'P2 (審查 #1、H4b #10)', 'P2b (審查 #2、#5)', 'P3 (審查 #2)',
    'P4 (審查 #1)', 'I1 (審查 #3)', 'I2 (審查 #3)', 'I3 (審查 #3)', 'P5 (審查 #2)', 'P6 (審查 #2、#3)', 'P6b', 'P7 (審查 #2)', 'P8 (審查 #2)',
    'P9 (審查 #9)', 'F1 (審查 #8)', 'F2 (審查 #8)', 'F3 (審查 #8)', 'R14 [', 'R14b [', 'H1 (審查 #4)', 'H2 (審查 #4)', 'KB1 [', 'KB2 [', 'KB3 [', 'KB4 [',
    'KB5 [', 'KB6 [Space setup]', 'R2b [', 'R13 (審查 #7)',
    // W184 H4 修正第二輪（GPT-6 H4b 審查 #1–#3、#5–#7、#10；主導看 0.7 倍 PNG）：送到才算（重開／接回失敗、寫不進去、送出中、Codex 收下）、
    // 遠端送的途中又改／刷新失敗、兩個入口同時送／那台拒收、壞欄位整份不收、鍵盤框捲進來／收掉的不給選、電源並排、私訊框輸入框只露整行。
    'N0 (H4b #1, round 3)', 'N1 (H4b #1, round 3)', 'N1b (H4b #1)', 'N2 (H4b #1, #10)', 'N3 (H4b #1, round 3)', 'N4 (H4b #1)',
    'N5 (H4b round 3) cold start is slow', 'N5b (H4b round 3) typed a new sentence', 'N7 (H4b round 3)', 'N7b (H4b round 3)',
    'N6 (H4b #1)', 'U1 (H4b #2, round 3)', 'U1b (H4b #2)', 'U2 (H4b #2)', 'U2b (H4b #2)', 'U3 (H4b #7, round 3)', 'U4 (H4b #7, round 3)', 'X1 (H4b #3)',
    'X2 (H4b #3)', 'P8b', 'V1 (H4b #5)', 'V1b (H4b #5)', 'V2 (H4b #5)', 'V3 (H4b #6)', 'V4 [', 'L1 [']) {
    assert.ok(all.includes(label), label);
  }
  // 審查 #10：沒有螢幕、送不了真的滑鼠事件＝未驗證（SKIP 寫原因），不再直接叫回呼然後記 PASS；回呼只在真的事件失敗後拿來分辨原因（仍記失敗）。
  const pressStep = slice(acceptance, 'func pressStep(_ track: NSRect', '\n        }\n');
  assert.match(pressStep, /guard onScreen else \{\s*return Pressed\(ok: false, verified: false,/);
  assert.ok(pressStep.indexOf('guard onScreen else') < pressStep.indexOf('await clickStep(track, index: index, of: count)'));
  assert.doesNotMatch(pressStep, /"pointer callbacks \(no display here\)"/);
  for (const site of ['R11 [TATWO assistant page] a real click on the other 速度 step', 'R12 [Space setup] a real click on the XL stop']) {
    const at = acceptance.indexOf(site);
    assert.ok(at > 0 && acceptance.slice(at, at + 900).includes('check.skip(label'), `${site}: unverified → SKIP`);
  }
  // 真的送出的參數：替身腳本記的是 sidecar 真的收到的（argv 與 stdin 的 send），走真的 send()／sendFromDM／ChatLiveEngine；遠端抓
  // RemoteLiveEngine 真的要交給連線的那一包，再交給主設備的 send_message。
  assert.ok(fix.includes("overrides[\"tatwo2.sidecarPath.\\(kind.rawValue)\"] = script.path") && fix.includes('model.send()')
    && fix.includes('model.sendFromDM(threadID: otherThread') && fix.includes('remote.sendPayloadTestTap = {')
    && fix.includes('try bridge.callForSelfTest(method: method, params: params)')
    && fix.includes('call(dmPayload.method, dmPayload.params)'));
  // 主設備的 send_message／get_document 只開給已配對設備：自測在主設備自己隔離的 live 根登記假的副設備（授權金鑰也在那個資料夾，不碰 ~/.ssh）。
  assert.match(fix, /hostEnvironment\["TATWO2_LIVE_ROOT"\] = hostLive\.path/);
  assert.match(fix, /hostEnvironment\["TATWO2_AUTHORIZED_KEYS"\] = hostRoot\.appendingPathComponent\("authorized_keys"\)\.path/);
  assert.match(fix, /DeviceRegistry\(root: hostLive, authorizedKeysURL: hostRoot\.appendingPathComponent\("authorized_keys"\)/);
  assert.match(fix, /ChatPageModel\(environment: hostEnvironment,/);
  assert.doesNotMatch(fix, /onBegan\?\(|onEnded\?\(/, 'the new checks never call the pointer callbacks directly');
  // R6 的參考是整個輸入框的上緣（不是工具列）；R10 畫真的 AssistantSpacePane（視窗模式），輸入框的位置由頁面自己回報。
  assert.match(acceptance, /"R6 \[\\\(suffix\)\] Space setup preview \(card hangs on the whole composer\)",\s*reference: "the composer's top edge \(the whole input box, not the toolbar\)", probe: spaceProbe, edge: \{ \$0\.composer\?\.minY \}/);
  assert.ok(acceptance.includes('edge: { _ in GlobalDMComposerFrames.shared.frames[.tatwo]?.minY }') && acceptance.includes('AssistantSpacePane(model: model, modeCardOpen: open)')
    && acceptance.includes('.environment(\\.tatwoSurfaceKind, .window)'));
  // 真的點：排進 App 的事件佇列（先過點外面收起的本機事件監看），點不到記 FAIL（不是 SKIP）。
  assert.ok(acceptance.includes('NSApp.postEvent(event, atStart: false)'));
  // W184 H4b：拉條的本機事件監看用事件的 cgEvent（螢幕座標）對回視窗，視窗在螢幕外就收不到：點拉條前把視窗搬進螢幕（全透明、不接真的滑鼠），
  // 沒有顯示器才改叫它接的回呼；失敗時再用回呼試一次讓證據分得出「事件送不進來」與「接線壞了」。點模型那一列靠卡的高度變了判斷換頁。
  assert.ok(acceptance.includes('func moveOnScreen() -> Bool') && acceptance.includes('window.alphaValue = 0') && acceptance.includes('window.ignoresMouseEvents = true'));
  assert.ok(acceptance.includes('func pressStep(') && acceptance.includes('capture.onBegan?(localX)') && acceptance.includes('capture.onEnded?(localX)'));
  assert.ok(acceptance.includes('abs(now.height - mainHeight) > 12'));
  assert.match(acceptance, /guard let chip = rig\.chipFrame\(\) else \{\s*check\(false, "R7/);
  for (const png of ['popover-probe.png', '"card-\\(level.title)-\\(suffix).png"', '"main-', 'dm-chat-', '"dm-', '"bot-studio-', '"space-',
    '"main-600-xxl-', '"dm-session-l-', '"click-', '"assistant-', 'click-TATWO-assistant-page-model-list.png', 'click-TATWO-assistant-page-after.png',
    'click-Space-setup-card-above-composer.png', 'click-Space-setup-after-xl.png']) {
    assert.ok(acceptance.includes(png), png);
  }
});

// W184 AB（H4 查核 #9，成立）：私訊框開著模式卡時按 Esc 會把整個私訊框收掉（routeEscape 看不到卡）。store 記著卡開著沒有
//（跟輸入框的 modeOpen 兩邊同步）；Esc 在 ChatGPT 的小卡之後、session 清單之前先收卡、框照舊開著；組字中照舊交給輸入法（最前面）。
test('W184 AB (H4 review #9): Esc with the DM mode card open closes only the card; the box stays; the next Esc takes the usual order', () => {
  const store = read('DM/GlobalDMStore.swift');
  const view = read('DM/GlobalDMView.swift');
  const panels = read('DM/GlobalDMPanelController.swift');
  assert.match(store, /@Published var isModeCardOpen = false/);
  assert.match(slice(store, 'func select(_ newTarget: GlobalDMTarget) {', '\n    }\n'), /isModeCardOpen = false/);
  assert.match(store, /if isPickerOpen \{ isModeCardOpen = false \}/);
  const composer = slice(view, 'struct GlobalDMComposer: View {', '\n}\n');
  assert.match(composer, /\.onChange\(of: modeOpen, initial: true\) \{ _, open in if store\.isModeCardOpen != open \{ store\.isModeCardOpen = open \} \}/);
  assert.match(composer, /\.onChange\(of: store\.isModeCardOpen\) \{ _, open in if modeOpen != open \{ modeOpen = open \} \}/);
  const route = slice(panels, 'static func routeEscape(', '\n    }\n');
  const layers = route.indexOf('GlobalDMDuo.shared.existing?.dismissChatGPTLayers()');
  const card = route.indexOf('if store.isModeCardOpen { store.isModeCardOpen = false; return nil }');
  const picker = route.indexOf('if store.isPickerOpen');
  assert.ok(layers > 0 && card > layers && picker > card, 'order: ChatGPT layers → mode card → session list');
  assert.ok(route.indexOf('if isComposing(in: window) { return event }') < card, 'composing (IME) still goes first');
  assert.match(route, /if !store\.isBrowsingBeside, let duo = GlobalDMDuo\.shared\.existing, duo\.isModeCardOpen \{ duo\.isModeCardOpen = false; return nil \}/);
  const acceptance = read('Chat/TatwoComposerModeAcceptance.swift');
  assert.match(slice(acceptance, 'static func run() async throws -> Bool {', 'W184MODE SUMMARY'), /await escapeChecks\(check, store: store\)/);
  for (const label of ['E0 (W184 AB, H4 review #9)', 'E1 (W184 AB, H4 review #9) a real Esc on the floating DM box with the mode card open']) {
    assert.ok(acceptance.includes(label), label);
  }
  // 真的事件：Esc 排進 App 的事件佇列（走面板控制器的本機監看），不是直接叫 routeEscape。
  const esc = slice(acceptance, 'static func escapeChecks(', '\n    }\n\n');
  assert.match(esc, /NSEvent\.keyEvent\(with: \.keyDown,[\s\S]*?keyCode: 53\)/);
  assert.doesNotMatch(esc, /routeEscape\(/);
});

// W184 H4 修正（GPT-6 H4 審查 #1、#2、#3、#5）：卡上看得到、按得到的每一項都真的送到那一條——這裡守接線（原始碼契約）；
// 送到了沒有由 w184mode 的 P／I 段看替身腳本記下的 sidecar 收到的、RemoteLiveEngine 真的要送的那一包、主設備真的收下。
test('W184 H4 fix (review #1, #2, #3, #5): each turn carries the card — model restart, per-turn ultrawork per thread, remote serialization', () => {
  const engine = read('Facade/ChatLiveEngine.swift');
  // #1 守：同一家換模型，重用前比對啟動時的模型；不一樣就走原本的啟動路徑重開（--resume 接回）。Codex 每一輪自己帶模型，不用重開。
  const ensure = slice(engine, 'private func ensureSidecar(', 'guard let idx = doc.threads.firstIndex');
  assert.match(ensure, /let modelMatches = engine == \.codex \|\| sidecarModels\[threadID\] == \(model \?\? ""\) \|\| runningThreads\.contains\(threadID\)/);
  assert.match(ensure, /&& modelMatches && apiKeyOptOutMatches && runtimeMatches && s\.startedWithoutMemory == \(memoryPolicy != nil\) \{ return s \}/);   // W187 also isolates memory capability; all previous reuse guards remain.
  assert.match(engine, /sidecarPermissionModes\[threadID\] = permissionMode \?\? "configured-default"\s*sidecarModels\[threadID\] = model \?\? ""/);
  // #2 守：ultrawork 每一輪接在送進 sidecar 的那一句後面（不是只在啟動時讀一次 systemPrompt）；關掉的那一輪說一聲。
  const send = slice(engine, 'ultrawork: UltraworkTurnSettings?, delivery: (@MainActor (LiveSendDelivery) -> Void)?) -> Bool {', 'func savePastedAttachment');
  assert.match(send, /let ultraworkTurn = ultraworkTurnBlock\(threadID: threadID, explicit: ultrawork\)\s*if let block = ultraworkTurn\.block \{ outgoing \+= "\\n\\n" \+ block \}[\s\S]*?guard sidecar\.send\(text: outgoing/);
  const take = slice(engine, 'private func ultraworkTurnBlock(', '\n    }\n');
  assert.match(take, /if let explicit \{ doc\.threads\[index\]\.ultrawork = explicit \}/);
  assert.match(take, /UltraworkTurnSettings\.turnBlock\(current: current, lastSent: doc\.threads\[index\]\.ultraworkSent\)/);
  // W184 H4 修正第二輪（GPT-6 H4b 審查 #1）：還沒送到就不記「上一輪帶出去的」（重開失敗時「已關閉」那一聲不被吃掉）。
  assert.doesNotMatch(code(take), /ultraworkSent =/);
  const ultra = read('Chat/TatwoComposerModeUltrawork.swift');
  assert.match(ultra, /if let briefing = current\?\.briefing \{ return briefing \}\s*return lastSent\?\.isOn == true \? offBriefing : nil/);
  // #5 守：整份角色（主導＋照檔位上場的每一個副手）都寫進那一段，不是只有 index 0。
  assert.match(ultra, /for \(index, id\) in activeAuxiliaries\.enumerated\(\) \{ lines\.append\("\\\(Self\.auxiliaryRole\(index\)\)：\\\(id\)"\) \}/);
  // 只有 TAP 例外；其他引擎送出的三條路都帶「目標那一條」的 ultrawork，不再用 ultraworkTurnBriefing 當 systemPrompt。
  const model = read('Facade/ChatPageModel.swift');
  const coderSend = slice(model, '    func send() {', 'func appendDroppedPath');
  assert.match(coderSend, /let isTap = routeChoice\.runtimeAdapter == \.chatgptTap/, 'only TAP is exempt; all other engines retain per-turn ultrawork');
  assert.match(coderSend, /systemPrompt: nil,[\s\S]*?ultrawork: isTap \? nil : ultraworkSettings\(for: id\)\)/);
  assert.match(slice(model, 'private func startPRContribution(', 'engine.onTurnComplete[id]'), /let ultrawork = ultraworkSettings\(for: threadID\)/);
  assert.doesNotMatch(code(model), /systemPrompt: ultraworkTurnBriefing|systemPrompt: briefing/);
  // #2 遠端守：RemoteLiveEngine.send 把 ultrawork 序列化（不再收了 systemPrompt 卻不送）；私訊框別台 session 的 deliver 帶還沒送到的那份；
  // 主設備收下帶進那一輪（不再寫死只給 systemPrompt: nil）；認不得的欄位當沒帶、不擋（舊版主設備也一樣照常送）。
  const remote = read('Facade/RemoteLiveEngine.swift');
  assert.match(remote, /let outgoing = TatwoUltraworkPending\.shared\.outgoing\(for: threadID\)\s*let sentUltrawork = ultrawork \?\? outgoing\?\.settings\s*if let sentUltrawork \{ params\["ultrawork"\] = sentUltrawork\.wireObject \}/);
  assert.match(remote, /if let ultrawork \{ params\["ultrawork"\] = ultrawork \}/);
  assert.match(remote, /let method = reasoningEffort != nil \|\| serviceTier != nil \? "send_message_with_options" : "send_message"/, 'ultrawork never changes the method');
  const bridge = read('Facade/OSAgentBridge.swift');
  const sendMessage = slice(bridge, 'case "send_message", "send_message_with_options":', 'case "new_thread":');
  assert.match(sendMessage, /let ultrawork = UltraworkTurnSettings\.accepting\(params\["ultrawork"\]\)/);
  assert.match(sendMessage, /serviceTier: serviceTier,\s*ultrawork: ultrawork\) else \{/);
  assert.doesNotMatch(sendMessage, /isSubset|params\.keys/);
  assert.match(ultra, /return ChatRouteChoice\.resolveOrNil\(text\)\?\.canonicalModelSlug/, 'only known model names get into the turn');
  // #3 守：存在那條 thread 的偏好（跟模型、速度、記憶同一個地方，重開還在）；壞掉的欄位只丟那一欄。
  const store = read('Facade/ChatLiveStore.swift');
  assert.match(store, /var ultrawork: UltraworkTurnSettings\?/);
  assert.match(store, /ultrawork = \(try\? c\.decodeIfPresent\(UltraworkTurnSettings\.self, forKey: \.ultrawork\)\) \?\? nil/);
  assert.match(engine, /func setUltrawork\(threadID: UUID, _ settings: UltraworkTurnSettings\?\) \{/);
  // #3 守：私訊框 session 讀、改的是那一條自己的（sendFromDM 帶的就是它）；同一條才跟 Coder 一起變。
  const dm = slice(mode, 'static func dm(store: GlobalDMStore)', 'static func dmLocalThread(');
  assert.match(dm, /model\?\.setUltraworkLevel\(\$0, for: id\)/);
  assert.doesNotMatch(code(dm), /model\?\.collaborationLevel|setCollaborationLevel/);
  assert.match(ultra, /if threadID == selectedThreadID \{ applyUltraworkMirror\(settings\) \}/);
  assert.match(model, /func restoreModelPreferences\(\) \{\s*restoreUltraworkPreferences\(\)/);
  // 開、關 ultrawork 不換這條的模型：只寫 ultrawork 那一欄（setUltraworkLevel 不碰 selectedModel／requestedModel）。
  assert.doesNotMatch(slice(ultra, 'func setUltraworkLevel(', '\n    }\n'), /selectedModel|requestedModel|setSingleModel/);
});

// W184 H4 修正（審查 #4）：看不到的拉條不能被點到。
test('W184 H4 fix (review #4): a slider only takes a press where it is visible (visibleRect, the card\'s scrolling viewport)', () => {
  const sliders = read('Chat/ChatPageSliderBridges.swift');
  const down = slice(sliders, 'case .leftMouseDown:', 'case .leftMouseDragged:');
  assert.match(down, /guard Self\.accepts\(point: point, bounds: bounds, visibleRect: visibleRect, viewport: viewportRect\) else \{ return \}/);
  assert.doesNotMatch(down, /guard bounds\.contains\(point\) else \{ return \}/, 'bounds alone is no longer enough');
  assert.match(sliders, /static func accepts\(point: NSPoint, bounds: NSRect, visibleRect: NSRect, viewport: NSRect\?\) -> Bool \{\s*guard bounds\.contains\(point\), visibleRect\.contains\(point\) else \{ return false \}\s*if let viewport \{ return viewport\.contains\(point\) \}/);
  assert.ok(sliders.includes('captureView.viewport = viewport'));
  assert.match(track, /@Environment\(\\\.tatwoComposerModeViewport\) private var viewport/);
  assert.match(track, /pendingSettleActive: settling \|\| pendingIndex != nil,\s*viewport: viewport\)/);
});

// W184 H4 修正（審查 #6）：所有入口同一套鍵盤與焦點（卡都由 TatwoComposerModePopover 掛）。
test('W184 H4 fix (review #6): one keyboard and focus path for every entry: Esc first, keys to the card, IME first, focus back', () => {
  const keys = read('Chat/TatwoComposerModeKeyboard.swift');
  for (const piece of ['case 53: return mods.isEmpty ? .escape : nil', 'case 48: return mods.isEmpty ? .next : (mods == [.shift] ? .previous : nil)',
    'case 36, 76: return mods.isEmpty ? .commit : nil', '(window?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true']) {
    assert.ok(keys.includes(piece), piece);
  }
  // 組字中一律先給輸入法：卡的監看與輸入框讓鍵的判斷都先看 marked text。
  assert.match(keys, /!TatwoComposerModeKeyboard\.isComposing\(in: window\),\s*let key = TatwoComposerModeKeyboard\.key\(for: event\) else \{ return false \}/);
  assert.match(keys, /isOpen\(in: window\) && !isComposing\(in: window\) && key\(for: event\) != nil/);
  // 輸入框：卡開著時把卡要的鍵讓出去（不送出、不選建議、不動游標），而且在送出與建議之前。
  const bridges = read('Chat/ChatPageAppKitBridges.swift');
  const keyDown = slice(bridges, 'override func keyDown(with event: NSEvent) {', 'override func isAccessibilityElement()');
  assert.ok(keyDown.indexOf('TatwoComposerModeKeyboard.yieldsToCard(event, in: window)') < keyDown.indexOf('consumeAsSuggestionKey(event)')
    && keyDown.indexOf('consumeAsSuggestionKey(event)') < keyDown.indexOf('onSubmit?()'));
  const focused = slice(bridges, 'private func handleFocusedKeyEvent(_ event: NSEvent) -> NSEvent? {', 'override func draw(');
  assert.ok(focused.indexOf('if TatwoComposerModeKeyboard.yieldsToCard(event, in: window) { return event }') > 0
    && focused.indexOf('yieldsToCard') < focused.indexOf('consumeAsSuggestionKey(event)') && focused.indexOf('yieldsToCard') < focused.indexOf('onSubmit?()'));
  // 卡：由掛卡那一層給「收起」；有它才收鍵盤（Plan 畫布那張沒有）；收卡後焦點回輸入框（別的輸入的地方拿著鍵盤就不搶）。
  const popover = slice(card, 'struct TatwoComposerModePopover<Card: View>: ViewModifier', 'extension View {');
  assert.match(popover, /\.environment\(\\\.tatwoComposerModeDismiss,\s*TatwoComposerModeDismiss\(action: \{ isPresented = false \}, isPresented: \{ isPresented \}\)\)/);
  // 卡收起的那一刻監看就不算開著（淡出途中不再搶鍵、輸入框的 Return 照常送出）。
  assert.match(keys, /var isActive: Bool \{ onKey != nil && \(isLive\?\(\) \?\? true\) \}/);
  assert.match(popover, /\.onChange\(of: isPresented\) \{ was, now in\s*if was && !now \{ host\.restoreFocusSoon\(\) \}/);
  assert.ok(card.includes('if let dismiss { TatwoComposerModeKeyMonitor(onKey: handleKey, isLive: dismiss.isPresented) }'));
  assert.match(keys, /if let current = window\.firstResponder as\? NSView, current is NSText \|\| current is NSTextField,\s*!frame\.intersects\(current\.convert\(current\.bounds, to: nil\)\) \{\s*return\s*\}/);
  // 每個入口都走同一個掛法（所以同一套鍵盤）：Coder、私訊框、助理頁、Space、Bot Studio。
  for (const [name, source] of [['Coder', composer], ['DM', dmComposer], ['assistant page', pane], ['Space', builder], ['Bot Studio', botComposer]]) {
    assert.ok(source.includes('.tatwoComposerModeCard(isPresented:'), name);
  }
});

// W184 H4 修正第二輪（GPT-6 H4b 審查 #1–#3、#5–#7、#10；主導看 0.7 倍 PNG）：守「送到才算」、遠端送的途中又改、兩個入口共用送出鎖、
// 壞欄位整份不收、鍵盤框捲進來／收掉的不給選、電源並排 S～XXL、私訊框輸入框只露整行。
test('W184 H4 fix round 2 (review H4b): delivered only when the engine or primary takes the turn; newest remote choice kept; one send lock; strict fields; keyboard visible; power beside S～XXL; whole lines', () => {
  const engine = read('Facade/ChatLiveEngine.swift');
  const sidecar = read('Engine/ClaudeSidecar.swift');
  // #1：寫不進引擎回 false（不再吞掉錯誤、照樣回 true）；送出時先掛「等確認」，確認前不記 ultraworkSent、不叫呼叫端清草稿。
  assert.match(sidecar, /func write\(_ data: Data\) -> Bool \{\s*do \{ try stdin\.write\(contentsOf: data\); return true \} catch \{ return false \}/);
  assert.match(sidecar, /func send\(text: String, uuid: String,[^)]*\) -> Bool \{/);
  const send = slice(engine, 'ultrawork: UltraworkTurnSettings?, delivery: (@MainActor (LiveSendDelivery) -> Void)?) -> Bool {', 'func savePastedAttachment');
  assert.match(send, /guard sidecar\.send\(text: outgoing, uuid: turn,[\s\S]*?\) else \{\s*runningThreads\.remove\(threadID\)[\s\S]*?return false\s*\}\s*if let groupText = groupBridge\.outgoing\[threadID\] \{ groupBridge\.sessions\[threadID\]\?\.adjustPrimarySent\(outgoing\.count - groupText\.count\) \}\s*pendingTurnDeliveries\[threadID\] = PendingTurnDelivery\(/);
  const confirm = slice(engine, 'private func confirmTurnDelivery(', '\n    }\n');
  assert.match(confirm, /doc\.threads\[index\]\.ultraworkSent = pending\.ultraworkSent[\s\S]*pending\.callback\?\(\.delivered\)/);
  // 確認＝這一輪的第一個原生事件（Codex 的 turn_accepted、串流、工具、成功的結果）；還沒確認就失敗或停＝沒送到；system init／model 不算。
  const sdk = slice(engine, 'if let pendingTurn = pendingTurnDeliveries[threadID]?.turn, pendingTurn == turnID[threadID] {', 'switch type {\n        case "system":');
  assert.match(sdk, /case "stream_event", "assistant", "user":\s*confirmTurnDelivery\(threadID\)/);
  assert.match(sdk, /case "system" where m\["subtype"\] as\? String == "turn_accepted":\s*confirmTurnDelivery\(threadID\)/);
  assert.match(sdk, /if m\["is_error"\] as\? Bool == true \|\| m\["subtype"\] as\? String == "cancelled" \{\s*failTurnDelivery\(/);
  assert.doesNotMatch(sdk, /"init"|"model"/);
  // 引擎在讀到那一句之前就結束（重開、接回原本的對話失敗）＝沒送到：說清楚、標那一列；不自動重送。
  const closed = slice(engine, 'case .closed:', 'func handleSDK(');
  assert.match(closed, /failTurnDelivery\(threadID, reason: "引擎在讀到這一句之前就結束了", markRow: true\)\s*appendSystem\(threadID, Self\.undeliveredClosedText/);
  assert.doesNotMatch(code(closed), /\.send\(/, 'no automatic resend');
  // Codex sidecar：turn/start 收下就回 turn_accepted（帶 App 的 client_turn_id）。
  const codex = readFileSync(new URL('../Engines/codex-sidecar/sidecar.mjs', import.meta.url), 'utf8');
  assert.match(codex, /turn\.id = id;\s*\/\/[^\n]*\n\s*sdk\(\{ type: 'system', subtype: 'turn_accepted', session_id: threadID, client_turn_id: turn\.uuid \}\);/);
  // #1、#7（第三輪，主導：「按了送出、字還在框裡，看起來就是壞了」）：Coder 按下送出就清輸入框（字與附件），先記下快照；
  // 確認收到＝什麼都不做；沒送到／不確定＝輸入框還空著（而且還是那一條）就放回、說一聲，已經打了新的一句就不蓋掉——抽屜一行
  // 「上一句沒送到：前 20 個字…」＋玻璃 chip「放回輸入框」（接在草稿前面）。不自動重送。
  const model = read('Facade/ChatPageModel.swift');
  const coderSend = slice(model, '    func send() {', 'func appendDroppedPath');
  assert.match(coderSend, /let isTap = routeChoice\.runtimeAdapter == \.chatgptTap/, 'only TAP is exempt; all other engines retain per-turn ultrawork');
  assert.doesNotMatch(coderSend, /if let inFlight = coderDeliveries\[id\]/, 'no "still sending" guard: the composer is already empty');
  assert.match(coderSend, /coderDeliveries\[id\] = CoderDelivery\(token: token, text: text, attachments: atts, names: droppedPathDisplayNames\)/);
  assert.match(coderSend, /let accepted = OSEventSources\.scope\(source\) \{ activeLive\.send\(/);
  assert.match(coderSend, /ultrawork: isTap \? nil : ultraworkSettings\(for: id\)\) \{ \[weak self\] outcome in\s*self\?\.finishCoderDelivery\(id, token: token, outcome\)\s*\} \}\s*if accepted \{\s*prompt = ""\s*droppedPaths = \[\]\s*droppedPathDisplayNames = \[:\]/);
  const putBack = slice(model, 'private func putBackUndelivered(', 'var coderUndeliveredNotice');
  assert.match(putBack, /let sentContext = CoderDraftIdentity\(deviceID: sent\.deviceID, threadID: id\)/);
  assert.match(putBack, /if currentCoderDraftIdentity == sentContext, composerEmpty \{\s*prompt = sent\.text\s*droppedPaths = sent\.attachments/);
  assert.match(putBack, /\} else \{\s*let previous = localLive\?\.groupBridge\.sessions\[id\] != nil && coderUndelivered\?\.threadID == id && coderUndelivered\?\.deviceID == sent\.deviceID \? coderUndelivered : nil\s*coderUndelivered = CoderUndelivered\(threadID: id, text: \(previous\.map \{ \$0\.text \+ "\\n" \} \?\? ""\) \+ sent\.text/);
  assert.match(model, /return flat\.count > 20 \? String\(flat\.prefix\(20\)\) \+ "…" : flat/);
  assert.match(slice(model, 'func restoreUndeliveredDraft()', '\n    }\n'), /undelivered\.text \+ "\\n" \+ current/);
  assert.doesNotMatch(slice(model, 'var canSend: Bool {', 'var canSteerCurrentTurn'), /coderDeliveries/);
  const drawer = slice(composer, 'var composerStatusBar: some View {', '.padding(.horizontal, 12)');
  assert.match(drawer, /let undelivered = model\.coderUndeliveredNotice/);
  assert.match(drawer, /Button \{ model\.restoreUndeliveredDraft\(\) \} label: \{\s*Text\("放回輸入框"\)[\s\S]*?\.chatGlassChip\(\)/);
  assert.doesNotMatch(drawer, /borderedProminent|\.buttonStyle\(\.bordered/, 'glass chip, not a blue system button');
  // 私訊框：按下就清（照舊），失敗時照同一套放回（本機 session 與本機助理）。
  const dmSend = slice(model, 'func sendFromDM(', 'var localLiveForBridge');
  assert.match(dmSend, /if let message = Self\.undeliveredMessage\(outcome\) \{ onUndelivered\(message\) \}/);
  assert.match(dmSend, /if accepted \{ onDelivered\(\) \}/);
  assert.match(slice(model, 'private func sendToLocalAssistant(', 'func sendAssistantDraft()'), /if let message = Self\.undeliveredMessage\(outcome\) \{ onUndelivered\(message\) \}/);
  const dmStore = read('DM/GlobalDMStore.swift');
  assert.match(dmStore, /accepted = model\?\.sendFromDM\(threadID: id, text: text, attachments: paths, onDelivered: delivered,\s*onUndelivered: undeliveredBack\)/);
  assert.match(slice(dmStore, 'func putBackUndelivered(', 'var undeliveredNotice'), /if empty \{\s*setDraft\(text, for: target\)[\s\S]*?\} else \{\s*undelivered = Undelivered\(target: target, text: text, files: files\)/);
  assert.match(dmView, /GlobalDMNoticeRow\(icon: "arrow\.uturn\.backward\.circle", text: undelivered, actionTitle: "放回輸入框",\s*identifier: "tatwo\.dm\.undelivered"\) \{ store\.restoreUndelivered\(\) \}/);
  // #2：每一次明確的選擇都記（就算跟那台的一樣）、帶世代；收下時只確認那個世代、先記已確認；確認之後才開始拉的文件才交還。
  const ultra = read('Chat/TatwoComposerModeUltrawork.swift');
  assert.match(slice(ultra, 'func setUltraworkSettings(', '\n    }\n'), /case \.remote\(_, let id\):[\s\S]*?TatwoUltraworkPending\.shared\.set\(settings, for: id\)/);
  assert.doesNotMatch(slice(ultra, 'func setUltraworkSettings(', '\n    }\n'), /TatwoUltraworkPending\.shared\.clear/);
  assert.match(ultra, /func delivered\(_ threadID: UUID, generation: Int, at time: TimeInterval\) \{\s*guard entries\[threadID\]\?\.generation == generation/);
  assert.match(ultra, /if let confirmedAt = entry\.confirmedAt, fetchStartedAt >= confirmedAt \{ entries\[id\] = nil \}/);
  const remote = read('Facade/RemoteLiveEngine.swift');
  const remoteSend = slice(remote, 'delivery: (@MainActor (LiveSendDelivery) -> Void)?\n    ) -> Bool {', '/// W179 F：助理與私訊框送到主設備那條');
  assert.ok(remoteSend.indexOf('TatwoUltraworkPending.shared.delivered(threadID, generation: sentGeneration') < remoteSend.indexOf('self.refreshDocument(notify: true)'),
    'confirmed first, then refresh');
  assert.match(remote, /private func refreshDocument\(notify: Bool, then completion: @escaping @MainActor \(\) -> Void = \{\}\) \{\s*let startedAt = Self\.clock\(\)[\s\S]*?try self\.apply\(result: result, notify: notify\)\s*self\.reconcileUltrawork\(fetchStartedAt: startedAt\)/);
  // #7：Coder 與私訊框共用每條一把送出鎖（同一台的遠端引擎）：後到的那句當場退回；那台拒收＝沒送到（草稿留著）。
  assert.match(remoteSend, /guard !sendingThreadIDs\.contains\(threadID\) else \{[\s\S]*?return false\s*\}/);
  assert.match(slice(remote, 'func deliver(threadID: UUID', 'nonisolated static func deliverParams'),
    /guard !sendingThreadIDs\.contains\(threadID\) else \{\s*return completion\(\.failure\(RemoteHostLinkError\.remoteError\(Self\.sendingCode\)\)\)/);
  const delivery = slice(remote, 'static func delivery(for error:', '@discardableResult func send(');
  assert.match(delivery, /guard case RemoteHostLinkError\.remoteError\(let code\) = error else \{\s*return \.unknown\(/);
  assert.match(delivery, /return \.notDelivered\(RemoteSendRejection\.reason\(for: code\)/);
  assert.match(read('Facade/RemoteSendRejection.swift'), /case "invalid_params": "[^"\n]*參數[^"\n]*"/);
  // #3：欄位在但型別錯、內容認不得＝整份不收（不拿空的蓋掉原本的）；檔位是 true 也不收。
  const accepting = slice(ultra, 'static func accepting(_ value: Any?)', '\n    }\n}');
  assert.match(accepting, /CFGetTypeID\(number\) != CFBooleanGetTypeID\(\)/);
  assert.match(accepting, /if let raw = object\["auxiliary"\] \{\s*guard let list = raw as\? \[Any\], list\.count <= 8 else \{ return nil \}/);
  assert.doesNotMatch(accepting, /as\? \[Any\] \?\? \[\]/);
  // #5：鍵盤框到中間那一段的哪一區就捲到它；中間整個收掉時不給選；清單的列也捲進來。
  assert.match(card, /guard hasSections, fit\.showsSections else \{ return targets \}/);
  assert.match(card, /\.onChange\(of: focusID, initial: true\) \{ _, id in\s*guard let id else \{ return \}\s*DispatchQueue\.main\.async \{ proxy\.scrollTo\(id, anchor: nil\) \}/);
  assert.match(card, /\.onChange\(of: keyListIndex, initial: true\) \{ _, index in[\s\S]*?let id = Self\.listScrollID\(flat\[index\]\.id\)\s*DispatchQueue\.main\.async \{ proxy\.scrollTo\(id, anchor: nil\) \}/);
  // 自測量鍵盤框的真位置：框著的那一塊墊 AppKit 定位點（捲動不一定重新回報 SwiftUI 的位置）；電源也有定位點。
  assert.match(card, /\.background \{ if keyed \{ TatwoComposerModeKeyFocusMarker\(\) \} \}/);
  assert.match(card, /\.background\(TatwoComposerModePowerMarker\(\)\)/);
  // #6：電源在 S～XXL 旁邊（固定在上面）；底列只剩說明、可以收。
  assert.match(card, /private var showsFooter: Bool \{ mode\.footnote != nil \}/);
  assert.doesNotMatch(slice(card, 'private var footer: some View', 'private func noteLine('), /power|setLevel/);
  // 主導看 PNG：私訊框輸入框的文字區只露整行、在裡面捲、不跟底下那排疊著。
  assert.match(dmComposer, /\.frame\(height: GlobalDMComposerText\.visibleHeight\(textFrame\)\)\s*\.frame\(height: textFrame, alignment: \.top\)/);
  assert.match(dmView, /static let lineHeight: CGFloat = NSLayoutManager\(\)\.defaultLineHeight\(for: \.systemFont\(ofSize: GlobalDMChatLayout\.messageSize\)\)/);
  // 挑檔單獨編的兩個 node 測試照樣編得過：資料型別在它們本來就編的檔裡；鍵盤那個正式檔整份一起編（主導 e88ae585 全套 node 抓到的兩條）。
  assert.match(read('Facade/ChatLiveStore.swift'), /struct UltraworkTurnSettings: Codable, Equatable, Sendable \{\s*var level: Int\s*var primaryModelID: String\?\s*var auxiliaryModelIDs: \[String\]\s*\}/);
  const layoutTest = readFileSync(new URL('./tatwo2-composer-layout.test.mjs', import.meta.url), 'utf8');
  assert.ok(layoutTest.includes("App/Sources/Tatwo2/Chat/TatwoComposerModeKeyboard.swift") && layoutTest.includes('${keyboard}'));
  // 第四輪：U 段換連線的接縫在 RemoteLiveEngine（只有 DEBUG 建構子能換），RemoteHostLink 不留任何替身（W91c 信任清單零 diff）。
  assert.doesNotMatch(read('Facade/RemoteHostLink.swift'), /TestDouble|testDouble/);
  assert.match(remote, /#if DEBUG\s*\n(?:\s*\/\/\/.*\n)*\s*convenience init\(link: RemoteHostLink, callingThrough caller: any RemoteLiveCalling,/);
  assert.match(remote, /convenience init\(link: RemoteHostLink, store: ChatLiveStore, initial: \[String: Any\]\? = nil\) throws \{\s*try self\.init\(link: link, caller: link, store: store, initial: initial\)/);
  assert.match(read('Chat/TatwoComposerModeAcceptanceRound2.swift'), /RemoteLiveEngine\(link: link, callingThrough: BridgeCaller\(gate: gate, bridge: bridge\),/);
});

// 第四輪（主導：G3c drawn 在整合全套裡因主題不對失敗）：自測換主題只換這個程序畫的樣子，共用的存檔（tatwo.activeThemeID；
// 自測程式的偏好設定網域整台共用，lead-verify 的 HOME 隔離隔不到）全程不動；量像素的自測先定主題；G3c drawn 明確選 fable5。
test('W184 H4 round 4: self-tests switch themes without touching the shared stored theme; pixel self-tests pin their theme', () => {
  const scope = read('Visual/TatwoThemeSelfTest.swift');
  assert.match(scope, /^#if DEBUG/);
  assert.match(read('Visual/TatwoTheme.swift'), /private static let key = "tatwo\.activeThemeID"/);
  assert.match(scope, /static let storedKey = "tatwo\.activeThemeID"/);
  assert.match(slice(scope, 'func use(_ theme: TatwoThemeID) {', '\n    }'), /TatwoThemeStore\.shared\.select\(theme\)\s*keepStored\(\)/);
  assert.match(slice(scope, 'func restore() {', '\n    }'), /TatwoThemeStore\.shared\.select\(original\)\s*keepStored\(\)/);
  // 產品以外沒有人直接叫 select：自測一律經過 TatwoThemeSelfTestScope（切了就會還原、存檔不動）。
  const walk = (dir) => readdirSync(new URL('../App/Sources/Tatwo2/' + dir, import.meta.url), { withFileTypes: true })
    .flatMap((entry) => entry.isDirectory() ? walk(dir + entry.name + '/') : entry.name.endsWith('.swift') ? [dir + entry.name] : []);
  const direct = walk('').filter((name) => /Acceptance|SelfTest/.test(name) && name !== 'Visual/TatwoThemeSelfTest.swift')
    .filter((name) => /TatwoThemeStore\.shared\.select\(|\bthemes\.select\(/.test(code(read(name))));
  assert.deepEqual(direct, []);
  // 兩個主題迴圈：迴圈開始前記下、defer 還原（含中途 continue／失敗）。
  const acceptance = read('Chat/TatwoComposerModeAcceptance.swift');
  assert.match(acceptance, /let themeScope = TatwoThemeSelfTestScope\(\)\s*defer \{ themeScope\.restore\(\) \}\s*for theme in \[TatwoThemeID\.fable5, \.aurora\] \{\s*themeScope\.use\(theme\)/);
  assert.match(acceptance, /let themeScope = TatwoThemeSelfTestScope\(\)\s*defer \{ themeScope\.restore\(\) \}\s*for theme in \[TatwoThemeID\.fable5, \.aurora\] \{\s*smallDMChecks\(/);
  assert.match(read('Chat/TatwoComposerModeAcceptanceFix.swift'), /let themeScope = TatwoThemeSelfTestScope\(\)\s*themeScope\.use\(theme\)\s*defer \{ themeScope\.restore\(\) \}/);
  // G3c：drawn 之前明確選 fable5（門檻照它調的），結束還原。
  const g3c = read('DM/GlobalDMChatGPTG3cAcceptance.swift');
  const pinned = g3c.indexOf('themeScope.use(.fable5)');
  assert.ok(pinned > 0 && pinned < g3c.indexOf('G3c (drawn)'), 'G3c pins fable5 before its drawn checks');
  assert.match(g3c, /themeScope\.use\(\.fable5\)\s*defer \{ themeScope\.restore\(\) \}/);
  // 量像素的自測：程序一開始就定在 fable5（不吃共用存檔剛好是什麼）。
  assert.match(read('SelfTest.swift'), /if let name = ProcessInfo\.processInfo\.environment\["TATWO2_SELFTEST"\], TatwoThemeSelfTestScope\.pixelSelfTests\.contains\(name\) \{\s*TatwoThemeSelfTestScope\(\)\.use\(\.fable5\)/);
  for (const name of ['w184chat', 'w184forms', 'w184button', 'w184tent', 'w184browser', 'w184mode']) assert.ok(scope.includes(`"${name}"`), name);
});
