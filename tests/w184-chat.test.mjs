import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// W184 C（使用者 09-29：「私訊鈕的ui完全垃圾 應該要參照手機app的規格去設計」；對照稿 Main、Outer-ChatGPT、Open-Portrait-Chat）：
// 私訊框的訊息列、提示列、輸入列照手機 App。原始碼契約；版面數值與真的畫出來的位置、識別碼、畫面證據在 `TATWO2_SELFTEST=w184chat`。
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

const view = read('DM/GlobalDMView.swift');
const phone = read('DM/GlobalDMChatPhone.swift');
const strip = read('DM/GlobalDMTargetStrip.swift');
const text = read('DM/GlobalDMMessageText.swift');
const list = slice(view, 'struct GlobalDMMessageList', 'struct GlobalDMComposer');
// W184 AB 拿掉了 GlobalDMChordHint（⌥⌘ 說明搬進「⋯ 更多」）：輸入列這一段到 GlobalDMKey 為止。
const composer = slice(view, 'struct GlobalDMComposer: View', 'struct GlobalDMKey');
const notice = slice(view, 'struct GlobalDMNoticeRow', 'struct GlobalDMMessageList');
const chipLabel = slice(view, 'struct GlobalDMChipLabel', 'struct GlobalDMIconLabel');
const attach = slice(strip, 'struct GlobalDMAttachButton: View', 'private func popUp()');
const attachments = slice(strip, 'struct GlobalDMAttachmentRow: View', '\n}\n');

