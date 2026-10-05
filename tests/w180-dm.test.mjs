import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// W180 R1（A3、A4、D2）：私訊框的對象圖示列、模型 chip、附件、子討論串與所有配對設備、「到 Island 查看」定位。
// 原始碼契約；實際行為在 `TATWO2_SELFTEST=w180dm`（DM/GlobalDMW180Acceptance.swift）。
const read = (name) => readFileSync(new URL('../App/Sources/Tatwo2/' + name, import.meta.url), 'utf8');
const code = (source) => source.replace(/\/\/[^\n]*/g, '');
const slice = (source, start, end) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = source.indexOf(end, from + start.length);
  assert.ok(to > from, `missing ${end} after ${start}`);
  return source.slice(from, to);
};

test('A3 icon strip scrolls horizontally (trackpad and mouse wheel) with fading ends', () => {
  const strip = read('DM/GlobalDMTargetStrip.swift');
  assert.match(strip, /struct GlobalDMHorizontalScroller<Content: View>: NSViewRepresentable/);
  assert.match(strip, /final class GlobalDMHorizontalScrollView: NSScrollView/);
  assert.match(strip, /hasHorizontalScroller = false/);
  assert.match(strip, /horizontalScrollElasticity = \.allowed/);
  assert.match(strip, /verticalScrollElasticity = \.none/);
  // A plain mouse wheel only has a vertical delta: it scrolls the row sideways.
  const wheel = slice(strip, 'override func scrollWheel(with event: NSEvent)', 'func updateFade()');
  assert.match(wheel, /abs\(event\.scrollingDeltaY\) > abs\(event\.scrollingDeltaX\)/);
  assert.match(wheel, /origin\.x = min\(max\(0, origin\.x - step\), room\)/);
  assert.match(wheel, /contentView\.scroll\(to: origin\)/);
  // Both ends fade while there is more to see.
  assert.match(strip, /private let fade = CAGradientLayer\(\)/);
  assert.match(strip, /layer\?\.mask = fade/);
  assert.match(strip, /fade\.colors = \[leading \? clear : solid, solid, solid, trailing \? clear : solid\]/);
  assert.match(strip, /override func reflectScrolledClipView\(_ clipView: NSClipView\) \{\s*super\.reflectScrolledClipView\(clipView\)\s*updateFade\(\)/);
  // W184 AB：框頂的圖示列改成頂列左上的圓鈕列（只露目前那顆、指到向右展開），不再左右捲；左右捲的一排留給附件小卡。
  const icons = slice(strip, 'struct GlobalDMIconStrip: View', 'struct GlobalDMIconButton');
  assert.match(icons, /HStack\(spacing: DMPhone\.Strip\.spacing\)/);
  assert.match(icons, /store\.activate\(item\)/);
  assert.match(icons, /\.onHover \{ inside in hover\.hovering\(inside\) \}/);
  assert.doesNotMatch(icons, /GlobalDMHorizontalScroller/);
  // First click works on a non-key panel (same as the W179 target chip): the inner host is the panel's hosting view.
  const make = slice(strip, 'func makeNSView(context: Context) -> GlobalDMHorizontalScrollView', 'func updateNSView(');
  assert.match(make, /let host = GlobalDMHostingView\(rootView: AnyView\(content\)\)\s*host\.sizingOptions = \[\.intrinsicContentSize\]/);
  assert.doesNotMatch(make, /NSHostingView\(rootView:/);
  const scrollView = slice(strip, 'final class GlobalDMHorizontalScrollView: NSScrollView', 'func updateFade()');
  assert.match(scrollView, /override func acceptsFirstMouse\(for event: NSEvent\?\) -> Bool \{ true \}/);
  assert.match(read('DM/GlobalDMPanelController.swift'), /final class GlobalDMHostingView: NSHostingView<AnyView> \{\s*override func acceptsFirstMouse\(for event: NSEvent\?\) -> Bool \{ true \}/);
  // The attachment chips scroll the same way (the SwiftUI horizontal ScrollView ignores the mouse wheel).
  const files = slice(strip, 'struct GlobalDMAttachmentRow: View', 'private func chip(');
  assert.match(files, /GlobalDMHorizontalScroller \{\s*HStack\(spacing: 6\)/);
  assert.doesNotMatch(code(strip), /ScrollView\(\.horizontal/);
});

test('A3 icons: same avatar on a glass circle, accent ring when selected, device mark, later icons grey', () => {
  const strip = read('DM/GlobalDMTargetStrip.swift');
  const button = slice(strip, 'struct GlobalDMIconButton: View', '// MARK: - 左右捲的一排');
  assert.match(button, /GlobalDMAvatar\(letter: item\.letter, color: GlobalDMPalette\.color\(for: item\.tint\)/);
  assert.match(button, /\.background\(GlobalDMGlassCircle\(isSelected: isCurrent\)\)/);
  // W184 AB：目前那顆 2pt 強調色外圈、其他 1pt 淡框（同一時間只有一顆亮）。
  assert.match(button, /Circle\(\)\.strokeBorder\(isCurrent \? LiquidGlassTokens\.brandAccent : Color\.primary\.opacity\(0\.14\),\s*lineWidth: isCurrent \? DMPhone\.Strip\.currentRing : DMPhone\.Strip\.otherRing\)/);
  // One accent ring at a time: C while the picker is open, ⌘ while the key page is open, otherwise the current target.
  const store = read('DM/GlobalDMStore.swift');
  const selected = slice(store, 'func isSelected(_ item: GlobalDMIconItem) -> Bool', 'func activate(_ item: GlobalDMIconItem)');
  assert.match(selected, /case \.coder: return isPickerOpen/);
  assert.match(selected, /case \.directKeys: return isEditingDirectKeys/);
  assert.match(selected, /default: return !isPickerOpen && !isEditingDirectKeys && isCurrentTarget\(item\)/);
  // W184 AB：頂列的圓鈕照「目前頁面」亮（單欄 Browser 開著＝地球；內橫的 Browser 在右欄＝左欄的對象）。
  assert.match(strip, /let current = store\.currentPageID\(besideBrowser: besideBrowser\)/);
  assert.match(strip, /GlobalDMIconButton\(item: item, isCurrent: isCurrent\)/);
  assert.match(button, /if item\.device != nil \{/);
  assert.match(button, /\.disabled\(!item\.isEnabled\)/);
  assert.doesNotMatch(code(strip), /\.blue\b|accentColor|borderedProminent|\.menuStyle\(|\.tint\(|NSAlert/);
});

test('A3 icon order: assistant, ChatGPT, Coder, recent sessions, later (Bot team, LINE), direct keys', () => {
  const store = read('DM/GlobalDMStore.swift');
  const items = slice(store, 'func iconItems(showingOthers: Bool = GlobalDMStore.showsOtherTargets) -> [GlobalDMIconItem]', 'private func keyed(');
  const order = ['kind: .assistant, letter: "T"', 'kind: .chatGPT, letter: "G"', 'kind: .coder, letter: "C"',
    'for session in iconSessions(all)', 'kind: .later, letter: "隊", title: "Bot 團隊（之後）"',
    'kind: .later, letter: "L", title: "LINE（之後）"', 'kind: .directKeys, letter: "⌘", title: "設定直達鍵…"'];
  let at = -1;
  for (const piece of order) {
    const next = items.indexOf(piece, at + 1);
    assert.ok(next > at, `order: ${piece}`);
    at = next;
  }
  assert.match(items, /tint: \.session, device: session\.deviceName/);
  assert.match(items, /: GlobalDMSessionCandidate\.abbreviation\(session\.projectName\)/);
  assert.match(items, /if hasDirectKeys \{/);
  assert.match(store, /static let iconSessionLimit = 3/);
  // The current session always has an icon, even when it is not among the most recent.
  const recent = slice(store, 'func iconSessions(_ all: [GlobalDMSessionCandidate])', 'func iconItems(');
  assert.match(recent, /if picked\.count >= Self\.iconSessionLimit \{ picked\.removeLast\(\) \}/);
  // Offline: the last seen project and device; never seen: '?' with the device it may be on (not Coder's C).
  assert.match(recent, /let current = all\.first \{ \$0\.id == id \} \?\? knownSessions\[id\]/);
  assert.match(recent, /deviceName: model\?\.dmSessionAwaitedDeviceName\(id\)/);
  assert.match(items, /letter: session\.projectName\.isEmpty \? "\?"/);
  // Clicking: assistant / ChatGPT / a session switch directly; Coder opens the session picker in the box.
  const activate = slice(store, 'func activate(_ item: GlobalDMIconItem)', 'func title(for target');
  assert.match(activate, /case \.session\(let id\): select\(\.thread\(id\)\)/);
  assert.match(activate, /case \.coder:\s*isEditingDirectKeys = false\s*isPickerOpen\.toggle\(\)/);
  assert.match(activate, /case \.later:\s*break/);
});

test('A3 header (W184 AB/F): only the current page circle top-left (⋯ and ⌄ gone; their menu is the circle\'s right-click menu); no name row; the session picker still opens in the body', () => {
  const phone = read('DM/GlobalDMPhoneBox.swift');
  const bar = slice(phone, 'struct GlobalDMTopBar: View', 'enum GlobalDMTopBarLayout');
  assert.match(bar, /GlobalDMIconStrip\(store: store, besideBrowser: form\.isDuo\)/);
  assert.match(bar, /\.frame\(height: DMPhone\.headerHeight\)/);
  // 名字行拿掉：目前對象由圓鈕的外圈表示；舊名字行的識別碼 tatwo.dm.target 包在目前那顆外面（唸得出「目前對象：名字」）。
  assert.match(phone, /\.accessibilityLabel\("目前對象：\\\(name\)"\)\s*\.accessibilityIdentifier\("tatwo\.dm\.target"\)/);
  assert.doesNotMatch(bar, /Text\(name\)|GlobalDMChordHint|GlobalDMTargetPicker\(|isBrowsing/);
  // The session picker opens inside the body region (below the header, above the composer), as in W179 UI.
  const view = read('DM/GlobalDMView.swift');
  const region = slice(view, 'struct GlobalDMBodyRegion', 'struct GlobalDMNoticeRow');
  assert.ok(region.includes('if store.isPickerOpen {'));
  assert.ok(region.includes('GlobalDMMenuLayout.pickerFrame(bodySize: geo.size)'));
  assert.ok(region.includes('GlobalDMTargetPicker(store: store, maxHeight: frame.height)'));
  const picker = slice(view, 'struct GlobalDMTargetPicker', 'struct GlobalDMBadge');
  for (const piece of ['store.sessionRows()', "store.sessionRows(query: store.sessionQuery, everything: true)", '其他專案的對話…',
    'Button { store.select(target) }']) {
    assert.ok(picker.includes(piece), piece);
  }
  assert.doesNotMatch(picker, /外部 App（經 TAP）|heading\("釘選"\)/, 'pinned/external rows moved to the icon strip');
});

test('A4 model chip sits in the composer toolbar, next to send (W181: the DM\'s own capsule chip)', () => {
  // W184 H4 修正（查核 #15）：私訊框的模型改由「模式選擇」chip（GlobalDMModeChip → TatwoComposerMode.dm）與模式卡的模型列畫，
  // 原本的 GlobalDMModelChip 已經沒人用（只剩定義）。守的東西不變，改守真的在畫的那一條：
  const mode = read('Chat/TatwoComposerMode.swift');
  const modeCard = read('Chat/TatwoComposerModeCard.swift');
  const dmMode = slice(mode, 'static func dm(store: GlobalDMStore)', 'static func dmLocalThread(');
  // W181（「這邊輸入筐比例很醜」）：私訊框用自己的膠囊 chip，寬度跟著模型名；TATWO 助理那顆照舊。
  // W184 F 小修正：模型名不截（.fixedSize()、排版優先；寬度不夠時旁邊的記憶膠囊先縮）→ 模式選擇 chip：一整排 .fixedSize()、
  // 私訊框那顆排版優先；窄的時候換成簡稱那一排，模型那一段的簡稱就是整個模型名。
  assert.match(read('Chat/ChatComposerChrome.swift'), /\.fixedSize\(\)\s*\.modifier\(ChatComposerModeChipSurface\(style: style, selected: selected\)\)/);
  assert.match(slice(modeCard, 'struct GlobalDMModeChip', 'struct GlobalDMModeCard'), /\.layoutPriority\(1\)/);
  assert.match(mode, /return Segment\(id: "model", text: text, short: title,/);
  assert.match(read('Assistant/AssistantModelMenu.swift'), /ChatComposerModelLabel\(title: title, suffix: nil, compact: false, selected: false\)/);
  // chip 的位置（原本是選單的定位點；現在是卡的「點 chip 不算點外面」）：chip 自己墊著。
  assert.ok(read('Chat/ChatComposerChrome.swift').includes('.background(TatwoComposerModeChipAnchor())'));
  // 選單內容：同助理的模型選單（store.modelOptions：品牌分段、停用的標「已停用」不能選）。
  assert.ok(dmMode.includes('let options = assistantOptions(store.modelOptions(for: target))'));
  // 回覆中、那台離線不能換：模型列停用（卡上點了不開清單）、chip 那一段變淡；滑過與卡上寫為什麼（store.modelChipHelp）。
  assert.match(dmMode, /isEnabled: canChoose,\s*options: options/);
  assert.ok(dmMode.includes('dimmed: !canChoose'));
  assert.ok(modeCard.includes('let canPick = row.isEnabled && !row.options.isEmpty') && modeCard.includes('guard canPick else { return }'));
  assert.ok(dmMode.includes('mode.modelNote = canChoose ? store.modelHeadline(for: target) : store.modelChipHelp'));
  assert.ok(dmMode.includes('mode.help = store.modelChipHelp'));
  // A session on an offline device: chip off, and it says why.
  const store = read('DM/GlobalDMStore.swift');
  const can = slice(store, 'var canChooseModel: Bool {', 'func modelOptions(for target: GlobalDMTarget)');
  assert.match(can, /case \.thread\(let id\): return model\.dmSessionModelSelectable\(id\)/);
  assert.ok(can.includes('"那台連上後才能換模型"'));
  const chatModel = read('Facade/ChatPageModel.swift');
  assert.match(chatModel, /func dmSessionModelSelectable\(_ threadID: UUID\) -> Bool \{\s*localLive\?\.threadRecord\(threadID\) != nil \|\| dmRemote\(for: threadID\) != nil/);
  assert.doesNotMatch(chatModel, /"那台預設"/);
  const view = read('DM/GlobalDMView.swift');
  const composer = slice(view, 'struct GlobalDMComposer: View', 'struct GlobalDMKey');
  // W180 E1：記憶 chip 放在模型 chip 旁（對象是 ChatGPT 時它自己不畫）。
  // 守：一排的順序＝＋附件…（彈性空白）…記憶、模型、送出／停止。W184 C：這一排是私訊框自己的 HStack（36 高；＋ 往左凸 6），
  // 送出／停止是私訊框自己的 36pt 圓鈕（Coder 的 ChatComposerToolbarRow／送出／停止不改）。
  // W184 H4：記憶、模型收進同一個位置的一顆「模式選擇」chip（GlobalDMModeChip：模型那段識別碼 tatwo.dm.model、記憶那段 tatwo-memory-strength），
  // 所以守的順序變成：＋附件…（彈性空白）…模式選擇（記憶、模型）、送出／停止；模型、記憶各自的路徑見下面與 tests/w184-mode.test.mjs。
  assert.match(composer, /HStack\(spacing: GlobalDMChatLayout\.composerItemSpacing\) \{\s*GlobalDMAttachButton\(store: store\)\s*\.padding\(\.leading, GlobalDMChatLayout\.plusOutset\)\s*Spacer\(minLength: 4\)\s*(?:\/\/[^\n]*\n\s*)*GlobalDMModeChip\(store: store, isOpen: \$modeOpen, anchor: modeAnchor\)\s*if isRunning \{\s*GlobalDMStopButton \{ store\.stop\(\) \}/);
  // 守：模式選擇的模型那段走的還是同一條路（store 的模型選單內容、store.chooseModel、不能選時 store.canChooseModel／modelChipHelp）。
  for (const piece of ['store.modelOptions(for: target)', 'store?.chooseModel(id, for: target)', 'store.canChooseModel',
    'store.modelChipHelp', 'store.modelHeadline(for: target)', 'identifier: "tatwo.dm.model"']) {
    assert.ok(dmMode.includes(piece), `DM mode: ${piece}`);
  }
  // W184 H4 修正（查核 #17）：停用的引擎在卡上照樣變淡、不能選（assistantOptions 帶著 isDisabled、清單那一列 .disabled、點了不選）。
  assert.ok(mode.includes('isSelected: option.isSelected, isDisabled: option.isDisabled)'));
  assert.ok(modeCard.includes('.disabled(option.isDisabled)') && modeCard.includes('guard !option.isDisabled else { return }'));
  assert.match(composer, /onPasteImage: \{ store\.pasteAttachment\(from: \$0\) \}/);
  // W181：「⌥⌘ 開關」那行從輸入框下面搬走；W184 AB：名字行也拿掉，⌥⌘ 說明進選單（W184 F：頁面圓鈕的右鍵選單），ChatGPT 的註腳由房 C 放到輸入框上方。
  assert.doesNotMatch(composer, /GlobalDMChordHint\(/);
  assert.doesNotMatch(view, /GlobalDMChordHint/);
  const menu = read('Assistant/AssistantModelMenu.swift');
  assert.match(menu, /static func makeMenu\(headline: String\?, options: \[AssistantModelOption\],/);
  assert.match(menu, /static func popUp\(_ menu: NSMenu, above view: NSView\)/);
});

test('A4 each target has its own model path and a pick changes only that target', () => {
  const store = read('DM/GlobalDMStore.swift');
  const choose = slice(store, 'func chooseModel(_ modelID: String, for target: GlobalDMTarget)', 'func chooseChatGPT(');
  assert.match(choose, /case \.assistant: model\?\.setAssistantModel\(modelID\)/);
  assert.match(choose, /case \.thread\(let id\): model\?\.setDMSessionModel\(id, modelID: modelID\)/);
  assert.match(store, /case \.assistant: return model\?\.assistantModelOptions \?\? \[\]/);
  const model = read('Facade/ChatPageModel.swift');
  const set = slice(model, 'func setDMSessionModel(_ threadID: UUID, modelID: String)', '// MARK: - W180 D2 私訊框的附件');
  // Local session: that session's own preferences (same as Coder); disabled engines refused; no Coder state.
  assert.match(set, /guard !engine\.isRunning\(threadID\), !isEngineDisabled\(kind\),/);
  assert.match(set, /engine\.setModelPreferences\(threadID: threadID, model: route\.id,/);
  // Session on another device: held in memory, carried with the next turn (F room primaryTurn).
  assert.match(set, /dmRemoteModelChoices\[threadID\] = route\.id/);
  // The session Coder has open: Coder's chip re-reads that session's own preference (no other Coder state touched).
  assert.match(set, /if selectedRemote == nil, selectedThreadID == threadID \{ restoreModelPreferences\(\) \}/);
  assert.doesNotMatch(set, /selectedModel|selectedThreadID =(?!=)|selectedRemote =(?!=)|\bprompt\b|persistModelPreferences/);
  const options = slice(model, 'func dmSessionModelOptions(_ threadID: UUID)', 'func dmSessionModelHeadline(');
  assert.match(options, /isDisabled: \{ self\.isEngineDisabled\(\$0\) \}/);
  assert.match(options, /isDisabled: \{ _ in false \}/);
  const remote = slice(model, 'private func sendFromDMToRemote(', '\n    }\n');
  assert.match(remote, /AssistantModelRouting\.primaryTurn\(choice: choice\)/);
  // ChatGPT: the DM's own choice, from the same model list ChatGPT Space shows; ChatGPT Space's own pick untouched.
  const send = slice(store, 'func send() -> Bool', '// MARK: - 模型 chip');
  assert.match(send, /let arguments = ChatGPTModelMenu\.sendArguments\(chatGPTCatalog, chatGPTChoice\)/);
  assert.match(send, /session\.send\(text, model: arguments\.model, effort: arguments\.effort,/);
  const session = read('TAP/ChatGPTConversationSession.swift');
  // 守：私訊框選的模型、強度與附件都交給 TAP。W184 G3：「＋」選的工具也照 ChatGPT Space 的帶法交給 TAP（tool＝網頁的 hint）。
  assert.match(session, /func send\(_ text: String, model: String\? = nil, effort: String\? = nil, attachments: \[TapAttachment\] = \[\], tool: String\? = nil\)/);
  // W184 G3b 第二輪（審查 #4）：接著舊對話送時多帶私訊框看到的那一支末端（parentID）；W184 G3c：臨時聊天時多帶臨時旗標（temporary）。
  // .048：個人化須同時受臨時模式與明確選擇約束；其餘參數仍逐一精確驗證，不接受任意參數。
  const tapSend = /tap\.send\(requestID: id, text: text, conversationID: conversationID, model: model, effort: effort,\s*attachments: attachments, tool: tool, gizmoID: conversationID == nil \? projectID : nil, temporary: isTemporary, parentID: parent,\s*temporaryPersonalized: isTemporary && temporaryPersonalized\)/;
  assert.match(session, tapSend);
  const actualCall = session.match(tapSend)[0];
  for (const [before, after] of [
    ['isTemporary && temporaryPersonalized', 'temporaryPersonalized'],
    ['isTemporary && temporaryPersonalized', 'isTemporary || temporaryPersonalized'],
    ['isTemporary && temporaryPersonalized', 'true'],
    [/,\s*temporaryPersonalized: isTemporary && temporaryPersonalized/, ''],
    [', temporary: isTemporary', ''],
    [', parentID: parent', ''],
  ]) {
    const mutated = actualCall.replace(before, after);
    assert.notEqual(mutated, actualCall, `mutation must change the call: ${before}`);
    assert.doesNotMatch(mutated, tapSend, `reject missing or weakened send arguments: ${before}`);
  }
  assert.match(send, /\}, tool: tool\?\.id\)/);
  const space = read('TAP/ChatGPTSpace.swift');
  assert.match(space, /var modelCatalogPublisher: AnyPublisher<ChatGPTModelCatalog, Never>/);
  // 守：私訊框的清單跟 ChatGPT Space 同一份（W184 G3：多帶「＋」的工具，同一個 publisher）。
  assert.match(space, /Publishers\.CombineLatest4\(\$models, \$defaultModelID, \$defaultEffortID, \$tools\)/);
  assert.match(space, /enum ChatGPTModelMenu \{/);
  assert.match(store, /ChatGPTSpaceModel\.shared\.modelCatalogPublisher/);
  for (const file of ['DM/GlobalDMStore.swift', 'DM/GlobalDMView.swift', 'DM/GlobalDMTargetStrip.swift', 'DM/GlobalDMChatGPTComposer.swift']) {
    assert.doesNotMatch(read(file), /selectedModelID|selectedEffortID/, `${file} never writes ChatGPT Space's selection`);
  }
  // Nothing about the model pick is persisted by the DM.
  assert.equal((store.match(/defaults\.set\(/g) ?? []).length, 2);
});

test('D2 attachments: local assistant, local sessions and ChatGPT take files; sessions on other devices say why and stay off', () => {
  const store = read('DM/GlobalDMStore.swift');
  const block = slice(store, 'func attachmentBlock(for target: GlobalDMTarget) -> String?', 'func addAttachments(');
  assert.match(block, /if model\.assistantAcceptsAttachments \{ return nil \}/);
  assert.match(block, /return model\.dmSessionAttachmentNote\(id\)/);
  const model = read('Facade/ChatPageModel.swift');
  assert.ok(model.includes('"主設備上的對話暫不支援附件"'));
  const note = slice(model, 'func dmSessionAttachmentNote(_ threadID: UUID) -> String?', 'func dmSaveAttachment(');
  assert.match(note, /if localLive\?\.threadRecord\(threadID\) != nil \{ return nil \}/);
  const strip = read('DM/GlobalDMTargetStrip.swift');
  const plus = slice(strip, 'struct GlobalDMAttachButton: View', 'struct GlobalDMAttachmentRow');
  assert.match(plus, /let block = store\.attachmentBlock\(for: store\.target\)/);
  // Not .disabled (a disabled button often shows no tooltip): faded, and a click puts the reason in the box.
  assert.match(plus, /Button \{ if let block \{ store\.showNotice\(block\) \} else \{ popUp\(\) \} \}/);
  assert.match(plus, /\.opacity\(block == nil \? 1 : 0\.45\)/);
  assert.doesNotMatch(code(plus), /\.disabled\(/);
  assert.match(plus, /\.help\(block \?\? "附加檔案或貼上剪貼簿圖片"\)/);
  assert.match(plus, /"附加檔案…"\) \{ \[store\] in store\.pickAttachments\(\) \}/);
  assert.match(plus, /"貼上剪貼簿圖片"\)/);
  // Never pretend: a send with files to a target that cannot take them is refused with the note.
  const send = slice(store, 'func send() -> Bool', '// MARK: - 模型 chip');
  assert.match(send, /if !files\.isEmpty, let block = attachmentBlock\(for: target\) \{\s*notice = block\s*return false\s*\}/);
  const dm = slice(model, 'func sendFromDM(threadID: UUID, text: String, attachments: [String] = [],', 'var localLiveForBridge');
  assert.match(dm, /guard attachments\.isEmpty else \{ return false \}\s*return sendFromDMToRemote/);
  assert.match(model, /if !attachments\.isEmpty, !assistantAcceptsAttachments \{ return false \}/);
  // Local files go to the engine as paths (pasted images saved like the Coder composer); ChatGPT files stay in memory.
  assert.match(model, /return try\? localLive\.savePastedAttachment\(data: data, suggestedName: suggestedName\)/);
  assert.match(store, /guard let url = model\?\.dmSaveAttachment\(data: png, suggestedName: name\)/);
  assert.match(store, /file\.data\.map \{ TapAttachment\(name: file\.name, mime: file\.mime, data: \$0\) \}/);
  // 守：ChatGPT 的檔案讀進記憶體、照 ChatGPT Space 的規矩收（看不懂的圖片轉 JPEG、合計 20 MB）。W184 G3：私訊框直接用 Space 那一套
  // （attachFiles／attach(from:)／admit，Space 自己也用它們）；規矩本身在 Space 裡。
  assert.match(store, /ChatGPTSpaceModel\.attachFiles\(urls, into: chatGPTSink\)/);
  assert.match(store, /switch ChatGPTSpaceModel\.admit\(data, name: name, mime: mime, currentBytes:/);
  assert.match(read('TAP/ChatGPTSpace.swift'), /static func admit\([^)]*\)[^{]*\{\s*let file = webCompatible\(data, name: name, mime: mime\)[\s\S]{0,120}guard total <= attachmentLimit/);
  // ⌘V on a target that cannot take files still pastes the clipboard's text; only drags and file/image-only clipboards are eaten.
  const paste = slice(store, 'func pasteAttachment(from pasteboard: NSPasteboard) -> Bool', 'func showNotice(');
  assert.match(paste, /pasteAttachment\(from: pasteboard, preferText: true\)/);
  assert.match(paste, /if ComposerPastePolicy\.prefersText\(from: pasteboard, fileURLs: urls, preferText: preferText\) \{ return false \}/);
  assert.match(read('Chat/ComposerPastePolicy.swift'), /guard preferText, pasteboard\.name != \.drag, fileURLs\.isEmpty,\s*let text = pasteboard\.string\(forType: \.string\) else \{ return false \}\s*return !text\.trimmingCharacters\(in: \.whitespacesAndNewlines\)\.isEmpty/);
  assert.match(paste, /if preferText, let block = attachmentBlock\(for: target\), pasteboard\.name != \.drag,\s*pasteboard\.string\(forType: \.string\) != nil \{\s*if !urls\.isEmpty \{ notice = block \+ "；只貼上文字" \}\s*return false\s*\}/);
  // Same short words for attachments in every bubble (ChatGPT's file names too).
  const text = read('DM/GlobalDMMessageText.swift');
  assert.match(text, /static func displayText\(_ raw: String, files: \[String\]\) -> String/);
  assert.match(read('DM/GlobalDMView.swift'), /text: GlobalDMMessageText\.displayText\(message\.text, files: message\.files\)/);
  assert.doesNotMatch(read('DM/GlobalDMView.swift'), /\[附件\]/);
  for (const file of ['DM/GlobalDMStore.swift', 'DM/GlobalDMView.swift', 'DM/GlobalDMTargetStrip.swift']) {
    assert.doesNotMatch(read(file), /FileManager|\.write\(to:|createFile|JSONEncoder|NSLog|print\(/, file);
  }
});

test('D2 sub-threads are targets under their parent; every paired device lists its sessions; offline devices say so', () => {
  const model = read('Facade/ChatPageModel.swift');
  const devices = slice(model, 'var dmRemoteDevices: [GlobalDMRemoteDevice] {', 'func dmRemote(for threadID: UUID)');
  assert.match(devices, /for session in remoteSessions where !listed\.contains\(session\.device\.id\)/);
  assert.match(devices, /isPrimary: false/);
  assert.match(model, /func dmRemote\(for threadID: UUID\) -> GlobalDMRemoteDevice\? \{\s*guard localLive\?\.threadRecord\(threadID\) == nil else \{ return nil \}\s*return dmRemoteDevices\.first \{ \$0\.engine\?\.threadRecord\(threadID\) != nil \}/);
  // W201：未選取的設備不報備離線；既有 session 選取、草稿與不能送出的驗收保持。
  const store = read('DM/GlobalDMStore.swift');
  assert.match(store, /var place: String \{ isPrimary \? "主設備「\\\(device\.displayName\)」" : "「\\\(device\.displayName\)」" \}/);
  const tree = slice(store, 'enum GlobalDMSessionTree', '/// W180 A3：框頂圖示列的一顆');
  assert.match(tree, /if let parent = root\.parentID, rootIDs\.contains\(parent\) \{ continue \}/);
  assert.match(tree, /for child in children\[session\.id\] \?\? \[\] \{ add\(child, depth: depth \+ 1\) \}/);
  // Other-device delivery failures do not call that device the primary.
  assert.match(model, /note\.replacingOccurrences\(of: "主設備「", with: "「"\)/);
});

test('D2 到 Island 查看 opens the Island at this target\'s request by id, never another one', () => {
  const notice = read('New/IslandNotice.swift');
  assert.match(notice, /var pendingRequestIDs: \[UUID\]/);
  assert.match(notice, /var threadID: UUID\? = nil/);
  assert.match(notice, /func pendingRequestIDs\(threadID: UUID\) -> \[UUID\]/);
  assert.match(notice, /\$0\.request\.threadID == threadID/);
  assert.match(notice, /requestID: UUID = UUID\(\), fullTextRequired: Bool = false, threadID: UUID\? = nil\) async -> Decision/);
  const reveal = slice(notice, 'func reveal(id: UUID) -> Bool', 'var hostAvailable = false');
  assert.match(reveal, /if let entry = active, entry\.request\.id == id/);
  assert.match(reveal, /holdOpen\(true\)/);
  assert.match(reveal, /queue\.insert\(entry, at: 0\)/);
  const store = read('DM/GlobalDMStore.swift');
  const open = slice(store, 'func revealApprovalInIsland(in island: IslandNotice? = nil) -> UUID?', 'private func bringModalForward()');
  assert.match(open, /island\.pendingRequestIDs\(threadID: threadID\)\.first \{ island\.reveal\(id: \$0\) \}/);
  assert.doesNotMatch(open, /island\.pendingRequestIDs\.first/);
  assert.match(open, /if revealed == nil \{ IslandExceptionsNavigation\.openWork\(\) \}/);
  assert.match(read('DM/GlobalDMView.swift'), /actionTitle: "到 Island 核准",\s*identifier: "tatwo\.dm\.approval"\) \{ store\.revealApprovalInIsland\(\) \}/);
});

test('W183 R8b: the third round icon Browser swaps the box content for a phone browser; box size and look unchanged', () => {
  const view = read('DM/GlobalDMView.swift');
  const desk = read('DM/GlobalDMDeskViews.swift');
  const store = read('DM/GlobalDMStore.swift');
  const panels = read('DM/GlobalDMPanelController.swift');
  const strip = read('DM/GlobalDMTargetStrip.swift');
  const pane = read('DM/DMBrowserView.swift');
  const overlay = read('DM/GlobalDMWebSheet.swift');
  // 第三顆圓鈕：TATWO、ChatGPT、Browser（地球）；對象（target）不變，只在記憶體（不多寫 UserDefaults）。
  assert.match(store, /case browser\n/);
  const items = slice(store, 'func iconItems(showingOthers: Bool = GlobalDMStore.showsOtherTargets) -> [GlobalDMIconItem]', 'private func keyed(');
  assert.ok(items.indexOf('kind: .chatGPT, letter: "G"') < items.indexOf('kind: .browser, letter: "B", title: "Browser"'));
  assert.ok(items.indexOf('kind: .browser, letter: "B", title: "Browser"') < items.indexOf('guard showingOthers else { return items }'));
  assert.match(store, /@Published var isBrowsing = false/);
  assert.match(store, /case \.browser:\s*showBrowser\(\)/);
  assert.match(store, /if isBrowsing \{ return item\.kind == \.browser \}/);
  assert.match(store, /func select\(_ newTarget: GlobalDMTarget\) \{\s*isPickerOpen = false\s*isEditingDirectKeys = false\s*isBrowsing = false/);
  assert.match(store, /guard !isBrowsing else \{ return false \}/);
  assert.match(strip, /item\.kind == \.browser \? \.browser : nil/);
  assert.match(view, /Image\(systemName: "globe"\)/);
  // Browser 開著：單欄（停靠框、浮動框的外直、內直）換成 DMBrowserPane；W184 AB：內橫的 Browser 在右欄、左欄照常是對話。
  // W184 F／G1（GPT-6 審查 #5）：框裡的 Browser 用哪一份從根畫面的環境值拿（正式＝nil＝.shared；自測接假的）。
  assert.match(view, /if store\.isBrowsing, role\.showsBrowser \{\s*(?:\/\/[^\n]*\n\s*)?DMBrowserPane\(store: store, browser: browserServices\.browser, flow: browserServices\.flow, connect: browserServices\.connect\)/);
  assert.match(desk, /var showsBrowser: Bool \{ self == \.single \}/);
  // 頂列在對話與 Browser 同一條（不再有 Browser 開著就藏起來的名字行），高度不跳。
  assert.doesNotMatch(slice(read('DM/GlobalDMPhoneBox.swift'), 'struct GlobalDMTopBar: View', 'enum GlobalDMTopBarLayout'), /isBrowsing/);
  // Browser 一次只有一份：內橫只在右欄（左欄那個 store 的；W184 AB：內橫開 Browser＝isBrowsingBeside，左欄的 isBrowsing 不動），第二個 store 不開 Browser。
  // W184 G2c 第二輪（GPT-6 #1）：右欄是不是 Browser 抽成 GlobalDMDuoLayout.rightColumnShowsBrowser（畫面與 ⌘⌥T 共用同一條）；判斷不變：
  // Browser 圓鈕開過（isBrowsingBeside／isBrowsing）或還有分頁，或拿不到第二個 store。
  assert.match(desk, /GlobalDMDuoLayout\.rightColumnShowsBrowser\(browsing: primary\.isBrowsing, browsingBeside: primary\.isBrowsingBeside,\s*hasTabs: browser\.hasTabs, hasSecondary: secondary != nil\) \{\s*DMBrowserPane\(store: primary, browser: services\.browser, flow: services\.flow, connect: services\.connect\)/);
  assert.match(read('DM/GlobalDMDesk.swift'), /static func rightColumnShowsBrowser\(browsing: Bool, browsingBeside: Bool, hasTabs: Bool, hasSecondary: Bool\) -> Bool \{\s*rightShowsBrowser\(browsing: browsingBeside \|\| browsing, hasTabs: hasTabs\) \|\| !hasSecondary\s*\}/);
  assert.match(read('DM/GlobalDMDesk.swift'), /static func rightShowsBrowser\(browsing: Bool, hasTabs: Bool\) -> Bool \{ browsing \|\| hasTabs \}/);
  assert.match(store, /guard !browsesBeside else \{ isBrowsingBeside = true; return \}/);
  assert.match(read('DM/GlobalDMDesk.swift'), /if second\.isBrowsing \{ second\.isBrowsing = false \}/);
  // R6b 的確認卡照舊蓋在框上：整支手機一層（內橫也只有一層、蓋兩欄）。
  assert.match(read('DM/GlobalDMPhoneBox.swift'), /\.modifier\(GlobalDMWebSheetOverlay\(store: store\)\)[^\n]*\n\s*\.modifier\(GlobalDMBoxChrome\(cornerRadius: look\.radius\)\)/);
  assert.doesNotMatch(overlay, /GlobalDMWebSheetController|GlobalDMWebSheetCard|handoffGrace/);
  // 框的尺寸、圓角不改（W181）。
  assert.match(view, /static let box = CGSize\(width: 466, height: 678\)/);
  assert.match(view, /static let cornerRadius: CGFloat = 52/);
  // Browser 開著時 Esc 給網頁。
  assert.match(panels, /if store\.isBrowsing \{ return event \}/);
  // 對照稿：網址 pill（鎖頭＋網域）＋「這台：<名稱>」；中間頁面；底部上一頁、下一頁、分頁（分頁總覽）。
  // W184 D：這幾樣收進平常藏起、滑鼠到底部才浮出的操作列；分頁總覽的卡片上寫綠勾「完成」（原本的分頁 chip 換成卡片格）。
  // W184 G2d（使用者 09-30：「你就只是把現成的browser space做成duo自適應尺寸而已」）：上一頁、下一頁、網址＝主視窗 Browser space 那一排頂列
  // （DMBrowserChrome 的 DMBrowserToolbar：滑鼠到上緣才浮出）；「這台：<名稱>」與「所有分頁」（分頁總覽）在它的 ⋯ 裡；網址的鎖頭、警告規則照舊。
  const chrome = read('DM/DMBrowserChrome.swift');
  assert.match(chrome, /EmbeddedBrowserToolbar\(addressText: \$address, addressFieldFocused: focused,/);
  assert.match(chrome, /Button\("這個 Browser 在這台：\\\(DMBrowser\.deviceName\)"\) \{\}\.disabled\(true\)/);
  assert.match(chrome, /Button\("所有分頁（\\\(browser\.tabs\.count\)）…", action: showTabs\)/);
  assert.match(pane, /if !browser\.tabs\.isEmpty \{ browser\.isShowingTabList = true \}/);
  assert.match(pane, /Label\("完成", systemImage: "checkmark\.circle\.fill"\)/);
  assert.match(pane, /Image\(systemName: Self\.symbol\(tab, warn: warn\)\)/);
  assert.match(pane, /return warn \? "exclamationmark\.triangle\.fill" : "lock\.fill"/);
  assert.match(pane, /Text\("不是 \\\(expected\)"\)/);
  // 原生網頁：照頁面區的圓角裁；點進網頁讓框拿鍵盤，不把整個 App 叫到前景。
  assert.match(pane, /if bounds\.contains\(convert\(event\.locationInWindow, from: nil\)\) \{ window\.makeKey\(\) \}/);
  assert.doesNotMatch(pane, /NSApp\.activate|activate\(ignoringOtherApps|TextField|NSWindow\(|WKWebView/);
  // 玻璃 chip、不用藍色；不寫檔、不記日誌（網址只在記憶體）。
  assert.doesNotMatch(pane, /\.blue\b|accentColor|borderedProminent|\.bordered\b/);
  assert.doesNotMatch(pane + read('DM/DMBrowser.swift'), /FileManager|\.write\(to:|createFile|JSONEncoder|NSLog|print\(|UserDefaults/);
});
