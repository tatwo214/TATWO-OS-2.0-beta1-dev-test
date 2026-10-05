import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';

// W179 UI 精修：私訊框圖層、按鈕一致、TATWO 輸入框對齊 Coder 的原始碼契約。
// 版面數值（停靠框不蓋輸入框、桌面框不蓋圓鈕、選單範圍、蓋層狀態機）由 `TATWO2_SELFTEST=w179ui` 實際算過。
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
const folder = (dir) => readdirSync(new URL('../App/Sources/Tatwo2/' + dir, import.meta.url))
  .filter((name) => name.endsWith('.swift'))
  .map((name) => [dir + '/' + name, read(dir + '/' + name)]);

test('TATWO composer is the Coder composer: same text view, glass card, toolbar, send/stop, status drawer', () => {
  const pane = read('Assistant/AssistantSpacePane.swift');
  for (const piece of [
    'ChatComposerTextView(', 'text: $model.assistantPrompt', 'slashCommands: []', 'accessibilityTextLabel: "TATWO 助理訊息"',
    'ChatComposerToolbarRow(compact:', 'ChatComposerSendButton(enabled: model.assistantCanSend',
    'ChatComposerStopButton(action: model.stopAssistant)', '.liquidGlassPanelSurface(cornerRadius: LiquidGlassTokens.radiusPrimary)',
    '.globalDMComposerFrame(.tatwo', 'ChatComposerStatusDrawer(text: status.text, tone: status.tone)', '.zIndex(-1)',
    '.padding(.top, -13)', 'ChatTranscriptDisplayBuilder.build(', 'ChatInlineWorkTimelineView(', 'ChatTypingIndicatorRow(',
    'ChatUILayout.chatColumnMaxWidth', 'TatwoThemeStore.shared', 'TatwoChatTranscriptVisualMetrics.windowComposerTextMinimumHeight',
    'TatwoChatTranscriptVisualMetrics.windowComposerMinimumHeight',
  ]) {
    assert.ok(pane.includes(piece), piece);
  }
  // Outer spacing 8 with the drawer's -13 leaves 5pt under the composer, exactly like Coder.
  assert.match(pane, /VStack\(alignment: \.leading, spacing: 8\) \{\s*VStack\(alignment: \.leading, spacing: 0\) \{\s*ChatComposerTextView\(/);
  for (const piece of ['TextField(', 'Button("送出"', 'Button("停止"', '@FocusState', '在主設備「']) {
    assert.ok(!code(pane).includes(piece), `pane must not contain ${piece}`);
  }
  // Header is only the title.
  assert.match(pane, /Label\("TATWO 助理", systemImage: "sparkles"\)\s*\.font\(\.headline\)\s*\.frame\(width: column/);
  assert.doesNotMatch(pane, /route\.title|assistantRouteChoice\.title/);
});

test('model chip is the Coder model chip (a Button, whole chip clickable) opening a native menu; primary name on its first line', () => {
  const menu = read('Assistant/AssistantModelMenu.swift');
  // Same label as Coder's model chip, drawn by a plain Button (a borderless SwiftUI Menu drops the glass and the chevron
  // and only its text is clickable; .menuStyle(.button) is out per D2).
  assert.match(menu, /Button\(action: popUp\) \{\s*ChatComposerModelLabel\(title: title, suffix: nil, compact: false, selected: false\)\s*\}\s*\.buttonStyle\(\.plain\)/);
  assert.doesNotMatch(code(menu), /\bMenu \{|\.menuStyle\(/);
  assert.match(menu, /menu\.popUp\(positioning: nil, at: topLeft, in: view\)/);
  // Native menu content: primary line (not clickable), a section per brand, selected checkmark, disabled engines greyed.
  const build = slice(menu, 'static func makeMenu(', '\n    }\n');
  for (const piece of ['menu.autoenablesItems = false', 'line.isEnabled = false', '.sectionHeader(title: brand.rawValue)',
    'item.state = option.isSelected ? .on : .off', 'item.isEnabled = !option.isDisabled', 'ChatRouteBrandGroup.pickerOrder']) {
    assert.ok(build.includes(piece), piece);
  }
  assert.match(build, /if let primaryName \{\s*let line = NSMenuItem\(title: "在主設備「\\\(primaryName\)」上跑/);
  // The anchor view never takes the click away from the chip.
  assert.match(menu, /override func hitTest\(_ point: NSPoint\) -> NSView\? \{ nil \}/);
});

test('status drawer is quiet unless there is something to say (Coder 09-11 ruling)', () => {
  const status = read('Assistant/AssistantComposerStatus.swift');
  for (const piece of ['"工作中"', 'tatwo-assistant-offline', 'tatwo-assistant-primary-hint', 'tone: .quiet']) {
    assert.ok(status.includes(piece), piece);
  }
  assert.doesNotMatch(code(status), /primaryName|在主設備「/, 'no permanent primary line');
  const pane = read('Assistant/AssistantSpacePane.swift');
  // W182 R5：頂端那行說了「離線、在這台接著聊」時，輸入框下不再重複（其他時候照舊）。
  assert.match(pane, /let status = AssistantComposerStatus\.resolve\(hint: model\.assistantPrimaryHint,\s*(?:\/\/[^\n]*\n\s*)?placementNote: (?:model\.assistantOfflineHandoffActive \? nil : )?model\.assistantPlacementNote/);
  // The note and the hint only reach the drawer: read once, and the composer section draws no error card.
  assert.equal(count(pane, 'model.assistantPlacementNote'), 1);
  assert.equal(count(pane, 'model.assistantPrimaryHint'), 1);
  assert.doesNotMatch(slice(pane, 'private func composer(column: CGFloat)', 'private var isConnecting'), /ChatErrorCard/);
  // Drawer text colours follow Coder: only a hint is dark; 工作中 is the neutral grey; a warning is secondary.
  const chrome = read('Chat/ChatComposerChrome.swift');
  const colors = slice(chrome, 'private var textColor: Color {', '\n    }');
  assert.match(colors, /case \.hint: Color\.primary\.opacity\(0\.9\)/);
  assert.match(colors, /case \.warning: Color\.secondary\n/);
  assert.match(colors, /case \.working, \.info, \.quiet: Color\.secondary\.opacity\(0\.88\)/);
});

test('shared composer pieces: stop button and drawer copy Coder exactly; Coder callers unchanged', () => {
  const chrome = read('Chat/ChatComposerChrome.swift');
  const composer = read('Chat/ChatPage+Composer.swift');
  assert.match(chrome, /var usesCommandReturn = true/);
  assert.match(chrome, /enum ChatComposerStatusTone: Equatable, Sendable/);
  const stop = slice(chrome, 'struct ChatComposerStopButton', 'enum ChatComposerStatusTone');
  const coderStop = slice(composer, 'var composerStopTint', 'var composerStopButton');
  const coderStopButton = composer.slice(composer.indexOf('var composerStopButton: some View'));
  for (const piece of ['stop.fill', '.font(.system(size: 10, weight: .black))', '.frame(width: 28, height: 28)', '.opacity(0.78)',
    'LiquidGlassTokens.tint.opacity(LiquidGlassTokens.strokeOpacity)', 'LiquidGlassTokens.shadowRadius']) {
    assert.ok(stop.includes(piece), `shared stop: ${piece}`);
    assert.ok(coderStopButton.includes(piece), `coder stop: ${piece}`);
  }
  assert.ok(stop.includes('Color(nsColor: .systemRed)') && coderStop.includes('Color(nsColor: .systemRed)'));
  const drawer = slice(chrome, 'struct ChatComposerStatusDrawerShape', 'struct ChatComposerStatusDrawer: View');
  assert.match(drawer, /sideSlope: CGFloat = 5/);
  assert.match(drawer, /cornerRadius: CGFloat = 16/);
  const drawerView = chrome.slice(chrome.indexOf('struct ChatComposerStatusDrawer: View'));
  for (const piece of ['Color.primary.opacity(0.075)', 'Color.primary.opacity(0.16)', 'glassIdentityFillOpacity * 1.6',
    'minHeight: 28, maxHeight: 28', '.padding(.horizontal, 14)']) {
    assert.ok(drawerView.includes(piece), `drawer: ${piece}`);
  }
  // Coder still draws its own pieces and calls the send button the old way.
  assert.match(composer, /\.liquidGlassPanelSurface\(cornerRadius: LiquidGlassTokens\.radiusPrimary\)\s*\.globalDMComposerFrame\(\.coder, active: surface == \.window\)/);
  assert.match(composer, /var composerStopButton: some View/);
  assert.match(composer, /private struct RoundedInvertedTrapezoid/);
  assert.match(composer, /ChatComposerSendButton\(enabled: model\.canSend\) \{ model\.send\(\) \}/);
  assert.doesNotMatch(composer, /ChatComposerStopButton|ChatComposerStatusDrawer/);
});

test('DM composer is the compact TATWO composer; hidden while the direct-key page is open', () => {
  const view = read('DM/GlobalDMView.swift');
  const composer = slice(view, 'struct GlobalDMComposer: View', 'struct GlobalDMKey');
  assert.ok(composer.includes('ChatComposerTextView(text: draft'));
  // 守：私訊框的送出鈕不註冊 ⌘↩（多個私訊框同時開著時不搶；Return 由文字框送），停止鈕停這個對象。
  // W184 C：36pt 的送出／停止是私訊框自己的（GlobalDMChatPhone.swift），Coder 的 ChatComposerChrome 不改。
  assert.match(composer, /GlobalDMSendButton\(enabled: canSend && store\.hasContentToSend\) \{\s*_ = store\.send\(\)/);
  assert.ok(composer.includes('GlobalDMStopButton { store.stop() }'));
  const phone = read('DM/GlobalDMChatPhone.swift');
  const send = slice(phone, 'struct GlobalDMSendButton', 'struct GlobalDMStopButton');
  assert.doesNotMatch(send, /keyboardShortcut/, 'the DM send button never takes ⌘↩');
  assert.match(send, /\.disabled\(!enabled\)/);
  // W181（「這邊輸入筐比例很醜」）：輸入框貼著框底、圓角與框同心（框的圓角減邊距）；W184 C 從 DMPhone 的 barRadius 取（52−12＝40）。
  assert.ok(composer.includes('.liquidGlassPanelSurface(cornerRadius: GlobalDMChatLayout.composerRadius)'));
  assert.match(phone, /static var composerRadius: CGFloat \{ DMPhone\.barRadius \}/);
  assert.match(read('DM/DMPhoneMetrics.swift'), /static var barRadius: CGFloat \{ concentric\(screenRadius, inset: edgeInset\) \}/);
  // W184 AB：舊的 GlobalDMLayout.composerCornerRadius 沒人用了（同心圓角只看上一條的 DMPhone.barRadius），拿掉。
  assert.doesNotMatch(view, /composerCornerRadius/);
  assert.ok(!composer.includes('GlobalDMChordHint('));
  // W184 C：輸入字與佔位字 17pt（手機內文 token）。
  assert.ok(composer.includes('pointSize: GlobalDMChatLayout.messageSize'));
  assert.match(phone, /static let messageSize = DMPhone\.TextSize\.body/);
  assert.doesNotMatch(composer, /roundButton|TextField\(/);
  // Lead decision: the direct-key page takes the whole body; the composer comes back when leaving it.
  assert.equal(count(view, 'if !store.isEditingDirectKeys {\n                GlobalDMComposer('), 2);
  // W184 AB：⌥⌘ 的說明不再佔頂列（名字行拿掉），搬進選單（W184 F：原本的「⋯ 更多」改成頁面圓鈕的右鍵選單）：一行不能點的說明，
  // 沒有權限時多一項打開設定；不是 chip。
  assert.doesNotMatch(view, /struct GlobalDMChordHint/);
  const phoneBox = read('DM/GlobalDMPhoneBox.swift');
  const more = phoneBox.slice(phoneBox.indexOf('enum GlobalDMMoreMenu'));
  assert.match(more, /let item = NSMenuItem\(title: title, action: nil, keyEquivalent: ""\)\s*item\.isEnabled = false/);
  assert.match(more, /menu\.addItem\(info\("要在其他 App 用 ⌥⌘，要開裝置控制和資料取用（舊稱輔助使用）權限"/);
  assert.doesNotMatch(more, /OSChipButton|Button\(/);
});

test('DM box and button use the App glass; no custom beige, black shadow or bubble colors', () => {
  const view = read('DM/GlobalDMView.swift');
  const chrome = slice(view, 'struct GlobalDMBoxChrome', 'struct GlobalDMBubble');
  assert.ok(chrome.includes('liquidGlassPanelSurface'));
  assert.doesNotMatch(chrome, /GlobalDMPalette|\.shadow\(color: \.black/);
  const button = slice(view, 'struct GlobalDMRoundButton', 'struct GlobalDMBoxHost');
  assert.ok(button.includes('liquidGlassPanelSurface(cornerRadius: GlobalDMLayout.buttonSize / 2)'));
  const palette = slice(view, 'enum GlobalDMPalette {', '\n}');
  const names = [...palette.matchAll(/static let (\w+)/g)].map((m) => m[1]);
  assert.deepEqual(names, ['assistantAvatar', 'sessionAvatar', 'chatGPTAvatar', 'laterAvatar']);
  for (const [name, source] of folder('DM')) {
    assert.doesNotMatch(source, /GlobalDMPalette\.(box|hairline|pill|menu|menuCurrent|secondary|text|mine|mineText|theirs|field|action|later|fab)\b/, name);
    assert.doesNotMatch(source, /0x2A2724/, name);
  }
});

test('DM messages: user bubble, Markdown replies, error card, system note, typing dots (W184 C: phone rows, no avatar)', () => {
  const view = read('DM/GlobalDMView.swift');
  assert.match(view, /case \.mine:[\s\S]{0,300}GlobalDMUserBubble\(text: bubble\.text\)/);
  // 守：錯誤卡、系統說明（含「用了 N 條記憶」）、打字點點都還在，用的是 Coder 的元件。
  // W184 C（對照稿：回覆不帶頭像，對象由頂列圓鈕表示）：回覆與打字列不畫頭像，打字列只有點點。
  for (const piece of ['ChatErrorCard(presentation:', 'ChatSystemNoteRow(presentation:', 'GlobalDMTypingRow(route:']) {
    assert.ok(view.includes(piece), piece);
  }
  const list = slice(view, 'struct GlobalDMMessageList', 'struct GlobalDMComposer');
  assert.doesNotMatch(list, /ChatModelAvatar\(|GlobalDMAvatar\(|ChatTypingIndicatorRow\(/, 'replies and the typing row carry no avatar');
  assert.ok(read('DM/GlobalDMChatPhone.swift').includes('ChatTypingDots()'), 'typing dots are the shared ones');
  // Same conversation, same rows: typing dots while the answer has no text yet (ChatGPT too, no literal …),
  // and every system note the TATWO page shows.
  assert.match(view, /static func rows\(_ messages: \[ChatMessage\], running: Bool = false\)/);
  assert.match(view, /running: model\.assistantIsRunning\)/);
  assert.match(view, /running: model\.dmSessionIsRunning\(id\)\)/);
  assert.doesNotMatch(code(view), /text: "…"|"info\|PR"/);
  const text = read('DM/GlobalDMMessageText.swift');
  // 守：泡泡底色是 App 的語意色（Coder 使用者訊息同一個 token），不照抄對照稿的米色；
  // W184 C：圓角、內距、行高改從私訊框自己的 GlobalDMChatLayout 取（圓角 20、內距 9／14、行高 23）。
  assert.ok(text.includes('GlobalDMChatLayout.userBubbleRadius'));
  assert.ok(text.includes('userBubbleTintOpacity'));
  assert.match(view, /struct GlobalDMMessageList: View, @MainActor Equatable/);
});

test('icon buttons are one glass circle (in-box icons the size of the send button; top bar 44)', () => {
  const view = read('DM/GlobalDMView.swift');
  const desk = read('DM/GlobalDMDeskViews.swift');
  assert.match(view, /static let iconButtonSize: CGFloat = 28/);
  // W184 AB：框頂的 ✕ 拿掉（W184 F：頂列的 ⌄ 收起也拿掉，收起靠 ⌥⌘ 與 Esc），框裡還有直達鍵頁的清除鈕。
  assert.ok(count(view + desk, 'GlobalDMIconLabel(systemImage: "xmark")') >= 1);
  assert.equal(count(view, 'GlobalDMIconLabel(systemImage: "chevron.left")'), 1);
  assert.equal(count(desk, 'GlobalDMIconLabel(systemImage: "chevron.left")'), 1);
  const circle = slice(view, 'struct GlobalDMGlassCircle', 'struct GlobalDMIconLabel');
  assert.match(circle, /Circle\(\)/);
  assert.doesNotMatch(circle, /RoundedRectangle/);
  // W184 AB：頂列的圓鈕也是同一種玻璃圓（44）；尺寸鈕拿掉。W184 F：右上的 ⋯、⌄ 拿掉，頂列只剩左上的頁面圓鈕（同一種玻璃圓）。
  assert.match(slice(read('DM/GlobalDMTargetStrip.swift'), 'struct GlobalDMIconButton: View', '// MARK: - 左右捲的一排'), /\.background\(GlobalDMGlassCircle\(isSelected: isCurrent\)\)/);
  assert.doesNotMatch(read('DM/GlobalDMPhoneBox.swift'), /struct GlobalDMTopBarIcon|struct GlobalDMMoreButton|struct GlobalDMCollapseButton/);
  assert.doesNotMatch(desk, /struct GlobalDMSizeMenuButton/);
});

test('text actions are the App glass chip; selection is the only accent', () => {
  const view = read('DM/GlobalDMView.swift');
  const notice = slice(view, 'struct GlobalDMNoticeRow', 'struct GlobalDMMessageList');
  // 守：提示列的鈕是 App 的玻璃 chip（不是藍色系統鈕、不用 isPrimary 強調），底是 App 的液態玻璃。
  // W184 C：chip 是私訊框自己的 32 高玻璃膠囊（GlobalDMGlassCapsule，同 chatGlassChip 的公式）；底的圓角 24 跟 chip 同心。
  assert.ok(notice.includes('GlobalDMChipButton(title: actionTitle, action: action)'));
  assert.ok(notice.includes('.chatLiquidSection(cornerRadius: GlobalDMChatLayout.noticeRadius'));
  const chipButton = slice(read('DM/GlobalDMChatPhone.swift'), 'struct GlobalDMChipButton', 'struct GlobalDMChatGPTCaption');
  assert.ok(chipButton.includes('.background(GlobalDMGlassCapsule())'));
  assert.doesNotMatch(chipButton, /isPrimary|brandAccent|borderedProminent/);
  assert.doesNotMatch(notice, /isPrimary/);
  const desk = read('DM/GlobalDMDeskViews.swift');
  assert.match(desk, /OSChipButton\(title: title, action: action\)/);
  for (const [name, source] of [...folder('DM'), ...folder('Assistant')]) {
    assert.doesNotMatch(code(source), /\.menuStyle\(\.button\)|\.borderedProminent|\.buttonStyle\(\.bordered|NSAlert|confirmationDialog/, name);
  }
});

test('menus stay between the header and the composer and scroll inside', () => {
  const view = read('DM/GlobalDMView.swift');
  assert.doesNotMatch(view, /\.padding\(\.top, 46\)|maxHeight: 330|\.frame\(height: 280\)/);
  for (const piece of ['struct GlobalDMBodyRegion', 'GlobalDMMenuLayout.pickerFrame(bodySize:', 'GlobalDMTargetPicker(store: store, maxHeight:']) {
    assert.ok(view.includes(piece), piece);
  }
  const picker = slice(view, 'struct GlobalDMTargetPicker', 'struct GlobalDMBadge');
  assert.match(picker, /ViewThatFits\(in: \.vertical\)/);
  assert.match(picker, /\.liquidGlassPanelSurface\(cornerRadius: LiquidGlassTokens\.radiusCard\)/);
  // The picker is drawn in exactly one place: over the body region, sized from that region's measured size.
  assert.equal(count(view, 'GlobalDMTargetPicker(store:'), 1);
  const region = slice(view, 'struct GlobalDMBodyRegion', 'struct GlobalDMNoticeRow');
  assert.ok(region.includes('GlobalDMMenuLayout.pickerFrame(bodySize: geo.size)'));
  assert.ok(region.includes('GlobalDMTargetPicker(store: store, maxHeight: frame.height)'));
  // Both panes stack: box header (in GlobalDMBox), then the body region, then the composer row.
  for (const [start, end] of [['struct GlobalDMThreadPane', 'struct GlobalDMChatGPTPane'], ['struct GlobalDMChatGPTPane', 'struct GlobalDMBodyRegion']]) {
    const pane = slice(view, start, end);
    const body = pane.indexOf('GlobalDMBodyRegion(store: store)');
    const composer = pane.indexOf('GlobalDMComposer(store: store');
    assert.ok(body > 0 && composer > body, start);
  }
  // W184 AB：頂列在 GlobalDMPhoneBox.swift；session 選單不畫在頂列。
  assert.doesNotMatch(read('DM/GlobalDMPhoneBox.swift'), /GlobalDMTargetPicker\(/);
  // Old helpers that no screen used are gone (the self-test must check what the screen uses).
  assert.doesNotMatch(read('DM/GlobalDMLayering.swift'), /func composerHeight\(|func bodyHeight\(/);
  assert.doesNotMatch(view, /composerChrome/);
});

test('W184 AB: one top bar for the whole phone (inner landscape too); ✕ and the size button are gone', () => {
  // 守：框級的東西只有一組、只在一個地方（W179 UI 的「單欄、雙欄同一個位置」）：頂列左上的頁面圓鈕（W184 F：右上的 ⋯ 更多、⌄ 收起拿掉，
  // 選單改在這顆圓鈕的右鍵），內橫也只有這一條頂列。
  const phone = read('DM/GlobalDMPhoneBox.swift');
  assert.equal(count(phone, 'GlobalDMTopBar(store: store, form: form)'), 1);
  assert.equal(count(phone, 'GlobalDMMoreButton('), 0);
  assert.equal(count(phone, 'GlobalDMCollapseButton('), 0);
  assert.equal(count(read('DM/GlobalDMTargetStrip.swift'), '.modifier(GlobalDMPageMenu(active: isCurrent, store: store, anchor: menuAnchor, surface: surface))'), 1);
  const box = slice(phone, 'struct GlobalDMPhoneBox: View', '// MARK: - 頂列');
  // W184 F2：對話那一層＝一條頂列＋欄（欄裡對話欄與內橫右欄同一個 ZStack），換形態時整層滑、不重建。
  assert.match(box, /VStack\(spacing: 0\) \{\s*GlobalDMTopBar\(store: store, form: form\)\s*columns\(look, width: width\)/);
  const view = read('DM/GlobalDMView.swift');
  const desk = read('DM/GlobalDMDeskViews.swift');
  for (const gone of ['GlobalDMBoxControls', 'GlobalDMBoxChromeLayout', 'GlobalDMBoxControlsOverlay', 'GlobalDMSizeMenuButton']) {
    assert.doesNotMatch(view + desk + read('DM/GlobalDMLayering.swift'), new RegExp(gone), gone);
  }
  // W184 F：⌄ 收起拿掉；收起靠 ⌥⌘、Esc（照舊浮動框收浮動框、停靠框收停靠框）。W184 F2：頁面圓鈕右鍵選單最下面補「收起私訊框」，
  // 沿用舊 ✕／⌄ 的識別碼 tatwo.dm.close，收的是選單所在的那個框（單按 ⌥⌘ 關掉、單欄又在看 Browser 時也一下就收）。
  assert.match(phone, /close\.identifier = NSUserInterfaceItemIdentifier\("tatwo\.dm\.close"\)/);
  assert.match(phone, /if surface == \.floating \{ store\.isFloatingOpen = false \} else \{ store\.isOpen = false \}/);
  const escape = slice(read('DM/GlobalDMPanelController.swift'), 'private func handleEscape(_ event: NSEvent) -> NSEvent? {', '// MARK: - 換形態（W184 AB）');
  assert.match(escape, /if store\.isEditingDirectKeys \{ store\.isEditingDirectKeys = false; return nil \}\s*if window === floating \{ store\.isFloatingOpen = false \} else if store\.isOpen \{ store\.isOpen = false \} else \{ return event \}/);
  // 右欄（另一個對象）沒有自己的頂列：GlobalDMBox 裡不畫頂列。
  assert.doesNotMatch(slice(view, 'struct GlobalDMBox: View', 'enum GlobalDMAvatarArt'), /GlobalDMTopBar|GlobalDMIconStrip/);
});

test('layering: main-window covers fold the docked panels; box sits above the composer', () => {
  const page = read('Chat/ChatPage.swift');
  assert.ok(page.includes('.globalDMCovers(globalDMCoversMainWindow, id: "chat")'));
  assert.ok(page.includes('GlobalDMLightboxCover(model: ChatGPTSpaceModel.shared)'));
  const covers = slice(page, 'var globalDMCoversMainWindow: Bool', '\n    }');
  for (const flag of ['showSettingsPage', 'showChatSearch', 'globalNoteOpen', 'showUltraworkPanel', 'showSingleModelPanel', 'ultraworkRolePickerTarget']) {
    assert.ok(covers.includes(flag), flag);
  }
  // The model / collaboration panels only count when they are drawn (same condition as chatFloatingPanelOverlay).
  assert.match(covers, /\(!planInspectorPresented && \(showUltraworkPanel \|\| showSingleModelPanel \|\| ultraworkRolePickerTarget != nil\)\)/);
  // W184 H4 修正（GPT-6 H4 審查 #7）：模式卡（showUltraworkPanel）不再畫在這個浮層，改掛在 Coder 輸入框上（量輸入框真的上緣、點外面不吞）；
  // 浮層只剩舊的模型／角色清單。蓋層的判斷照舊把模式卡算進去（卡開著時停靠框先收，免得跟卡疊在輸入框右上）。
  assert.match(read('Chat/ChatPage+Panels.swift'), /if !planInspectorPresented\s*&& \(showSingleModelPanel \|\| ultraworkRolePickerTarget != nil\)/);
  assert.match(read('Chat/ChatPage+Composer.swift'), /\.tatwoComposerModeCard\(isPresented: \$showUltraworkPanel\) \{/);
  // ChatGPT Space reports its composer too, only in the main window.
  assert.ok(read('TAP/ChatGPTSpace.swift').includes('.globalDMComposerFrame(.chatgpt, active: !showsHeader)'));
  assert.ok(read('Shell/AppShell.swift').includes('.globalDMCovers(surface == .window && chatModel.coldStartHydrationFailureMessage != nil, id: "shell")'));
  const controller = read('DM/GlobalDMPanelController.swift');
  for (const piece of ['willBeginSheetNotification', 'didEndSheetNotification', 'window.attachedSheet != nil', 'NSApp.modalWindow',
    'GlobalDMCoverRegistry.shared.$overlays', 'GlobalDMComposerFrames.shared.$frames', 'GlobalDMDockedPresence.resolve(',
    'GlobalDMDockedPresence.takesFocus(',
    'GlobalDMDockLayout.place(content: content, composer: composer, mode: store.model?.mode, boxOpen: store.isOpen,']) {
    assert.ok(controller.includes(piece), piece);
  }
  // W184 AB：停靠框的大小照目前形態（純函式照樣拿內容區、輸入框、模式、開關，多一個形態大小）。
  assert.match(controller, /boxOpen: store\.isOpen,\s*boxSize: desk\.form\.size\)/);
  assert.equal(count(controller, '&& !mainWindowCovered'), 2);
  // The tool-approval confirm is not a cover: the docked box keeps its 等你核准 row.
  assert.ok(controller.includes('approvalPending: !(store.model?.localLiveForBridge?.pendingPermissionThreadIDs.isEmpty ?? true)'));
  assert.ok(controller.includes('panel.worksWhenModal = true'));
  assert.doesNotMatch(controller, /ChatGPTSpaceModel/);
  // Reporters only clear what they reported: the menu-bar panel's ChatPage never wipes the main window's state.
  const layering = read('DM/GlobalDMLayering.swift');
  assert.match(layering, /var isCovered: Bool \{ !overlays\.isEmpty \|\| sheet \|\| \(appModal && !approvalPending\) \}/);
  assert.match(layering, /case \.chatgpt\?: return \.chatgpt/);
  assert.match(slice(layering, 'private struct GlobalDMCoverReporter', 'extension View'), /guard now != reported else \{ return \}/);
  assert.match(slice(layering, 'private struct GlobalDMComposerFrameReporter', 'extension View'), /guard rect != nil \|\| reported else \{ return \}/);
});

test('desk bubble sits one level above the floating box; the box opens beside it', () => {
  assert.ok(read('DM/GlobalDMDeskController.swift').includes('NSWindow.Level.floating.rawValue + 1'));
  const desk = read('DM/GlobalDMDesk.swift');
  assert.match(desk, /static let bubbleGap: CGFloat = 12/);
  assert.match(desk, /static func boxBeside\(bubble: CGRect, wanted: CGSize, visible: CGRect\)/);
});

test('memory card confirms inside the card with glass chips, never a system alert', () => {
  const settings = read('New/OSSettingsPage.swift');
  const memory = slice(settings, '@ViewBuilder private var memorySection', 'private var memoryConfirmMessage');
  assert.doesNotMatch(memory, /confirmationDialog|NSAlert|\.alert\(/);
  // The confirm row is neutral glass: question, explanation, 取消／確定 as plain glass chips (accent only for selection).
  const confirm = slice(memory, 'if let confirm = memoryConfirm', 'Text(memory.folderLine)');
  assert.ok(confirm.includes('.chatLiquidSection(cornerRadius: 12)'));
  assert.ok(confirm.includes('OSChipButton(title: "取消")'));
  assert.ok(confirm.includes('OSChipButton(title: confirm.restore ? "還原" : "接上")'));
  assert.doesNotMatch(confirm, /isPrimary|SetupBanner|brandAccent/);
});

test('w179ui self-test entry covers every group', () => {
  const selfTest = read('SelfTest.swift');
  assert.ok(selfTest.includes('TATWO2_SELFTEST"] == "w179ui"'));
  assert.ok(selfTest.includes('GlobalDMUIAcceptance.run()'));
  const acceptance = read('DM/GlobalDMUIAcceptance.swift');
  assert.ok(acceptance.startsWith('#if DEBUG'));
  assert.ok(acceptance.includes('W179UI SUMMARY failures='));
  for (const group of ['A', 'B', 'C', 'D', 'E', 'F', 'G']) {
    assert.match(acceptance, new RegExp(`"${group}\\d `), group);
  }
  assert.doesNotMatch(acceptance, /NSPanel\(|makeKeyAndOrderFront/);
});