test('C tokens: every number comes from DMPhone (fonts 17/15/13/11, 36 circles, 32 chips, concentric 52 − 12)', () => {
  for (const line of ['static let messageSize = DMPhone.TextSize.body', 'static let noticeSize = DMPhone.TextSize.secondary',
    'static let footnoteSize = DMPhone.TextSize.footnote', 'static let captionSize = DMPhone.TextSize.caption',
    'static let glyphSize = DMPhone.TextSize.body', 'static let stopGlyphSize = DMPhone.TextSize.footnote',
    'static var composerInset: CGFloat { DMPhone.edgeInset }', 'static var composerRadius: CGFloat { DMPhone.barRadius }',
    'static var controlSize: CGFloat { DMPhone.smallControl }', 'static var chipHeight: CGFloat { DMPhone.chipHeight }']) {
    assert.ok(phone.includes(line), line);
  }
  const metrics = read('DM/DMPhoneMetrics.swift');
  assert.match(metrics, /static let body: CGFloat = 17\s*static let secondary: CGFloat = 15\s*static let footnote: CGFloat = 13\s*static let caption: CGFloat = 11/);
  assert.match(metrics, /static var barRadius: CGFloat \{ concentric\(screenRadius, inset: edgeInset\) \}/);
  // 字級只用 token：這一區（訊息列、提示列、輸入列、chip、附件小卡、送出／停止、說明行）不寫死任何字級數字。
  for (const [name, source] of [['GlobalDMChatPhone.swift', phone], ['message list', list], ['composer', composer],
    ['notice row', notice], ['chip label', chipLabel], ['＋ button', attach], ['attachment chips', attachments],
    ['GlobalDMMessageText.swift', text]]) {
    assert.doesNotMatch(code(source), /\.system\(size: \d/, `${name}: font sizes come from the tokens`);
  }
  // DMPhone 沒有的值在私訊框自己的檔用 token 組出來（提示列 32＋8×2＝48、圓角 16＋8＝24 跟 chip 同心）。
  assert.match(phone, /static var noticeMinHeight: CGFloat \{ chipHeight \+ noticeInset \* 2 \}/);
  assert.match(phone, /static var noticeRadius: CGFloat \{ chipHeight \/ 2 \+ noticeInset \}/);
  assert.match(phone, /static let noteTypography = ChatNoteTypography\(text: footnoteSize, label: captionSize, mark: captionSize\)/);
});

test('C1 message list: my bubble right and at most 78%, replies full width with no avatar, bottom-aligned, 18 apart', () => {
  assert.match(phone, /static let userBubbleMaxFraction: CGFloat = 0\.78/);
  assert.match(list, /case \.mine:\s*HStack\(spacing: 0\) \{\s*Spacer\(minLength: rowWidth - GlobalDMChatLayout\.userBubbleMaxWidth\(rowWidth: rowWidth\)\)\s*GlobalDMUserBubble\(text: bubble\.text\)\s*\}\s*\.frame\(width: rowWidth, alignment: \.trailing\)/);
  assert.match(list, /case \.theirs:[^\n]*\n(\s*\/\/[^\n]*\n)*\s*GlobalDMRichText\(text: bubble\.text\)\s*\.frame\(width: rowWidth, alignment: \.leading\)/);
  // 對照稿：回覆不帶頭像（對象由頂列圓鈕表示）；打字列只有點點。
  assert.doesNotMatch(list, /ChatModelAvatar\(|GlobalDMAvatar\(|ChatTypingIndicatorRow\(/);
  assert.match(phone, /static let showsReplyAvatar = false/);
  // 內距 上 10、左右 16（內橫兩欄 20）、下 16（放在尾巴裡，捲到底也留著）；貼底排。
  // W184 F2：換形態途中左右留白連續變（環境值；停著＝nil，照角色）。
  assert.match(list, /let side = sideMargin \?\? GlobalDMChatLayout\.sideMargin\(for: role\)/);
  assert.match(phone, /role == \.single \? DMPhone\.margin : DMPhone\.wideMargin/);
  // W184 G3c（使用者：「文字頂部漸淡應頂天 不是空一節」）：上面的內距＝listTop＋往上延伸的那一段（手機框給頂列的高度），
  // 捲到最上面時第一則在頂列下面、捲動時可以捲進頂列底下；守的東西不變：上 10、貼底排。
  assert.match(list, /let headerAvoidanceInset = max\(0, bleed\)/);
  assert.match(list, /\.padding\(\.top, topInset\)/);
  assert.match(list, /Color\.clear\.frame\(height: GlobalDMChatLayout\.listBottom\)\.id\("tatwo\.dm\.tail"\)/);
  assert.match(list, /\.frame\(minHeight: viewportHeight, alignment: \.bottom\)/);
  assert.match(list, /\.defaultScrollAnchor\(\.bottom\)/);
  // 間距 18；「用了 N 條記憶」緊貼它的回覆（6）。
  assert.match(list, /let gaps = GlobalDMChatLayout\.gaps\(bubbles\)/);
  assert.match(list, /\.padding\(\.top, gaps\[index\]\)/);
  assert.match(phone, /static let messageSpacing: CGFloat = 18/);
  assert.match(phone, /previous\.kind == \.theirs && bubble\.isMemoryUsage \? metaSpacing : messageSpacing/);
  // 捲到最新一則的行為照舊。
  assert.match(list, /\.onChange\(of: bubbles\.count\) \{ _, _ in scrollToTail\(proxy\) \}/);
  assert.match(list, /\.onChange\(of: bubbles\.last\?\.text\) \{ _, _ in scrollToTail\(proxy\) \}/);
});

test('C1 rows keep everything: Markdown, error card, system notes (13pt in the DM), typing dots, the offline mark', () => {
  // 17pt 行高 25（回覆）／23（我說的）；泡泡內距 9／14、圓角 20；底色照 App 的語意色（Coder 使用者訊息同一個 token）。
  assert.match(text, /static let pointSize: CGFloat = GlobalDMChatLayout\.messageSize/);
  assert.match(text, /lineSpacing: GlobalDMChatLayout\.replyLineSpacing\)/);
  assert.match(text, /\.lineSpacing\(GlobalDMChatLayout\.replyLineSpacing\)/);
  const bubble = slice(text, 'struct GlobalDMUserBubble', '\n}\n');
  for (const piece of ['GlobalDMChatLayout.userBubbleRadius', 'GlobalDMChatLayout.userLineSpacing',
    'GlobalDMChatLayout.userBubbleHorizontalPadding', 'GlobalDMChatLayout.userBubbleVerticalPadding',
    'LiquidGlassTokens.brandAccent.opacity(TatwoChatTranscriptVisualMetrics.userBubbleTintOpacity)']) {
    assert.ok(bubble.includes(piece), piece);
  }
  assert.doesNotMatch(code(bubble), /Color\(red:|#[0-9a-fA-F]{6}/, 'no beige copied from the mock');
  assert.match(phone, /static let userBubbleVerticalPadding: CGFloat = 9\s*static let userBubbleHorizontalPadding: CGFloat = 14\s*static let userBubbleRadius: CGFloat = 20\s*static let userLineHeight: CGFloat = 23/);
  assert.match(phone, /static let replyLineHeight: CGFloat = 25/);
  // Markdown 照 Coder 的元件排；錯誤卡、系統說明（含「用了 N 條記憶」）、打字點點都還在。
  assert.match(text, /ChatAssistantTranscriptBlockView\(/);
  assert.ok(list.includes('ChatErrorCard(presentation: error, rowWidth: rowWidth + ChatErrorCard.textColumnInset, canRetry: false, onRetry: {})'));
  assert.ok(list.includes('.padding(.leading, -ChatErrorCard.textColumnInset)'), 'error card lines up with the reply text (no avatar column)');
  assert.ok(list.includes('ChatSystemNoteRow(presentation: note, rowWidth: rowWidth)'));
  assert.ok(list.includes('GlobalDMTypingRow(route: bubble.modelID.map(ChatRouteChoice.resolve) ?? avatarRoute, rowWidth: rowWidth)'));
  assert.ok(phone.includes('ChatTypingDots()'));
  // 說明字 13、小標 11：私訊框用環境值設；Coder、TATWO 不設＝照舊 12／10.5／11（只換字級）。
  assert.ok(list.includes('.environment(\\.chatNoteTypography, GlobalDMChatLayout.noteTypography)'));
  const note = read('New/ChatSystemNoteRow.swift');
  assert.match(note, /struct ChatNoteTypography: Equatable, Sendable \{\s*var text: CGFloat = 12\s*var label: CGFloat = 10\.5\s*var mark: CGFloat = 11/);
  assert.match(note, /Text\(presentation\.text\)\s*\.font\(\.system\(size: typography\.text\)\)/);
  const usage = read('Memory/TatwoMemoryUsageRow.swift');
  assert.match(usage, /Text\(note\.headline\)\s*\.font\(\.system\(size: typography\.text\)\)/);
  assert.match(usage, /@Environment\(\\\.chatNoteTypography\) private var typography/);
  for (const surface of ['Chat/ChatPage+Transcript.swift', 'Assistant/AssistantSpacePane.swift']) {
    assert.doesNotMatch(read(surface), /chatNoteTypography/, `${surface} keeps the standard note sizes`);
  }
  // 〔在「X」離線時〕標記是訊息本身的字：訊息列不改它。
  const rows = slice(view, 'static func rows(_ messages: [ChatMessage], running: Bool = false)', 'static func rows(_ messages: [TapMessage]');
  assert.doesNotMatch(rows, /離線時/);
});

test('C2 glass capsule composer: 12 from the edges, 12/12/10/16, corner 40, two layers, ＋ … memory, model, send/stop', () => {
  assert.ok(composer.includes('.liquidGlassPanelSurface(cornerRadius: GlobalDMChatLayout.composerRadius)'));
  for (const piece of ['.padding(.top, GlobalDMChatLayout.composerTop)', '.padding(.trailing, GlobalDMChatLayout.composerTrailing)',
    '.padding(.bottom, GlobalDMChatLayout.composerBottom)', '.padding(.leading, GlobalDMChatLayout.composerLeading)',
    '.padding(.horizontal, GlobalDMChatLayout.composerInset)', '.padding(.bottom, GlobalDMChatLayout.composerInset)',
    'VStack(alignment: .leading, spacing: GlobalDMChatLayout.composerLayerSpacing)']) {
    assert.ok(composer.includes(piece), piece);
  }
  assert.match(phone, /static let composerTop: CGFloat = 12\s*static let composerTrailing: CGFloat = 12\s*static let composerBottom: CGFloat = 10\s*static let composerLeading: CGFloat = 16/);
  // 兩層：上面是字（17pt，佔位字照舊），下面一排；順序＝＋…彈性空白…記憶、模型、送出／停止。
  // W184 H4：記憶、模型收進同一個位置的一顆「模式選擇」chip（GlobalDMModeChip，兩段各帶舊識別碼）；守的順序＝＋…彈性空白…模式選擇、送出／停止。
  const textAt = composer.indexOf('ChatComposerTextView(text: draft');
  const rowAt = composer.indexOf('HStack(spacing: GlobalDMChatLayout.composerItemSpacing)');
  assert.ok(textAt > 0 && rowAt > textAt, 'text above the row');
  assert.ok(composer.includes('pointSize: GlobalDMChatLayout.messageSize'));
  const order = ['GlobalDMAttachButton(store: store)', '.padding(.leading, GlobalDMChatLayout.plusOutset)', 'Spacer(minLength: 4)',
    'GlobalDMModeChip(store: store, isOpen: $modeOpen, anchor: modeAnchor)', 'GlobalDMStopButton { store.stop() }',
    'GlobalDMSendButton(enabled: canSend && store.hasContentToSend)'];
  let at = rowAt;
  for (const piece of order) {
    const next = composer.indexOf(piece, at);
    assert.ok(next > at, `order: ${piece}`);
    at = next;
  }
  assert.ok(composer.includes('.frame(height: GlobalDMChatLayout.controlSize)'));
  // ＋、送出、停止是 36 的圓；送出是強調色、白色上箭頭；不能送時是淡玻璃；停止同 Coder 的顏色。
  assert.match(attach, /\.frame\(width: GlobalDMChatLayout\.controlSize, height: GlobalDMChatLayout\.controlSize\)\s*\.background\(GlobalDMGlassCircle\(\)\)/);
  const send = slice(phone, 'struct GlobalDMSendButton', 'struct GlobalDMStopButton');
  assert.match(send, /Image\(systemName: "arrow\.up"\)/);
  assert.match(send, /AnyShapeStyle\(Color\.white\)/);
  assert.match(send, /AnyShapeStyle\(LiquidGlassTokens\.brandAccent\)/);
  assert.match(send, /\.frame\(width: GlobalDMChatLayout\.controlSize, height: GlobalDMChatLayout\.controlSize\)/);
  const stop = slice(phone, 'struct GlobalDMStopButton', 'struct GlobalDMChipButton');
  assert.match(stop, /TatwoActivePalette\.current\.usesGlass \? Color\(nsColor: \.systemRed\) : LiquidGlassTokens\.brandAccent/);
  // 記憶、模型 chip：32 高、13pt 的玻璃膠囊。
  assert.match(chipLabel, /\.frame\(height: GlobalDMChatLayout\.chipHeight\)\s*\.background\(GlobalDMGlassCapsule\(\)\)/);
  assert.match(chipLabel, /\.font\(\.system\(size: GlobalDMChatLayout\.footnoteSize, weight: \.medium\)\)/);
  assert.match(read('Memory/TatwoMemoryStrengthChip.swift'), /GlobalDMChipLabel\(title: "記憶", value: state\.strength\.title\)/);
  // W184 H4：守同一個樣子——私訊框的模式選擇 chip（記憶、模型收在一顆）也是 32 高、13pt 的玻璃膠囊（ChatComposerModeChip 的 .dmPhone）。
  const modeChrome = read('Chat/ChatComposerChrome.swift');
  assert.match(slice(modeChrome, 'private struct ChatComposerModeChipSurface', 'struct ChatComposerSendButton'),
    /case \.dmPhone:[\s\S]*?\.frame\(height: GlobalDMChatLayout\.chipHeight\)\s*\.background\(GlobalDMGlassCapsule\(\)\)/);
  assert.match(slice(modeChrome, 'struct ChatComposerModeChip: View', 'private struct ChatComposerModeChipSurface'),
    /\.system\(size: GlobalDMChatLayout\.footnoteSize, weight: \.medium\)/);
});

test('C2 behavior unchanged: Return / Shift-Return / IME, ⌘V and drops, attachment chips, disabled chips, drafts', () => {
  // Return 送出（文字框的 onSubmit）；Shift-Return 換行、組字中不送由 Coder 的文字元件處理（照舊用同一個元件）。
  assert.ok(composer.includes('onSubmit: { _ = store.send() }'));
  assert.ok(composer.includes('onPasteImage: { store.pasteAttachment(from: $0) }'));
  assert.ok(composer.includes('slashCommands: [])'));
  assert.match(composer, /\.accessibilityIdentifier\("tatwo\.dm\.input"\)\s*\.id\(target\)/);
  // Coder 清單開著時先縮成一行、附件收起（草稿與附件都在）。
  assert.match(composer, /let folded = store\.isPickerOpen/);
  assert.match(composer, /if !files\.isEmpty, !folded \{\s*GlobalDMAttachmentRow\(store: store, files: files\)/);
  // 附件小卡可移除；帶不了附件時 ＋ 變淡、點了說原因（不用 .disabled）。
  assert.match(attachments, /Button \{ store\.removeAttachment\(file\.id\) \}/);
  assert.match(attach, /\.opacity\(block == nil \? 1 : 0\.45\)/);
  assert.match(attach, /Button \{ if let block \{ store\.showNotice\(block\) \} else \{ popUp\(\) \} \}/);
  assert.doesNotMatch(code(attach), /\.disabled\(/);
  // 模型 chip 回覆中、那台離線、Space 關掉時不能按；記憶 chip 對象是 ChatGPT 時不畫。
  // W184 H4 修正（查核 #15）：助理與 session 的模型、記憶收進「模式選擇」（GlobalDMModeChip → TatwoComposerMode.dm）；原本的
  // GlobalDMModelChip 已經沒人用。守的東西不變、改守真的在畫的那一條：不能選時模型列停用、卡上點了不開清單，記憶那排照它能不能選。
  // （ChatGPT 對象的模型在它自己的輸入框：GlobalDMChatGPTComposer。）
  const dmMode = slice(read('Chat/TatwoComposerMode.swift'), 'static func dm(store: GlobalDMStore)', 'static func dmLocalThread(');
  assert.match(dmMode, /let canChoose = store\.canChooseModel/);
  assert.match(dmMode, /isEnabled: canChoose,\s*options: options/);
  assert.match(read('Chat/TatwoComposerModeCard.swift'), /let canPick = row\.isEnabled && !row\.options\.isEmpty[\s\S]*?guard canPick else \{ return \}/);
  assert.match(slice(read('Chat/TatwoComposerMode.swift'), 'static func memorySteps(', 'static func memorySegment('), /isEnabled: state\.isEnabled/);
  assert.match(read('Memory/TatwoMemoryStrengthChip.swift'), /case \.chatGPT: return nil/);
  // 送出鈕不搶 ⌘↩（多個私訊框同時開著）；草稿規則在 store（送到才清），畫面不動它。
  assert.doesNotMatch(phone, /keyboardShortcut/);
  // W184 G3 修正單：對象是 ChatGPT 時的送出鈕也一樣——私訊框的 ChatGPT 輸入框、共用的送出鍵那一格、ChatGPT 的送出鈕都不註冊快捷鍵。
  const chatGPTSend = [read('DM/GlobalDMChatGPTComposer.swift'),
    slice(read('TAP/ChatGPTComposerKit.swift'), 'struct ChatGPTSendSlot: View', 'protocol ChatGPTModelPicking'),
    slice(read('TAP/ChatGPTPages.swift'), 'struct ChatGPTSendButton: View', 'struct ChatGPTLink')];
  for (const source of chatGPTSend) assert.doesNotMatch(source, /keyboardShortcut/);
  assert.match(read('DM/GlobalDMStore.swift'), /if self\.draft\(for: target\) == text \{ self\.setDraft\("", for: target\) \}/);
  // 直達鍵頁開著、［連線］卡蓋著時輸入列照舊拿掉。
  assert.equal(count(view, 'if !store.isEditingDirectKeys {\n                GlobalDMComposer('), 2);
  assert.match(composer, /if !webSheetActive \{ composer \}/);
});

test('C2 the ChatGPT line sits above the composer, centered, with a lock — only when the target is ChatGPT', () => {
  assert.match(composer, /if GlobalDMChatLayout\.showsChatGPTCaption\(for: target\) \{\s*GlobalDMChatGPTCaption\(\)/);
  assert.match(phone, /static func showsChatGPTCaption\(for target: GlobalDMTarget\) -> Bool \{ target == \.chatGPT \}/);
  const caption = slice(phone, 'struct GlobalDMChatGPTCaption', 'struct GlobalDMTypingRow');
  assert.ok(caption.includes('static let text = "OS 不記錄對話內容・用你自己的 ChatGPT 帳號"'));
  assert.ok(caption.includes('Image(systemName: "lock.fill")'));
  assert.ok(caption.includes('.multilineTextAlignment(.center)'));
  assert.ok(caption.includes('.accessibilityIdentifier("tatwo.dm.chatgptCaption")'));
  // 在說明行上方的是訊息區；說明行在玻璃卡上方（同一個輸入列區塊裡，跟著輸入列一起收起）。
  assert.ok(composer.indexOf('GlobalDMChatGPTCaption()') < composer.indexOf('.liquidGlassPanelSurface('));
});

test('C3 notice rows: one plain sentence + at most one glass chip; approval stays in the Island', () => {
  assert.match(notice, /let actionTitle: String\?/);
  assert.equal(count(notice, 'GlobalDMChipButton('), 1, 'at most one button');
  assert.ok(notice.includes('.accessibilityIdentifier(identifier + ".action")'));
  assert.ok(notice.includes('.frame(minHeight: GlobalDMChatLayout.noticeMinHeight)'));
  assert.ok(notice.includes('.font(.system(size: GlobalDMChatLayout.noticeSize))'));
  assert.doesNotMatch(code(notice), /OSChipButton|borderedProminent|\.blue\b|isPrimary/);
  const chip = slice(phone, 'struct GlobalDMChipButton', 'struct GlobalDMChatGPTCaption');
  assert.ok(chip.includes('.frame(height: GlobalDMChatLayout.chipHeight)'));
  assert.ok(chip.includes('.background(GlobalDMGlassCapsule())'));
  // 一句話的規則（自測拿各種提示列的真實文字核對）。
  const rule = slice(phone, 'enum GlobalDMNoticeRule', '// MARK: - 私訊框自己的小元件');
  assert.match(rule, /static let maximumActions = 1/);
  assert.match(rule, /!trimmed\.contains\(where: \\\.isNewline\)/);
  // 各提示列都還在、同一種樣式：主設備離線（含在這台接著聊）、送不到主設備、等你核准→Island、一般提示、ChatGPT 關閉／沒登入／失敗。
  assert.match(view, /GlobalDMNoticeRow\(icon: "wifi\.slash", text: note, actionTitle: noteAction\?\.title, identifier: "tatwo\.dm\.primaryOffline"\) \{\s*noteAction\?\.run\(\)/);
  assert.match(view, /GlobalDMNoticeRow\(icon: "info\.circle", text: hint, actionTitle: nil, identifier: "tatwo\.dm\.primaryHint"\)/);
  assert.match(view, /GlobalDMNoticeRow\(tone: \.attention, icon: "hand\.raised", text: "等你核准", actionTitle: "到 Island 核准",\s*identifier: "tatwo\.dm\.approval"\) \{ store\.revealApprovalInIsland\(\) \}/);
  assert.match(view, /GlobalDMNoticeRow\(icon: "info\.circle", text: notice, actionTitle: nil, identifier: "tatwo\.dm\.notice"\)/);
  for (const id of ['tatwo.dm.chatgptOff', 'tatwo.dm.chatgptLogin', 'tatwo.dm.chatgptFailed']) {
    assert.ok(view.includes(`identifier: "${id}"`), id);
  }
  assert.match(phone, /static let attentionAccentOpacity: Double = 0\.12/);
  assert.match(read('New/ChatGPTHandsSection.swift'), /\.chatLiquidSection\(cornerRadius: 12, accentOpacity: 0\.12\)/, 'the accent value is an existing glass token use');
});

test('identifiers stay: composer, chips, notices (with .action), plus the new ChatGPT line', () => {
  for (const id of ['tatwo.dm.input', 'tatwo.dm.send', 'tatwo.dm.stop']) {
    assert.ok(composer.includes(`.accessibilityIdentifier("${id}")`), id);
  }
  assert.ok(strip.includes('.accessibilityIdentifier("tatwo.dm.attach")'));
  assert.ok(strip.includes('.accessibilityIdentifier("tatwo.dm.attachments")'));
  assert.ok(strip.includes('.accessibilityIdentifier("tatwo.dm.model")'));
  assert.ok(read('Memory/TatwoMemoryStrengthChip.swift').includes('.accessibilityIdentifier("tatwo-memory-strength")'));
  for (const id of ['tatwo.dm.primaryOffline', 'tatwo.dm.primaryHint', 'tatwo.dm.approval', 'tatwo.dm.notice',
    'tatwo.dm.chatgptOff', 'tatwo.dm.chatgptLogin', 'tatwo.dm.chatgptFailed']) {
    assert.ok(view.includes(`"${id}"`), id);
  }
  assert.ok(read('DM/GlobalDMDeskViews.swift').includes('identifier: "tatwo.dm.keys.notice"'));
  assert.ok(phone.includes('"tatwo.dm.chatgptCaption"'));
});

test('Coder shared pieces untouched: the DM wraps its own send/stop/row; ChatComposerChrome keeps its 28pt buttons', () => {
  assert.doesNotMatch(code(composer), /ChatComposerSendButton|ChatComposerStopButton|ChatComposerToolbarRow/);
  const chrome = read('Chat/ChatComposerChrome.swift');
  assert.match(chrome, /struct ChatComposerToolbarRow<Content: View>: View \{[\s\S]*?\.frame\(height: 28\)/);
  assert.match(slice(chrome, 'struct ChatComposerSendButton', 'struct ChatComposerStopButton'), /\.frame\(width: 28, height: 28\)/);
  assert.match(slice(chrome, 'struct ChatComposerStopButton', 'enum ChatComposerStatusTone'), /\.frame\(width: 28, height: 28\)/);
  assert.doesNotMatch(code(phone), /\.borderedProminent|\.blue\b|accentColor|\.tint\(/);
  assert.doesNotMatch(code(view), /\.blue\b|accentColor|borderedProminent|\.tint\(/);
});

test('executable self-test w184chat covers the brief (rules, drawn positions, identifiers, PNG evidence)', () => {
  const self = read('SelfTest.swift');
  assert.match(self, /TATWO2_SELFTEST"\] == "w184chat"[\s\S]{0,200}GlobalDMChatAcceptance\.run\(\)/);
  const acceptance = read('DM/GlobalDMChatAcceptance.swift');
  assert.match(acceptance, /^#if DEBUG/);
  assert.match(acceptance, /NativeStagingIsolation\.validationError\(environment\) == nil/);
  assert.match(acceptance, /isolated engine homes must be logged out/);
  assert.match(acceptance, /environment\["TATWO2_SELFTEST_ARTIFACTS"\]/);
  for (const label of ['C1 my messages are a bubble at most 78% of the row',
    'C1 replies: full width, no bubble, no avatar, 17pt with line height 25',
    'C1 the 用了 N 條記憶 line sits 6 under its reply',
    'C1-C3 every font size in the message list, notices and composer is a token (17/15/13/11)',
    'C2 composer sits 12 from the box edges; corner 52 − 12 = 40 (concentric)',
    'C2 the ChatGPT line (OS keeps no record · your own account) is only for ChatGPT',
    'C3 every notice kind is one plain sentence', 'C3 each notice has at most one button',
    'C1 (drawn) a short message of mine sits at the right', 'C1 (drawn) a long message of mine wraps inside 78% of the row',
    'C1 (drawn) a reply runs the full width', 'C1 (drawn) messages sit at the bottom',
    'C2/C3 assistant: input, ＋, 記憶, 模型, 送出, 等你核准＋到 Island 核准', 'C2 ChatGPT: the line above the composer is there; no memory chip',
    'C2 while replying the send button becomes stop', 'C2 attachments: the chip row is there',
    'C3 ChatGPT needs login', 'C3 ChatGPT Space off', 'C3 ChatGPT failed', 'W184CHAT SUMMARY failures=']) {
    assert.ok(acceptance.includes(label), label);
  }
  for (const png of ['assistant.png', 'chatgpt.png', 'primary-offline.png', 'attachments.png']) {
    assert.ok(acceptance.includes(`"${png}"`), png);
  }
  // 範例用中性名字（不寫設備名）；沒有無條件的通過。
  assert.ok(acceptance.includes('"Primary One"'));
  assert.doesNotMatch(acceptance, /check\(true,/);
  // 核准仍只在 Island：畫「等你核准」列用引擎真的等核准狀態，不另做核准卡。
  assert.match(acceptance, /engine\.withPendingPermission\(assistantID\)/);
});

// ---- W184 G3（使用者 09-29 看了 v2.0.21.029：「chatgpt私訊的輸入筐也不夠像chatgpt 缺少很多實用功能」）----
// 私訊框對象是 ChatGPT 時，輸入框＝ChatGPT Space 輸入框的元件（共用，不是複製）；私訊框用手機 token，ChatGPT Space 照舊。
// 畫面、真的動作（假 Pod）與 PNG 在 `TATWO2_SELFTEST=w184chat` 的 G3 那一段（DM/GlobalDMChatGPTComposerAcceptance.swift）。
const g3 = read('DM/GlobalDMChatGPTComposer.swift');
const kit = read('TAP/ChatGPTComposerKit.swift');
const pages = read('TAP/ChatGPTPages.swift');
const space = read('TAP/ChatGPTSpace.swift');
const dmStore = read('DM/GlobalDMStore.swift');
const g3Layers = slice(g3, 'struct GlobalDMChatGPTComposerLayers: View', '// MARK: - ChatGPT 那一欄上面的幾層');
const g3Pane = slice(g3, 'struct GlobalDMChatGPTPaneLayers: ViewModifier', '// MARK: - 資料與動作');
// W184 G3b：頂列（≡、模型名、新對話）、抽屜、「/」與 ＋ 小卡的動作（DM）；＋ 小卡與「/」小視窗本身是共用元件（TAP）。
const nav = read('DM/GlobalDMChatGPTNavigation.swift');
const quick = read('TAP/ChatGPTQuickMenu.swift');
const phoneBox = read('DM/GlobalDMPhoneBox.swift');

test('G3 shared, not copied: the DM ChatGPT composer and ChatGPT Space use the same components', () => {
  // 守：兩邊用同一個元件（名字出現在兩邊的呼叫端），元件只定義一次（在共用檔）。
  // W184 G3b：＋ 是 ChatGPTPlusButton＋ChatGPTQuickMenu（＋ 小卡，兩邊同一張）。
  // W184 G3c（使用者：「功能鍵也不全」）：模型與思考強度膠囊回到私訊框的輸入框（G3b 放在頂列），兩邊同一個元件。
  for (const piece of ['ChatGPTPlusButton(', 'ChatGPTComposerChips(', 'ChatGPTPickerCapsule(', 'ChatGPTSendSlot(']) {
    assert.ok(g3Layers.includes(piece), `DM uses ${piece}`);
    assert.ok(space.includes(piece), `ChatGPT Space uses ${piece}`);
  }
  // W184 G3b 追加（使用者：「只留ai對話 不用麥克風輸入法」）：守——私訊框沒有聽寫（沒有鈕、沒有綁輸入框的聽寫）；
  // ChatGPT Space 的聽寫照舊用共用的鈕。
  assert.ok(space.includes('ChatGPTDictationButton('), 'ChatGPT Space keeps its dictation');
  // （dmPhone 的 dictation 尺寸欄位是共用 struct 的必填欄位，數字照 token 留著、不畫。）
  assert.doesNotMatch(g3, /ChatGPTDictation|dictation\.(cancel|start|textView)|"tatwo\.dm\.dictate"/, 'the DM has no dictation');
  assert.ok(!nav.includes('ChatGPTPickerCapsule('), 'the model capsule is no longer on the top bar (W184 G3c)');
  for (const piece of ['ChatGPTFloatingCardLayer(', 'ChatGPTDropHighlight(', 'ChatGPTQuickMenu(', 'ChatGPTQuickMenu.plusSections(']) {
    assert.ok(g3Pane.includes(piece), `DM uses ${piece}`);
    assert.ok(space.includes(piece), `ChatGPT Space uses ${piece}`);
  }
  assert.match(g3Pane, /let metrics = ChatGPTComposerMetrics\.dmPhone/);
  assert.match(g3Pane, /ChatGPTEffortCard\(model: store, metrics: metrics\)/);
  assert.match(space, /ChatGPTEffortCard\(model: model\)/);
  assert.match(g3Pane, /ChatGPTVoiceOverlay\(model: voice, metrics: metrics,/);
  assert.match(space, /ChatGPTVoiceOverlay\(model: model\)/);
  for (const [name, source] of [['struct ChatGPTPlusButton', kit], ['struct ChatGPTQuickMenu: View', quick], ['struct ChatGPTToolChip', kit],
    ['struct ChatGPTComposerChips', kit],
    ['struct ChatGPTPickerCapsule', kit], ['struct ChatGPTDictationButton', kit], ['struct ChatGPTSendSlot', kit],
    ['struct ChatGPTFloatingCardLayer', kit], ['final class ChatGPTVoiceMode', kit], ['struct ChatGPTAttachmentTile', pages],
    ['struct ChatGPTEffortCard<Model: ChatGPTModelPicking>', pages], ['struct ChatGPTVoiceOverlay<Voice: ChatGPTVoiceShowing>', pages]]) {
    assert.equal(count(source, name), 1, `${name} is defined once`);
    for (const other of [g3, space, view, phone, strip, nav]) assert.equal(count(other, name), 0, `${name} is not copied`);
  }
  // ＋ 小卡不是系統選單（使用者 09-29 17:35）：共用元件、私訊框都沒有 Menu／menuStyle。
  assert.doesNotMatch(code(quick) + code(nav), /(^|[^A-Za-z])Menu \{|\.menuStyle|\.contextMenu/);
  // 沒有第二份：私訊框自己不畫 ＋ 選單、聲波、聽寫、滑桿、網頁版分層的字。
  assert.doesNotMatch(code(g3), /Menu \{|Image\(systemName: "waveform"\)|startDictation|ChatGPTEffortSlider\(|Text\("加入照片和檔案"\)|plusTools \{|NSFilePromiseReceiver/);
  assert.equal(count(space, 'startDictation:'), 0, 'dictation lives in the shared button');
  assert.equal(count(kit, 'startDictation:'), 1);
});

test('G3 the DM composer dispatches ChatGPT into the same glass capsule; other targets keep their composer', () => {
  // 守：外框（說明行、玻璃膠囊、同心圓角、內外距）同一個；對象是 ChatGPT 才換成 ChatGPT 的三層；其他對象照舊（W184 C 的排法）。
  assert.match(composer, /if target == \.chatGPT \{[\s\S]{0,400}GlobalDMChatGPTComposerLayers\(store: store, session: chatGPTSession \?\? store\.chatGPT, placeholder: placeholder,\s*canSend: canSend, folded: folded, textHeight: \$textHeight, focused: \$focused\)\s*\} else \{\s*if !files\.isEmpty, !folded \{\s*GlobalDMAttachmentRow/);
  // 同一則對話：窗格的 session 交給輸入框（語音、回答中都看它）。
  assert.match(view, /initiallyFocused: role\.takesInitialFocus, chatGPTSession: session\)/);
  assert.ok(composer.indexOf('GlobalDMChatGPTComposerLayers(') < composer.indexOf('.liquidGlassPanelSurface(cornerRadius: GlobalDMChatLayout.composerRadius)'));
  assert.match(view, /\.modifier\(GlobalDMChatGPTPaneLayers\(store: store, voice: session\.voice\)\)/);
  // 三層：上面小卡與縮圖（Coder 清單開著時收起）→ 字（17pt、Return／Shift-Return 照舊、照片 App 的檔案承諾也收）→ 下面一排。
  const chipsAt = g3Layers.indexOf('ChatGPTComposerChips(');
  const textAt = g3Layers.indexOf('ChatComposerTextView(');
  const rowAt = g3Layers.indexOf('HStack(spacing: GlobalDMChatLayout.composerItemSpacing)');
  assert.ok(chipsAt > 0 && textAt > chipsAt && rowAt > textAt, 'chips, text, row');
  assert.match(g3Layers, /if !folded, tool != nil \|\| !files\.isEmpty \{\s*\/\/[^\n]*\n\s*GlobalDMHorizontalScroller \{/);
  for (const piece of ['onSubmit: { _ = store.send() }', 'onPasteImage: { store.pasteAttachment(from: $0) }', 'acceptsPhotoDrags: true',
    'pointSize: metrics.inputText', 'minimumHeight: GlobalDMChatLayout.inputMinimumHeight',
    'maximumHeight: GlobalDMChatLayout.inputMaximumHeight', 'slashCommands: []']) {
    assert.ok(g3Layers.includes(piece), piece);
  }
  // 下面一排的順序照 ChatGPT iPhone App（W184 G3b）：＋ …（彈性空白）… 圓框放大鏡（網路搜尋）、語音模式／送出／停止
  // （W184 G3b 追加：麥克風（聽寫）拿掉）；W184 G3c：模型膠囊照 ChatGPT Space 的輸入框回到這一排（放大鏡與送出那一格之間）。
  const order = ['ChatGPTPlusButton(', '.padding(.leading, GlobalDMChatLayout.plusOutset)', 'Spacer(minLength: 4)',
    'ChatGPTToggleGlyph(systemName: "magnifyingglass.circle"', 'ChatGPTPickerCapsule(', 'ChatGPTSendSlot('];
  let at = rowAt;
  for (const piece of order) {
    const next = g3Layers.indexOf(piece, at);
    assert.ok(next > at, `order: ${piece}`);
    at = next;
  }
  assert.doesNotMatch(g3Layers, /GlobalDMMemoryChip|GlobalDMModelChip|GlobalDMSendButton|GlobalDMStopButton/,
    'no memory chip for ChatGPT; ChatGPT buttons (the model capsule is ChatGPT Space\'s, not the DM chip)');
  // W184 G3c（使用者：「chatgpt duo輸入筐造型r角很醜」）：守——對象是 ChatGPT 也是這一個玻璃膠囊（同心 40），沒有另一種底。
  assert.equal(count(composer, '.liquidGlassPanelSurface(cornerRadius: GlobalDMChatLayout.composerRadius)'), 1);
  assert.doesNotMatch(code(view), /GlobalDMComposerSurface|composerFill/);
});

test('G3 tokens: the DM set is built from DMPhone only (17/15/13/11, 36 circles, 32 chips, glass); ChatGPT Space keeps its numbers', () => {
  assert.doesNotMatch(code(g3), /\.system\(size: \d/, 'no hard-coded font size in the DM ChatGPT composer');
  const dm = slice(g3, 'static let dmPhone: ChatGPTComposerMetrics = {', '}()');
  // W184 G3b：私訊框的 ChatGPT 對象照 ChatGPT iPhone App（中性外觀；滑桿與選中照 App 的強調色——見下面 accent 那一條）。
  assert.match(dm, /chrome: \.phone,/);
  assert.match(dm, /stopFilled: true/);
  assert.match(dm, /let round = DMPhone\.smallControl/);
  for (const field of ['chipText', 'chipIcon', 'chipClose', 'tileName', 'tileKind', 'tileCloseGlyph', 'pickerText', 'pickerChevron', 'cardTitle',
    'cardRow', 'cardDetail', 'cardSmall', 'cardChevron', 'cardCheck', 'voiceTitle', 'voiceStatus', 'voiceButton', 'dropText', 'tileFileGlyph',
    'menuText', 'menuCaption']) {
    assert.match(dm, new RegExp(`${field}: DMPhone\\.TextSize\\.(body|secondary|footnote|caption)\\b`), `${field} is a phone token`);
  }
  for (const round of ['plus', 'dictation', 'voice', 'send', 'stop']) {
    assert.match(dm, new RegExp(`${round}: Round\\(size: round, glyph: DMPhone\\.TextSize\\.(body|secondary|footnote|caption)\\)`), round);
  }
  assert.match(dm, /chipHeight: DMPhone\.chipHeight/);
  assert.match(dm, /pickerHeight: DMPhone\.chipHeight/);
  assert.match(dm, /cardRadius: DMPhone\.cardRadius/);
  assert.match(dm, /menuRadius: DMPhone\.cardRadius,\s*menuRowRadius: DMPhone\.chipHeight \/ 2, menuRowHeight: DMPhone\.touch \+ 8/);
  assert.match(dm, /menuIcon: round,/);
  // W184 G3b 追加（使用者：「輸入筐字體太大跟chatgpt classic一樣即可」）：守——私訊框打的字與佔位字照 ChatGPT Space 的輸入框那一個數字
  // （不另訂）；Space 自己也用這一個（值照舊 15）。
  assert.match(dm, /inputText: ChatGPTComposerMetrics\.space\.inputText,/);
  assert.match(space, /pointSize: ChatGPTComposerMetrics\.space\.inputText,/);
  // ChatGPT Space：原本寫在輸入框裡的數字，一個都不變（樣子不變）。
  const spaceSet = slice(kit, 'static let space = ChatGPTComposerMetrics(', 'dropText: 14)');
  for (const piece of ['chrome: .web', 'plus: Round(size: 28, glyph: 14)', 'dictation: Round(size: 28, glyph: 13)', 'voice: Round(size: 30, glyph: 13)',
    'send: Round(size: 30, glyph: 14)', 'stop: Round(size: 28, glyph: 11)', 'stopFilled: false', 'chipHeight: 28, chipText: 12, chipIcon: 11, chipClose: 9, chipCloseFrame: 16',
    'tileImage: 144, tileFileWidth: 240, tileFileHeight: 56, tileFileIcon: 40, tileFileGlyph: 17, tileRadius: 16',
    'tileName: 13, tileKind: 12, tileClose: 22, tileCloseGlyph: 8.5, chipsSpacing: 8', 'pickerHeight: 32, pickerText: 15, pickerChevron: 10',
    'cardTitle: 16, cardRow: 14, cardDetail: 12, cardSmall: 13, cardChevron: 11, cardCheck: 12',
    'voiceRing: 150, voiceDot: 96, voiceGlyph: 30, voiceTitle: 17, voiceStatus: 13, voiceButton: 13, voiceButtonHeight: 36',
    'menuText: 14, menuCaption: 12, menuRadius: 16', 'inputText: 15,', 'dropRadius: 18, dropInset: 16']) {
    assert.ok(spaceSet.includes(piece), piece);
  }
  assert.match(pages, /static let imageSize: CGFloat = 144/);
  assert.match(pages, /static let width: CGFloat = 260/);
  // 私訊框不要藍色：滑桿用品牌色（ChatGPT Space 照舊主題藍）；不用系統藍鈕。
  assert.match(pages, /accent: metrics\.chrome == \.web \? ChatGPTPalette\.accent : LiquidGlassTokens\.brandAccent/);
  assert.doesNotMatch(code(g3), /\.borderedProminent|\.blue\b|accentColor|\.tint\(/);
});

test('G3 the tool card, model and level, and files really reach ChatGPT the way ChatGPT Space sends them', () => {
  // 工具：送出時帶 tool（TAP 的 hint），送到了才清小卡（同草稿）。
  const send = slice(dmStore, 'func send() -> Bool', '// MARK: - 模型 chip');
  assert.match(send, /let tool = chatGPTTool[\s\S]*?session\.send\(text, model: arguments\.model, effort: arguments\.effort,[\s\S]*?\}, tool: tool\?\.id\)/);
  assert.match(send, /if accepted \{\s*delivered\(\)\s*if chatGPTTool == tool \{ chatGPTTool = nil \}/);
  const session = read('TAP/ChatGPTConversationSession.swift');
  // 守：工具照 Space 的帶法交給 TAP；W184 G3b 第二輪（審查 #4）：接著舊對話送時也帶上私訊框看到的那一支末端（parent）；
  // W184 G3c：臨時聊天的每一句都帶臨時旗標（isTemporary）。
  assert.match(session, /attachments: attachments, tool: tool, gizmoID: conversationID == nil \? projectID : nil, temporary: isTemporary, parentID: parent,\s*temporaryPersonalized: isTemporary && temporaryPersonalized\)/);
  assert.match(read('TAP/ChatGPTTap.swift'), /if let tool \{ payload\["hint"\] = tool \}/);
  // W184 G3 第三輪：Space 先記下選的工具（排太久沒送出時放回去），送的照舊是它的代號。
  assert.match(space, /let chosenTool = selectedTool\s*let tool = chosenTool\?\.id/, 'ChatGPT Space sends its tool the same way');
  // 「＋」（W184 G3b：＋ 小卡）：兩邊同一份清單規則（ChatGPTQuickMenu.plusSections）與同一份最近用過的 App；選了 App 記代號。
  assert.match(g3Pane, /ChatGPTQuickMenu\(sections: ChatGPTQuickMenu\.plusSections\(\s*tools: store\.chatGPTCatalog\.tools, recentApps: store\.chatGPTRecentApps,/);
  assert.match(space, /ChatGPTQuickMenu\(sections: ChatGPTQuickMenu\.plusSections\(\s*tools: model\.tools, recentApps: UserDefaults\.standard\.stringArray\(forKey: ChatGPTSpaceModel\.recentAppsKey\) \?\? \[\],/);
  assert.match(nav, /default:\s*guard id\.hasPrefix\("tool:"\), let tool = chatGPTCatalog\.tools\.first\(where: \{ "tool:" \+ \$0\.id == id \}\) else \{ return \}\s*setChatGPTPlusOpen\(false\)\s*chooseChatGPTTool\(tool\)/);
  // W184 G3 修正單：「最近用過的 App」只有一份——私訊框（左欄、內橫右欄）記在 recentAppsDefaults，預設就是 ChatGPT Space 用的
  // UserDefaults.standard；右欄的 store 用自己的設定 suite，但不另給最近用過的 App（沿用預設）。
  assert.match(dmStore, /func chooseChatGPTTool\(_ tool: TapTool\?\) \{\s*chatGPTTool = tool\s*if let tool \{ ChatGPTSpaceModel\.rememberApp\(tool, in: recentAppsDefaults\) \}/);
  assert.match(dmStore, /var chatGPTRecentApps: \[String\] \{ recentAppsDefaults\.stringArray\(forKey: ChatGPTSpaceModel\.recentAppsKey\) \?\? \[\] \}/);
  assert.match(dmStore, /directKeys: Bool = true,\s*recentApps: UserDefaults = \.standard\) \{/);
  assert.match(read('DM/GlobalDMDesk.swift'), /let store = GlobalDMStore\(defaults: defaults,\s*refreshChatGPTToolCatalog: refreshChatGPTToolCatalog,\s*directKeys: false\)/);
  assert.match(space, /var plusApps: \[TapTool\] \{ Self\.plusApps\(tools, recent: UserDefaults\.standard\.stringArray\(forKey: Self\.recentAppsKey\) \?\? \[\]\) \}/);
  assert.match(space, /func choose\(_ tool: TapTool\) \{\s*selectedTool = tool\s*Self\.rememberApp\(tool, in: \.standard\)/);
  // 模型與強度：膠囊與面板看 GlobalDMStore 的 chatGPTCatalog／chatGPTChoice（同 ChatGPTModelMenu 的規則），不動 ChatGPT Space 的選擇。
  const picking = slice(g3, 'extension GlobalDMStore: ChatGPTModelPicking {', '\n}\n');
  assert.match(picking, /ChatGPTModelMenu\.effectiveModel\(chatGPTCatalog, chatGPTChoice\)/);
  assert.match(picking, /ChatGPTModelMenu\.effectiveEffort\(chatGPTCatalog, chatGPTChoice\)/);
  assert.match(picking, /func pickerChoose\(effort id: String\) \{ chooseChatGPT\(ChatGPTModelChoice\(modelID: chatGPTChoice\.modelID, effortID: id\)\) \}/);
  assert.doesNotMatch(g3, /selectedModelID|selectedEffortID/);
  // W184 G3c：模型膠囊在輸入框裡（同一個膠囊元件、同 ChatGPT Space 的輸入框）；回答中不能換；面板浮在它上面。
  assert.match(g3Layers, /ChatGPTPickerCapsule\(label: store\.pickerLabel, isOpen: store\.isChatGPTModelCardOpen, metrics: metrics,\s*identifier: "tatwo\.dm\.model"\) \{ store\.toggleChatGPTModelCard\(\) \}\s*\.disabled\(!store\.canChooseModel\)/);
  // 附件：ChatGPT Space 那一套（Finder 檔案、「照片」App 的檔案承諾、原始 PNG／JPEG／HEIC、拖到對話區）；只進 ChatGPT 對象、只在記憶體。
  const paste = slice(dmStore, 'func pasteAttachment(from pasteboard: NSPasteboard) -> Bool', 'func showNotice(');
  assert.match(paste, /if target == \.chatGPT, attachmentBlock\(for: target\) == nil \{\s*return ChatGPTSpaceModel\.attach\(from: pasteboard, into: chatGPTSink\)/);
  assert.match(dmStore, /return ChatGPTSpaceModel\.attach\(providers: providers, into: chatGPTSink\)/);
  // W184 G3b 第二輪（審查 #1）：收的時候照「開始收的那一則」放（晚到的不會掉進中途換過去的那一則）；守的東西不變：一律進 ChatGPT 對象。
  assert.match(dmStore, /ChatGPTSpaceModel\.AttachmentSink\(add: \{ \[weak self\] data, name, mime in\s*self\?\.receiveChatGPTAttachment\(data, name: name, mime: mime, origin: origin\)/);
  assert.match(dmStore, /attachmentsByTarget\[\.chatGPT\] = list/);
  assert.match(g3Pane, /\.onDrop\(of: \[UTType\.fileURL, UTType\.image\], isTargeted: \$dropTargeted\) \{ providers in\s*store\.attachChatGPT\(providers: providers\)/);
  assert.match(space, /func attach\(from pasteboard: NSPasteboard\) -> Bool \{\s*Self\.attach\(from: pasteboard, into: attachmentSink\)/);
  // W184 G3b 第二輪（使用者：「快捷指令直接參照chatgpt那邊有什麼 這邊chatgpt space、duo就有什麼」）：＋ 小卡只放 ChatGPT 那邊有的——
  // 私訊框自己加的「貼上剪貼簿圖片」拿掉（兩邊的 ＋ 都沒有這一列）；守：⌘V 貼上照舊可用（輸入框交給 store.pasteAttachment）。
  assert.doesNotMatch(code(quick), /貼上剪貼簿圖片|id: "paste"/);
  assert.doesNotMatch(code(g3Pane + nav + space), /canPaste|case "paste"/);
  assert.match(g3Layers, /onPasteImage: \{ store\.pasteAttachment\(from: \$0\) \}/);
  assert.doesNotMatch(space, /pasteClipboard:/);
});

test('G3 voice: ChatGPT voice mode in the web position (the DM has no dictation since G3b 追加); voice ends on Esc and when ChatGPT goes off screen', () => {
  // 送出鍵那一格照網頁：回答中＝停止、空白＝語音模式、有字＝送出（不能送時淡灰）。
  assert.match(kit, /static func kind\(isSending: Bool, isEmpty: Bool\) -> Kind \{\s*isSending \? \.stop : \(isEmpty \? \.voice : \.send\)/);
  assert.match(g3Layers, /ChatGPTSendSlot\(isSending: session\.isSending, isEmpty: !store\.hasContentToSend,/);
  assert.match(g3Layers, /identifiers: \.init\(stop: "tatwo\.dm\.stop", voice: "tatwo\.dm\.voice", send: "tatwo\.dm\.send"\)/);
  // W184 G3 修正單：語音開著時文字送不出（canSend 也看語音）；聲波鈕要「這則可以開始」而且「ChatGPT 那一欄真的在畫面上」；
  // 三個動作照舊交給 store（停止、開始語音、送出）。
  assert.match(g3Layers, /canSend: canSend && store\.hasContentToSend && !voice\.voiceActive,\s*voiceEnabled: canSend && session\.canStartVoice && store\.chatGPTColumnOnScreen, metrics: metrics,/);
  assert.match(g3Layers, /stop: \{ store\.stop\(\) \}, startVoice: \{ store\.startChatGPTVoice\(\) \}, send: \{ _ = store\.send\(\) \}\)/);
  // 語音開著：撤掉輸入框焦點（可以程式撤）。
  assert.match(g3Layers, /accessibilityTextLabel: "私訊內容", allowsProgrammaticBlur: true,/);
  assert.match(g3Layers, /\.onChange\(of: voice\.voiceActive\) \{ _, active in\s*if active \{ focused = false \}\s*\}/);
  // W184 G3b 追加（使用者：「只留ai對話 不用麥克風輸入法」）：守——私訊框沒有聽寫鈕、不綁聽寫；語音模式照舊。
  // W184 G3c（GPT-6 審查 #3）：輸入框交出 NSTextView 只為了看有沒有在組字（抽屜打開時不搶焦點），不綁聽寫；守的東西不變。
  assert.doesNotMatch(g3Layers, /ChatGPTDictation|dictation|"tatwo\.dm\.dictate"/);
  assert.match(g3Layers, /onTextView: \{ textView\.view = \$0 \}/);
  // ChatGPT Space 還在用的共用聽寫（照舊）：綁住自己的輸入框、畫面消失就取消；開始前讓視窗成為 key、輸入框成為焦點，開始時再確認焦點還在。
  assert.match(space, /onTextView: \{ dictation\.textView = \$0 \}/);
  const dictation = slice(kit, 'final class ChatGPTDictation', 'struct ChatGPTDictationButton');
  assert.match(dictation, /if !Self\.isKey\(window\) \{ window\.makeKey\(\) \}\s*window\.makeFirstResponder\(textView\)/);
  assert.match(dictation, /guard let textView, let window = textView\.window, window\.isVisible, Self\.isKey\(window\),\s*window\.firstResponder === textView else \{ return \}\s*self\.begin\(textView\)/);
  assert.match(dictation, /func cancel\(\) \{\s*pending\?\.cancel\(\)\s*pending = nil\s*\}/);
  assert.match(read('Chat/ChatPageAppKitBridges.swift'), /onTextView\?\(textView\)/);
  // 即時語音：同 ChatGPT Space 的 ChatGPTVoiceMode；在私訊框自己這則對話；這則在送、別的地方拿著語音、有回答在跑都不開。
  const session = read('TAP/ChatGPTConversationSession.swift');
  // W184 G3 第三輪：語音拿著時，另一邊看到的那一句（私訊框另一欄／ChatGPT Space）。
  assert.match(session, /self\.voice = ChatGPTVoiceMode\(tap: tap, holderNotice: "私訊框另一欄的語音模式還開著"\)/);
  assert.match(session, /voice\.conversation = \{ \[weak self\] in self\?\.conversationID \}/);
  // W184 G3c：臨時聊天裡不開（語音在網頁開的是一般對話，會存進紀錄）；守的東西不變：這則在送、別的地方拿著語音、有回答在跑都不開。
  assert.match(session, /var canStartVoice: Bool \{ requestID == nil && voice\.canStart && !isTemporary \}/);
  assert.match(kit, /var canStart: Bool \{ !voiceActive && tap\.voiceStartBlocker == nil \}/);
  // session 自己也擋：語音開著不送文字（不只靠畫面遮住）。
  assert.match(session, /guard !text\.isEmpty \|\| !attachments\.isEmpty, requestID == nil else \{ return \}\s*\/\/[^\n]*\n\s*guard !voice\.voiceActive else \{ return \}/);
  // 語音結束：只收這次語音自己的那一則（開始時那則；新對話＝live 時看到的），版本對得上、沒在送才換上（舊逐字稿不蓋新回答）。
  assert.match(session, /if let current = self\.conversationID, current != conversationID \{ return \}/);
  assert.match(session, /guard let self, let fresh = try\? await self\.tap\.thread\(conversationID: conversationID, branch: nil\),\s*self\.revision == expected, self\.requestID == nil else \{ return \}/);
  for (const bump of [/requestID = id\s*revision \+= 1/, /func newConversation\(\) \{\s*stop\(\)\s*revision \+= 1/, /guard canStartVoice else \{ return false \}\s*revision \+= 1/]) {
    assert.match(session, bump, 'send, reset and a new voice bump the revision');
  }
  assert.match(kit, /finished\(startedIn \?\? liveConversation\)/);
  assert.match(kit, /if state\.live, startedIn == nil, let id = state\.conversationID \{ liveConversation = id \}/);
  // ChatGPT 那一欄真的在畫面上才開著：框看得到、對象是 ChatGPT、分頁開著、單欄沒換成 Browser、不是倒放；不是就結束（不只看租約）。
  // W184 G3 第三輪（修正核對 #3）：［連線］的 sheet 蓋住框也算不在畫面上（語音停）；呈現器出來／收起時回寫。
  assert.match(dmStore, /var chatGPTColumnOnScreen: Bool \{\s*isEnabled && isShowingBox && target == \.chatGPT && chatGPTAvailable && !isBrowsing && !hidesColumns && !coveredBySheet\s*\}/);
  assert.match(dmStore, /var coveredBySheet = false \{\s*didSet \{ if coveredBySheet != oldValue \{ refreshChatGPTLease\(\) \} \}/);
  const presenter = read('New/HandsConnectDMView.swift');
  assert.match(slice(presenter, '    func show() {', '    func hide() {'), /store\.coveredBySheet = covers\(store\)/);
  // W183 R12（主導 1）：收卡片也結束連線任務（左頁還給私訊、形態還原）；守的一樣：收起就放掉「蓋著」。
  assert.match(slice(presenter, '    func hide() {', 'private func requestBox()'), /guard isShown else \{ return \}\s*isShown = false\s*taskLayout\.end\(\.connect\)[^\n]*\n\s*store\.coveredBySheet = false/);
  assert.match(dmStore, /if !chatGPTColumnOnScreen, let session = chatGPTSession, session\.voice\.voiceActive \{ session\.voice\.endVoice\(\) \}/);
  assert.match(dmStore, /@Published var isBrowsing = false \{\s*didSet \{ if isBrowsing != oldValue \{ refreshChatGPTLease\(\) \} \}/);
  assert.match(dmStore, /var hidesColumns = false \{\s*didSet \{ if hidesColumns != oldValue \{ refreshChatGPTLease\(\) \} \}/);
  assert.match(read('DM/GlobalDMDeskController.swift'), /store\.hidesColumns = form == \.tent/);
  assert.match(g3, /func startChatGPTVoice\(\) -> Bool \{\s*guard chatGPTColumnOnScreen else \{ return false \}/);
  // 送出：語音開著不送（草稿留著、說一聲）。
  assert.match(dmStore, /if session\.voice\.voiceActive \{\s*notice = "語音模式開著；結束語音再送"\s*return false\s*\}/);
  // Esc：先停語音（Browser 開著、倒放都一樣，所以在那兩條之前）；再來才是思考強度面板（右欄的也算）。
  const esc = slice(read('DM/GlobalDMPanelController.swift'), 'private func handleEscape(', '// MARK: - 換形態');
  const voiceEsc = esc.indexOf('store.endChatGPTVoiceForEscape()');
  // 整合（W184 G2 把 Esc 抽成靜態的 routeEscape，form 由參數帶進來）：守的東西不變——停語音在倒放、Browser 面板、Browser 之前。
  const tentEsc = esc.indexOf('if form == .tent'), panelEsc = esc.indexOf('DMBrowserPanelEscape.closePanel'), browsingEsc = esc.indexOf('if store.isBrowsing {');
  assert.ok(voiceEsc > 0 && tentEsc > 0 && panelEsc > 0 && browsingEsc > 0 && voiceEsc < tentEsc && voiceEsc < panelEsc && voiceEsc < browsingEsc
            && voiceEsc < esc.indexOf('if store.isBrowsingBeside'), 'Esc stops voice before Browser and tent');
  assert.match(esc, /GlobalDMDuo\.shared\.existing\?\.endChatGPTVoiceForEscape\(\) == true \{ return nil \}/);
  assert.ok(esc.indexOf('store.dismissChatGPTLayers()') < esc.indexOf('if store.isPickerOpen'), 'Esc closes the ChatGPT card before the picker');
  assert.match(esc, /GlobalDMDuo\.shared\.existing\?\.dismissChatGPTLayers\(\) == true/);
  assert.match(dmStore, /func endChatGPTVoiceForEscape\(\) -> Bool \{\s*guard let session = chatGPTSession, session\.voice\.voiceActive else \{ return false \}\s*session\.voice\.stopVoice\(\)\s*return true\s*\}/);
  assert.match(g3Pane, /if voice\.voiceActive \{\s*ChatGPTVoiceOverlay/);
  // 停止中：畫面一直留著停止入口（按了＝直接關掉語音那一頁）。
  assert.match(pages, /Label\(model\.voiceStopping \? "直接關掉" : "結束語音", systemImage: "xmark"\)/);
});

test('G3 voice owner lives in ChatGPTTap: claimed before the start is sent, one side at a time, stop confirmed or the voice page is closed', () => {
  const tap = read('TAP/ChatGPTTap.swift');
  // 誰拿著語音（owner＋generation，@Published）：兩邊的聲波鈕、開始、停止、晚到的回覆都看它。
  assert.match(tap, /struct VoiceClaim: Equatable, Sendable \{\s*let owner: UUID\s*let generation: Int\s*\}/);
  // 不能開始的原因：沒連上、有人拿著語音、有回答在跑／停止中／排隊／換頁中、連接器或「新增」拿著 Pod。
  const blocker = slice(tap, 'var voiceStartBlocker: String? {', 'func claimVoice(owner: UUID');
  for (const piece of ['connection != .ready', 'voiceClaim != nil || voiceOpen', '!streams.isEmpty', 'activeRequestID != nil', 'stoppingRequestID != nil',
    '!sendQueue.isEmpty', 'pageRequests > 0']) {
    assert.ok(blocker.includes(piece), piece);
  }
  // 佔住在第一個 await 之前（ChatGPTVoiceMode.startVoice 先 claim 再開 Task）；開始時不是自己的就不送。
  assert.match(tap, /func claimVoice\(owner: UUID, holderNotice: String\? = nil, onEndRequest: \(@MainActor \(\) -> Void\)\? = nil\) -> VoiceClaim\? \{\s*guard voiceStartBlocker == nil else \{ return nil \}\s*voiceGeneration \+= 1/);
  assert.match(kit, /guard !voiceActive, let claim = tap\.claimVoice\(owner: owner, holderNotice: holderNotice,\s*onEndRequest: \{ \[weak self\] in self\?\.endVoice\(\) \}\) else \{ return false \}[\s\S]{0,700}Task \{\s*do \{\s*let state = try await tap\.voice\(start: startedIn, claim: claim\)/);
  assert.match(tap, /func voice\(start conversationID: String\?, claim: VoiceClaim\) async throws[^{]*\{\s*guard voiceClaim == claim else \{ throw TapError\.remote\("語音模式在另一邊"\) \}/);
  // 只放自己的；別人的語音不停。
  assert.match(tap, /func releaseVoice\(_ claim: VoiceClaim\) \{\s*guard voiceClaim == claim else \{ return \}/);
  assert.match(tap, /func voiceStop\(claim: VoiceClaim, timeout: Duration = \.seconds\(20\)\) async throws \{\s*guard voiceClaim == nil \|\| voiceClaim == claim else/);
  // 停止要確認：送結束、稍等、查狀態不是 live 才算；兩輪沒確認就關掉語音那一頁（Pod 休眠＝網頁關掉），有人看著再重開。
  const end = slice(tap, 'func endVoice(claim: VoiceClaim', 'func forceEndVoice(');
  assert.match(end, /for _ in 0\.\.<2 \{/);
  assert.match(end, /if let state = try\? await voiceState\(timeout: stateTimeout\), !state\.live \{/);
  assert.match(end, /forceEndVoice\(claim\)\s*return \.forced/);
  // 第三輪：關頁前先把排著的送出拿出來（見下一個測試），有人看著或有人在排隊就重開。
  assert.match(tap, /func forceEndVoice\(_ claim: VoiceClaim\) \{\s*guard voiceClaim == claim else \{ return \}[\s\S]{0,400}let users = !leases\.isEmpty \|\| !waiting\.isEmpty\s*sleep\(\)/);
  // 語音拿著 Pod 時：排隊的送出等它、會換頁的指令不做、連接器與「新增」拿不到。
  // W197（.056）：Dots 借用同一個 Pod 時送出也先排隊。
  assert.match(tap, /if paging, command != "voice", voiceClaim != nil \{ throw TapError\.remote\("語音模式開著；結束語音再試"\) \}/);
  // 共用的語音控制器：停止中一直留著（voiceStopping），確認停了或關掉那一頁才收；「開始」還沒回來不放。
  const voiceMode = slice(kit, 'final class ChatGPTVoiceMode', '\n}\n');
  assert.match(voiceMode, /@Published private\(set\) var voiceStopping = false/);
  assert.match(voiceMode, /let result = await tap\.endVoice\(claim: claim, stopTimeout: stopTimeout, stateTimeout: stateTimeout, pause: stopPause,/);
  assert.match(voiceMode, /finish\(forcedByUser \? \.forced : result\)/);
  assert.match(voiceMode, /guard self\.tap\.voiceClaim == claim else \{ self\.finish\(\.confirmed\); return \}/);
  // 關掉了語音那一頁：兩邊都說一聲。
  assert.match(read('TAP/ChatGPTConversationSession.swift'), /if voice\.lastEnd == \.forced \{ state = \.failed\("語音那一頁沒有回應，已經關掉那一頁（麥克風停了）；等一下就能再用"\) \}/);
  assert.match(space, /if voice\.lastEnd == \.forced \{ failure = "語音那一頁沒有回應，已經關掉那一頁（麥克風停了）；等一下就能再用" \}/);
});

test('G3 file promises: only regular files directly inside this drop\'s folder, opened without following links, size-capped', () => {
  const receive = slice(space, 'private static func receivePromises(', 'func addData(_ data: Data, name: String, mime: String)');
  // W184 G3 第三輪：上限照類型（圖片 200 MB、其他 20 MB，修正核對 #5）；檔案承諾只收一個名字的檔案（硬連結不收，#4(b)）。
  assert.match(receive, /guard let data = Self\.readReceivedFile\(url, in: directory, limit: Self\.readLimit\(for: url\.lastPathComponent\),\s*singleLink: true\) else \{ refused \+= 1; continue \}/);
  assert.doesNotMatch(receive, /Data\(contentsOf:/, 'no plain read that follows links');
  const reader = slice(space, 'nonisolated static func readReceivedFile(', 'func addData(_ data: Data, name: String, mime: String)');
  assert.match(reader, /let base = directory\.resolvingSymlinksInPath\(\)\.standardizedFileURL\.path/);
  assert.match(reader, /guard parent == base,/);
  assert.match(reader, /open\(path, O_RDONLY \| O_NOFOLLOW \| O_CLOEXEC \| O_NONBLOCK\)/);
  assert.match(reader, /\(info\.st_mode & S_IFMT\) == S_IFREG, info\.st_size >= 0, Int\(info\.st_size\) <= limit,\s*!singleLink \|\| info\.st_nlink == 1/);
  assert.match(reader, /guard parent == base, !name\.isEmpty, name != "\.\.", name != "\.", !name\.contains\("\/"\)/);
});

test('G3 round 3: drops onto the conversation and Finder files use the same safe reader; big photos keep being accepted', () => {
  // 修正核對 #4：拖到對話區（檔案網址、系統交來的圖片暫存檔）與 Finder 的檔案都走 readReceivedFile（不跟隨連結、只收一般檔、先看大小）。
  const attachFiles = slice(space, 'static func attachFiles(_ urls: [URL], into sink: AttachmentSink) {', 'nonisolated static func readLimit(for name: String)');
  assert.match(attachFiles, /guard let raw = readReceivedFile\(url, in: url\.deletingLastPathComponent\(\), limit: readLimit\(for: url\.lastPathComponent\)\) else \{/);
  const providers = slice(space, 'static func attach(providers: [NSItemProvider], into sink: AttachmentSink) -> Bool {', 'nonisolated static func receiveProvidedFile(');
  assert.match(providers, /Self\.attachFiles\(\[url\], into: sink\)/);
  assert.match(providers, /Self\.receiveProvidedFile\(url, fallbackMime: "image\/png", into: sink\)/);
  const provided = slice(space, 'nonisolated static func receiveProvidedFile(', 'private static func receivePromises(');
  assert.match(provided, /guard let data = readReceivedFile\(url, in: url\.deletingLastPathComponent\(\), limit: readLimit\(for: name\)\) else \{/);
  for (const section of [attachFiles, providers, provided]) assert.doesNotMatch(section, /Data\(contentsOf:/, 'no plain read that follows links or reads without a cap');
  // 修正核對 #5：圖片 200 MB（讀進來照舊由 admit 轉 JPEG、合計 20 MB 不變），其他 20 MB。
  assert.match(space, /nonisolated static let imageReadLimit = 200 \* 1024 \* 1024/);
  assert.match(space, /nonisolated static func readLimit\(for name: String\) -> Int \{\s*UTType\(filenameExtension: \(name as NSString\)\.pathExtension\)\?\.conforms\(to: \.image\) == true \? imageReadLimit : attachmentLimit\s*\}/);
});

test('G3 round 3: voice follows the Space screen too; the DM says who holds voice; queued text is never lost', () => {
  const tap = read('TAP/ChatGPTTap.swift');
  const session = read('TAP/ChatGPTConversationSession.swift');
  // 修正核對 #1：Space 主畫面不在了（切到其他模式、關分頁）＝結束 Space 的語音（跟私訊框同一條規則）。
  // W197（.056）：離開 Space 先把借給 Dots 的 Pod 收回來，其餘順序照舊。
  assert.match(space, /func disappear\(\) \{\s*closeDots\(\)\s*visible = false\s*tap\.setSpaceVisible\(false\)\s*(\/\/[^\n]*\n\s*)+voice\.endVoice\(\)/);
  assert.match(space, /private init\(\) \{\s*tap = \.shared\s*voice = ChatGPTVoiceMode\(tap: tap, holderNotice: "ChatGPT Space 的語音模式還開著"\)/);
  // 私訊框：另一邊拿著語音時說一句、給「結束那邊的語音」（請那一邊走它自己的確認結束）。
  assert.match(view, /if let elsewhere = session\.voiceElsewhere \{\s*GlobalDMNoticeRow\(icon: "waveform", text: elsewhere, actionTitle: "結束那邊的語音",\s*identifier: "tatwo\.dm\.voiceElsewhere"\) \{ session\.endVoiceElsewhere\(\) \}/);
  assert.match(session, /var voiceElsewhere: String\? \{\s*guard tap\.voiceClaim != nil, !voice\.holdsVoice else \{ return nil \}/);
  assert.match(tap, /func requestVoiceEnd\(\) -> Bool \{\s*guard voiceClaim != nil, let voiceEndRequest else \{ return false \}\s*voiceEndRequest\(\)/);
  assert.match(kit, /tap\.claimVoice\(owner: owner, holderNotice: holderNotice,\s*onEndRequest: \{ \[weak self\] in self\?\.endVoice\(\) \}\)/);
  // 排在語音後面不能無限期「打字中」：太久就不送、交回畫面放回輸入框（私訊框、Space 都放回）。
  // W203 extends the same deadline to Dots; voice timeout still returns the draft.
  assert.match(tap, /if voiceClaim != nil \|\| dotsLease != nil \{ scheduleQueueDeadline\(id\) \}/);
  assert.match(tap, /self\.voiceClaim != nil \|\| self\.dotsLease != nil \|\| self\.connection != \.ready else \{ return \}[\s\S]*self\.sendQueue\.removeAll \{ \$0\.id == id \}[\s\S]*else \{ self\.streams\[id\]\?\.yield\(\.failed\(Self\.queueTimeoutReason\)\)/);
  assert.match(session, /case \.failed\(let message, _\) where message == ChatGPTTap\.queueTimeoutReason && self\.state == \.queued && !hasResponse:/);
  assert.match(session, /self\.returnedDrafts\.append\(unsent\)[\s\S]*let restored = returnDraft\(unsent\)\s*if restored \{ self\.confirmReturnedDraft\(id\) \}/);
  assert.match(dmStore, /session\.returned = \{ \[weak self\]/);
  assert.match(dmStore, /draft\(for: \.chatGPT\)\.isEmpty && attachments\(for: \.chatGPT\)\.isEmpty && chatGPTTool == nil/);
  assert.match(dmStore, /guard chatGPTOrigin == origin, chatGPTSessionIfCreated\?\.isTemporary == temporary, chatGPTComposerIsEmpty else/);
  assert.match(dmStore, /chatGPTReturnedDrafts\.append\(/);
  assert.match(space, /if message == ChatGPTTap\.queueTimeoutReason, !dispatched, returnable != nil \{ returnedToDraft = true \}/);
  // 交回來＝照「排隊中就停掉」那一條把畫面換回去（stopRequested 在判斷之前設好，中間沒有 await）。
  assert.match(space, /stopRequested = true   \/\/ 沒交給網頁就交回來＝照「排隊中就停掉」把畫面換回去[^\n]*\n\s*\}[^]{0,900}?if stopRequested, !dispatched \{/);
  assert.doesNotMatch(slice(space, 'stopRequested = true   // 沒交給網頁就交回來', 'if stopRequested, !dispatched {'), /await/);
  assert.match(space, /draft: \(text, files, chosenTool\), restore: before\)/);
  // 修正核對 #2：放掉語音一定清旗標；連線狀態變了而沒人拿著也清；語音還是自己的才記「開著」。
  assert.match(slice(tap, '@Published private(set) var connection: TapConnection = .off {', '/// 最近一次送出的串流格式'),
    /if voiceClaim == nil \{\s*voiceOpen = false\s*voiceSeenLive = false\s*\}[\s\S]*if connection == \.ready \{ drainQueue\(\) \}/);
  assert.match(tap, /if voiceClaim == claim \{\s*voiceOpen = true\s*if live \{ voiceSeenLive = true \}\s*\}/);
  // 修正核對 #6：強制關掉語音那一頁時，排著的送出先拿出來、重開好了照順序送（用新網頁的鑰匙重新組指令）。
  const force = slice(tap, 'func forceEndVoice(_ claim: VoiceClaim) {', 'private func scheduleQueueDeadline(');
  assert.match(force, /let waiting = sendQueue\.compactMap \{ item in streams\[item\.id\]\.map \{ \(item, \$0\) \} \}/);
  assert.ok(force.indexOf('for (item, _) in waiting { streams[item.id] = nil }') < force.indexOf('sleep()'), 'taken out before the page is closed');
  assert.match(force, /for \(item, continuation\) in waiting \{\s*streams\[item\.id\] = continuation\s*sendQueue\.append\(item\)/);
  assert.match(force, /let users = !leases\.isEmpty \|\| !waiting\.isEmpty/);
  assert.match(tap, /let script = \(try\? keyedCommandScript\(next\.payload\)\) \?\? next\.script/);
  assert.match(tap, /transport\.run\(script\)\n    \}/);
});

test('G3 identifiers: the DM ones stay; the new buttons get tatwo.dm.<name>', () => {
  for (const id of ['tatwo.dm.input', 'tatwo.dm.attach', 'tatwo.dm.attachments', 'tatwo.dm.send', 'tatwo.dm.stop',
    'tatwo.dm.voice', 'tatwo.dm.tool', 'tatwo.dm.webSearch']) {
    assert.ok(g3Layers.includes(`"${id}"`), id);
  }
  // W184 G3b 追加：聽寫鈕拿掉，它的識別碼跟著不在（自測斷言畫面上沒有 tatwo.dm.dictate）。
  assert.ok(!g3Layers.includes('"tatwo.dm.dictate"'), 'the DM dictation button is gone');
  // 新元件給 tatwo.dm.<名字>。W184 G3c：模型膠囊回到輸入框（識別碼照舊 tatwo.dm.model）；≡ 拿掉了，它的識別碼 tatwo.dm.chatgpt.drawer
  // 留在左緣那一格（VoiceOver 按它打開抽屜）；頂列的新對話拿掉（使用者：新對話照舊用抽屜底部的「聊天」＝tatwo.dm.chatgpt.drawer.newChat）；
  // 右上的臨時聊天是新的 tatwo.dm.chatgpt.temporary。
  assert.ok(g3Layers.includes('"tatwo.dm.model"'), 'tatwo.dm.model');
  for (const id of ['tatwo.dm.chatgpt.drawer', 'tatwo.dm.chatgpt.temporary', 'tatwo.dm.chatgpt.temporaryNote', 'tatwo.dm.chatgpt.drawer.panel',
    'tatwo.dm.chatgpt.drawer.newChat', 'tatwo.dm.chatgpt.suggestions']) {
    assert.ok(nav.includes(`"${id}"`), id);
  }
  assert.ok(!nav.includes('"tatwo.dm.chatgpt.newChat"'), 'the top-bar new chat is gone (the drawer\'s 「聊天」 stays)');
  assert.ok(g3Pane.includes('"tatwo.dm.slash"') && g3Pane.includes('"tatwo.dm.plusMenu"'));
  assert.ok(g3Pane.includes('"tatwo.dm.voiceMode"') && g3Pane.includes('"tatwo.dm.voiceMode.stop"'));
  // ChatGPT Space 的識別碼照舊（預設值在共用元件裡）。
  for (const id of ['var identifier = "chatgpt.plus"', 'var identifier = "chatgpt.modelPicker"', 'var voice = "chatgpt.voice.start"',
    'var send = "chatgpt.send"']) {
    assert.ok(kit.includes(id), id);
  }
  assert.ok(pages.includes('var identifier = "chatgpt.voice"'));
  assert.ok(pages.includes('var identifier = "chatgpt.send"'));
});

test('G3 self-test in w184chat: rules, fake-Pod actions, drawn states and PNG evidence', () => {
  const acceptance = read('DM/GlobalDMChatAcceptance.swift');
  assert.match(acceptance, /for \(condition, label\) in await chatGPTComposerChecks\(root: root, model: model, artifacts: artifacts, axWorks: axWorks\) \{\s*check\(condition, label\)/);
  const g3test = read('DM/GlobalDMChatGPTComposerAcceptance.swift');
  assert.match(g3test, /^#if DEBUG/);
  for (const label of ['G3 DM ChatGPT composer: every font size is a phone token (17/15/13/11)',
    'G3 ChatGPT Space keeps its own numbers', 'G3 send slot like the web', 'G3 ＋ first level', 'G3 ＋ second level', 'G3 ＋ 更多',
    'G3 picker words like the web', 'G3 admit: images ChatGPT cannot read become JPEG', 'G3 admit: over 20 MB',
    'G3 DM send: the tool (as ChatGPT Space sends it), the picked level and the three files reach ChatGPT',
    'G3 DM paste (ChatGPT Space\'s intake)', 'G3 DM drop onto the conversation', 'G3 DM: Esc closes the card first',
    'G3 DM voice mode starts in the DM\'s own conversation', 'G3 DM: Esc ends voice mode first, even with Browser open',
    'G3 voice owner: the DM takes the voice before the start goes to the page', 'G3 voice owner: while the DM holds voice, ChatGPT Space cannot start',
    'G3 voice: Return and send do nothing while voice is on', 'G3 voice: the session itself refuses text while its voice is on',
    'G3 TAP: a send from the other side waits in the queue while voice holds the page', 'G3 TAP: commands that would move the page are refused',
    'G3 DM voice end: the stop is confirmed, then only the DM\'s own conversation comes back',
    'G3 voice owner: while ChatGPT Space\'s answer is running the DM cannot start voice',
    'G3 voice owner: while the DM\'s answer is running ChatGPT Space cannot start voice',
    'G3 voice owner: while ChatGPT Space holds voice the DM\'s wave button is off', 'G3 voice owner: the DM leaving the screen never ends ChatGPT Space\'s voice',
    'G3 voice ends when', 'G3 stop not confirmed yet: the voice screen stays', 'G3 stop never answered: after two tries the voice page is closed',
    'G3 stop acknowledged but the page still listens', 'G3 pressing 結束 (or Esc) again while stopping closes the voice page right away',
    'G3 revision: a late voice transcript does not replace the newer answer', 'G3 voice from a new chat: the DM takes the conversation it saw while live',
    'G3 voice from a new chat stopped right away', 'G3 ChatGPT Space voice: stopping while connecting voids the late start',
    'G3 ChatGPT Space voice: after 結束 while connecting, the voice stays claimed',
    'G3 dictation: the mic in the docked box makes the box key and dictates into its own input', 'G3 dictation: closing the box or switching target before it starts cancels it',
    'G3 dictation: switching away before it starts does not dictate anywhere', 'G3 dictation: a box that went away never starts dictation',
    'G3 file promise: a regular file inside this drop\'s folder is read', 'G3 file promise: a symlink to a file outside is refused',
    'G3 file promise: paths outside this drop\'s folder', 'G3 file promise: folders, nested files and non-regular files (a pipe) are refused',
    'G3 file promise: over the size limit is refused before reading',
    'G3 recent apps: an app picked in the 內橫 right column comes first in the left column\'s and ChatGPT Space\'s ＋ (one list)',
    'G3 file promise: a second name for the same file (hard link) is refused for promised files',
    'G3 large photos: a 21 MB TIFF scan is still accepted', 'G3 drop onto the conversation: a file URL that is a symlink is refused',
    'G3 drop onto the conversation: the system\'s image file goes through the same reader',
    'G3 voice elsewhere: the DM says 「ChatGPT Space 的語音模式還開著」', 'G3 voice elsewhere: 「結束那邊的語音」 asks ChatGPT Space\'s voice to end',
    'the ［連線］ sheet covering the box', 'G3 voice flags: after the page asked to log in again mid-voice and came back',
    'G3 voice flags: a voice that never went live and whose stop got no answer still clears the flags',
    'G3 queued behind the other side\'s voice: after the time limit the text goes back into the DM\'s input',
    'G3 forced close keeps the other side\'s queued message',
    'G3 other targets unchanged',
    'G3 (drawn) the voice-mode button is 30pt in ChatGPT Space and 36pt in the DM', 'G3 drawn: empty composer', 'G3 drawn: typing',
    'G3 drawn: tool card + thumbnails', 'G3 drawn: while ChatGPT answers the slot is stop', 'G3 drawn: the thinking card floats',
    'G3 (drawn) the two photos show as thumbnails above the text']) {
    assert.ok(g3test.includes(label), label);
  }
  for (const png of ['chatgpt-empty.png', 'chatgpt-typing.png', 'chatgpt-tool-attachments.png', 'chatgpt-answering.png',
    'chatgpt-model-card.png', 'chatgpt-voice.png', 'chatgpt-voice-stopping.png', 'chatgpt-voice-elsewhere.png']) {
    assert.ok(g3test.includes(`"${png}"`), png);
  }
  // 假 Pod 不開網頁、不連外；剪貼簿用私有的；沒有無條件的通過。
  assert.match(g3test, /NSPasteboard\(name: NSPasteboard\.Name\("ai\.tatwo\.selftest\.w184g3\./);
  // 縮圖是元件自己的 .task 讀的：截圖前先讓出主執行緒（不然截到的是空白底）。
  assert.match(g3test, /let shot = await settle\(first\)/);
  assert.doesNotMatch(g3test, /NSPasteboard\.general|check\(true,|URLSession|https?:\/\//);
});

// ---- W184 G3b（使用者 09-29 17:35 真機驗收 .030：「chatgpt沒有新對話、專案、過去對話、/指令」「＋號也跟chatgpt原版的快捷小視窗不一樣」
// 「字的滑動天地改漸出 現在是切線」；17:50 改方向：「ChatGPT私訊鈕版面改這樣」「左列專案改用滑鼠指到左側滑出 跟瀏覽器右側一樣」＋ChatGPT iPhone App 截圖）----
// 畫面、動作與 PNG 在 `TATWO2_SELFTEST=w184chat` 的 G3b 那一段（DM/GlobalDMChatGPTNavigationAcceptance.swift）。

test('G3b／G3c top bar: the page circle stays top-left; only 臨時聊天 top right while the ChatGPT column is on the phone (no ≡, model name or new chat)', () => {
  const bar = slice(phoneBox, 'struct GlobalDMTopBar: View', 'enum GlobalDMTopBarLayout');
  // 守：頂列本身不看 Browser、不放名字行（W184 AB／F 的規則照舊）；ChatGPT 那一欄的寬由手機框給（環境值），頂列只照它排。
  assert.match(bar, /@Environment\(\\\.globalDMChatGPTTopWidth\) private var chatGPTWidth/);
  // 守：只在 ChatGPT 那一欄在手機上時才排（寬＝那一欄扣左右留白）；看著對話本身（臨時聊天開著沒、回答中與語音開著時變淡）。
  assert.match(bar, /if let chatGPTWidth \{\s*GlobalDMChatGPTTopControls\(store: store, session: store\.chatGPT, width: max\(0, chatGPTWidth - margin \* 2\)\)\s*\}/);
  // 頁面圓鈕畫在上面一層（指到向右展開時蓋在上面）。
  assert.ok(bar.indexOf('GlobalDMChatGPTTopControls(') < bar.indexOf('GlobalDMIconStrip(store: store, besideBrowser: form.isDuo)'));
  assert.match(phoneBox, /private var chatGPTColumnShown: Bool \{\s*store\.target == \.chatGPT && !\(store\.isBrowsing && !form\.isDuo\) && store\.chatGPTAvailable\s*\}/);
  assert.match(phoneBox, /\.environment\(\\\.globalDMChatGPTTopWidth, chatGPTColumnShown \? look\.chatWidth\(in: width\) : nil\)/);
  const controls = slice(nav, 'struct GlobalDMChatGPTTopControls: View', 'struct GlobalDMChatGPTRoundButton: View');
  // W184 G3c（使用者：「chatgpt的展開鈕是多餘的 我們只要滑鼠指到左側展開即可」「右上隱私對話鈕無效 ui也跟原版不同」）：守——頂列沒有 ≡、
  // 沒有模型名、沒有新對話；右上只有一顆：ChatGPT 的臨時聊天，圖示跟 ChatGPT Space 同一個（虛線對話泡泡；開著＝實線＋選中的玻璃圓），按了真的開關。
  assert.doesNotMatch(code(controls), /line\.3\.horizontal|toggleChatGPTDrawer|ChatGPTPickerCapsule|newChatGPTConversation|systemName: "message"/);
  assert.match(controls, /Button \{\s*store\.toggleChatGPTTemporary\(\)\s*temporaryChoicePresented = blocker == nil && session\.temporary && session\.conversationID == nil && session\.messages\.isEmpty\s*\} label: \{\s*ChatGPTTemporaryChatIcon\(active: temporary\)/);
  assert.match(controls, /let temporary = session\.isTemporary/);
  assert.match(controls, /\.background \{ GlobalDMGlassCircle\(isSelected: temporary\) \}/);
  assert.match(controls, /\.help\(blocker \?\? ChatGPTTemporaryChatText\.help\(active: temporary\)\)/);
  assert.match(controls, /\.accessibilityIdentifier\("tatwo\.dm\.chatgpt\.temporary"\)/);
  // 圖示與字只有一份（ChatGPT Space 用同一個；Space 的樣子與行為不變：一樣的字）。
  assert.equal(count(pages, 'struct ChatGPTTemporaryChatIcon: View'), 1);
  assert.match(pages, /enum ChatGPTTemporaryChatText \{\s*static let title = "臨時聊天"/);
  assert.match(pages, /static func help\(active: Bool\) -> String \{ active \? "關閉臨時聊天" : "開啟臨時聊天：不會出現在紀錄裡" \}/);
  assert.match(space, /ChatGPTTemporaryChatIcon\(active: model\.temporaryChat\)/);
  assert.match(space, /\.help\(ChatGPTTemporaryChatText\.help\(active: model\.temporaryChat\)\)/);
  assert.match(space, /Text\(model\.temporaryPersonalized \? ChatGPTTemporaryChatText\.personalizedNote : ChatGPTTemporaryChatText\.note\)/);
  // 截圖中間的「對話｜工作」不放（TAP 一律切在「對話」、「工作」送不出去）。
  assert.doesNotMatch(nav, /"工作"/);
  // 守：模型面板浮在輸入框裡那顆膠囊上面（同 ChatGPT Space）；共用的浮動層只剩「往上浮」一種（G3b「浮在頂列下面」拿掉），Space 不變。
  assert.match(g3Pane, /ChatGPTFloatingCardLayer\(anchor: anchor, isOpen: store\.target == \.chatGPT && store\.isChatGPTModelCardOpen && store\.canChooseModel,\s*width: ChatGPTEffortCardMetrics\.width, dismiss: \{ store\.closeChatGPTModelCard\(\) \}\)/);
  assert.match(g3Pane, /\.transformPreference\(ChatGPTPickerAnchorKey\.self\) \{ \$0 = nil \}/);
  assert.doesNotMatch(code(kit), /var below|if below/);
  assert.match(kit, /VStack\(spacing: 0\) \{\s*Spacer\(minLength: 0\)\s*card\(\)\.layoutPriority\(leading \? 1 : 0\)/);
  assert.doesNotMatch(phoneBox + g3 + nav, /GlobalDMChatGPTModelCardLayer/);
});

test('G3b／G3c drawer: the 22pt left edge slides it out over a still main screen (no ≡, no handle drawn); ChatGPT Space\'s list, DM actions', () => {
  const layer = slice(nav, 'struct GlobalDMChatGPTDrawerLayer<Directory: ChatGPTConversationDirectory>: ViewModifier', '/// 同上，包成一個畫面');
  // W184 G3c（使用者：「左側展開時會把對話筐推去右邊修正對話筐為不動」，蓋過 G3b 的推開）：守——抽屜蓋在主畫面上面一層，
  // 主畫面不移、不裁、不變暗；點抽屜外面＝收（不點到底下的東西）。
  assert.match(layer, /ZStack\(alignment: \.topLeading\) \{\s*(?:\/\/[^\n]*\n\s*)+content\s*\.frame\(width: proxy\.size\.width, height: proxy\.size\.height\)/);
  assert.ok(layer.indexOf('content\n') < layer.indexOf('GlobalDMChatGPTDrawer(store: store, session: store.chatGPT, directory: directory)'), 'the drawer is drawn over the content');
  assert.doesNotMatch(code(layer), /\.offset\(x:|pushedDim|clipShape|drawerFill/);
  assert.doesNotMatch(nav, /pushedDim/);
  assert.match(layer, /\.onTapGesture \{ store\.closeChatGPTDrawer\(\) \}/);
  // 只裁抽屜那一層（滑進滑出不露到框外、內橫右欄不蓋到左欄）；主畫面不在這裡裁（訊息列表要往上延伸到框的上緣）。
  assert.match(layer, /ZStack\(alignment: \.topLeading\) \{\s*if open \{\s*GlobalDMChatGPTDrawer\(store: store, session: store\.chatGPT, directory: directory\)[\s\S]*?\}\s*(?:\/\/[^\n]*\n\s*)*\.frame\(width: proxy\.size\.width, height: proxy\.size\.height, alignment: \.topLeading\)\s*\.clipped\(\)/);
  assert.equal(count(code(layer), '.clipped()'), 1);
  // 左緣 22 寬的判斷區（頂列以下）指到就開；滑鼠離開抽屜：指到才開的收、釘住的留著。
  assert.match(nav, /static let handleStrip: CGFloat = 22/);
  assert.match(layer, /\.frame\(width: GlobalDMChatGPTDrawerLayout\.handleStrip, height: max\(0, proxy\.size\.height - DMPhone\.headerHeight\)\)[\s\S]{0,120}\.onHover \{ inside in if inside \{ store\.openChatGPTDrawer\(pinned: false\) \} \}/);
  assert.match(layer, /\.onHover \{ inside in if !inside \{ store\.chatGPTDrawerHoverEnded\(\) \} \}/);
  // 守：滑鼠移到抽屜外面的主畫面＝離開抽屜（抽屜滑出時剛好蓋在指標下、沒收到「進入」就移走也照樣收）。
  assert.match(layer, /\.onTapGesture \{ store\.closeChatGPTDrawer\(\) \}\s*\.onHover \{ inside in if inside \{ store\.chatGPTDrawerHoverEnded\(\) \} \}/);
  // W184 G3c（使用者：「左側展開槓也是多餘的」）：守——判斷區照舊、不畫槓（不用 Browser 的直把手）；VoiceOver 按這一格＝打開（釘住），
  // ≡ 的識別碼留在這一格。
  assert.match(layer, /Color\.clear\s*\.frame\(width: GlobalDMChatGPTDrawerLayout\.handleStrip/);
  assert.doesNotMatch(code(layer), /DMBrowserHandle/);
  assert.match(layer, /\.accessibilityAction \{ store\.openChatGPTDrawer\(pinned: true\) \}\s*\.accessibilityIdentifier\("tatwo\.dm\.chatgpt\.drawer"\)/);
  assert.match(nav, /func chatGPTDrawerHoverEnded\(\) \{\s*guard isChatGPTDrawerOpen, !chatGPTDrawerPinned else \{ return \}/);
  assert.match(nav, /func toggleChatGPTDrawer\(\) \{\s*if isChatGPTDrawerOpen \{ closeChatGPTDrawer\(\) \} else \{ openChatGPTDrawer\(pinned: true\) \}/);
  assert.match(phoneBox, /\.modifier\(GlobalDMChatGPTDrawerLayer\(store: store, enabled: chatGPTColumnShown, directory: ChatGPTSpaceModel\.shared\)\)/);
  // 內容照截圖：ChatGPT＋搜尋；圖庫、專案、外掛程式、已排程（Space 的頁；「遠端」「探索」Space 沒有，不列）；已釘選；最近；「聊天」＋齒輪。
  const drawer = slice(nav, 'struct GlobalDMChatGPTDrawer<Directory: ChatGPTConversationDirectory>: View', 'struct GlobalDMChatGPTDrawerRow: View');
  for (const piece of ['Text("ChatGPT")', '"圖庫"', 'title: "專案"', '"外掛程式"', '"已排程"', 'sectionTitle("已釘選")', 'Label("聊天", systemImage: "square.and.pencil")',
    'Image(systemName: "gearshape")', 'directory.directoryOpenSettings()', 'store.openChatGPTSpacePage(']) {
    assert.ok(drawer.includes(piece), piece);
  }
  assert.doesNotMatch(drawer, /"遠端"|"探索"/);
  // 資料讀 ChatGPT Space 那一份；Space 用自己的 conversations／projects／pinned／suggestions／頁面／TAP 設定接上。
  const conformance = slice(space, 'extension ChatGPTSpaceModel: ChatGPTConversationDirectory {', '// MARK: - 側欄：釘選、專案、對話');
  for (const piece of ['var directoryConversations: [TapConversation] { conversations }', 'var directoryProjects: [TapFolder] { projects }',
    'var directoryPinned: [TapFolder] { pinned }', 'var directorySuggestions: [TapSuggestion] { suggestions }',
    'func directoryOpen(_ page: ChatGPTPage) { open(page) }', 'func directoryOpenSettings() { openTapSettings() }',
    // W199：未就緒也要進入正式喚醒／期限流程，不能把第一次載入跳過而留下空白。
    'if !loadedOnce { Task { await refresh() } }']) {
    assert.ok(conformance.includes(piece), piece);
  }
  assert.match(space, /var groupedConversations: \[ConversationGroup\] \{ Self\.grouped\(filteredConversations\) \}/);
  // 點一則＝私訊框自己的對話換到那一則（只在記憶體），草稿（字、附件、工具小卡）各則自己的；回答中、語音開著不換。
  // W184 G3b 第二輪（審查 #1）：每換一次對話記一次（晚到的附件分得出該放哪一則）。
  assert.match(nav, /shelveChatGPTDraft\(for: session\.conversationID\)\s*chatGPTDraftGeneration \+= 1\s*session\.open\(conversationID: id\)\s*unshelveChatGPTDraft\(for: id\)/);
  assert.match(nav, /shelveChatGPTDraft\(for: session\.conversationID\)\s*chatGPTDraftGeneration \+= 1\s*session\.newConversation\(\)\s*unshelveChatGPTDraft\(for: nil\)/);
  assert.match(nav, /if session\.voice\.voiceActive \{ return "語音模式開著；結束語音再換對話" \}\s*if session\.isSending \{ return "ChatGPT 正在回答；等它結束再換對話" \}/);
  const session = read('TAP/ChatGPTConversationSession.swift');
  assert.match(session, /func open\(conversationID id: String\) \{\s*guard requestID == nil, !voice\.voiceActive else \{ return \}\s*revision \+= 1/);
  assert.match(session, /self\.revision == expected, self\.conversationID == id, self\.requestID == nil else \{ return \}/);
});

test('G3b composer and ＋ card like the ChatGPT iPhone app; 「/」 commands; suggestions when empty', () => {
  // 佔位字「問問 ChatGPT」。W184 G3c（使用者：「chatgpt duo輸入筐造型r角很醜」）：輸入框的底跟其他對象同一個玻璃膠囊（同心 40）——
  // G3b 那個實心灰底（composerFill）拿掉；守：只有一個底、圓角照舊是框的同心圓角。
  assert.match(composer, /\.liquidGlassPanelSurface\(cornerRadius: GlobalDMChatLayout\.composerRadius\)/);
  assert.match(view, /: session\.state == \.needsLogin \? "先登入 ChatGPT" : "問問 ChatGPT",/);
  assert.doesNotMatch(code(pages + view), /composerFill|struct GlobalDMComposerSurface/);
  // ＋ 小卡：照片、檔案、（私訊框）貼上、外掛程式 ›（換頁：工具＋App）、認真思考 ✓；圓形底的圖示；不是系統選單、沒有藍色反白。
  assert.match(quick, /var rows = \[ChatGPTQuickMenuRow\(id: "photos", symbol: "photo", title: "照片"\),\s*ChatGPTQuickMenuRow\(id: "files", symbol: "paperclip", title: "檔案"\)\]/);
  assert.match(quick, /rows\.append\(ChatGPTQuickMenuRow\(id: "plugins", symbol: "at", title: "外掛程式", selected: pluginSelected, opens: true\)\)/);
  assert.match(quick, /rows\.append\(ChatGPTQuickMenuRow\(id: "thinking", symbol: "gauge\.with\.dots\.needle\.67percent", title: "認真思考", selected: thinking\)\)/);
  assert.match(quick, /\.background\(Circle\(\)\.fill\(ChatGPTPalette\.pressed\)\)/);
  assert.match(quick, /label\(background: highlighted \? LiquidGlassTokens\.brandAccent\.opacity\(0\.14\) : \(hover \? ChatGPTPalette\.hover : Color\.clear\)\)/);
  assert.match(quick, /\.lineLimit\(1\)\s*\.truncationMode\(\.tail\)/);
  // 守：卡片跟著內容高、最多 maxHeight 才捲動（ScrollView 自己會撐滿可用高度＝留一大片空白；硬撐 fixedSize＝內容多時捲不動）；
  // 按鈕上面放不下時跟著縮、一樣可以捲；「/」上下鍵選到看不見的那一列會捲過去。
  assert.match(quick, /let height = min\(Self\.contentHeight\(sections, metrics: metrics\), Self\.maxHeight\)/);
  assert.match(quick, /\.frame\(minHeight: 0, idealHeight: height, maxHeight: height\)/);
  assert.match(quick, /\.onChange\(of: highlighted\) \{ _, id in\s*guard let id else \{ return \}\s*proxy\.scrollTo\(id\)/);
  assert.doesNotMatch(quick, /\.fixedSize\(horizontal: false, vertical: true\)/);
  // 認真思考＝兩段式的推理強度（勾＝想比較久的那一檔以上；取消＝最輕的一檔），ChatGPT Space 與私訊框同一條規則。
  assert.match(kit, /func toggleThinkingHard\(\) \{[\s\S]{0,200}pickerChoose\(effort: thinkingHard \? lightest\.id : target\)/);
  // 「/」：輸入框最前面打 / 才開；上下鍵選、Enter 選定＝工具小卡；Esc 只收小視窗（routeEscape → dismissChatGPTLayers 的第一層）。
  // W184 G3b 第二輪：規則抽成 ChatGPTSlash（ChatGPT Space 的輸入框同一條）。
  assert.match(quick, /guard text\.hasPrefix\("\/"\), !text\.dropFirst\(\)\.contains\(where: \{ \$0\.isWhitespace \|\| \$0\.isNewline \}\), dismissed != text else \{ return nil \}/);
  assert.match(nav, /return ChatGPTSlash\.query\(draft\(for: \.chatGPT\), dismissed: chatGPTSlashDismissed\)/);
  assert.match(g3Layers, /onSuggestionKey: \{ store\.handleChatGPTSlashKey\(\$0\) \}/);
  // 守：第一列再往上不吃（交還輸入框）；W184 G3b 第二輪起輸入框只交沒修飾鍵的 ↑↓（←→ 照常給游標，見 suggestionKeysVerticalOnly）。
  assert.match(quick, /case \.prev: return current > 0 \? current - 1 : nil/);
  assert.match(dmStore, /func dismissChatGPTLayers\(\) -> Bool \{\s*if chatGPTSlashOpen \{\s*chatGPTSlashDismissed = draft\(for: \.chatGPT\)\s*return true\s*\}/);
  const esc = slice(read('DM/GlobalDMPanelController.swift'), 'static func routeEscape(', '// MARK: - 換形態');
  assert.ok(esc.indexOf('store.dismissChatGPTLayers()') > 0 && esc.indexOf('store.dismissChatGPTLayers()') < esc.indexOf('if store.isPickerOpen'));
  // 空白時：建議（ChatGPT 給的；沒有就是最近 3 則）。
  assert.match(nav, /return suggestions\.prefix\(3\)\.map/);
  assert.match(nav, /return recent\.prefix\(3\)\.map/);
  // 守：建議與最近的對話都還沒有（剛連上、清單還沒讀到）時不是一片空白：照舊一行說明。
  assert.match(nav, /if items\.isEmpty \{[\s\S]{0,200}Text\("問 ChatGPT 任何事；用你自己的 ChatGPT 帳號。"\)/);
  // 守：建議只在新對話（沒有代號）；換到的舊對話讀取中、讀不到不當成空的新對話（審查 #3）。
  // W184 G3c：臨時聊天開著的新對話是臨時聊天的說明（同 ChatGPT Space），不列建議。
  assert.match(view, /if session\.messages\.isEmpty, isAvailable, session\.conversationID == nil \{\s*if session\.temporary \{[\s\S]{0,160}GlobalDMChatGPTTemporaryNote\(personalized: session\.temporaryPersonalized\)\s*\} else \{[\s\S]{0,200}GlobalDMChatGPTSuggestions\(store: store, directory: directory\)/);
  // 不動使用者的檔案：挑照片只從「圖片」資料夾開始（沒有 FileManager、沒有寫檔）。
  assert.doesNotMatch(dmStore, /FileManager|\.write\(to:/);
});

test('G3b messages fade at the top and bottom edges (every target); ChatGPT bubbles and 「思考」 like the app', () => {
  const list = slice(view, 'struct GlobalDMMessageList: View', 'struct GlobalDMEdgeFade: ViewModifier');
  // 守：上下緣各 24 漸出（不是一刀切），捲到最上面／最下面那一邊不遮（最後一則完整清楚）；所有對象都用這一個列表。
  assert.match(list, /static let edgeFade: CGFloat = 24/);
  // 守：每一則照它在捲動區裡的位置自己淡出（GlobalDMEdgeFade）；不遮整個 ScrollView——Coder 對話區遮整個 ScrollView 在 live 大視窗
  // 會把內文遮成透明（ChatPage+Transcript 拿掉過），列表本身不能再有 .mask。
  assert.match(list, /row\(bubble, rowWidth: rowWidth\)\s*\.modifier\(GlobalDMEdgeFade\(id: bubble\.id, viewport: viewportHeight, isFirst: index == 0,\s*isLast: index == bubbles\.count - 1, topInset: topInset\)\)/);
  assert.doesNotMatch(list, /\.mask[ ({]/);
  const fade = slice(view, 'struct GlobalDMEdgeFade: ViewModifier', 'struct GlobalDMComposer: View');
  assert.match(fade, /content\.mask \{\s*GeometryReader \{ proxy in\s*let frame = proxy\.frame\(in: \.named\(GlobalDMMessageList\.space\)\)/);
  assert.match(fade, /GlobalDMMessageList\.fadeStrength\(rowMinY: frame\.minY, rowMaxY: frame\.maxY, viewport: viewport,\s*isFirst: isFirst, isLast: isLast, topInset: topInset\)/);
  assert.match(fade, /GlobalDMMessageList\.fadeStops\(rowMinY: frame\.minY, rowHeight: frame\.height, viewport: viewport,\s*top: strength\.top, bottom: strength\.bottom\)/);
  // 守：強度每一則自己算（不靠整個列表的狀態，捲動時連續）：第一則照離內容最上面捲開多遠、最後一則照離最下面多遠，0→24 從 0 到 1；中間都是 1。
  // W184 G3c：「內容最上面」＝listTop＋頂列那一段的邊距（topInset；沒延伸時照舊是 listTop）。
  assert.match(list, /topInset: CGFloat = GlobalDMChatLayout\.listTop\) -> \(top: CGFloat, bottom: CGFloat\) \{\s*let top = isFirst \? min\(1, max\(0, \(topInset - rowMinY\) \/ edgeFade\)\) : 1/);
  assert.match(list, /let bottom = isLast \? min\(1, max\(0, \(rowMaxY \+ GlobalDMChatLayout\.listBottom - viewport\) \/ edgeFade\)\) : 1/);
  assert.match(list, /let fromTop = min\(1, max\(0, y \/ edgeFade\)\), fromBottom = min\(1, max\(0, \(viewport - y\) \/ edgeFade\)\)\s*return Double\(min\(1 - top \* \(1 - fromTop\), 1 - bottom \* \(1 - fromBottom\)\)\)/);
  assert.doesNotMatch(list, /@State private var atTop|onPreferenceChange/, 'no list-wide state for the fade');
  assert.equal(count(view, 'GlobalDMMessageList(bubbles:'), 2, 'assistant/sessions and ChatGPT use the same list');
  // ChatGPT 的樣子走環境值（泡泡反白、灰字「思考」），其他對象照舊。
  assert.match(list, /\.environment\(\\\.globalDMChatGPTLook, chatGPTLook\)/);
  assert.match(read('DM/GlobalDMMessageText.swift'), /@Environment\(\\\.globalDMChatGPTLook\) private var inverse/);
  assert.match(read('DM/GlobalDMChatPhone.swift'), /if chatGPTLook \{\s*Text\("思考"\)/);
  // 自測：G3b 那一段接進 w184chat，PNG 都存。
  const acceptance = read('DM/GlobalDMChatAcceptance.swift');
  assert.match(acceptance, /for \(condition, label\) in await chatGPTNavigationChecks\(root: root, model: model, artifacts: artifacts, axWorks: axWorks\) \{\s*check\(condition, label\)/);
  const g3b = read('DM/GlobalDMChatGPTNavigationAcceptance.swift');
  assert.match(g3b, /^#if DEBUG/);
  for (const png of ['chatgpt-main.png', 'chatgpt-drawer.png', 'chatgpt-plus-card.png', 'chatgpt-plus-plugins.png', 'chatgpt-slash.png', 'chatgpt-fade.png',
    'chatgpt-composer-empty.png', 'chatgpt-composer-text.png']) {
    assert.ok(g3b.includes(`"${png}"`), png);
  }
  for (const label of ['G3b empty chat: suggestions', 'G3b drawer: pinned (VoiceOver on the left edge) opens and keeps it',
    'G3c (drawn) the drawer covers the left side and the main screen stays put',
    'G3b drawer: a past conversation switches the DM to it', 'G3b new chat: clears the current one', 'G3b drafts stay with their own conversation',
    'G3b while ChatGPT answers the DM does not switch', 'G3b ＋ card like the iPhone app', 'G3b ＋ › 外掛程式', 'G3b 認真思考',
    'G3b Esc closes the ＋ card only', 'G3b 「/」: typing / at the start', 'G3b 「/」: Esc closes only the list', 'G3b fade mask: the top and bottom 24pt ramp in',
    'G3b fade: at the bottom the bottom edge is not faded', 'G3b (drawn) scrolled to the bottom',
    // W184 G3b 追加：輸入框特寫（沒字、有字）量字級＝ChatGPT Space；畫面上沒有聽寫鈕。
    'G3b 追加 drawn: the DM ChatGPT input (typed text and placeholder) is ChatGPT Space\'s size', 'G3b 追加 drawn composer']) {
    assert.ok(g3b.includes(label), label);
  }
  assert.match(g3b, /lacks: \["tatwo\.dm\.dictate"\]/);
  assert.ok(read('DM/GlobalDMChatGPTComposerAcceptance.swift').includes("G3b 追加: the DM ChatGPT input text and placeholder are ChatGPT Space's size"));
  // 假資料用一般的名字（不放使用者的私人對話、專案名）；不開網頁、不叫出主視窗。
  assert.doesNotMatch(g3b, /NSPasteboard\.general|check\(true,|URLSession|https?:\/\/|NSApp\.activate/);
});

// W184 G3b 第二輪：使用者「對不起 chatgpt私訊的快捷指令直接參照chatgpt gpt那邊有什麼 這邊chatgpt space、duo就有什麼」；
// GPT-6 審 51a16baa 的 1 高 8 中；主導看 PNG 的三條。每一條旁邊寫守什麼。
test('G3b 第二輪: ChatGPT-only shortcuts, review fixes 1–8 and the lead\'s three PNG notes', () => {
  const tap = read('TAP/ChatGPTTap.swift');
  const session = read('TAP/ChatGPTConversationSession.swift');
  const bridges = read('Chat/ChatPageAppKitBridges.swift');
  // A：「/」與 ＋ 只放 ChatGPT 那邊有的（TAP 讀到的那一份）；從沒讀過＝一行說明（不自己編）；私訊框與 Space 同一份規則、同一個元件。
  assert.match(quick, /@MainActor\s*enum ChatGPTSlash \{/);
  assert.match(quick, /static let notice = ChatGPTQuickMenuRow\(id: "none", symbol: "info\.circle", title: "還沒讀到 ChatGPT 的指令清單",/);
  assert.match(quick, /query != nil && \(catalog\.isEmpty \|\| !matches\.isEmpty\)/);
  assert.match(nav, /ChatGPTSlash\.isOpen\(query: chatGPTSlashQuery, catalog: chatGPTCatalog\.tools, matches: chatGPTSlashTools\)/);
  assert.match(g3Pane, /ChatGPTQuickMenu\(sections: ChatGPTSlash\.sections\(tools, catalogEmpty: store\.chatGPTCatalog\.tools\.isEmpty,/);
  assert.match(space, /ChatGPTQuickMenu\(sections: ChatGPTSlash\.sections\(tools, catalogEmpty: model\.tools\.isEmpty,/);
  // 網路搜尋只用 ChatGPT 列出來的那一個（不自己編一個 TapTool）。
  assert.doesNotMatch(code(nav), /TapTool\(id: Self\.chatGPTWebSearchToolID/);
  assert.match(nav, /guard let tool = chatGPTWebSearchTool else \{/);
  // 審查 #1：附件照開始收的那一則放（沒換過對話或又換回那一則＝輸入框；中途換走＝那一則收起來的草稿）；選檔視窗打開時就記下。
  assert.match(dmStore, /let here = origin\.generation == current\.generation \|\| origin\.key == current\.key/);
  assert.match(dmStore, /let origin = target == \.chatGPT \? chatGPTOrigin : nil\s*NSApp\.activate/);
  // 審查 #2：內橫右欄的 ChatGPT 有自己的控制，抽屜也在右欄裡（綁右欄自己的 store）。W184 G3c：那一排只剩臨時聊天、蓋在它的列表上面；
  // 模型膠囊在右欄自己的輸入框裡，面板浮在它上面、膠囊位置不往上傳（左欄那一層拿不到右欄的膠囊）。
  assert.match(view, /private var ownsControls: Bool \{ role == \.duoTrailing && isAvailable \}/);
  assert.match(view, /\.overlay\(alignment: \.top\) \{\s*if ownsControls \{\s*GeometryReader \{ proxy in\s*GlobalDMChatGPTTopControls\(store: store, session: session, width: proxy\.size\.width\)/);
  assert.match(nav, /if enabled \{\s*content\.modifier\(GlobalDMChatGPTDrawerLayer\(store: store, enabled: true, directory: directory\)\)/);
  assert.match(g3Pane, /\.transformPreference\(ChatGPTPickerAnchorKey\.self\) \{ \$0 = nil \}/);
  // 審查 #3：讀取中、讀不到、新對話分開；讀取中與讀不到不能送；讀不到說出來、有「重試」；同一則再點＝重讀。
  assert.match(session, /enum LoadState: Equatable \{\s*case none\s*case loading\s*case loaded\s*case failed\(String\)/);
  assert.match(session, /case \.loading: return "這則還在讀取，讀完再送"/);
  assert.match(nav, /guard id != session\.conversationID else \{\s*session\.retryLoad\(\)/);
  assert.match(view, /identifier: "tatwo\.dm\.chatgptLoadFailed"\) \{ session\.retryLoad\(\) \}/);
  // 審查 #4：接著舊對話送＝接在私訊框看到的那一支後面；同一則在別的地方（Space、另一欄）送完一輪＝私訊框重讀正本。
  assert.match(session, /let parent = conversationID == nil \? nil : seenLeaf/);
  assert.match(session, /updateWatch = tap\.\$conversationUpdate\.compactMap \{ \$0 \}\.sink/);
  assert.match(tap, /conversationUpdate = TapConversationUpdate\(conversationID: updated, requestID: id, serial: conversationUpdateSerial\)/);
  // 審查 #5：私訊框新建的對話會讓清單重讀；抽屜有「載入更多」；搜尋先問伺服器（查全部），查不了就說只查了已載入的。
  assert.match(space, /conversationUpdateWatch = tap\.\$conversationUpdate\.compactMap \{ \$0 \}\.sink/);
  assert.match(nav, /identifier: "tatwo\.dm\.chatgpt\.drawer\.loadMore"\)/);
  assert.match(nav, /只查了已載入的 \\\(directory\.directoryConversations\.count\) 則對話/);
  assert.match(nav, /let found = await directory\.directorySearch\(query\)/);
  // 審查 #6：組字中全部交回輸入法；只有沒修飾鍵的 ↑↓ 與 Enter 給清單；預設關（Coder 的 skill 建議照舊）。
  assert.match(bridges, /var suggestionKeysVerticalOnly = false/);
  assert.match(bridges, /if suggestionKeysVerticalOnly \{\s*guard !hasMarkedText\(\) else \{ return false \}\s*guard event\.modifierFlags\.intersection\(\[\.shift, \.option, \.command, \.control\]\)\.isEmpty else \{ return false \}/);
  assert.match(g3Layers, /suggestionKeysVerticalOnly: true\)/);
  // 審查 #7：看得到的 ChatGPT 抽屜、小卡、面板在「內橫右欄的網頁拿著鍵盤＝Esc 給網頁」之前收（組字、Browser 自己的面板、單欄 Browser 照舊在更前面）。
  const esc = slice(read('DM/GlobalDMPanelController.swift'), 'static func routeEscape(', '// MARK: - 換形態');
  const early = esc.indexOf('if store.dismissChatGPTLayers() { return nil }');
  assert.ok(early > esc.indexOf('if store.isBrowsing { return event }') && early < esc.indexOf('if store.isBrowsingBeside, let responder'), 'Esc order');
  assert.match(esc, /if !store\.isBrowsingBeside, GlobalDMDuo\.shared\.existing\?\.dismissChatGPTLayers\(\) == true \{ return nil \}/);
  // 審查 #8：Work 模式的對話不接著聊（網頁艙讀的時候標出來；帶歷史代號的送出也擋）。
  assert.match(tap, /if \(work\) \{ fail\('這則是 Work 模式的對話（跟 Codex 共用額度），這裡只做 Chat，不能接著聊'\); return; \}/);
  assert.match(tap, /isWork: \(data\["work"\] as\? Bool\) \?\? false/);
  assert.match(session, /if isWork \{ return Self\.workNotice \}/);
  // 主導 PNG 1：Esc 收起的「/」草稿改了就作廢（改回「/」也會再出來）。
  assert.match(dmStore, /if target == \.chatGPT, let dismissed = chatGPTSlashDismissed, dismissed != text \{ chatGPTSlashDismissed = nil \}/);
  // 主導 PNG 2：抽屜整支手機高（抽屜自己的底）。W184 G3c（使用者：「左側展開時會把對話筐推去右邊修正對話筐為不動」）蓋過「推開、稍暗的圓角卡」：
  // 守——抽屜蓋在上面、主畫面不移不暗不裁。
  const layer = slice(nav, 'struct GlobalDMChatGPTDrawerLayer<Directory: ChatGPTConversationDirectory>: ViewModifier', '/// W184 G3b 第二輪（審查 #2）');
  assert.match(nav, /\.background\(ChatGPTPalette\.drawerFill\)/);
  assert.match(layer, /\.frame\(width: drawerWidth, height: proxy\.size\.height\)/);
  assert.doesNotMatch(code(layer), /pushedDim|clipShape|\.offset\(x: open/);
  // 主導 PNG 3：膠囊的版本、檔位與 ⌄ 跟 Space 的膠囊同一套、同字級。W184 G3c：膠囊回到輸入框，頂列那時前面加的「ChatGPT」拿掉。
  assert.doesNotMatch(code(kit), /Text\("ChatGPT "\)/);
  assert.match(g3, /pickerText: DMPhone\.TextSize\.secondary/);
  // 行為測試（自測）都在：不是只看原始碼。
  const g3b = read('DM/GlobalDMChatGPTNavigationAcceptance.swift');
  for (const label of ['G3c the DM model capsule reads like ChatGPT Space\'s', 'G3c (drawn) the drawer is the whole phone\'s height',
    'G3b 第二輪 a conversation still loading cannot be sent to', 'G3b 第二輪 a failed read is not shown as an empty chat',
    'G3b 第二輪 a Work-mode conversation from the drawer', 'G3b 第二輪 same conversation in ChatGPT Space and the DM',
    'G3b 第二輪 a late attachment goes back to the conversation', 'G3b 第二輪 drawer list:', 'G3b 第二輪 「/」 before ChatGPT\'s list was ever read',
    'G3b 第二輪 (drawn) the 「/」 list is really on screen', 'G3b 第二輪 real key events', 'G3b 第二輪 Esc while the web page (CEF) holds the keyboard',
    'G3b 第二輪 (drawn) the 內橫 right column\'s ChatGPT']) {
    assert.ok(g3b.includes(label), label);
  }
  for (const png of ['chatgpt-duo-right.png', 'chatgpt-duo-right-model.png']) assert.ok(g3b.includes(`"${png}"`), png);
});

// ---- W184 G3c（使用者 09-30 02:4x 實測 .031）：ChatGPT 私訊框（≡、左緣槓、抽屜推開、右上隱私鈕、輸入框）與訊息上緣頂天 ----
// 畫面、動作與 PNG 在 `TATWO2_SELFTEST=w184chat` 的 G3c 那一段（DM/GlobalDMChatGPTG3cAcceptance.swift）。每一條旁邊寫守什麼。
test('G3c 臨時聊天 really reaches ChatGPT as a temporary chat (every message flagged, never listed); on/off from the top right; no voice inside', () => {
  const session = read('TAP/ChatGPTConversationSession.swift');
  const tap = read('TAP/ChatGPTTap.swift');
  // 守：session 記開關與送出後拿到的那一則；新對話看開關、之後看是不是臨時那一則——每一句都帶旗標（09-24 實機：第二句沒帶＝HTTP 404）。
  assert.match(session, /@Published var temporary = false\s*(?:\/\/[^\n]*\n\s*)*@Published var temporaryPersonalized = false\s*@Published private\(set\) var temporaryConversationID: String\?/);
  assert.match(session, /var isTemporary: Bool \{ conversationID == nil \? temporary : conversationID == temporaryConversationID \}/);
  assert.match(session, /case \.conversation\(let id\):\s*(?:\/\/[^\n]*\n\s*)*if conversationID == nil, temporary \{ temporaryConversationID = id \}\s*conversationID = id/);
  // 守：換對話、開新對話都回到一般（不會把別則當成臨時的送）。
  assert.match(slice(session, 'func open(conversationID id: String)', 'func retryLoad()'), /temporary = false/);
  assert.match(slice(session, 'func newConversation()', '// MARK: W184 G3：即時語音'), /temporary = false/);
  // 守：跟 ChatGPT Space 的臨時聊天同一條路——TAP 把旗標交給網頁艙，網頁艙在網頁自己的送出請求裡帶 history_and_training_disabled。
  assert.match(tap, /if temporary \{ payload\["temporary"\] = true \}/);
  assert.match(tap, /pendingTemporary = !!job\.temporary;/);
  assert.match(tap, /if \(pendingTemporary\) \{\s*body\.history_and_training_disabled = true;/);
  assert.match(space, /let temporary = selectedID == nil \? temporaryChat : selectedID == temporaryConversationID/);
  // 守：臨時的串流不記是哪一則、不發「這則剛送完」（清單不重讀、另一邊不去讀它）；一般的照舊。
  assert.match(tap, /if \(base\["temporary"\] as\? Bool\) == true \{\s*temporaryStreams\.insert\(id\)\s*\} else if let conversationID = base\["conversationID"\] as\? String \{\s*streamConversations\[id\] = conversationID/);
  assert.match(tap, /if !temporaryStreams\.contains\(id\) \{ streamConversations\[id\] = conversationID \}/);
  // W194 stop retains the stream through its receipt; both stop exits use the same cleanup.
  assert.match(tap, /finishStream\(stopped\)/);
  assert.match(slice(tap, 'private func resetAfterUnconfirmedStop()', 'func readyForSend('), /failPending\(/);
  for (const clear of [/streamConversations\.removeValue\(forKey: id\)\s*temporaryStreams\.remove\(id\)/,
    /streamConversations\.removeAll\(\)\s*temporaryStreams\.removeAll\(\)/]) {
    assert.match(tap, clear, 'finished, stopped and failed streams forget the temporary mark');
  }
  // 守：右上那一顆的動作——回答中、語音開著不換（說一句）；新對話＝開關；在有內容的一則裡按＝換一則新的，再照要的開或關。
  const toggle = slice(nav, 'func toggleChatGPTTemporary()', '/// 抽屜點了一則');
  assert.match(toggle, /if let blocker = chatGPTSwitchBlocker \{\s*showNotice\(blocker\)\s*return\s*\}/);
  assert.match(toggle, /let turnOn = !session\.isTemporary/);
  assert.match(toggle, /if session\.conversationID != nil \|\| !session\.messages\.isEmpty \{\s*guard newChatGPTConversation\(\) else \{ return \}\s*\}\s*session\.temporary = turnOn/);
  // 守：臨時聊天裡不開語音（語音在網頁開的是一般對話，會存進紀錄）；空白時是臨時聊天的說明（跟 Space 同一段字）＋這一句。
  assert.match(session, /var canStartVoice: Bool \{ requestID == nil && voice\.canStart && !isTemporary \}/);
  assert.match(nav, /static let voiceNote = "臨時聊天裡不開語音模式（語音會存進紀錄）。"/);
  assert.match(nav, /Text\(\(personalized \? ChatGPTTemporaryChatText\.personalizedNote : ChatGPTTemporaryChatText\.note\) \+ Self\.voiceNote\)/);
  assert.match(nav, /\.accessibilityIdentifier\("tatwo\.dm\.chatgpt\.temporaryNote"\)/);
  // 不寫死模型名、不用藍色系統鈕。
  assert.doesNotMatch(code(nav), /\.borderedProminent|\.blue\b|accentColor|GPT-\d/);
});

test('W194 message viewports avoid the floating top bar on every target; the shared frame and fade remain', () => {
  const list = slice(view, 'struct GlobalDMMessageList: View', 'struct GlobalDMComposer: View');
  // 守：捲動區延伸到框的上緣（負的上內距＝手機框給的值）——頂列那一段的列都畫得到（捲動區只畫跟它相交的列：只讓捲出上緣的不裁，
  // 整則捲到頂列底下的會不見，W184 G3c 第二輪量到）；上緣的漸淡在框的上緣；第一則上面多留同樣多（捲到最上面時在頂列下面）。
  // 用內容裡的內距，不用 contentMargins／safeArea（AppKit 那一層是 contentInsets，W184 F3T 的 H1、R2 量到捲動位置跑掉）。沒給這個值＝照舊。
  assert.match(list, /@Environment\(\\\.globalDMListBleed\) private var bleed/);
  assert.match(list, /\.padding\(\.top, -bleed\)\s*\.frame\(maxHeight: \.infinity\)/);
  assert.match(list, /let headerAvoidanceInset = max\(0, bleed\)/);
  assert.match(list, /\.padding\(\.top, topInset\)/);
  assert.doesNotMatch(code(list), /contentMargins|safeAreaPadding|safeAreaInset|scrollClipDisabled/);
  // 空白時的那一句照舊在頂列下面那一塊的正中間。
  assert.match(list, /\.frame\(width: geometry\.size\.width, height: max\(0, geometry\.size\.height - bleed\)\)\s*\.offset\(y: bleed\)/);
  assert.match(list, /private struct GlobalDMListBleedKey: EnvironmentKey \{\s*static let defaultValue: CGFloat = 0\s*\}/);
  // （F3T R2 的起點由房 AB 跟 R2 一起修：GPT-6 審查 G3c #4；這裡不釘 AB 的測試內部。）
  // 守：所有對象（助理、session、ChatGPT）都是這一個列表。
  assert.equal(count(view, 'GlobalDMMessageList(bubbles:'), 2, 'assistant/sessions and ChatGPT use the same list');
  // 守：手機框只動列表的範圍（插點標 W184 G3c）——欄在頂列底下一層、給列表頂列的高度；頂列本身不動（同一條、同一個位置、照舊可按）。
  const box = slice(phoneBox, 'struct GlobalDMPhoneBox: View', '// MARK: - 頂列');
  assert.match(box, /VStack\(spacing: 0\) \{\s*GlobalDMTopBar\(store: store, form: form\)\s*columns\(look, width: width\)\s*(?:\/\/[^\n]*\n\s*)*\.zIndex\(-1\)\s*\.environment\(\\\.globalDMListBleed, DMPhone\.headerHeight\)\s*\}/);
  assert.ok(box.includes('W184 G3c'), 'insertion points are marked');
  // 守：內橫右欄的裁切往上多留頂列那一段（右欄的列表也到框的上緣），左右照舊。
  assert.match(box, /\.padding\(\.top, DMPhone\.headerHeight\)\s*\.clipped\(\)\s*\.padding\(\.top, -DMPhone\.headerHeight\)/);
  // 守：內橫右欄的 ChatGPT 自己那一排（臨時聊天）蓋在列表上：內容照舊從它下面開始，列表多延伸這一段。
  assert.match(view, /private var controlsInset: CGFloat \{ ownsControls \? DMPhone\.headerBottom \+ DMPhone\.touch : 0 \}/);
  assert.match(view, /\.padding\(\.top, controlsInset\)\s*\.environment\(\\\.globalDMListBleed, listBleed \+ controlsInset\)/);
  // 守：抽屜那一層不裁主畫面（只裁抽屜），列表延伸上去不會被切掉。
  const layer = slice(nav, 'struct GlobalDMChatGPTDrawerLayer<Directory: ChatGPTConversationDirectory>: ViewModifier', '/// W184 G3b 第二輪（審查 #2）');
  assert.equal(count(code(layer), '.clipped()'), 1);
  // 自測：G3c 那一段接進 w184chat、PNG 都存、有反例；不開網頁、不連外、不叫出主視窗；範例不放使用者的東西。
  const acceptance = read('DM/GlobalDMChatAcceptance.swift');
  assert.match(acceptance, /for \(condition, label\) in await chatGPTG3cChecks\(root: root, model: model, artifacts: artifacts, axWorks: axWorks\) \{\s*check\(condition, label\)/);
  const g3c = read('DM/GlobalDMChatGPTG3cAcceptance.swift');
  assert.match(g3c, /^#if DEBUG/);
  assert.match(g3c, /GlobalDMPhoneBox\(store: store, model: model, surface: \.floating, form: form, secondary: secondary\)/);
  for (const png of ['chatgpt-g3c-main.png', 'chatgpt-temporary-on.png', 'chatgpt-temporary-off.png', 'chatgpt-composer-g3c.png',
    'assistant-composer-g3c.png', 'chatgpt-top-fade.png', 'chatgpt-top-scrolled.png', 'chatgpt-top-short.png', 'chatgpt-duo-top-fade.png',
    'assistant-top-fade.png']) {
    assert.ok(g3c.includes(`"${png}"`), png);
  }
  for (const label of ['G3c (drawn) no ≡ on the top bar and no handle drawn on the left edge', 'G3c 臨時聊天 really starts ChatGPT\'s temporary chat',
    'G3c 臨時聊天: voice mode stays off inside it', 'G3c while ChatGPT answers, 臨時聊天 does not switch', 'G3c 臨時聊天 off: pressing it again',
    'G3c (drawn) the icon shows the state', 'G3c 臨時聊天 in a normal conversation opens a new temporary chat',
    'G3c (drawn) the ChatGPT composer is the same glass capsule as the other targets', 'G3c the composer text stays ChatGPT Space\'s 15',
    'W194 (drawn) messages reserve the floating top bar', 'G3c the top bar stays on top', 'G3c scrolled to the top: the first message starts below the top bar',
    'W194 (drawn) short rows scrolling out of the viewport',
    'W194 (drawn) 內橫: both columns reserve the shared floating top bar', 'W194 (drawn) assistant／session conversations also reserve the floating header']) {
    assert.ok(g3c.includes(label), label);
  }
  // 反例寫在標籤裡（以前的樣子），沒有無條件的通過。
  assert.ok(g3c.includes('反例：.031'));
  assert.doesNotMatch(g3c, /NSPasteboard\.general|check\(true,|URLSession|https?:\/\/|NSApp\.activate/);
  const nav3 = read('DM/GlobalDMChatGPTNavigationAcceptance.swift');
  assert.ok(nav3.includes('G3c (drawn) the drawer covers the left side and the main screen stays put'));
  assert.ok(nav3.includes('反例：以前主畫面被推開'));
});

// ---- W184 G3c GPT-6 審查（/rooms/w183-handoff/w184g3c-gpt6-report.md）第 1、2、3、5 條 ----
test('G3c review #1: a temporary send is never let through unless the body actually sent carries history_and_training_disabled', () => {
  const tap = read('TAP/ChatGPTTap.swift');
  const session = read('TAP/ChatGPTConversationSession.swift');
  // 守（網頁艙）：臨時聊天先把非字串的 body 讀成字串（位元組、Blob、串流），改寫後讀回實際要送出的內容確認旗標；確認不了＝擋下（丟 AbortError、
  // 不叫原本的 fetch）、回報「擋下、沒有送出」；確認了先發 temporary 再送。反例測試在 tests/w177-chatgpt-space.test.mjs（改之前會送出）。
  assert.match(tap, /if \(job\.temporary\) init = await textBody\(init\);/);
  assert.match(tap, /if \(job\.temporary\) \{\s*const turn = turns\[job\.id\];\s*if \(!temporaryFlagged\(init\) \|\| \(job\.temporaryPersonalized === true && !personalizedContextOK\(job\)\)\) \{[\s\S]{0,300}throw abortError\(\);\s*\}\s*if \(turn\) turn\.temporaryConfirmed = true;\s*post\(\{ type: 'stream', id: job\.id, kind: 'temporary' \}\);/);
  assert.match(tap, /body\.history_and_training_disabled !== true\s*\|\| body\.is_do_not_remember !== false/);
  assert.match(tap, /body\.history_and_training_disabled === true/);
  // 守：沒確認的臨時一輪不回報對話代號；在網頁上完成了也算失敗（網頁走了別的路送出）。
  assert.match(tap, /if \(turn\.temporary && !turn\.temporaryConfirmed\) return;/);
  assert.match(tap, /if \(!failure && turn\.temporary && !turn\.temporaryConfirmed\) failure = TEMP_UNCONFIRMED;/);
  assert.match(tap, /temporary: !!\(pendingSend && pendingSend\.id === id && pendingSend\.temporary\), temporaryConfirmed: false/);
  // 守（App）：臨時的串流沒收到確認就來了接受／對話代號／回答／標題／完成＝當失敗、停下（對話代號不交給畫面）。
  assert.match(tap, /if temporaryStreams\.contains\(id\), !temporaryConfirmed\.contains\(id\),\s*\["accepted", "conversation", "text", "title", "progress", "activity", "finished"\]\.contains\(kind\) \{\s*continuation\.yield\(\.failed\(Self\.temporaryUnconfirmedReason\)\)\s*stop\(requestID: id\)/);
  assert.match(tap, /case "temporary":\s*if temporaryStreams\.contains\(id\) \{ temporaryConfirmed\.insert\(id\) \}/);
  // session 只在收到對話代號時記臨時的那一則（沒確認的不會送到這裡）。
  assert.match(session, /if conversationID == nil, temporary \{ temporaryConversationID = id \}/);

});

test('G3c review #2: without ≡ the keyboard still reaches the list (⌘⇧S, ChatGPT\'s toggle-sidebar key), focus goes in and comes back; ⌘⇧O new chat', () => {
  const panels = read('DM/GlobalDMPanelController.swift');
  // 守：只收 ⌘⇧S／⌘⇧O（認實體鍵位；帶 ⌥ 的直達鍵、⌥⌘Tab、⌥⌘T 不撞）；組字中、倒放、在設直達鍵、ChatGPT 那一欄不在畫面上照原本的路。
  assert.match(nav, /static let drawerKeyCode: UInt16 = 1/);
  assert.match(nav, /static let newChatKeyCode: UInt16 = 31/);
  assert.match(nav, /event\.modifierFlags\.intersection\(\[\.command, \.option, \.control, \.shift\]\) == \[\.command, \.shift\]/);
  assert.match(panels, /guard let event = self\.handleChatGPTKeys\(event\) else \{ return nil \}\s*(?:\/\/[^\n]*\n\s*)*guard let event = self\.handleNewTab\(event\) else \{ return nil \}\s*return self\.handleEscape\(event\)/);
  assert.match(panels, /guard drawer \|\| newChat, form != \.tent, !isComposing\(in: window\) else \{ return event \}/);
  assert.match(panels, /owner\.toggleChatGPTDrawerFromKeyboard\(\)/);
  // 守：鍵盤打開＝釘住＋抽屜把焦點拿進搜尋欄（↑↓ 選、Return 打開）；收起時輸入框那一層把焦點還回去。
  assert.match(nav, /func toggleChatGPTDrawerFromKeyboard\(\) \{[\s\S]{0,300}chatGPTDrawerKeyboard = true\s*openChatGPTDrawer\(pinned: true\)/);
  assert.match(nav, /@FocusState private var searchFocused: Bool/);
  assert.match(nav, /\.focused\(\$searchFocused\)/);
  assert.match(nav, /\.onKeyPress\(\.downArrow\)/);
  assert.match(nav, /\.onKeyPress\(\.upArrow\)/);
  assert.match(nav, /\.onSubmit \{ openKeyboardSelection\(\) \}/);
  assert.match(nav, /if store\.chatGPTDrawerKeyboard \{ focusSearch\(\) \}/);
  // VoiceOver 照舊從左緣那一格打開（識別碼 tatwo.dm.chatgpt.drawer）。
  assert.match(nav, /\.accessibilityAction \{ store\.openChatGPTDrawer\(pinned: true\) \}\s*\.accessibilityIdentifier\("tatwo\.dm\.chatgpt\.drawer"\)/);
  const g3c = read('DM/GlobalDMChatGPTG3cAcceptance.swift');
  for (const label of ['G3c keyboard: ⌘⇧S opens the ChatGPT conversation list pinned', 'G3c keyboard: with the input focused, ⌘⇧S moves focus into the list\'s search field',
    'G3c keyboard: ⌘⇧O starts a new chat']) {
    assert.ok(g3c.includes(label), label);
  }
});

test('G3c review #3: while the drawer covers the input, the input takes no keys and Return sends nothing; composing is never cut', () => {
  const store = read('DM/GlobalDMStore.swift');
  // 守：送出入口看抽屜（被蓋住的輸入框收到的 Return 不算數；草稿留著）。
  assert.match(store, /if isChatGPTDrawerOpen \{ return false \}/);
  // 守：抽屜開著時底下被蓋住的不給 VoiceOver。
  assert.match(nav, /\.accessibilityHidden\(open\)/);
  const native = read('Chat/ChatPageAppKitBridges.swift');
  assert.match(native, /var accessibilityHidden = false/);
  assert.equal((native.match(/updateAccessibility\(scrollView, textView: textView\)/g) ?? []).length, 2);
  for (const view of ['scrollView', 'scrollView.contentView', 'textView']) {
    assert.ok(native.includes(`${view}.setAccessibilityHidden(accessibilityHidden)`), view);
  }
  assert.match(native, /override func isAccessibilityElement\(\) -> Bool \{\s*!isAccessibilityHidden\(\)/);
  assert.match(g3, /accessibilityHidden: store\.isChatGPTDrawerOpen/);
  // 守：輸入框撤焦點（組字中等字選完再撤，候選字不丟）；收起時焦點還回去（開之前有焦點才還）。
  assert.match(g3, /\.onChange\(of: store\.isChatGPTDrawerOpen\) \{ _, open in\s*if open \{\s*if focused \{ refocusAfterDrawer = true \}\s*blurForDrawer\(\)\s*\} else if refocusAfterDrawer \{/);
  assert.match(g3, /while store\.isChatGPTDrawerOpen, textView\.view\?\.hasMarkedText\(\) == true \{/);
  assert.match(g3, /onTextView: \{ textView\.view = \$0 \}/);
  const g3c = read('DM/GlobalDMChatGPTG3cAcceptance.swift');
  for (const label of ['G3c drawer over the input: Return in the covered input sends nothing', 'G3c drawer while composing: the input keeps focus and its candidate']) {
    assert.ok(g3c.includes(label), label);
  }
});

test('G3c review #5: the top-bar button tests really click (both columns) and a transparent-mask counterexample proves they can fail', () => {
  const g3c = read('DM/GlobalDMChatGPTG3cAcceptance.swift');
  // 守：真的滑鼠事件（ClickRig：排進 App 的事件佇列），不是直接叫 store；左欄、內橫右欄各點各的；透明遮罩那一次不能變。
  assert.match(g3c, /let rig = TatwoComposerModeAcceptance\.ClickRig\(view, size: size\)/);
  assert.match(g3c, /await rig\.click\(spot\)/);
  assert.match(g3c, /Color\.black\.opacity\(0\.001\)\.contentShape\(Rectangle\(\)\)\.onTapGesture \{\}/);
  assert.match(g3c, /check\(leftPress\.toggled && leftPress\.back && !maskedPress\.toggled,/);
  assert.match(g3c, /check\(rightPress\.toggled && rightPress\.back && session\.isTemporary == leftBefore,/);
  // 守：點到的是 nil 不算過。
  assert.match(g3c, /check\(barHit != nil && buttonHit != nil && listHit != nil/);
});
